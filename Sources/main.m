#import <Cocoa/Cocoa.h>
#import <UserNotifications/UserNotifications.h>
#import <errno.h>
#import <fts.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *const DSAutomaticCleaning = @"automaticCleaning";
static NSString *const DSPeriodicCleaning = @"periodicCleaning";
static NSString *const DSPeriodicCleaningInterval = @"periodicCleaningInterval";
static NSString *const DSAppleDouble = @"appleDouble";
static NSString *const DSAppleDoubleExtensions = @"appleDoubleExtensions";
static NSString *const DSCustomFiles = @"customFiles";
static NSString *const DSCustomFileExtensions = @"customFileExtensions";
static NSString *const DSDSStore = @"dsStore";
static NSString *const DSTrashes = @"trashes";
static NSString *const DSSpotlight = @"spotlight";
static NSString *const DSFileEvents = @"fileEvents";
static NSString *const DSApdisk = @"apdisk";
static NSString *const DSVolumeIcon = @"volumeIcon";
static NSString *const DSDesktopIni = @"desktopIni";
static NSString *const DSThumbsDb = @"thumbsDb";
static NSString *const DSTemporaryItems = @"temporaryItems";
static NSString *const DSAppleDoubleDirectories = @"appleDoubleDirectories";
static NSString *const DSExcludedVolumes = @"excludedVolumes";
static NSString *const DSVolumeRules = @"volumeRules";
static NSString *const DSCleanupProfile = @"cleanupProfile";
static NSString *const DSProfileCrossPlatform = @"crossPlatform";
static NSString *const DSProfileMacMetadata = @"macMetadata";
static NSString *const DSProfileCustom = @"custom";
static NSString *const DSVolumeRuleExcluded = @"excluded";
static NSString *const DSVolumeRuleAutomatic = @"allowAutomatic";
static NSString *const DSVolumeRulePeriodic = @"allowPeriodic";
static NSString *const DSVolumeRuleName = @"name";
static NSUInteger DSPreviewFileTraversalCount = 0;

static NSArray<NSString *> *DSCleanupPreferenceKeys(void) {
    return @[
        DSAppleDouble, DSCustomFiles, DSDSStore, DSTrashes, DSSpotlight, DSFileEvents,
        DSApdisk, DSVolumeIcon, DSDesktopIni, DSThumbsDb, DSTemporaryItems,
        DSAppleDoubleDirectories
    ];
}

static BOOL DSIsPreviewTraversalExcludedRootDirectory(NSString *directoryName) {
    return [@[@".Trashes", @".Spotlight-V100", @".fseventsd", @".TemporaryItems"] containsObject:directoryName];
}

static NSString *DSCleanupReportLabel(NSString *key) {
    static NSDictionary<NSString *, NSString *> *labels;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        labels = @{
            DSAppleDouble: @"File ._* (AppleDouble)",
            DSCustomFiles: @"File con estensioni selezionate",
            DSDSStore: @"File .DS_Store",
            DSTrashes: @"Cartella .Trashes",
            DSSpotlight: @"Indice Spotlight",
            DSFileEvents: @"Registro .fseventsd",
            DSApdisk: @"File .apdisk",
            DSVolumeIcon: @"File .VolumeIcon.icns",
            DSDesktopIni: @"File Desktop.ini",
            DSThumbsDb: @"File Thumbs.db",
            DSTemporaryItems: @"Cartella .TemporaryItems",
            DSAppleDoubleDirectories: @"Cartelle .AppleDouble"
        };
    });
    return labels[key] ?: key;
}

static NSDictionary<NSString *, id> *DSDefaultPreferences(void) {
    return @{
        DSAutomaticCleaning: @NO,
        DSPeriodicCleaning: @NO,
        // Stored in minutes.  Values from the 0.4.5 releases were seconds and
        // are migrated transparently by periodicCleanupIntervalMinutes.
        DSPeriodicCleaningInterval: @60,
        DSAppleDouble: @YES,
        DSAppleDoubleExtensions: @"",
        DSCustomFiles: @NO,
        DSCustomFileExtensions: @[],
        DSDSStore: @YES,
        DSTrashes: @NO,
        DSSpotlight: @NO,
        DSFileEvents: @NO,
        DSApdisk: @NO,
        DSVolumeIcon: @NO,
        DSDesktopIni: @NO,
        DSThumbsDb: @NO,
        DSTemporaryItems: @NO,
        DSAppleDoubleDirectories: @NO,
        DSExcludedVolumes: @"",
        DSVolumeRules: @{},
        DSCleanupProfile: DSProfileCrossPlatform
    };
}

@interface DSFlippedView : NSView
@end

@implementation DSFlippedView
- (BOOL)isFlipped { return YES; }
@end

typedef NS_ENUM(NSUInteger, DSOperationKind) {
    DSOperationKindPreview,
    DSOperationKindCleanup
};

@interface DSOperationState : NSObject
@property (copy) NSString *identifier;
@property (copy) NSString *volumeIdentity;
@property (copy) NSString *volumeName;
@property (copy) NSURL *volumeURL;
@property DSOperationKind kind;
@property NSUInteger completedCategories;
@property NSUInteger totalCategories;
@property NSUInteger removedCount;
@property (copy) NSString *category;
@property (copy) NSString *safeLocation;
@property BOOL cancellationRequested;
@property BOOL automaticCleanup;
@property BOOL periodicCleanup;
@property NSTimeInterval lastUpdateTime;
@property (copy) void (^progressHandler)(DSOperationState *operation);
@end

@implementation DSOperationState
@end

@interface DSVolumeTarget : NSObject
@property (nonatomic, readonly, copy) NSURL *volumeURL;
@property (nonatomic, readonly, copy) NSString *mountIdentity;
- (instancetype)initWithVolumeURL:(NSURL *)volumeURL mountIdentity:(NSString *)mountIdentity;
@end

@implementation DSVolumeTarget

- (instancetype)initWithVolumeURL:(NSURL *)volumeURL mountIdentity:(NSString *)mountIdentity {
    self = [super init];
    if (self) {
        _volumeURL = [volumeURL copy];
        _mountIdentity = [mountIdentity copy];
    }
    return self;
}

@end

@interface DriveSweepController : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) NSWindow *dashboardWindow;
@property (strong) NSTextField *dashboardStatusLabel;
@property (strong) NSWindow *preferencesWindow;
@property (strong) NSTimer *scanTimer;
@property (strong) NSTimer *periodicCleanupTimer;
@property (strong) NSArray<NSURL *> *eligibleVolumes;
@property (strong) NSDictionary<NSString *, NSString *> *eligibleVolumeIdentities;
@property (strong) NSMutableSet<NSString *> *scheduledCleanupPaths;
@property (strong) NSMutableSet<NSString *> *handledMountIdentities;
@property dispatch_queue_t cleanupQueue;
@property (strong) NSScrollView *dashboardScrollView;
@property (strong) NSView *dashboardDocumentView;
@property (strong) NSButton *analyzeAllButton;
@property (strong) NSPopUpButton *profilePopup;
@property (strong) NSTextField *periodicIntervalTextField;
@property (strong) NSButton *scheduleButton;
@property (strong) NSMutableDictionary<NSString *, DSVolumeTarget *> *dashboardVolumeTargets;
@property (strong) NSMutableDictionary<NSString *, NSButton *> *preferenceCheckboxes;
@property (strong) NSMutableDictionary<NSString *, NSTextField *> *preferenceTextFields;
@property (nonatomic, copy) NSString *dashboardStatusMessage;
@property (strong) DSOperationState *activeOperation;
@property (strong) NSTextField *operationStatusLabel;
@property (strong) NSProgressIndicator *operationProgressIndicator;
@property (strong) NSButton *cancelOperationButton;
- (NSDictionary<NSString *, id> *)diskInfoForVolume:(NSURL *)url error:(NSError **)error;
- (NSDictionary<NSString *, id> *)cleanupOptionsSnapshot;
- (NSDictionary<NSString *, id> *)previewVolumeOnWorker:(NSURL *)volume expectedMountIdentity:(NSString *)expectedMountIdentity options:(NSDictionary<NSString *, id> *)options;
- (NSDictionary<NSString *, id> *)cleanVolumeOnWorker:(NSURL *)volume expectedMountIdentity:(NSString *)expectedMountIdentity options:(NSDictionary<NSString *, id> *)options;
- (BOOL)isVolumeExcludedForIdentity:(NSString *)identity;
- (BOOL)allowsAutomaticCleaningForIdentity:(NSString *)identity;
- (BOOL)allowsPeriodicCleaningForIdentity:(NSString *)identity;
- (void)setVolumeRuleForIdentity:(NSString *)identity name:(NSString *)name excluded:(BOOL)excluded allowAutomatic:(BOOL)allowAutomatic;
- (void)setPeriodicCleaning:(BOOL)allowed forIdentity:(NSString *)identity name:(NSString *)name;
@end

@implementation DriveSweepController

- (void)installApplicationMenu {
    NSMenu *menuBar = [[NSMenu alloc] initWithTitle:@"DriveSweep"];
    NSMenuItem *applicationItem = [[NSMenuItem alloc] initWithTitle:@"DriveSweep" action:nil keyEquivalent:@""];
    NSMenu *applicationMenu = [[NSMenu alloc] initWithTitle:@"DriveSweep"];
    NSMenuItem *open = [[NSMenuItem alloc] initWithTitle:@"Apri DriveSweep" action:@selector(showDashboard:) keyEquivalent:@"o"];
    open.target = self;
    [applicationMenu addItem:open];
    NSMenuItem *preferences = [[NSMenuItem alloc] initWithTitle:@"Preferenze…" action:@selector(showPreferences:) keyEquivalent:@","];
    preferences.target = self;
    [applicationMenu addItem:preferences];
    [applicationMenu addItem:[NSMenuItem separatorItem]];
    [applicationMenu addItemWithTitle:@"Nascondi DriveSweep" action:@selector(hide:) keyEquivalent:@"h"];
    [applicationMenu addItemWithTitle:@"Nascondi altre" action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
    [applicationMenu addItem:[NSMenuItem separatorItem]];
    [applicationMenu addItemWithTitle:@"Esci da DriveSweep" action:@selector(terminate:) keyEquivalent:@"q"];
    applicationItem.submenu = applicationMenu;
    [menuBar addItem:applicationItem];
    NSApp.mainMenu = menuBar;
}

- (NSInteger)periodicCleanupIntervalMinutes {
    NSNumber *value = [[NSUserDefaults standardUserDefaults] objectForKey:DSPeriodicCleaningInterval];
    NSInteger rawValue = value.integerValue;
    // 0.4.5 accepted only these four second values.  Restrict migration to
    // that exact legacy set so a valid new value such as 1,440 or 10,080
    // minutes is never mistaken for seconds after an app relaunch.
    NSSet<NSNumber *> *legacySeconds = [NSSet setWithArray:@[@(15 * 60), @(60 * 60), @(6 * 60 * 60), @(24 * 60 * 60)]];
    NSInteger minutes = [legacySeconds containsObject:@(rawValue)] ? rawValue / 60 : rawValue;
    return MAX(5, MIN(minutes ?: 60, 10080));
}

- (NSTimeInterval)periodicCleanupInterval {
    return [self periodicCleanupIntervalMinutes] * 60;
}

- (BOOL)periodicCleanupIsEnabled {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults boolForKey:DSPeriodicCleaning];
}

- (NSString *)periodicCleanupIntervalLabel {
    NSInteger minutes = [self periodicCleanupIntervalMinutes];
    return [NSString stringWithFormat:@"%ld %@", (long)minutes, minutes == 1 ? @"minuto" : @"minuti"];
}

- (void)configurePeriodicCleanupTimer {
    [self.periodicCleanupTimer invalidate];
    self.periodicCleanupTimer = nil;
    if (![self periodicCleanupIsEnabled]) return;
    self.periodicCleanupTimer = [NSTimer scheduledTimerWithTimeInterval:[self periodicCleanupInterval]
        target:self selector:@selector(runPeriodicCleanup:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.periodicCleanupTimer forMode:NSRunLoopCommonModes];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([self periodicCleanupIsEnabled]) [self runPeriodicCleanup:nil];
    });
}

- (void)startPeriodicCleanup:(id)sender {
    (void)sender;
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:DSPeriodicCleaning];
    [self configurePeriodicCleanupTimer];
    [self setDashboardStatusMessage:[NSString stringWithFormat:@"Pianificazione avviata: ogni %@.", [self periodicCleanupIntervalLabel]]];
    [self rebuildMenu];
}

- (void)stopPeriodicCleanup:(id)sender {
    (void)sender;
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:DSPeriodicCleaning];
    [self.periodicCleanupTimer invalidate];
    self.periodicCleanupTimer = nil;
    if (self.activeOperation.periodicCleanup) {
        @synchronized (self.activeOperation) { self.activeOperation.cancellationRequested = YES; }
    }
    [self setDashboardStatusMessage:@"Pianificazione fermata. Nessuna nuova pulizia periodica verrà avviata."];
    [self rebuildMenu];
}

- (void)togglePeriodicCleanup:(id)sender {
    if ([self periodicCleanupIsEnabled]) [self stopPeriodicCleanup:sender];
    else [self startPeriodicCleanup:sender];
}

- (NSArray<DSVolumeTarget *> *)periodicCleanupTargets {
    if (![self periodicCleanupIsEnabled] || self.activeOperation) return @[];
    NSMutableArray<DSVolumeTarget *> *targets = [NSMutableArray array];
    for (NSURL *url in self.eligibleVolumes) {
        NSString *identity = self.eligibleVolumeIdentities[url.path];
        if (!identity.length || [self.scheduledCleanupPaths containsObject:url.path]) continue;
        if ([self isVolumeExcludedForIdentity:identity] || ![self allowsPeriodicCleaningForIdentity:identity]) continue;
        [targets addObject:[[DSVolumeTarget alloc] initWithVolumeURL:url mountIdentity:identity]];
    }
    return targets.copy;
}

- (void)cleanNextPeriodicTarget:(NSArray<DSVolumeTarget *> *)targets index:(NSUInteger)index {
    if (![self periodicCleanupIsEnabled] || index >= targets.count) return;
    DSVolumeTarget *target = targets[index];
    [self cleanVolume:target.volumeURL source:@"pulizia periodica" expectedMountIdentity:target.mountIdentity completion:^(BOOL success) {
        (void)success;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self cleanNextPeriodicTarget:targets index:index + 1];
        });
    }];
}

- (void)runPeriodicCleanup:(NSTimer *)timer {
    (void)timer;
    NSArray<DSVolumeTarget *> *targets = [self periodicCleanupTargets];
    if (targets.count) [self cleanNextPeriodicTarget:targets index:0];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [[NSUserDefaults standardUserDefaults] registerDefaults:DSDefaultPreferences()];
    [self installApplicationMenu];

    self.eligibleVolumes = @[];
    self.eligibleVolumeIdentities = @{};
    self.scheduledCleanupPaths = [NSMutableSet set];
    self.handledMountIdentities = [NSMutableSet set];
    self.dashboardVolumeTargets = [NSMutableDictionary dictionary];
    self.preferenceCheckboxes = [NSMutableDictionary dictionary];
    self.preferenceTextFields = [NSMutableDictionary dictionary];
    self.cleanupQueue = dispatch_queue_create("com.github.naicud.drivesweep.cleanup", DISPATCH_QUEUE_SERIAL);
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSImage *menuIcon = [NSImage imageWithSystemSymbolName:@"broom.fill" accessibilityDescription:@"DriveSweep"];
    menuIcon.template = YES;
    self.statusItem.button.image = menuIcon;
    self.statusItem.button.toolTip = @"DriveSweep — pulisci dischi esterni";
    if (!menuIcon) self.statusItem.button.title = @"DS";
    [self rebuildMenu];
    [[UNUserNotificationCenter currentNotificationCenter]
        requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
        completionHandler:^(BOOL granted, NSError *error) {
            (void)granted;
            (void)error;
        }];

    NSNotificationCenter *workspaceCenter = [[NSWorkspace sharedWorkspace] notificationCenter];
    [workspaceCenter addObserver:self selector:@selector(volumeMounted:) name:NSWorkspaceDidMountNotification object:nil];
    [workspaceCenter addObserver:self selector:@selector(volumeUnmounted:) name:NSWorkspaceDidUnmountNotification object:nil];
    self.scanTimer = [NSTimer scheduledTimerWithTimeInterval:15 target:self selector:@selector(checkMountedVolumes) userInfo:nil repeats:YES];
    [self checkMountedVolumes];
    [self configurePeriodicCleanupTimer];
    [self showDashboard:nil];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.scanTimer invalidate];
    [self.periodicCleanupTimer invalidate];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)hasVisibleWindows {
    if (!hasVisibleWindows) [self showDashboard:nil];
    return YES;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return NO;
}

- (BOOL)windowShouldClose:(NSWindow *)window {
    if (window == self.dashboardWindow) {
        /*
         * The dashboard is the app's primary window.  Keeping it alive and
         * ordering it out gives Dock re-open a stable window to bring back;
         * closing a manually owned NSWindow on macOS 26 can leave AppKit's
         * later reopen event with a stale window reference.
         */
        [window orderOut:nil];
        return NO;
    }
    if (window == self.preferencesWindow) {
        [window orderOut:nil];
        return NO;
    }
    return YES;
}

- (NSArray<NSURL *> *)externalVolumes {
    NSArray *keys = @[NSURLVolumeNameKey, NSURLVolumeIsReadOnlyKey];
    NSArray<NSURL *> *mounted = [[NSFileManager defaultManager]
        mountedVolumeURLsIncludingResourceValuesForKeys:keys
        options:NSVolumeEnumerationSkipHiddenVolumes];
    NSMutableArray<NSURL *> *external = [NSMutableArray array];
    for (NSURL *url in mounted) {
        if ([self isEligibleExternalVolume:url error:nil]) [external addObject:url];
    }
    return external;
}

- (NSDictionary<NSString *, id> *)diskInfoForVolume:(NSURL *)url error:(NSError **)error {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/diskutil"];
    task.arguments = @[@"info", @"-plist", url.path];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        if (error) *error = launchError;
        return nil;
    }
    [task waitUntilExit];
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    if (task.terminationStatus != 0) {
        if (error) *error = [NSError errorWithDomain:@"DriveSweep" code:1 userInfo:@{NSLocalizedDescriptionKey: @"diskutil non ha potuto verificare il disco."}];
        return nil;
    }
    NSError *plistError = nil;
    NSDictionary *info = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:&plistError];
    if (![info isKindOfClass:NSDictionary.class]) {
        if (error) *error = plistError ?: [NSError errorWithDomain:@"DriveSweep" code:2 userInfo:@{NSLocalizedDescriptionKey: @"diskutil ha restituito dati non validi."}];
        return nil;
    }
    return info;
}

- (BOOL)isEligibleExternalVolume:(NSURL *)url error:(NSError **)error {
    NSNumber *readOnly = nil;
    [url getResourceValue:&readOnly forKey:NSURLVolumeIsReadOnlyKey error:nil];
    if (readOnly.boolValue) return NO;

    NSString *name = url.lastPathComponent ?: @"";
    NSString *excluded = [[NSUserDefaults standardUserDefaults] stringForKey:DSExcludedVolumes] ?: @"";
    for (NSString *rawCandidate in [excluded componentsSeparatedByString:@","]) {
        NSString *candidate = [rawCandidate stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (candidate.length && [candidate caseInsensitiveCompare:name] == NSOrderedSame) return NO;
    }

    NSDictionary *info = [self diskInfoForVolume:url error:error];
    if (!info) return NO;
    NSNumber *internal = info[@"Internal"];
    NSNumber *removableOrExternal = info[@"RemovableMediaOrExternalDevice"];
    NSNumber *systemImage = info[@"SystemImage"];
    NSNumber *writable = info[@"WritableVolume"];
    NSString *deviceIdentifier = info[@"DeviceIdentifier"];
    NSString *busProtocol = info[@"BusProtocol"];
    if ([busProtocol isKindOfClass:NSString.class] && [busProtocol caseInsensitiveCompare:@"Disk Image"] == NSOrderedSame) return NO;
    return internal && removableOrExternal && systemImage && writable && !internal.boolValue && removableOrExternal.boolValue && !systemImage.boolValue && writable.boolValue && deviceIdentifier.length > 0;
}

- (NSString *)mountIdentityForVolume:(NSURL *)url {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/diskutil"];
    task.arguments = @[@"info", @"-plist", url.path];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) return nil;
    [task waitUntilExit];
    if (task.terminationStatus != 0) return nil;
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    NSDictionary *info = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil];
    NSString *volumeUUID = info[@"VolumeUUID"];
    if (volumeUUID.length) return volumeUUID;
    NSString *diskUUID = info[@"DiskUUID"];
    return diskUUID.length ? diskUUID : nil;
}

- (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)volumeRules {
    NSDictionary *rules = [[NSUserDefaults standardUserDefaults] dictionaryForKey:DSVolumeRules];
    return [rules isKindOfClass:NSDictionary.class] ? rules : @{};
}

- (NSDictionary<NSString *, id> *)volumeRuleForIdentity:(NSString *)identity {
    if (!identity.length) return @{};
    NSDictionary *rule = [self volumeRules][identity];
    return [rule isKindOfClass:NSDictionary.class] ? rule : @{};
}

- (BOOL)isVolumeExcludedForIdentity:(NSString *)identity {
    return identity.length && [[self volumeRuleForIdentity:identity][DSVolumeRuleExcluded] boolValue];
}

- (BOOL)allowsAutomaticCleaningForIdentity:(NSString *)identity {
    return identity.length && [[self volumeRuleForIdentity:identity][DSVolumeRuleAutomatic] boolValue] && ![self isVolumeExcludedForIdentity:identity];
}

- (BOOL)allowsPeriodicCleaningForIdentity:(NSString *)identity {
    return identity.length && [[self volumeRuleForIdentity:identity][DSVolumeRulePeriodic] boolValue] && ![self isVolumeExcludedForIdentity:identity];
}

- (void)setVolumeRuleForIdentity:(NSString *)identity name:(NSString *)name excluded:(BOOL)excluded allowAutomatic:(BOOL)allowAutomatic {
    if (!identity.length) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *rules = [[self volumeRules] mutableCopy];
    NSMutableDictionary *rule = [[self volumeRuleForIdentity:identity] mutableCopy];
    if (excluded || allowAutomatic || [rule[DSVolumeRulePeriodic] boolValue]) {
        rule[DSVolumeRuleName] = name ?: @"";
        rule[DSVolumeRuleExcluded] = @(excluded);
        rule[DSVolumeRuleAutomatic] = @(allowAutomatic && !excluded);
        if (excluded) rule[DSVolumeRulePeriodic] = @NO;
        rules[identity] = rule.copy;
    } else {
        [rules removeObjectForKey:identity];
    }
    [defaults setObject:rules.copy forKey:DSVolumeRules];
}

- (void)setPeriodicCleaning:(BOOL)allowed forIdentity:(NSString *)identity name:(NSString *)name {
    if (!identity.length) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *rules = [[self volumeRules] mutableCopy];
    NSMutableDictionary *rule = [[self volumeRuleForIdentity:identity] mutableCopy];
    BOOL excluded = [rule[DSVolumeRuleExcluded] boolValue];
    if (allowed || excluded || [rule[DSVolumeRuleAutomatic] boolValue]) {
        rule[DSVolumeRuleName] = name ?: @"";
        rule[DSVolumeRuleExcluded] = @(excluded);
        rule[DSVolumeRuleAutomatic] = @([rule[DSVolumeRuleAutomatic] boolValue] && !excluded);
        rule[DSVolumeRulePeriodic] = @(allowed && !excluded);
        rules[identity] = rule.copy;
    } else {
        [rules removeObjectForKey:identity];
    }
    [defaults setObject:rules.copy forKey:DSVolumeRules];
}

- (NSString *)volumeRuleSummaryForIdentity:(NSString *)identity {
    if (!identity.length) return @"Identità non verificata — azioni bloccate";
    if ([self isVolumeExcludedForIdentity:identity]) return @"Escluso per questo disco";
    BOOL automatic = [self allowsAutomaticCleaningForIdentity:identity];
    BOOL periodic = [self allowsPeriodicCleaningForIdentity:identity];
    if (automatic && periodic) return @"Auto al mount + pianificazione attivi";
    if (periodic) return @"Incluso nella pianificazione";
    if (automatic) return @"Auto al mount consentito";
    return @"Nessuna pulizia automatica — consenso per disco richiesto";
}

- (void)setDashboardStatusMessage:(NSString *)message {
    _dashboardStatusMessage = [message copy];
    if (self.dashboardStatusLabel) self.dashboardStatusLabel.stringValue = _dashboardStatusMessage ?: @"";
}

- (NSUInteger)enabledCategoryCountForOptions:(NSDictionary<NSString *, id> *)options {
    NSUInteger count = 0;
    for (NSString *key in DSCleanupPreferenceKeys()) if ([self cleanupOption:key isEnabledInOptions:options]) count++;
    return count;
}

- (NSString *)safeLocationForURL:(NSURL *)url volume:(NSURL *)volume {
    if (!url || [url.path isEqualToString:volume.path]) return @"Radice del disco";
    NSString *name = url.lastPathComponent;
    return name.length ? [NSString stringWithFormat:@"Cartella in analisi: …/%@", name] : @"Cartella in analisi";
}

- (BOOL)operationShouldStop:(DSOperationState *)operation {
    if (!operation) return NO;
    @synchronized (operation) { return operation.cancellationRequested; }
}

- (NSString *)operationStatusText:(DSOperationState *)operation {
    if ([self operationShouldStop:operation]) {
        return [NSString stringWithFormat:@"Annullamento richiesto per %@: attendo che il filesystem termini la cartella in corso.", operation.volumeName];
    }
    NSString *verb = operation.kind == DSOperationKindPreview ? @"Analisi" : @"Pulizia";
    NSString *category = operation.category.length ? DSCleanupReportLabel(operation.category) : @"preparazione";
    NSString *location = operation.safeLocation.length ? [NSString stringWithFormat:@" · %@", operation.safeLocation] : @"";
    return [NSString stringWithFormat:@"%@ %@ · %@ (%lu di %lu)%@",
        verb, operation.volumeName, category, (unsigned long)operation.completedCategories, (unsigned long)operation.totalCategories, location];
}

- (void)updateOperationUI:(DSOperationState *)operation {
    if (operation != self.activeOperation) return;
    NSString *status = [self operationStatusText:operation];
    self.operationStatusLabel.stringValue = status;
    self.operationStatusLabel.accessibilityLabel = @"Stato operazione DriveSweep";
    self.operationStatusLabel.accessibilityValue = status;
    self.operationProgressIndicator.hidden = NO;
    self.operationProgressIndicator.indeterminate = NO;
    self.operationProgressIndicator.minValue = 0;
    self.operationProgressIndicator.maxValue = MAX(operation.totalCategories, 1);
    self.operationProgressIndicator.doubleValue = operation.completedCategories;
    self.operationProgressIndicator.accessibilityLabel = @"Categorie completate";
    self.operationProgressIndicator.accessibilityValue = [NSString stringWithFormat:@"%lu di %lu", (unsigned long)operation.completedCategories, (unsigned long)operation.totalCategories];
    self.cancelOperationButton.hidden = NO;
    self.cancelOperationButton.enabled = ![self operationShouldStop:operation];
    self.cancelOperationButton.accessibilityLabel = @"Annulla l'operazione in corso";
    [self rebuildMenu];
}

- (void)publishOperation:(DSOperationState *)operation category:(NSString *)category location:(NSURL *)location categoryFinished:(BOOL)categoryFinished force:(BOOL)force {
    if (!operation) return;
    BOOL shouldPublish = force;
    @synchronized (operation) {
        if (category.length) operation.category = category;
        if (location) operation.safeLocation = [self safeLocationForURL:location volume:operation.volumeURL];
        NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
        if (categoryFinished) operation.completedCategories++;
        if (force || now - operation.lastUpdateTime >= 0.25 || categoryFinished) {
            operation.lastUpdateTime = now;
            shouldPublish = YES;
        }
    }
    if (!shouldPublish) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [self updateOperationUI:operation]; });
}

- (void)recordRemovalForOperation:(DSOperationState *)operation {
    if (!operation) return;
    void (^handler)(DSOperationState *) = nil;
    @synchronized (operation) {
        operation.removedCount++;
        handler = operation.progressHandler;
    }
    if (handler) handler(operation);
}

- (DSOperationState *)beginOperationKind:(DSOperationKind)kind volume:(NSURL *)volume identity:(NSString *)identity options:(NSDictionary<NSString *, id> *)options {
    if (self.activeOperation) return nil;
    DSOperationState *operation = [[DSOperationState alloc] init];
    operation.identifier = NSUUID.UUID.UUIDString;
    operation.kind = kind;
    operation.volumeIdentity = identity ?: @"";
    operation.volumeName = volume.lastPathComponent ?: @"Disco esterno";
    operation.volumeURL = volume;
    operation.totalCategories = [self enabledCategoryCountForOptions:options];
    operation.safeLocation = @"Verifico il disco";
    self.activeOperation = operation;
    [self publishOperation:operation category:nil location:nil categoryFinished:NO force:YES];
    return operation;
}

- (void)finishOperation:(DSOperationState *)operation result:(NSDictionary<NSString *, id> *)result {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (operation != self.activeOperation) return;
        BOOL cancelled = [result[@"cancelled"] boolValue];
        NSString *message = cancelled
            ? [NSString stringWithFormat:@"Operazione annullata su %@: %lu elementi già rimossi.", operation.volumeName, (unsigned long)[result[@"removed"] unsignedIntegerValue]]
            : nil;
        if (message.length) [self setDashboardStatusMessage:message];
        self.activeOperation = nil;
        self.operationStatusLabel.stringValue = message ?: @"";
        self.operationProgressIndicator.hidden = YES;
        self.cancelOperationButton.hidden = YES;
        [self rebuildMenu];
    });
}

- (void)cancelActiveOperation:(id)sender {
    DSOperationState *operation = self.activeOperation;
    if (!operation) return;
    @synchronized (operation) { operation.cancellationRequested = YES; }
    [self updateOperationUI:operation];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (operation != self.activeOperation || ![self operationShouldStop:operation]) return;
        NSString *message = [NSString stringWithFormat:@"Annullamento richiesto per %@: il filesystem sta ancora terminando la cartella in corso. DriveSweep non forza l'interruzione.", operation.volumeName];
        self.operationStatusLabel.stringValue = message;
        self.operationStatusLabel.accessibilityValue = message;
        self.cancelOperationButton.enabled = NO;
    });
}

- (void)volumeMounted:(NSNotification *)notification {
    NSURL *url = notification.userInfo[NSWorkspaceVolumeURLKey];
    if (!url) return;
    [self checkMountedVolumes];
}

- (void)volumeUnmounted:(NSNotification *)notification {
    NSURL *url = notification.userInfo[NSWorkspaceVolumeURLKey];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (url) {
            [self.scheduledCleanupPaths removeObject:url.path];
            NSString *identity = self.eligibleVolumeIdentities[url.path];
            if (identity) [self.handledMountIdentities removeObject:identity];
        }
        [self checkMountedVolumes];
    });
}

- (void)checkMountedVolumes {
    dispatch_async(self.cleanupQueue, ^{
        NSArray<NSURL *> *volumes = [self externalVolumes];
        NSMutableDictionary<NSString *, NSString *> *identities = [NSMutableDictionary dictionary];
        for (NSURL *url in volumes) {
            NSString *identity = [self mountIdentityForVolume:url];
            if (identity) identities[url.path] = identity;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.eligibleVolumes = volumes;
            self.eligibleVolumeIdentities = identities;
            [self rebuildMenu];
            if ([[NSUserDefaults standardUserDefaults] boolForKey:DSAutomaticCleaning]) {
                for (NSURL *url in volumes) {
                    NSString *identity = identities[url.path];
                    if (![self allowsAutomaticCleaningForIdentity:identity] || [self.handledMountIdentities containsObject:identity]) continue;
                    [self.handledMountIdentities addObject:identity];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        if ([[NSUserDefaults standardUserDefaults] boolForKey:DSAutomaticCleaning]) {
                            [self cleanVolume:url source:@"montaggio automatico" expectedMountIdentity:identity completion:nil];
                        }
                    });
                }
            }
        });
    });
}

- (NSUInteger)removeNamedFiles:(NSString *)name fromVolume:(NSURL *)volume directoriesOnly:(BOOL)directoriesOnly errors:(NSMutableArray<NSString *> *)errors operation:(DSOperationState *)operation {
    NSFileManager *manager = [NSFileManager defaultManager];
    struct stat rootStatus;
    if (lstat(volume.fileSystemRepresentation, &rootStatus) != 0) {
        [errors addObject:[NSString stringWithFormat:@"%@ (%s)", volume.lastPathComponent, strerror(errno)]];
        return 0;
    }
    if (!S_ISDIR(rootStatus.st_mode) || S_ISLNK(rootStatus.st_mode)) {
        [errors addObject:[NSString stringWithFormat:@"%@ (la radice non è una directory sicura)", volume.lastPathComponent]];
        return 0;
    }
    NSDirectoryEnumerator *enumerator = [manager enumeratorAtURL:volume
        includingPropertiesForKeys:@[NSURLIsDirectoryKey]
        options:NSDirectoryEnumerationSkipsPackageDescendants
        errorHandler:^BOOL(NSURL *url, NSError *error) {
            [errors addObject:[NSString stringWithFormat:@"%@ (%@)", url.lastPathComponent, error.localizedDescription]];
            return YES;
        }];
    NSUInteger removed = 0;
    NSURL *item = nil;
    while ((item = [enumerator nextObject])) {
        if ([self operationShouldStop:operation]) break;
        [self publishOperation:operation category:nil location:item categoryFinished:NO force:NO];
        struct stat itemStatus;
        if (lstat(item.fileSystemRepresentation, &itemStatus) != 0) {
            [errors addObject:[NSString stringWithFormat:@"%@ (%s)", item.lastPathComponent, strerror(errno)]];
            continue;
        }
        BOOL itemIsDirectory = S_ISDIR(itemStatus.st_mode);
        BOOL itemIsRegularFile = S_ISREG(itemStatus.st_mode);
        BOOL deviceMatches = itemStatus.st_dev == rootStatus.st_dev;
        if (itemIsDirectory && [@[@".Trashes", @".Spotlight-V100", @".fseventsd"] containsObject:item.lastPathComponent]) {
            [enumerator skipDescendants];
        }
        if (![item.lastPathComponent isEqualToString:name]) continue;
        if (directoriesOnly != itemIsDirectory) continue;
        if (!deviceMatches || S_ISLNK(itemStatus.st_mode) || (!itemIsDirectory && !itemIsRegularFile)) {
            [errors addObject:[NSString stringWithFormat:@"%@ (obiettivo non sicuro, ignorato)", item.lastPathComponent]];
            if (itemIsDirectory) [enumerator skipDescendants];
            continue;
        }
        NSError *removeError = nil;
        if ([manager removeItemAtURL:item error:&removeError]) { removed++; [self recordRemovalForOperation:operation]; }
        else if (removeError) [errors addObject:[NSString stringWithFormat:@"%@ (%@)", item.lastPathComponent, removeError.localizedDescription]];
        if (itemIsDirectory) [enumerator skipDescendants];
    }
    if ([self operationShouldStop:operation]) return removed;
    NSURL *rootItem = [volume URLByAppendingPathComponent:name];
    struct stat rootItemStatus;
    if (lstat(rootItem.fileSystemRepresentation, &rootItemStatus) == 0) {
        BOOL rootIsDirectory = S_ISDIR(rootItemStatus.st_mode);
        BOOL rootIsRegularFile = S_ISREG(rootItemStatus.st_mode);
        if (rootItemStatus.st_dev != rootStatus.st_dev || S_ISLNK(rootItemStatus.st_mode) || directoriesOnly != rootIsDirectory || (!rootIsDirectory && !rootIsRegularFile)) {
            if (directoriesOnly == rootIsDirectory) [errors addObject:[NSString stringWithFormat:@"%@ (obiettivo radice non sicuro, ignorato)", rootItem.lastPathComponent]];
            return removed;
        }
        NSError *removeError = nil;
        if ([manager removeItemAtURL:rootItem error:&removeError]) { removed++; [self recordRemovalForOperation:operation]; }
        else if (removeError) [errors addObject:[NSString stringWithFormat:@"%@ (%@)", rootItem.lastPathComponent, removeError.localizedDescription]];
    } else if (errno != ENOENT) {
        [errors addObject:[NSString stringWithFormat:@"%@ (%s)", rootItem.lastPathComponent, strerror(errno)]];
    }
    return removed;
}

- (NSUInteger)removeRootDirectory:(NSString *)name fromVolume:(NSURL *)volume errors:(NSMutableArray<NSString *> *)errors operation:(DSOperationState *)operation {
    if ([self operationShouldStop:operation]) return 0;
    struct stat rootStatus;
    if (lstat(volume.fileSystemRepresentation, &rootStatus) != 0) {
        [errors addObject:[NSString stringWithFormat:@"%@ (%s)", volume.lastPathComponent, strerror(errno)]];
        return 0;
    }
    if (!S_ISDIR(rootStatus.st_mode) || S_ISLNK(rootStatus.st_mode)) {
        [errors addObject:[NSString stringWithFormat:@"%@ (la radice non è una directory sicura)", volume.lastPathComponent]];
        return 0;
    }
    NSURL *target = [volume URLByAppendingPathComponent:name];
    struct stat targetStatus;
    if (lstat(target.fileSystemRepresentation, &targetStatus) != 0) {
        if (errno != ENOENT) [errors addObject:[NSString stringWithFormat:@"%@ (%s)", name, strerror(errno)]];
        return 0;
    }
    if (!S_ISDIR(targetStatus.st_mode) || S_ISLNK(targetStatus.st_mode) || targetStatus.st_dev != rootStatus.st_dev) {
        [errors addObject:[NSString stringWithFormat:@"%@ (obiettivo non sicuro, ignorato)", name]];
        return 0;
    }
    NSError *removeError = nil;
    if ([[NSFileManager defaultManager] removeItemAtURL:target error:&removeError]) { [self recordRemovalForOperation:operation]; return 1; }
    if (removeError) [errors addObject:[NSString stringWithFormat:@"%@ (%@)", name, removeError.localizedDescription]];
    return 0;
}

- (NSSet<NSString *> *)protectedAppleDoubleExtensionsFromValue:(NSString *)value {
    NSMutableSet<NSString *> *extensions = [NSMutableSet set];
    for (NSString *rawExtension in [value componentsSeparatedByString:@","]) {
        NSString *extension = [[rawExtension stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
        if ([extension hasPrefix:@"."]) extension = [extension substringFromIndex:1];
        if (extension.length) [extensions addObject:extension];
    }
    return extensions.copy;
}

- (NSSet<NSString *> *)normalizedCustomFileExtensionsFromValue:(id)value {
    NSArray *rawExtensions = nil;
    if ([value isKindOfClass:[NSArray class]]) rawExtensions = value;
    else if ([value isKindOfClass:[NSString class]]) rawExtensions = [value componentsSeparatedByString:@","];
    else rawExtensions = @[];

    NSMutableSet<NSString *> *extensions = [NSMutableSet set];
    NSCharacterSet *whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    for (id rawValue in rawExtensions) {
        if (![rawValue isKindOfClass:[NSString class]]) continue;
        NSString *extension = [rawValue lowercaseString];
        if ([extension hasPrefix:@"."]) extension = [extension substringFromIndex:1];
        if (!extension.length || extension.length > 32 ||
            [extension rangeOfCharacterFromSet:whitespace].location != NSNotFound ||
            [extension rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\*?[]"]].location != NSNotFound ||
            [extension containsString:@"."]) continue;
        [extensions addObject:extension];
    }
    return extensions.copy;
}

- (NSDictionary<NSString *, id> *)cleanupOptionsSnapshot {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary<NSString *, id> *options = [NSMutableDictionary dictionary];
    for (NSString *key in DSCleanupPreferenceKeys()) options[key] = @([defaults boolForKey:key]);
    NSString *extensionValue = [defaults stringForKey:DSAppleDoubleExtensions] ?: @"";
    options[DSAppleDoubleExtensions] = [self protectedAppleDoubleExtensionsFromValue:extensionValue];
    options[DSCustomFileExtensions] = [self normalizedCustomFileExtensionsFromValue:[defaults objectForKey:DSCustomFileExtensions]];
    return options.copy;
}

- (BOOL)cleanupOption:(NSString *)key isEnabledInOptions:(NSDictionary<NSString *, id> *)options {
    if ([key isEqualToString:DSCustomFiles]) return [options[key] boolValue] && [options[DSCustomFileExtensions] count] > 0;
    return [options[key] boolValue];
}

- (NSString *)cleanupProfileDisplayName:(NSString *)profile {
    if ([profile isEqualToString:DSProfileMacMetadata]) return @"Conserva metadati Mac";
    if ([profile isEqualToString:DSProfileCustom]) return @"Personalizzato";
    return @"Condivisione multipiattaforma";
}

- (NSString *)cleanupProfileDescription:(NSString *)profile {
    if ([profile isEqualToString:DSProfileMacMetadata]) return @"Conserva AppleDouble e altri metadati Mac; rimuove solo .DS_Store.";
    if ([profile isEqualToString:DSProfileCustom]) return @"Mantiene esattamente i toggle scelti manualmente.";
    return @"Prepara il disco per Mac/Windows/Linux: rimuove ._* e .DS_Store.";
}

- (void)selectProfile:(NSString *)profile inPopup:(NSPopUpButton *)popup {
    for (NSUInteger index = 0; index < popup.itemArray.count; index++) {
        NSMenuItem *item = popup.itemArray[index];
        if ([item.representedObject isEqual:profile]) {
            [popup selectItemAtIndex:index];
            return;
        }
    }
}

- (void)applyCleanupProfile:(NSString *)profile {
    if (!profile.length) profile = DSProfileCrossPlatform;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![profile isEqualToString:DSProfileCustom]) {
        BOOL crossPlatform = [profile isEqualToString:DSProfileCrossPlatform];
        for (NSString *key in DSCleanupPreferenceKeys()) {
            BOOL enabled = [key isEqualToString:DSDSStore] || (crossPlatform && [key isEqualToString:DSAppleDouble]);
            [defaults setBool:enabled forKey:key];
        }
    }
    [defaults setObject:profile forKey:DSCleanupProfile];
    [self refreshPreferenceControls];
    [self rebuildMenu];
}

- (void)resetSafeDefaults:(id)sender {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary<NSString *, id> *safe = DSDefaultPreferences();
    [defaults setBool:[safe[DSAutomaticCleaning] boolValue] forKey:DSAutomaticCleaning];
    [defaults setBool:[safe[DSPeriodicCleaning] boolValue] forKey:DSPeriodicCleaning];
    [defaults setObject:safe[DSPeriodicCleaningInterval] forKey:DSPeriodicCleaningInterval];
    for (NSString *key in DSCleanupPreferenceKeys()) [defaults setBool:[safe[key] boolValue] forKey:key];
    [defaults setObject:safe[DSAppleDoubleExtensions] forKey:DSAppleDoubleExtensions];
    [defaults setObject:safe[DSCustomFileExtensions] forKey:DSCustomFileExtensions];
    [defaults setObject:safe[DSCleanupProfile] forKey:DSCleanupProfile];
    [self selectProfile:DSProfileCrossPlatform inPopup:self.profilePopup];
    [self configurePeriodicCleanupTimer];
    [self refreshPreferenceControls];
    [self rebuildMenu];
    [self notify:@"Impostazioni sicure ripristinate. Le regole per singolo disco non sono state modificate."];
}

- (void)profileSelectionChanged:(NSPopUpButton *)sender {
    NSString *profile = sender.selectedItem.representedObject;
    [self applyCleanupProfile:profile ?: DSProfileCustom];
}

- (NSUInteger)removeAppleDoubleFilesFromVolume:(NSURL *)volume protectedExtensions:(NSSet<NSString *> *)protectedExtensions errors:(NSMutableArray<NSString *> *)errors operation:(DSOperationState *)operation {
    [self publishOperation:operation category:nil location:volume categoryFinished:NO force:YES];
    if ([self operationShouldStop:operation]) return 0;
    char *paths[] = { (char *)volume.fileSystemRepresentation, NULL };
    FTS *tree = fts_open(paths, FTS_NOCHDIR | FTS_PHYSICAL | FTS_XDEV, NULL);
    if (!tree) {
        [errors addObject:[NSString stringWithFormat:@"%@ (%s)", volume.lastPathComponent, strerror(errno)]];
        return 0;
    }
    NSUInteger removed = 0;
    FTSENT *entry = nil;
    while ((entry = fts_read(tree))) {
        if ([self operationShouldStop:operation]) break;
        NSURL *entryURL = [NSURL fileURLWithFileSystemRepresentation:entry->fts_accpath isDirectory:NO relativeToURL:nil];
        [self publishOperation:operation category:nil location:entryURL categoryFinished:NO force:NO];
        if (entry->fts_info == FTS_D) {
            NSNumber *isPackage = nil;
            NSURL *directoryURL = [NSURL fileURLWithFileSystemRepresentation:entry->fts_path isDirectory:YES relativeToURL:nil];
            [directoryURL getResourceValue:&isPackage forKey:NSURLIsPackageKey error:nil];
            if (isPackage.boolValue) {
                fts_set(tree, entry, FTS_SKIP);
                continue;
            }
        }
        if (entry->fts_info == FTS_DNR || entry->fts_info == FTS_ERR) {
            [errors addObject:[NSString stringWithFormat:@"%s (%s)", entry->fts_path, strerror(entry->fts_errno)]];
            continue;
        }
        if (entry->fts_info != FTS_F) continue;
        NSString *name = [NSString stringWithUTF8String:entry->fts_name];
        if (![name hasPrefix:@"._"]) continue;
        NSString *extension = [[name substringFromIndex:2].pathExtension lowercaseString];
        if ([protectedExtensions containsObject:extension]) continue;
        if (unlink(entry->fts_accpath) == 0) { removed++; [self recordRemovalForOperation:operation]; }
        else [errors addObject:[NSString stringWithFormat:@"%@ (%s)", name, strerror(errno)]];
    }
    fts_close(tree);
    return removed;
}

- (NSUInteger)removeCustomExtensionFilesFromVolume:(NSURL *)volume extensions:(NSSet<NSString *> *)extensions errors:(NSMutableArray<NSString *> *)errors operation:(DSOperationState *)operation {
    if (!extensions.count || [self operationShouldStop:operation]) return 0;
    struct stat rootStatus;
    if (lstat(volume.fileSystemRepresentation, &rootStatus) != 0) {
        [errors addObject:[NSString stringWithFormat:@"%@ (%s)", volume.lastPathComponent, strerror(errno)]];
        return 0;
    }
    if (!S_ISDIR(rootStatus.st_mode) || S_ISLNK(rootStatus.st_mode)) {
        [errors addObject:[NSString stringWithFormat:@"%@ (la radice non è una directory sicura)", volume.lastPathComponent]];
        return 0;
    }

    char *paths[] = { (char *)volume.fileSystemRepresentation, NULL };
    FTS *tree = fts_open(paths, FTS_NOCHDIR | FTS_PHYSICAL | FTS_XDEV, NULL);
    if (!tree) {
        [errors addObject:[NSString stringWithFormat:@"%@ (%s)", volume.lastPathComponent, strerror(errno)]];
        return 0;
    }
    NSUInteger removed = 0;
    FTSENT *entry = nil;
    while ((entry = fts_read(tree))) {
        if ([self operationShouldStop:operation]) break;
        NSURL *entryURL = [NSURL fileURLWithFileSystemRepresentation:entry->fts_path isDirectory:entry->fts_info == FTS_D relativeToURL:nil];
        [self publishOperation:operation category:nil location:entryURL categoryFinished:NO force:NO];
        if (entry->fts_info == FTS_D) {
            NSNumber *isPackage = nil;
            [entryURL getResourceValue:&isPackage forKey:NSURLIsPackageKey error:nil];
            NSString *directoryName = [NSString stringWithUTF8String:entry->fts_name];
            if (isPackage.boolValue || DSIsPreviewTraversalExcludedRootDirectory(directoryName)) fts_set(tree, entry, FTS_SKIP);
            continue;
        }
        if (entry->fts_info == FTS_DNR || entry->fts_info == FTS_ERR) {
            [errors addObject:[NSString stringWithFormat:@"%s (%s)", entry->fts_path, strerror(entry->fts_errno)]];
            continue;
        }
        if (entry->fts_info != FTS_F) continue;
        struct stat itemStatus;
        if (lstat(entry->fts_accpath, &itemStatus) != 0) {
            [errors addObject:[NSString stringWithFormat:@"%s (%s)", entry->fts_path, strerror(errno)]];
            continue;
        }
        if (!S_ISREG(itemStatus.st_mode) || S_ISLNK(itemStatus.st_mode) || itemStatus.st_dev != rootStatus.st_dev) continue;
        NSString *name = [NSString stringWithUTF8String:entry->fts_name];
        if (![extensions containsObject:name.pathExtension.lowercaseString]) continue;
        if (unlink(entry->fts_accpath) == 0) { removed++; [self recordRemovalForOperation:operation]; }
        else [errors addObject:[NSString stringWithFormat:@"%@ (%s)", name, strerror(errno)]];
    }
    fts_close(tree);
    return removed;
}

- (NSUInteger)countNamedFiles:(NSString *)name fromVolume:(NSURL *)volume directoriesOnly:(BOOL)directoriesOnly errors:(NSMutableArray<NSString *> *)errors operation:(DSOperationState *)operation {
    NSFileManager *manager = [NSFileManager defaultManager];
    struct stat rootStatus;
    if (lstat(volume.fileSystemRepresentation, &rootStatus) != 0) {
        [errors addObject:[NSString stringWithFormat:@"%@ (%s)", volume.lastPathComponent, strerror(errno)]];
        return 0;
    }
    NSMutableSet<NSString *> *matchedPaths = [NSMutableSet set];
    NSDirectoryEnumerator *enumerator = [manager enumeratorAtURL:volume
        includingPropertiesForKeys:@[NSURLIsDirectoryKey]
        options:NSDirectoryEnumerationSkipsPackageDescendants
        errorHandler:^BOOL(NSURL *url, NSError *error) {
            [errors addObject:[NSString stringWithFormat:@"%@ (%@)", url.lastPathComponent, error.localizedDescription]];
            return YES;
        }];
    NSURL *item = nil;
    while ((item = [enumerator nextObject])) {
        if ([self operationShouldStop:operation]) break;
        [self publishOperation:operation category:nil location:item categoryFinished:NO force:NO];
        NSNumber *isDirectory = nil;
        [item getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
        struct stat itemStatus;
        if (lstat(item.fileSystemRepresentation, &itemStatus) != 0) {
            [errors addObject:[NSString stringWithFormat:@"%@ (%s)", item.lastPathComponent, strerror(errno)]];
            continue;
        }
        if (itemStatus.st_dev != rootStatus.st_dev) {
            if (isDirectory.boolValue) [enumerator skipDescendants];
            continue;
        }
        if (isDirectory.boolValue && [@[@".Trashes", @".Spotlight-V100", @".fseventsd"] containsObject:item.lastPathComponent]) {
            [enumerator skipDescendants];
        }
        if ([item.lastPathComponent isEqualToString:name] && directoriesOnly == isDirectory.boolValue) {
            [matchedPaths addObject:item.path];
        }
    }
    NSURL *rootItem = [volume URLByAppendingPathComponent:name];
    BOOL rootIsDirectory = NO;
    if ([manager fileExistsAtPath:rootItem.path isDirectory:&rootIsDirectory] && directoriesOnly == rootIsDirectory) {
        [matchedPaths addObject:rootItem.path];
    }
    return matchedPaths.count;
}

- (NSUInteger)countRootDirectory:(NSString *)name fromVolume:(NSURL *)volume errors:(NSMutableArray<NSString *> *)errors operation:(DSOperationState *)operation {
    if ([self operationShouldStop:operation]) return 0;
    NSURL *target = [volume URLByAppendingPathComponent:name];
    BOOL isDirectory = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:target.path isDirectory:&isDirectory] && isDirectory) return 1;
    return 0;
}

- (NSDictionary<NSString *, NSNumber *> *)countAppleDoubleFilesFromVolume:(NSURL *)volume protectedExtensions:(NSSet<NSString *> *)protectedExtensions errors:(NSMutableArray<NSString *> *)errors operation:(DSOperationState *)operation {
    [self publishOperation:operation category:nil location:volume categoryFinished:NO force:YES];
    if ([self operationShouldStop:operation]) return @{ @"removable": @0, @"protected": @0 };
    char *paths[] = { (char *)volume.fileSystemRepresentation, NULL };
    FTS *tree = fts_open(paths, FTS_NOCHDIR | FTS_PHYSICAL | FTS_XDEV, NULL);
    if (!tree) {
        [errors addObject:[NSString stringWithFormat:@"%@ (%s)", volume.lastPathComponent, strerror(errno)]];
        return @{ @"removable": @0, @"protected": @0 };
    }
    NSUInteger removable = 0;
    NSUInteger protectedCount = 0;
    FTSENT *entry = nil;
    while ((entry = fts_read(tree))) {
        if ([self operationShouldStop:operation]) break;
        NSURL *entryURL = [NSURL fileURLWithFileSystemRepresentation:entry->fts_accpath isDirectory:NO relativeToURL:nil];
        [self publishOperation:operation category:nil location:entryURL categoryFinished:NO force:NO];
        if (entry->fts_info == FTS_DNR || entry->fts_info == FTS_ERR) {
            [errors addObject:[NSString stringWithFormat:@"%s (%s)", entry->fts_path, strerror(entry->fts_errno)]];
            continue;
        }
        if (entry->fts_info != FTS_F) continue;
        NSString *name = [NSString stringWithUTF8String:entry->fts_name];
        if (![name hasPrefix:@"._"]) continue;
        NSString *extension = [[name substringFromIndex:2].pathExtension lowercaseString];
        if ([protectedExtensions containsObject:extension]) protectedCount++;
        else removable++;
    }
    fts_close(tree);
    return @{ @"removable": @(removable), @"protected": @(protectedCount) };
}

- (NSDictionary<NSString *, id> *)previewFileCountsOnePassFromVolume:(NSURL *)volume options:(NSDictionary<NSString *, id> *)options errors:(NSMutableArray<NSString *> *)errors operation:(DSOperationState *)operation {
    DSPreviewFileTraversalCount++;
    [self publishOperation:operation category:DSAppleDouble location:volume categoryFinished:NO force:YES];
    if ([self operationShouldStop:operation]) return @{ @"cancelled": @YES, @"counts": @{}, @"protected": @0 };
    char *paths[] = { (char *)volume.fileSystemRepresentation, NULL };
    FTS *tree = fts_open(paths, FTS_NOCHDIR | FTS_PHYSICAL | FTS_XDEV, NULL);
    if (!tree) {
        [errors addObject:[NSString stringWithFormat:@"%@ (%s)", volume.lastPathComponent, strerror(errno)]];
        return @{ @"cancelled": @NO, @"counts": @{}, @"protected": @0 };
    }
    struct stat rootStatus;
    if (lstat(volume.fileSystemRepresentation, &rootStatus) != 0 || !S_ISDIR(rootStatus.st_mode) || S_ISLNK(rootStatus.st_mode)) {
        [errors addObject:[NSString stringWithFormat:@"%@ (la radice non è una directory sicura)", volume.lastPathComponent]];
        fts_close(tree);
        return @{ @"cancelled": @NO, @"counts": @{}, @"protected": @0 };
    }
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    for (NSString *key in DSCleanupPreferenceKeys()) counts[key] = @0;
    NSUInteger protectedCount = 0;
    NSSet<NSString *> *protectedExtensions = options[DSAppleDoubleExtensions];
    NSDictionary<NSString *, NSString *> *fileNames = @{ DSDSStore: @".DS_Store", DSApdisk: @".apdisk", DSVolumeIcon: @".VolumeIcon.icns", DSDesktopIni: @"Desktop.ini", DSThumbsDb: @"Thumbs.db" };
    FTSENT *entry = nil;
    while ((entry = fts_read(tree))) {
        if ([self operationShouldStop:operation]) break;
        NSURL *entryURL = [NSURL fileURLWithFileSystemRepresentation:entry->fts_path isDirectory:entry->fts_info == FTS_D relativeToURL:nil];
        [self publishOperation:operation category:nil location:entryURL categoryFinished:NO force:NO];
        if (entry->fts_info == FTS_D) {
            NSNumber *isPackage = nil;
            [entryURL getResourceValue:&isPackage forKey:NSURLIsPackageKey error:nil];
            NSString *directoryName = [NSString stringWithUTF8String:entry->fts_name];
            if (isPackage.boolValue || DSIsPreviewTraversalExcludedRootDirectory(directoryName)) {
                fts_set(tree, entry, FTS_SKIP);
            }
            if ([self cleanupOption:DSAppleDoubleDirectories isEnabledInOptions:options] && [directoryName isEqualToString:@".AppleDouble"]) {
                counts[DSAppleDoubleDirectories] = @([counts[DSAppleDoubleDirectories] unsignedIntegerValue] + 1);
            }
            continue;
        }
        if (entry->fts_info == FTS_DNR || entry->fts_info == FTS_ERR) {
            [errors addObject:[NSString stringWithFormat:@"%s (%s)", entry->fts_path, strerror(entry->fts_errno)]];
            continue;
        }
        if (entry->fts_info != FTS_F) continue;
        if (!entry->fts_statp || !S_ISREG(entry->fts_statp->st_mode) || entry->fts_statp->st_dev != rootStatus.st_dev) continue;
        NSString *name = [NSString stringWithUTF8String:entry->fts_name];
        if ([self cleanupOption:DSAppleDouble isEnabledInOptions:options] && [name hasPrefix:@"._"]) {
            NSString *extension = [[name substringFromIndex:2].pathExtension lowercaseString];
            if ([protectedExtensions containsObject:extension]) protectedCount++;
            else counts[DSAppleDouble] = @([counts[DSAppleDouble] unsignedIntegerValue] + 1);
        }
        if ([self cleanupOption:DSCustomFiles isEnabledInOptions:options] &&
            [options[DSCustomFileExtensions] containsObject:name.pathExtension.lowercaseString]) {
            counts[DSCustomFiles] = @([counts[DSCustomFiles] unsignedIntegerValue] + 1);
        }
        for (NSString *key in fileNames) {
            if ([self cleanupOption:key isEnabledInOptions:options] && [name isEqualToString:fileNames[key]]) {
                counts[key] = @([counts[key] unsignedIntegerValue] + 1);
            }
        }
    }
    fts_close(tree);
    return @{ @"cancelled": @([self operationShouldStop:operation]), @"counts": counts.copy, @"protected": @(protectedCount) };
}

- (NSDictionary<NSString *, id> *)previewVolumeOnWorker:(NSURL *)volume expectedMountIdentity:(NSString *)expectedMountIdentity options:(NSDictionary<NSString *, id> *)options {
    return [self previewVolumeOnWorker:volume expectedMountIdentity:expectedMountIdentity options:options operation:nil];
}

- (NSDictionary<NSString *, id> *)cancelledPreviewResult:(NSMutableDictionary<NSString *, NSNumber *> *)counts errors:(NSArray<NSString *> *)errors {
    return @{ @"success": @NO, @"cancelled": @YES, @"counts": counts.copy, @"protectedAppleDouble": @0, @"errors": errors ?: @[] };
}

- (NSDictionary<NSString *, id> *)previewVolumeOnWorker:(NSURL *)volume expectedMountIdentity:(NSString *)expectedMountIdentity options:(NSDictionary<NSString *, id> *)options operation:(DSOperationState *)operation {
    NSError *eligibilityError = nil;
    if (![self isEligibleExternalVolume:volume error:&eligibilityError]) {
        NSString *message = eligibilityError.localizedDescription ?: @"Il disco non è più un volume esterno fisico scrivibile.";
        return @{ @"success": @NO, @"counts": @{}, @"protectedAppleDouble": @0, @"errors": @[message] };
    }
    if (expectedMountIdentity && ![[self mountIdentityForVolume:volume] isEqualToString:expectedMountIdentity]) {
        return @{ @"success": @NO, @"counts": @{}, @"protectedAppleDouble": @0, @"errors": @[@"Il disco è stato smontato o la sua identità è cambiata prima dell'analisi."] };
    }
    if ([self isVolumeExcludedForIdentity:expectedMountIdentity]) {
        return @{ @"success": @NO, @"counts": @{}, @"protectedAppleDouble": @0, @"errors": @[@"Il disco è escluso dalle regole di DriveSweep."] };
    }
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    NSUInteger protectedAppleDouble = 0;
    for (NSString *key in DSCleanupPreferenceKeys()) counts[key] = @0;
    NSDictionary<NSString *, id> *filePreview = [self previewFileCountsOnePassFromVolume:volume options:options errors:errors operation:operation];
    NSDictionary<NSString *, NSNumber *> *fileCounts = filePreview[@"counts"];
    for (NSString *key in DSCleanupPreferenceKeys()) if (fileCounts[key]) counts[key] = fileCounts[key];
    protectedAppleDouble = [filePreview[@"protected"] unsignedIntegerValue];
    if ([filePreview[@"cancelled"] boolValue]) return [self cancelledPreviewResult:counts errors:errors];
    for (NSString *key in @[DSAppleDouble, DSCustomFiles, DSDSStore, DSApdisk, DSVolumeIcon, DSDesktopIni, DSThumbsDb, DSAppleDoubleDirectories]) {
        if ([self cleanupOption:key isEnabledInOptions:options]) [self publishOperation:operation category:key location:nil categoryFinished:YES force:YES];
    }
    NSDictionary<NSString *, NSString *> *rootCategories = @{ DSTrashes: @".Trashes", DSSpotlight: @".Spotlight-V100", DSFileEvents: @".fseventsd", DSTemporaryItems: @".TemporaryItems" };
    for (NSString *key in rootCategories) {
        if (![self cleanupOption:key isEnabledInOptions:options]) continue;
        [self publishOperation:operation category:key location:volume categoryFinished:NO force:YES];
        counts[key] = @([self countRootDirectory:rootCategories[key] fromVolume:volume errors:errors operation:operation]);
        if ([self operationShouldStop:operation]) return [self cancelledPreviewResult:counts errors:errors];
        [self publishOperation:operation category:key location:nil categoryFinished:YES force:YES];
    }
    return @{ @"success": @(errors.count == 0), @"cancelled": @NO, @"counts": counts.copy, @"protectedAppleDouble": @(protectedAppleDouble), @"errors": errors.copy };
}

- (NSDictionary<NSString *, id> *)cleanVolumeOnWorker:(NSURL *)volume {
    return [self cleanVolumeOnWorker:volume expectedMountIdentity:nil options:[self cleanupOptionsSnapshot]];
}

- (NSDictionary<NSString *, id> *)cleanVolumeOnWorker:(NSURL *)volume expectedMountIdentity:(NSString *)expectedMountIdentity options:(NSDictionary<NSString *, id> *)options {
    return [self cleanVolumeOnWorker:volume expectedMountIdentity:expectedMountIdentity options:options operation:nil];
}

- (NSDictionary<NSString *, id> *)cancelledCleanupResult:(NSUInteger)removed errors:(NSArray<NSString *> *)errors {
    return @{ @"success": @NO, @"cancelled": @YES, @"removed": @(removed), @"appleDoubleProcessed": @NO, @"errors": errors ?: @[] };
}

- (BOOL)volume:(NSURL *)volume matchesExpectedMountIdentity:(NSString *)expectedMountIdentity {
    return !expectedMountIdentity.length || [[self mountIdentityForVolume:volume] isEqualToString:expectedMountIdentity];
}

- (NSDictionary<NSString *, id> *)mountChangedCleanupResultWithRemoved:(NSUInteger)removed {
    return @{ @"success": @NO, @"cancelled": @NO, @"removed": @(removed), @"appleDoubleProcessed": @NO, @"errors": @[@"Il disco è stato smontato o la sua identità è cambiata durante la pulizia."] };
}

- (BOOL)automaticCleanupStillAllowedForOperation:(DSOperationState *)operation identity:(NSString *)identity {
    if (!operation.automaticCleanup) return YES;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (operation.periodicCleanup) {
        return [defaults boolForKey:DSPeriodicCleaning] && [self allowsPeriodicCleaningForIdentity:identity];
    }
    return [defaults boolForKey:DSAutomaticCleaning] && [self allowsAutomaticCleaningForIdentity:identity];
}

- (NSDictionary<NSString *, id> *)cleanVolumeOnWorker:(NSURL *)volume expectedMountIdentity:(NSString *)expectedMountIdentity options:(NSDictionary<NSString *, id> *)options operation:(DSOperationState *)operation {
    NSError *eligibilityError = nil;
    if (![self isEligibleExternalVolume:volume error:&eligibilityError]) {
        NSString *message = eligibilityError.localizedDescription ?: @"Il disco non è più un volume esterno fisico scrivibile.";
        return @{ @"success": @NO, @"removed": @0, @"appleDoubleProcessed": @NO, @"errors": @[message] };
    }
    if (![self volume:volume matchesExpectedMountIdentity:expectedMountIdentity]) {
        return @{ @"success": @NO, @"removed": @0, @"appleDoubleProcessed": @NO, @"errors": @[@"Il disco è stato smontato o la sua identità è cambiata prima della pulizia."] };
    }
    if ([self isVolumeExcludedForIdentity:expectedMountIdentity]) {
        return @{ @"success": @NO, @"removed": @0, @"appleDoubleProcessed": @NO, @"errors": @[@"Il disco è escluso dalle regole di DriveSweep."] };
    }
    if (![self automaticCleanupStillAllowedForOperation:operation identity:expectedMountIdentity]) {
        return @{ @"success": @NO, @"removed": @0, @"appleDoubleProcessed": @NO, @"errors": @[@"La pulizia automatica non è più autorizzata."] };
    }
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    NSUInteger removed = 0;
    BOOL appleDoubleProcessed = [self cleanupOption:DSAppleDouble isEnabledInOptions:options];
    if (appleDoubleProcessed) {
        if (![self automaticCleanupStillAllowedForOperation:operation identity:expectedMountIdentity]) return @{ @"success": @NO, @"removed": @0, @"appleDoubleProcessed": @NO, @"errors": @[@"La pulizia automatica non è più autorizzata."] };
        if (![self volume:volume matchesExpectedMountIdentity:expectedMountIdentity]) return [self mountChangedCleanupResultWithRemoved:removed];
        [self publishOperation:operation category:DSAppleDouble location:volume categoryFinished:NO force:YES];
        removed += [self removeAppleDoubleFilesFromVolume:volume protectedExtensions:options[DSAppleDoubleExtensions] errors:errors operation:operation];
        if ([self operationShouldStop:operation]) return [self cancelledCleanupResult:removed errors:errors];
        [self publishOperation:operation category:DSAppleDouble location:nil categoryFinished:YES force:YES];
    }
    if ([self cleanupOption:DSCustomFiles isEnabledInOptions:options]) {
        if (![self automaticCleanupStillAllowedForOperation:operation identity:expectedMountIdentity]) return @{ @"success": @NO, @"removed": @(removed), @"appleDoubleProcessed": @(appleDoubleProcessed), @"errors": @[@"La pulizia automatica non è più autorizzata."] };
        if (![self volume:volume matchesExpectedMountIdentity:expectedMountIdentity]) return [self mountChangedCleanupResultWithRemoved:removed];
        [self publishOperation:operation category:DSCustomFiles location:volume categoryFinished:NO force:YES];
        removed += [self removeCustomExtensionFilesFromVolume:volume extensions:options[DSCustomFileExtensions] errors:errors operation:operation];
        if ([self operationShouldStop:operation]) return [self cancelledCleanupResult:removed errors:errors];
        [self publishOperation:operation category:DSCustomFiles location:nil categoryFinished:YES force:YES];
    }
    NSArray<NSArray<id> *> *fileCategories = @[
        @[DSDSStore, @".DS_Store", @NO], @[DSApdisk, @".apdisk", @NO], @[DSVolumeIcon, @".VolumeIcon.icns", @NO],
        @[DSDesktopIni, @"Desktop.ini", @NO], @[DSThumbsDb, @"Thumbs.db", @NO], @[DSAppleDoubleDirectories, @".AppleDouble", @YES]
    ];
    for (NSArray<id> *entry in fileCategories) {
        NSString *key = entry[0]; if (![self cleanupOption:key isEnabledInOptions:options]) continue;
        if (![self automaticCleanupStillAllowedForOperation:operation identity:expectedMountIdentity]) return @{ @"success": @NO, @"removed": @(removed), @"appleDoubleProcessed": @(appleDoubleProcessed), @"errors": @[@"La pulizia automatica non è più autorizzata."] };
        if (![self volume:volume matchesExpectedMountIdentity:expectedMountIdentity]) return [self mountChangedCleanupResultWithRemoved:removed];
        [self publishOperation:operation category:key location:volume categoryFinished:NO force:YES];
        removed += [self removeNamedFiles:entry[1] fromVolume:volume directoriesOnly:[entry[2] boolValue] errors:errors operation:operation];
        if ([self operationShouldStop:operation]) return [self cancelledCleanupResult:removed errors:errors];
        [self publishOperation:operation category:key location:nil categoryFinished:YES force:YES];
    }
    NSDictionary<NSString *, NSString *> *rootCategories = @{ DSTrashes: @".Trashes", DSSpotlight: @".Spotlight-V100", DSFileEvents: @".fseventsd", DSTemporaryItems: @".TemporaryItems" };
    for (NSString *key in rootCategories) {
        if (![self cleanupOption:key isEnabledInOptions:options]) continue;
        if (![self automaticCleanupStillAllowedForOperation:operation identity:expectedMountIdentity]) return @{ @"success": @NO, @"removed": @(removed), @"appleDoubleProcessed": @(appleDoubleProcessed), @"errors": @[@"La pulizia automatica non è più autorizzata."] };
        if (![self volume:volume matchesExpectedMountIdentity:expectedMountIdentity]) return [self mountChangedCleanupResultWithRemoved:removed];
        [self publishOperation:operation category:key location:volume categoryFinished:NO force:YES];
        removed += [self removeRootDirectory:rootCategories[key] fromVolume:volume errors:errors operation:operation];
        if ([self operationShouldStop:operation]) return [self cancelledCleanupResult:removed errors:errors];
        [self publishOperation:operation category:key location:nil categoryFinished:YES force:YES];
    }
    return @{ @"success": @(errors.count == 0), @"cancelled": @NO, @"removed": @(removed), @"appleDoubleProcessed": @(appleDoubleProcessed), @"errors": errors };
}

- (void)cleanVolume:(NSURL *)volume source:(NSString *)source expectedMountIdentity:(NSString *)expectedMountIdentity completion:(void (^)(BOOL success))completion {
    if (!expectedMountIdentity.length) {
        NSString *message = [NSString stringWithFormat:@"Pulizia di %@ annullata: non è stato possibile verificare l'identità del disco.", volume.lastPathComponent];
        [self setDashboardStatusMessage:message];
        [self rebuildMenu];
        [self notify:message];
        if (completion) completion(NO);
        return;
    }
    if ([self isVolumeExcludedForIdentity:expectedMountIdentity]) {
        NSString *message = [NSString stringWithFormat:@"Pulizia di %@ annullata: il disco è escluso nelle regole per UUID.", volume.lastPathComponent];
        [self setDashboardStatusMessage:message];
        [self rebuildMenu];
        [self notify:message];
        if (completion) completion(NO);
        return;
    }
    BOOL mountAutomatic = [source isEqualToString:@"montaggio automatico"];
    BOOL periodicAutomatic = [source isEqualToString:@"pulizia periodica"];
    BOOL automaticAuthorized = mountAutomatic && [[NSUserDefaults standardUserDefaults] boolForKey:DSAutomaticCleaning] && [self allowsAutomaticCleaningForIdentity:expectedMountIdentity];
    BOOL periodicAuthorized = periodicAutomatic && [[NSUserDefaults standardUserDefaults] boolForKey:DSPeriodicCleaning] && [self allowsPeriodicCleaningForIdentity:expectedMountIdentity];
    if ((mountAutomatic || periodicAutomatic) && !(automaticAuthorized || periodicAuthorized)) {
        if (completion) completion(NO);
        return;
    }
    if (self.activeOperation) {
        NSString *message = [NSString stringWithFormat:@"Attendi: DriveSweep sta già lavorando su %@.", self.activeOperation.volumeName];
        [self setDashboardStatusMessage:message];
        [self rebuildMenu];
        if (completion) completion(NO);
        return;
    }
    if ([self.scheduledCleanupPaths containsObject:volume.path]) {
        if (completion) {
            NSString *message = [NSString stringWithFormat:@"La pulizia di %@ è già in corso.", volume.lastPathComponent];
            [self setDashboardStatusMessage:message];
            [self rebuildMenu];
            [self notify:message];
            completion(NO);
        }
        return;
    }
    NSDictionary<NSString *, id> *options = [self cleanupOptionsSnapshot];
    DSOperationState *operation = [self beginOperationKind:DSOperationKindCleanup volume:volume identity:expectedMountIdentity options:options];
    if (!operation) {
        if (completion) completion(NO);
        return;
    }
    operation.automaticCleanup = mountAutomatic || periodicAutomatic;
    operation.periodicCleanup = periodicAutomatic;
    [self.scheduledCleanupPaths addObject:volume.path];
    [self setDashboardStatusMessage:[NSString stringWithFormat:@"Pulizia di %@ in corso…", volume.lastPathComponent]];
    [self rebuildMenu];
    dispatch_async(self.cleanupQueue, ^{
        NSDictionary<NSString *, id> *result = [self cleanVolumeOnWorker:volume expectedMountIdentity:expectedMountIdentity options:options operation:operation];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.scheduledCleanupPaths removeObject:volume.path];
            BOOL success = [result[@"success"] boolValue];
            NSUInteger removed = [result[@"removed"] unsignedIntegerValue];
            NSArray<NSString *> *errors = result[@"errors"];
            BOOL cancelled = [result[@"cancelled"] boolValue];
            NSString *details = [NSString stringWithFormat:@"%lu elementi rimossi", (unsigned long)removed];
            NSString *message = cancelled
                ? [NSString stringWithFormat:@"Pulizia di %@ annullata (%@).", volume.lastPathComponent, details]
                : success
                ? [NSString stringWithFormat:@"%@ pulito (%@; %@).", volume.lastPathComponent, source, details]
                : [NSString stringWithFormat:@"Pulizia di %@ non completata: %@", volume.lastPathComponent, [errors componentsJoinedByString:@"; "]];
            [self setDashboardStatusMessage:message];
            self.statusItem.button.toolTip = message;
            if (!success || ![source isEqualToString:@"controllo automatico"]) [self notify:message];
            [self rebuildMenu];
            if (completion) completion(success);
            [self finishOperation:operation result:result];
        });
    });
}

- (void)presentAlertModally:(NSAlert *)alert {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentAlertModally:alert];
        });
        return;
    }

    /*
     * DriveSweep has a manually-created dashboard window. On macOS 26,
     * beginSheetModalForWindow: can route through an
     * internal NSTitlebarBackgroundView and abort the process. runModal
     * orders the alert's own NSWindow and is deterministic for this app.
     */
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

- (void)showPreviewReport:(NSDictionary<NSString *, id> *)report options:(NSDictionary<NSString *, id> *)options volume:(NSURL *)volume {
    NSDictionary<NSString *, NSNumber *> *counts = report[@"counts"];
    NSMutableString *details = [NSMutableString stringWithString:@"DriveSweep non ha rimosso alcun file.\n\n"];
    NSUInteger total = 0;
    for (NSString *key in DSCleanupPreferenceKeys()) {
        if (![self cleanupOption:key isEnabledInOptions:options]) continue;
        NSUInteger count = [counts[key] unsignedIntegerValue];
        total += count;
        [details appendFormat:@"%@ — %lu\n", DSCleanupReportLabel(key), (unsigned long)count];
    }
    if ([self cleanupOption:DSAppleDouble isEnabledInOptions:options]) {
        NSUInteger protectedCount = [report[@"protectedAppleDouble"] unsignedIntegerValue];
        [details appendFormat:@"AppleDouble mantenuti dalla whitelist — %lu\n", (unsigned long)protectedCount];
    }
    [details appendFormat:@"\nTotale candidati: %lu", (unsigned long)total];
    NSArray<NSString *> *errors = report[@"errors"];
    if (errors.count) [details appendFormat:@"\n\nAnalisi parziale:\n%@", [errors componentsJoinedByString:@"\n"]];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"Analisi di %@", volume.lastPathComponent];
    alert.informativeText = details;
    alert.alertStyle = errors.count ? NSAlertStyleWarning : NSAlertStyleInformational;
    [alert addButtonWithTitle:@"Chiudi"];
    if (![report[@"success"] boolValue] && errors.count) {
        [self setDashboardStatusMessage:[NSString stringWithFormat:@"Analisi di %@ non completata: %@", volume.lastPathComponent, [errors componentsJoinedByString:@"; "]]];
        [self rebuildMenu];
    }
    [self presentAlertModally:alert];
}

- (void)previewVolume:(NSURL *)volume expectedMountIdentity:(NSString *)expectedMountIdentity {
    if (!expectedMountIdentity.length) {
        [self notify:[NSString stringWithFormat:@"Analisi di %@ annullata: non è stato possibile verificare l'identità del disco.", volume.lastPathComponent]];
        return;
    }
    if (self.activeOperation) {
        [self setDashboardStatusMessage:[NSString stringWithFormat:@"Attendi: DriveSweep sta già lavorando su %@.", self.activeOperation.volumeName]];
        [self rebuildMenu];
        return;
    }
    NSDictionary<NSString *, id> *options = [self cleanupOptionsSnapshot];
    DSOperationState *operation = [self beginOperationKind:DSOperationKindPreview volume:volume identity:expectedMountIdentity options:options];
    if (!operation) return;
    dispatch_async(self.cleanupQueue, ^{
        NSDictionary<NSString *, id> *report = [self previewVolumeOnWorker:volume expectedMountIdentity:expectedMountIdentity options:options operation:operation];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishOperation:operation result:report];
            [self showPreviewReport:report options:options volume:volume];
        });
    });
}

- (void)notify:(NSString *)message {
    self.statusItem.button.toolTip = message;
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = @"DriveSweep";
    content.body = message;
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:NSUUID.UUID.UUIDString content:content trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
}

- (void)rebuildMenu {
    NSMenu *menu = [[NSMenu alloc] init];
    NSString *periodicStatus = [self periodicCleanupIsEnabled]
        ? [NSString stringWithFormat:@"Pulizia periodica attiva — ogni %@", [self periodicCleanupIntervalLabel]]
        : @"Pulizia periodica disattivata";
    NSMenuItem *periodicItem = [[NSMenuItem alloc] initWithTitle:periodicStatus action:nil keyEquivalent:@""];
    periodicItem.enabled = NO;
    [menu addItem:periodicItem];
    NSMenuItem *periodicToggle = [[NSMenuItem alloc] initWithTitle:([self periodicCleanupIsEnabled] ? @"Ferma pianificazione" : @"Avvia pianificazione") action:@selector(togglePeriodicCleanup:) keyEquivalent:@""];
    periodicToggle.target = self;
    [menu addItem:periodicToggle];
    NSMenuItem *periodicNow = [[NSMenuItem alloc] initWithTitle:@"Esegui pianificazione ora" action:@selector(runPeriodicCleanup:) keyEquivalent:@""];
    periodicNow.target = self; periodicNow.enabled = [self periodicCleanupIsEnabled] && !self.activeOperation;
    [menu addItem:periodicNow];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *open = [[NSMenuItem alloc] initWithTitle:@"Apri DriveSweep" action:@selector(showDashboard:) keyEquivalent:@"o"];
    open.target = self;
    [menu addItem:open];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *analyzeAll = [[NSMenuItem alloc] initWithTitle:@"Analizza tutti i dischi esterni" action:@selector(previewAll:) keyEquivalent:@"c"];
    analyzeAll.target = self;
    analyzeAll.enabled = self.eligibleVolumes.count > 0;
    [menu addItem:analyzeAll];

    NSArray<NSURL *> *volumes = self.eligibleVolumes;
    if (volumes.count) {
        [menu addItem:[NSMenuItem separatorItem]];
        for (NSURL *url in volumes) {
            NSString *identity = self.eligibleVolumeIdentities[url.path];
            DSVolumeTarget *target = [[DSVolumeTarget alloc] initWithVolumeURL:url mountIdentity:identity];
            BOOL excluded = [self isVolumeExcludedForIdentity:identity];
            NSString *volumeTitle = excluded ? [NSString stringWithFormat:@"%@ (escluso)", url.lastPathComponent] : url.lastPathComponent;
            NSMenuItem *volumeItem = [[NSMenuItem alloc] initWithTitle:volumeTitle action:nil keyEquivalent:@""];
            NSMenu *submenu = [[NSMenu alloc] initWithTitle:url.lastPathComponent];
            NSMenuItem *preview = [[NSMenuItem alloc] initWithTitle:@"Analizza…" action:@selector(previewFromMenu:) keyEquivalent:@""];
            preview.target = self; preview.representedObject = target; preview.enabled = identity.length && !excluded;
            NSMenuItem *clean = [[NSMenuItem alloc] initWithTitle:@"Pulisci ora" action:@selector(cleanFromMenu:) keyEquivalent:@""];
            clean.target = self; clean.representedObject = target; clean.enabled = identity.length && !excluded && ![self.scheduledCleanupPaths containsObject:url.path];
            NSMenuItem *eject = [[NSMenuItem alloc] initWithTitle:@"Pulisci ed espelli" action:@selector(cleanAndEject:) keyEquivalent:@""];
            eject.target = self; eject.representedObject = target; eject.enabled = clean.enabled;
            [submenu addItem:preview]; [submenu addItem:clean]; [submenu addItem:eject];
            volumeItem.submenu = submenu;
            [menu addItem:volumeItem];
        }
    } else {
        NSMenuItem *empty = [[NSMenuItem alloc] initWithTitle:@"Nessun disco esterno collegato" action:nil keyEquivalent:@""];
        empty.enabled = NO;
        [menu addItem:empty];
    }
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *preferences = [[NSMenuItem alloc] initWithTitle:@"Preferenze…" action:@selector(showPreferences:) keyEquivalent:@","];
    preferences.target = self; [menu addItem:preferences];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Esci da DriveSweep" action:@selector(terminate:) keyEquivalent:@"q"];
    [menu addItem:quit];
    self.statusItem.menu = menu;
    self.statusItem.button.toolTip = [NSString stringWithFormat:@"DriveSweep — %@", periodicStatus];
    self.statusItem.button.accessibilityLabel = self.statusItem.button.toolTip;
    [self refreshDashboard];
}

- (void)showAggregatePreviewDetails:(NSString *)details candidateTotal:(NSUInteger)candidateTotal skippedCount:(NSUInteger)skippedCount {
    NSMutableString *message = [NSMutableString stringWithFormat:@"DriveSweep non ha rimosso alcun file.\n\nTotale candidati: %lu", (unsigned long)candidateTotal];
    if (skippedCount) [message appendFormat:@"\nDischi saltati: %lu", (unsigned long)skippedCount];
    if (details.length) [message appendFormat:@"\n\n%@", details];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Analisi di tutti i dischi esterni";
    alert.informativeText = message;
    alert.alertStyle = [details containsString:@"Errore"] ? NSAlertStyleWarning : NSAlertStyleInformational;
    [alert addButtonWithTitle:@"Chiudi"];
    [self presentAlertModally:alert];
}

- (void)previewAll:(id)sender {
    NSArray<NSURL *> *volumes = [self.eligibleVolumes copy];
    NSDictionary<NSString *, NSString *> *identities = [self.eligibleVolumeIdentities copy];
    NSDictionary<NSString *, id> *options = [self cleanupOptionsSnapshot];
    if (!volumes.count) {
        [self notify:@"Non ci sono dischi esterni idonei da analizzare."];
        return;
    }
    dispatch_async(self.cleanupQueue, ^{
        NSMutableString *details = [NSMutableString string];
        NSUInteger candidateTotal = 0;
        NSUInteger skippedCount = 0;
        for (NSURL *url in volumes) {
            NSString *identity = identities[url.path];
            if (!identity.length || [self isVolumeExcludedForIdentity:identity]) {
                skippedCount++;
                [details appendFormat:@"%@ — saltato (regola di esclusione o identità non verificata)\n", url.lastPathComponent];
                continue;
            }
            NSDictionary<NSString *, id> *report = [self previewVolumeOnWorker:url expectedMountIdentity:identity options:options];
            if (![report[@"success"] boolValue]) {
                [details appendFormat:@"%@ — Errore: %@\n", url.lastPathComponent, [report[@"errors"] componentsJoinedByString:@"; "]];
                continue;
            }
            NSDictionary<NSString *, NSNumber *> *counts = report[@"counts"];
            NSUInteger volumeTotal = 0;
            for (NSString *key in DSCleanupPreferenceKeys()) volumeTotal += [counts[key] unsignedIntegerValue];
            candidateTotal += volumeTotal;
            [details appendFormat:@"%@ — %lu candidati, %lu protetti dalla whitelist\n", url.lastPathComponent, (unsigned long)volumeTotal, (unsigned long)[report[@"protectedAppleDouble"] unsignedIntegerValue]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showAggregatePreviewDetails:details candidateTotal:candidateTotal skippedCount:skippedCount];
        });
    });
}

- (void)cleanAll:(id)sender {
    // Keep the old selector safe for an already-built menu: the global action is preview-only.
    [self previewAll:sender];
}

- (void)cleanFromMenu:(NSMenuItem *)sender {
    DSVolumeTarget *target = sender.representedObject;
    [self cleanVolume:target.volumeURL source:@"manuale" expectedMountIdentity:target.mountIdentity completion:nil];
}

- (void)previewFromMenu:(NSMenuItem *)sender {
    DSVolumeTarget *target = sender.representedObject;
    [self previewVolume:target.volumeURL expectedMountIdentity:target.mountIdentity];
}

- (DSVolumeTarget *)volumeTargetForDashboardButton:(NSButton *)sender {
    return self.dashboardVolumeTargets[sender.identifier];
}

- (void)previewFromDashboardButton:(NSButton *)sender {
    DSVolumeTarget *target = [self volumeTargetForDashboardButton:sender];
    [self previewVolume:target.volumeURL expectedMountIdentity:target.mountIdentity];
}

- (void)cleanFromDashboardButton:(NSButton *)sender {
    DSVolumeTarget *target = [self volumeTargetForDashboardButton:sender];
    [self cleanVolume:target.volumeURL source:@"manuale" expectedMountIdentity:target.mountIdentity completion:nil];
}

- (void)cleanAndEjectFromDashboardButton:(NSButton *)sender {
    DSVolumeTarget *target = [self volumeTargetForDashboardButton:sender];
    [self cleanVolume:target.volumeURL source:@"prima dell'espulsione" expectedMountIdentity:target.mountIdentity completion:^(BOOL success) {
        if (!success) {
            [self notify:[NSString stringWithFormat:@"%@ non è stato espulso: la pulizia non è stata completata.", target.volumeURL.lastPathComponent]];
            return;
        }
        [self ejectVolumeTarget:target];
    }];
}

- (void)toggleVolumeRule:(NSButton *)sender {
    NSString *identity = sender.identifier;
    DSVolumeTarget *target = [self volumeTargetForDashboardButton:sender];
    if (!identity.length || !target) return;
    NSDictionary<NSString *, id> *rule = [self volumeRuleForIdentity:identity];
    BOOL excluded = [rule[DSVolumeRuleExcluded] boolValue];
    BOOL allowAutomatic = [rule[DSVolumeRuleAutomatic] boolValue];
    BOOL allowPeriodic = [rule[DSVolumeRulePeriodic] boolValue];
    if (sender.tag == 1) {
        excluded = !excluded;
        if (excluded) allowAutomatic = NO;
    } else if (sender.tag == 2 && !excluded) {
        allowAutomatic = !allowAutomatic;
    } else if (sender.tag == 3 && !excluded) {
        allowPeriodic = !allowPeriodic;
    }
    [self setVolumeRuleForIdentity:identity name:target.volumeURL.lastPathComponent excluded:excluded allowAutomatic:allowAutomatic];
    [self setPeriodicCleaning:allowPeriodic forIdentity:identity name:target.volumeURL.lastPathComponent];
    [self rebuildMenu];
}

- (void)toggleVolumeRuleFromMenu:(NSMenuItem *)sender {
    DSVolumeTarget *target = sender.representedObject;
    NSString *identity = target.mountIdentity;
    if (!identity.length || !target) return;
    NSDictionary<NSString *, id> *rule = [self volumeRuleForIdentity:identity];
    BOOL excluded = [rule[DSVolumeRuleExcluded] boolValue];
    BOOL allowAutomatic = [rule[DSVolumeRuleAutomatic] boolValue];
    BOOL allowPeriodic = [rule[DSVolumeRulePeriodic] boolValue];
    if (sender.tag == 1) {
        excluded = !excluded;
        if (excluded) allowAutomatic = NO;
    } else if (sender.tag == 2 && !excluded) {
        allowAutomatic = !allowAutomatic;
    } else if (sender.tag == 3 && !excluded) {
        allowPeriodic = !allowPeriodic;
    }
    [self setVolumeRuleForIdentity:identity name:target.volumeURL.lastPathComponent excluded:excluded allowAutomatic:allowAutomatic];
    [self setPeriodicCleaning:allowPeriodic forIdentity:identity name:target.volumeURL.lastPathComponent];
    [self rebuildMenu];
}

- (void)cleanAndEject:(NSMenuItem *)sender {
    DSVolumeTarget *target = sender.representedObject;
    [self cleanVolume:target.volumeURL source:@"prima dell'espulsione" expectedMountIdentity:target.mountIdentity completion:^(BOOL success) {
        if (!success) {
            [self notify:[NSString stringWithFormat:@"%@ non è stato espulso: la pulizia non è stata completata.", target.volumeURL.lastPathComponent]];
            return;
        }
        [self ejectVolumeTarget:target];
    }];
}

- (void)ejectVolumeTarget:(DSVolumeTarget *)target {
    if (![self volume:target.volumeURL matchesExpectedMountIdentity:target.mountIdentity]) {
        [self notify:[NSString stringWithFormat:@"%@ non è stato espulso: il disco è cambiato dopo la pulizia.", target.volumeURL.lastPathComponent]];
        return;
    }
    NSError *error = nil;
    if (![[NSWorkspace sharedWorkspace] unmountAndEjectDeviceAtURL:target.volumeURL error:&error]) {
        [self notify:[NSString stringWithFormat:@"Non riesco a espellere %@: %@", target.volumeURL.lastPathComponent, error.localizedDescription]];
    }
}

- (void)showDashboard:(id)sender {
    if (!self.dashboardWindow) {
        self.dashboardWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 580)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        // Keep the retained dashboard instance valid after the user closes it.
        // applicationShouldHandleReopen: reuses this window instead of allocating
        // a new controller, so AppKit must not release it on close.
        self.dashboardWindow.releasedWhenClosed = NO;
        self.dashboardWindow.title = @"DriveSweep";
        self.dashboardWindow.minSize = NSMakeSize(600, 480);
        self.dashboardWindow.delegate = self;
        [self.dashboardWindow center];

        NSView *content = self.dashboardWindow.contentView;
        NSTextField *title = [NSTextField labelWithString:@"DriveSweep è attivo"];
        title.frame = NSMakeRect(24, 526, 560, 32);
        title.font = [NSFont boldSystemFontOfSize:24];
        [content addSubview:title];

        NSTextField *description = [NSTextField wrappingLabelWithString:@"Analizza prima di cancellare. DriveSweep lavora solo su dischi fisici esterni scrivibili e non avvia pulizie automatiche senza il consenso del singolo UUID."];
        description.frame = NSMakeRect(24, 480, 584, 38);
        description.font = [NSFont systemFontOfSize:13];
        [content addSubview:description];

        self.dashboardStatusLabel = [NSTextField labelWithString:@""];
        self.dashboardStatusLabel.frame = NSMakeRect(24, 448, 584, 24);
        self.dashboardStatusLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        [content addSubview:self.dashboardStatusLabel];

        self.analyzeAllButton = [NSButton buttonWithTitle:@"Analizza tutti" target:self action:@selector(previewAll:)];
        self.analyzeAllButton.frame = NSMakeRect(24, 404, 150, 34);
        self.analyzeAllButton.bezelStyle = NSBezelStyleRounded;
        [content addSubview:self.analyzeAllButton];

        NSButton *preferences = [NSButton buttonWithTitle:@"Preferenze…" target:self action:@selector(showPreferences:)];
        preferences.frame = NSMakeRect(186, 404, 130, 34);
        preferences.bezelStyle = NSBezelStyleRounded;
        [content addSubview:preferences];

        self.scheduleButton = [NSButton buttonWithTitle:@"Avvia pianificazione" target:self action:@selector(togglePeriodicCleanup:)];
        self.scheduleButton.frame = NSMakeRect(330, 404, 210, 34);
        self.scheduleButton.bezelStyle = NSBezelStyleRounded;
        self.scheduleButton.accessibilityLabel = @"Avvia o ferma pulizia periodica";
        [content addSubview:self.scheduleButton];

        self.operationStatusLabel = [NSTextField labelWithString:@""];
        self.operationStatusLabel.frame = NSMakeRect(330, 414, 286, 20);
        self.operationStatusLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
        self.operationStatusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [content addSubview:self.operationStatusLabel];
        self.operationProgressIndicator = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(330, 398, 174, 10)];
        self.operationProgressIndicator.indeterminate = YES;
        self.operationProgressIndicator.hidden = YES;
        [content addSubview:self.operationProgressIndicator];
        self.cancelOperationButton = [NSButton buttonWithTitle:@"Annulla" target:self action:@selector(cancelActiveOperation:)];
        self.cancelOperationButton.frame = NSMakeRect(514, 393, 96, 24);
        self.cancelOperationButton.bezelStyle = NSBezelStyleRounded;
        self.cancelOperationButton.hidden = YES;
        [content addSubview:self.cancelOperationButton];

        self.dashboardScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(24, 24, 592, 360)];
        self.dashboardScrollView.hasVerticalScroller = YES;
        self.dashboardScrollView.autohidesScrollers = YES;
        self.dashboardScrollView.borderType = NSBezelBorder;
        self.dashboardScrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        self.dashboardDocumentView = [[DSFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 576, 100)];
        self.dashboardDocumentView.autoresizingMask = NSViewWidthSizable;
        self.dashboardScrollView.documentView = self.dashboardDocumentView;
        [content addSubview:self.dashboardScrollView];
    }
    [self refreshDashboard];
    [self.dashboardWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (NSButton *)dashboardButtonWithTitle:(NSString *)title action:(SEL)action identity:(NSString *)identity frame:(NSRect)frame enabled:(BOOL)enabled {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.frame = frame;
    button.bezelStyle = NSBezelStyleRounded;
    button.identifier = identity ?: @"";
    button.enabled = enabled;
    return button;
}

- (NSButton *)dashboardActionsButtonForVolume:(NSURL *)volume identity:(NSString *)identity enabled:(BOOL)enabled {
    BOOL excluded = [self isVolumeExcludedForIdentity:identity];
    DSVolumeTarget *target = [[DSVolumeTarget alloc] initWithVolumeURL:volume mountIdentity:identity];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Azioni disco"];
    NSArray<NSArray<id> *> *actions = @[
        @[@"Analizza", NSStringFromSelector(@selector(previewFromMenu:))],
        @[@"Pulisci ora", NSStringFromSelector(@selector(cleanFromMenu:))],
        @[@"Pulisci ed espelli", NSStringFromSelector(@selector(cleanAndEject:))]
    ];
    for (NSArray<id> *entry in actions) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:entry[0] action:NSSelectorFromString(entry[1]) keyEquivalent:@""];
        item.target = self; item.representedObject = target; item.enabled = enabled;
        [menu addItem:item];
    }
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *exclude = [[NSMenuItem alloc] initWithTitle:(excluded ? @"Includi questo disco" : @"Escludi questo disco") action:@selector(toggleVolumeRuleFromMenu:) keyEquivalent:@""];
    exclude.target = self; exclude.representedObject = target; exclude.identifier = identity ?: @""; exclude.tag = 1; exclude.enabled = identity.length > 0;
    [menu addItem:exclude];
    NSMenuItem *automatic = [[NSMenuItem alloc] initWithTitle:([self allowsAutomaticCleaningForIdentity:identity] ? @"Blocca pulizia automatica" : @"Consenti pulizia automatica") action:@selector(toggleVolumeRuleFromMenu:) keyEquivalent:@""];
    automatic.target = self; automatic.representedObject = target; automatic.identifier = identity ?: @""; automatic.tag = 2; automatic.enabled = identity.length > 0 && !excluded;
    [menu addItem:automatic];
    NSMenuItem *periodic = [[NSMenuItem alloc] initWithTitle:([self allowsPeriodicCleaningForIdentity:identity] ? @"Rimuovi dalla pianificazione" : @"Includi nella pianificazione") action:@selector(toggleVolumeRuleFromMenu:) keyEquivalent:@""];
    periodic.target = self; periodic.representedObject = target; periodic.identifier = identity ?: @""; periodic.tag = 3; periodic.enabled = identity.length > 0 && !excluded;
    [menu addItem:periodic];
    NSMenuItem *title = [[NSMenuItem alloc] initWithTitle:@"Azioni…" action:nil keyEquivalent:@""];
    title.enabled = NO;
    [menu insertItem:title atIndex:0];
    NSPopUpButton *button = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(68, 18, 132, 30) pullsDown:YES];
    button.menu = menu;
    button.enabled = identity.length > 0 && !self.activeOperation;
    button.accessibilityLabel = [NSString stringWithFormat:@"Azioni per %@", volume.lastPathComponent];
    return button;
}

- (NSView *)dashboardCardForVolume:(NSURL *)volume identity:(NSString *)identity frame:(NSRect)frame {
    NSBox *card = [[NSBox alloc] initWithFrame:frame];
    card.boxType = NSBoxCustom;
    card.cornerRadius = 10;
    card.titlePosition = NSNoTitle;

    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(16, 66, 40, 40)];
    icon.image = [[NSWorkspace sharedWorkspace] iconForFile:volume.path];
    icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    [card addSubview:icon];

    NSTextField *name = [NSTextField labelWithString:volume.lastPathComponent ?: @"Disco esterno"];
    name.frame = NSMakeRect(68, 86, 360, 24);
    name.font = [NSFont boldSystemFontOfSize:15];
    [card addSubview:name];

    NSString *rule = [self volumeRuleSummaryForIdentity:identity];
    if ([self.scheduledCleanupPaths containsObject:volume.path]) rule = @"Pulizia in corso…";
    if (self.activeOperation) {
        rule = [self.activeOperation.volumeIdentity isEqualToString:identity]
            ? self.operationStatusLabel.stringValue
            : [NSString stringWithFormat:@"In attesa: %@ in corso", self.activeOperation.volumeName];
    }
    NSTextField *status = [NSTextField labelWithString:rule];
    status.frame = NSMakeRect(68, 64, 440, 20);
    status.font = [NSFont systemFontOfSize:12];
    status.textColor = [self isVolumeExcludedForIdentity:identity] ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
    [card addSubview:status];

    BOOL excluded = [self isVolumeExcludedForIdentity:identity];
    BOOL identityVerified = identity.length > 0;
    BOOL busy = [self.scheduledCleanupPaths containsObject:volume.path] || self.activeOperation != nil;
    BOOL actionsEnabled = identityVerified && !excluded && !busy;
    [card addSubview:[self dashboardActionsButtonForVolume:volume identity:identity enabled:actionsEnabled]];
    return card;
}

- (void)refreshDashboard {
    if (!self.dashboardStatusLabel || !self.dashboardDocumentView) return;
    self.scheduleButton.title = [self periodicCleanupIsEnabled] ? @"Ferma pianificazione" : @"Avvia pianificazione";
    NSArray<NSURL *> *volumes = self.eligibleVolumes;
    [self.dashboardVolumeTargets removeAllObjects];
    for (NSView *subview in [self.dashboardDocumentView.subviews copy]) [subview removeFromSuperview];
    if (volumes.count == 0) {
        self.dashboardStatusLabel.stringValue = self.dashboardStatusMessage.length ? self.dashboardStatusMessage : @"Nessun disco esterno idoneo collegato.";
        self.analyzeAllButton.enabled = NO;
        NSTextField *empty = [NSTextField wrappingLabelWithString:@"Collega un disco esterno fisico e scrivibile per iniziare."];
        empty.frame = NSMakeRect(24, 28, 520, 40);
        empty.textColor = NSColor.secondaryLabelColor;
        [self.dashboardDocumentView addSubview:empty];
        self.dashboardDocumentView.frame = NSMakeRect(0, 0, self.dashboardDocumentView.frame.size.width, 88);
        return;
    }
    NSUInteger actionableCount = 0;
    for (NSURL *volume in volumes) {
        NSString *identity = self.eligibleVolumeIdentities[volume.path];
        if (identity.length) self.dashboardVolumeTargets[identity] = [[DSVolumeTarget alloc] initWithVolumeURL:volume mountIdentity:identity];
        if (identity.length && ![self isVolumeExcludedForIdentity:identity]) actionableCount++;
    }
    self.dashboardStatusLabel.stringValue = self.dashboardStatusMessage.length
        ? self.dashboardStatusMessage
        : [NSString stringWithFormat:@"%lu dischi esterni rilevati · profilo %@", (unsigned long)volumes.count, [self cleanupProfileDisplayName:[[NSUserDefaults standardUserDefaults] stringForKey:DSCleanupProfile]]];
    self.analyzeAllButton.enabled = actionableCount > 0;
    CGFloat width = self.dashboardDocumentView.frame.size.width;
    if (width < 560) width = 560;
    CGFloat y = 16;
    for (NSURL *volume in volumes) {
        NSString *identity = self.eligibleVolumeIdentities[volume.path];
        [self.dashboardDocumentView addSubview:[self dashboardCardForVolume:volume identity:identity frame:NSMakeRect(8, y, width - 16, 122)]];
        y += 136;
    }
    self.dashboardDocumentView.frame = NSMakeRect(0, 0, width, y);
}

- (NSButton *)checkbox:(NSString *)title key:(NSString *)key y:(CGFloat)y {
    NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(24, y, 390, 24)];
    button.buttonType = NSButtonTypeSwitch;
    button.title = title;
    button.state = [[NSUserDefaults standardUserDefaults] boolForKey:key] ? NSControlStateValueOn : NSControlStateValueOff;
    button.target = self;
    button.action = @selector(saveCheckbox:);
    button.identifier = key;
    button.accessibilityLabel = title;
    self.preferenceCheckboxes[key] = button;
    return button;
}

- (NSTextField *)preferenceTextField:(NSString *)key y:(CGFloat)y {
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(24, y, 390, 24)];
    field.stringValue = [[NSUserDefaults standardUserDefaults] stringForKey:key] ?: @"";
    field.identifier = key;
    field.target = self;
    field.action = @selector(saveTextPreference:);
    field.continuous = YES;
    self.preferenceTextFields[key] = field;
    return field;
}

- (NSTextField *)preferenceLabel:(NSString *)text y:(CGFloat)y height:(CGFloat)height font:(NSFont *)font color:(NSColor *)color {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.frame = NSMakeRect(24, y, 390, height);
    label.font = font ?: [NSFont systemFontOfSize:12];
    label.textColor = color ?: NSColor.labelColor;
    return label;
}

- (NSTextField *)preferenceSection:(NSString *)title y:(CGFloat)y {
    NSTextField *section = [NSTextField labelWithString:title.uppercaseString];
    section.frame = NSMakeRect(24, y, 390, 22);
    section.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    section.textColor = NSColor.controlAccentColor;
    return section;
}

- (void)refreshPreferenceControls {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (NSString *key in self.preferenceCheckboxes) {
        self.preferenceCheckboxes[key].state = [defaults boolForKey:key] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    self.preferenceTextFields[DSAppleDoubleExtensions].stringValue = [defaults stringForKey:DSAppleDoubleExtensions] ?: @"";
    self.preferenceTextFields[DSExcludedVolumes].stringValue = [defaults stringForKey:DSExcludedVolumes] ?: @"";
    NSArray<NSString *> *customExtensions = [defaults objectForKey:DSCustomFileExtensions];
    self.preferenceTextFields[DSCustomFileExtensions].stringValue = [customExtensions isKindOfClass:NSArray.class] ? [customExtensions componentsJoinedByString:@", "] : @"";
    [self selectProfile:[defaults stringForKey:DSCleanupProfile] ?: DSProfileCrossPlatform inPopup:self.profilePopup];
    self.periodicIntervalTextField.stringValue = [NSString stringWithFormat:@"%ld", (long)[self periodicCleanupIntervalMinutes]];
}

- (void)showPreferences:(id)sender {
    if (!self.preferencesWindow) {
        self.preferencesWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 470, 620)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        self.preferencesWindow.releasedWhenClosed = NO;
        self.preferencesWindow.delegate = self;
        self.preferencesWindow.title = @"Preferenze DriveSweep";
        NSView *content = self.preferencesWindow.contentView;
        self.preferenceCheckboxes = [NSMutableDictionary dictionary];
        self.preferenceTextFields = [NSMutableDictionary dictionary];
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:content.bounds];
        scroll.hasVerticalScroller = YES;
        scroll.autohidesScrollers = YES;
        scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        DSFlippedView *document = [[DSFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 440, 1320)];
        scroll.documentView = document;
        [content addSubview:scroll];

        [document addSubview:[self preferenceSection:@"Profilo operativo" y:20]];
        self.profilePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(24, 48, 390, 28) pullsDown:NO];
        NSArray<NSArray<NSString *> *> *profiles = @[
            @[DSProfileCrossPlatform, @"Condivisione multipiattaforma"],
            @[DSProfileMacMetadata, @"Conserva metadati Mac"],
            @[DSProfileCustom, @"Personalizzato"]
        ];
        for (NSArray<NSString *> *profile in profiles) {
            [self.profilePopup addItemWithTitle:profile[1]];
            self.profilePopup.lastItem.representedObject = profile[0];
        }
        self.profilePopup.target = self;
        self.profilePopup.action = @selector(profileSelectionChanged:);
        [document addSubview:self.profilePopup];
        [document addSubview:[self preferenceLabel:[self cleanupProfileDescription:[[NSUserDefaults standardUserDefaults] stringForKey:DSCleanupProfile]] y:82 height:38 font:[NSFont systemFontOfSize:11] color:NSColor.secondaryLabelColor]];

        [document addSubview:[self preferenceSection:@"Modalità automatica" y:132]];
        [document addSubview:[self checkbox:@"Pulisci automaticamente dopo il mount" key:DSAutomaticCleaning y:160]];
        [document addSubview:[self preferenceLabel:@"Disattivata per default. Anche se attiva, richiede il consenso esplicito per ogni VolumeUUID." y:188 height:34 font:[NSFont systemFontOfSize:11] color:NSColor.systemOrangeColor]];

        [document addSubview:[self preferenceSection:@"Metadati quotidiani" y:238]];
        [document addSubview:[self checkbox:@"Rimuovi file ._* (AppleDouble)" key:DSAppleDouble y:266]];
        [document addSubview:[self preferenceLabel:@"Rischio: può rimuovere resource fork, FinderInfo o altri metadati Mac. Usa la whitelist per eps, psd e file legacy." y:294 height:42 font:[NSFont systemFontOfSize:11] color:NSColor.systemOrangeColor]];
        [document addSubview:[self preferenceLabel:@"Mantieni AppleDouble per estensioni (es. eps, psd):" y:340 height:20 font:[NSFont systemFontOfSize:11] color:NSColor.secondaryLabelColor]];
        [document addSubview:[self preferenceTextField:DSAppleDoubleExtensions y:366]];
        [document addSubview:[self checkbox:@"Rimuovi .DS_Store" key:DSDSStore y:400]];
        [document addSubview:[self preferenceLabel:@"Rischio basso: Finder può ricreare questi file, ma le viste delle cartelle possono tornare ai valori predefiniti." y:428 height:34 font:[NSFont systemFontOfSize:11] color:NSColor.secondaryLabelColor]];

        [document addSubview:[self preferenceSection:@"Categorie avanzate" y:478]];
        [document addSubview:[self preferenceLabel:@"Off per default. Svuotare Cestino, indici e cartelle di sistema può cancellare dati recuperabili o richiedere che macOS li ricrei." y:506 height:40 font:[NSFont systemFontOfSize:11] color:NSColor.systemOrangeColor]];
        NSArray<NSArray<NSString *> *> *advanced = @[
            @[DSTrashes, @"Svuota .Trashes del disco"],
            @[DSSpotlight, @"Rimuovi indice Spotlight (.Spotlight-V100)"],
            @[DSFileEvents, @"Rimuovi registro eventi (.fseventsd)"],
            @[DSApdisk, @"Rimuovi file .apdisk"],
            @[DSVolumeIcon, @"Rimuovi .VolumeIcon.icns"],
            @[DSDesktopIni, @"Rimuovi Desktop.ini"],
            @[DSThumbsDb, @"Rimuovi Thumbs.db"],
            @[DSTemporaryItems, @"Rimuovi .TemporaryItems del disco"],
            @[DSAppleDoubleDirectories, @"Rimuovi cartelle .AppleDouble"]
        ];
        CGFloat advancedY = 552;
        for (NSArray<NSString *> *item in advanced) {
            [document addSubview:[self checkbox:item[1] key:item[0] y:advancedY]];
            advancedY += 28;
        }

        [document addSubview:[self preferenceSection:@"Dischi esclusi (legacy)" y:824]];
        [document addSubview:[self preferenceLabel:@"Nomi separati da virgola. Per una regola stabile usa il pulsante Escludi sulla scheda del disco: quella regola è legata al VolumeUUID." y:852 height:40 font:[NSFont systemFontOfSize:11] color:NSColor.secondaryLabelColor]];
        [document addSubview:[self preferenceTextField:DSExcludedVolumes y:898]];
        NSButton *reset = [NSButton buttonWithTitle:@"Ripristina impostazioni sicure" target:self action:@selector(resetSafeDefaults:)];
        reset.frame = NSMakeRect(24, 936, 220, 30);
        reset.bezelStyle = NSBezelStyleRounded;
        [document addSubview:reset];
        [document addSubview:[self preferenceLabel:@"Ripristina AppleDouble + .DS_Store, disattiva automatico e categorie avanzate. Non modifica le regole per singolo disco." y:974 height:38 font:[NSFont systemFontOfSize:11] color:NSColor.secondaryLabelColor]];

        [document addSubview:[self preferenceSection:@"Pulizia periodica in background" y:1034]];
        [document addSubview:[self checkbox:@"Esegui la pulizia periodica" key:DSPeriodicCleaning y:1062]];
        [document addSubview:[self preferenceLabel:@"È indipendente dalla pulizia al mount. Include solo i dischi selezionati dal relativo menu Azioni e non li espelle mai." y:1090 height:40 font:[NSFont systemFontOfSize:11] color:NSColor.systemOrangeColor]];
        [document addSubview:[self preferenceLabel:@"Intervallo in minuti (da 5 a 10.080):" y:1136 height:20 font:[NSFont systemFontOfSize:11] color:NSColor.secondaryLabelColor]];
        self.periodicIntervalTextField = [[NSTextField alloc] initWithFrame:NSMakeRect(270, 1132, 144, 28)];
        self.periodicIntervalTextField.target = self;
        self.periodicIntervalTextField.action = @selector(savePeriodicInterval:);
        self.periodicIntervalTextField.accessibilityLabel = @"Intervallo pulizia periodica in minuti";
        [document addSubview:self.periodicIntervalTextField];

        [document addSubview:[self preferenceSection:@"File con estensioni selezionate" y:1190]];
        [document addSubview:[self checkbox:@"Rimuovi file con queste estensioni esatte" key:DSCustomFiles y:1218]];
        [document addSubview:[self preferenceLabel:@"Rischio alto. Inserisci estensioni separate da virgola (es. tmp, bak). Nessun wildcard, percorso o cartella; pacchetti, link e cartelle protette sono sempre esclusi." y:1246 height:42 font:[NSFont systemFontOfSize:11] color:NSColor.systemOrangeColor]];
        [document addSubview:[self preferenceTextField:DSCustomFileExtensions y:1290]];
    }
    [self refreshPreferenceControls];
    [self.preferencesWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)saveCheckbox:(NSButton *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:(sender.state == NSControlStateValueOn) forKey:sender.identifier];
    if ([DSCleanupPreferenceKeys() containsObject:sender.identifier]) {
        [[NSUserDefaults standardUserDefaults] setObject:DSProfileCustom forKey:DSCleanupProfile];
    }
    if ([sender.identifier isEqualToString:DSAutomaticCleaning] || [sender.identifier isEqualToString:DSPeriodicCleaning]) {
        [self configurePeriodicCleanupTimer];
    }
    [self refreshPreferenceControls];
    [self rebuildMenu];
}
- (void)saveTextPreference:(NSTextField *)sender {
    if ([sender.identifier isEqualToString:DSCustomFileExtensions]) {
        NSArray<NSString *> *normalized = [[[self normalizedCustomFileExtensionsFromValue:sender.stringValue] allObjects] sortedArrayUsingSelector:@selector(compare:)];
        [[NSUserDefaults standardUserDefaults] setObject:normalized forKey:sender.identifier];
        sender.stringValue = [normalized componentsJoinedByString:@", "];
        [[NSUserDefaults standardUserDefaults] setObject:DSProfileCustom forKey:DSCleanupProfile];
    } else {
        [[NSUserDefaults standardUserDefaults] setObject:sender.stringValue forKey:sender.identifier];
    }
    [self rebuildMenu];
}

- (void)savePeriodicInterval:(NSTextField *)sender {
    NSInteger minutes = MAX(5, MIN(sender.integerValue ?: 60, 10080));
    [[NSUserDefaults standardUserDefaults] setInteger:minutes forKey:DSPeriodicCleaningInterval];
    sender.stringValue = [NSString stringWithFormat:@"%ld", (long)minutes];
    [self configurePeriodicCleanupTimer];
    [self rebuildMenu];
}

@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        DriveSweepController *controller = [[DriveSweepController alloc] init];
        app.delegate = controller;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
