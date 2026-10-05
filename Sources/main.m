#import <Cocoa/Cocoa.h>
#import <UserNotifications/UserNotifications.h>
#import <errno.h>
#import <fts.h>
#import <mach/mach.h>
#import <math.h>
#import <string.h>
#import <sys/resource.h>
#import <sys/stat.h>
#import <unistd.h>
#import <signal.h>
#import "Resources.inc"

static NSString *const DSAutomaticCleaning = @"automaticCleaning";
static NSString *const DSPeriodicCleaning = @"periodicCleaning";
static NSString *const DSPeriodicCleaningInterval = @"periodicCleaningInterval";
static NSString *const DSPeriodicCleaningIntervalUnit = @"periodicCleaningIntervalUnit";
static NSString *const DSPeriodicCleaningIntervalUnitMinutes = @"minutes";
static NSString *const DSPeriodicCleaningIntervalUnitSeconds = @"seconds";
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
static NSString *const DSVolumeRuleCustomExtensionsFingerprint = @"customExtensionsFingerprint";
static NSString *const DSVolumeRuleName = @"name";
static NSString *const DSNotificationAuthorizationRequested = @"notificationAuthorizationRequested";
static NSUInteger DSPreviewFileTraversalCount = 0;
static const double DSResourceGuardMaximumCPUPercent = 80.0;
static const uint64_t DSResourceGuardMaximumResidentBytes = 750ULL * 1024ULL * 1024ULL;
static const NSInteger DSMinimumPeriodicCleanupIntervalMinutes = 1;
static const NSInteger DSMaximumPeriodicCleanupIntervalMinutes = 7 * 24 * 60;

static NSArray<NSString *> *DSCleanupPreferenceKeys(void) {
    return @[
        DSAppleDouble, DSCustomFiles, DSDSStore, DSTrashes, DSSpotlight, DSFileEvents,
        DSApdisk, DSVolumeIcon, DSDesktopIni, DSThumbsDb, DSTemporaryItems,
        DSAppleDoubleDirectories
    ];
}

static BOOL DSIsProtectedTraversalRootDirectory(NSString *directoryName) {
    return [@[@".Trashes", @".Spotlight-V100", @".fseventsd", @".TemporaryItems"] containsObject:directoryName];
}

static BOOL DSIsPreviewTraversalExcludedRootDirectory(NSString *directoryName) {
    return DSIsProtectedTraversalRootDirectory(directoryName);
}

static BOOL DSIsBuiltInCleanupFileName(NSString *fileName) {
    static NSSet<NSString *> *builtInNames;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        builtInNames = [NSSet setWithObjects:@".DS_Store", @".apdisk", @".VolumeIcon.icns", @"Desktop.ini", @"Thumbs.db", nil];
    });
    return [builtInNames containsObject:fileName];
}

static BOOL DSIsCustomExtensionCandidate(NSString *fileName, NSSet<NSString *> *extensions) {
    if (!fileName.length || [fileName hasPrefix:@"._"] || DSIsBuiltInCleanupFileName(fileName)) return NO;
    return [extensions containsObject:fileName.pathExtension.lowercaseString];
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

static void DSBroadcastPreferences(void) {
    [NSUserDefaults.standardUserDefaults synchronize];
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"com.github.naicud.drivesweep.preferences"
        object:[NSString stringWithFormat:@"%d", getpid()] userInfo:nil deliverImmediately:YES];
}

@interface DSFlippedView : NSView
@end

@implementation DSFlippedView
- (BOOL)isFlipped { return YES; }
@end

// Native controls, dynamic system colors and no rendering dependencies.
static NSTextField *DSLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *label = [NSTextField labelWithString:text ?: @""];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

static NSStackView *DSStack(NSArray<NSView *> *views, NSUserInterfaceLayoutOrientation orientation, CGFloat spacing) {
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = orientation;
    stack.alignment = orientation == NSUserInterfaceLayoutOrientationVertical ? NSLayoutAttributeLeading : NSLayoutAttributeCenterY;
    stack.spacing = spacing;
    return stack;
}

@interface DSSurfaceView : NSView
@end
@implementation DSSurfaceView
- (void)refreshSurfaceAppearance {
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        self.layer.backgroundColor = [NSColor.windowBackgroundColor blendedColorWithFraction:0.065 ofColor:NSColor.labelColor].CGColor;
        self.layer.borderColor = [NSColor.separatorColor colorWithAlphaComponent:0.3].CGColor;
        self.layer.borderWidth = 1;
    }];
}
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; [self refreshSurfaceAppearance]; }
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; [self refreshSurfaceAppearance]; }
@end

@interface DSCapacityBar : NSView
@property double usedFraction;
@end
@implementation DSCapacityBar
- (void)drawRect:(NSRect)dirtyRect {
    [NSColor.quaternaryLabelColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:4 yRadius:4] fill];
    NSRect used = self.bounds;
    used.size.width *= MAX(0, MIN(1, self.usedFraction));
    [(self.usedFraction > 0.9 ? NSColor.systemOrangeColor : NSColor.controlAccentColor) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:used xRadius:4 yRadius:4] fill];
}
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
@property NSTimeInterval startedAt;
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
@property (strong) NSTimer *scheduleCountdownTimer;
@property (strong) NSDate *nextPeriodicCleanupDate;
@property (strong) NSTimer *resourceMonitorTimer;
@property (strong) DSResourceSampler *periodicResourceSampler;
@property (strong) NSArray<NSURL *> *eligibleVolumes;
@property (strong) NSDictionary<NSString *, NSString *> *eligibleVolumeIdentities;
@property (strong) NSMutableSet<NSString *> *scheduledCleanupPaths;
@property (strong) NSMutableSet<NSString *> *handledMountIdentities;
@property dispatch_queue_t cleanupQueue;
@property dispatch_queue_t discoveryQueue;
@property BOOL discoveryRunning;
@property BOOL discoveryRequested;
@property NSUInteger mountGeneration;
@property (strong) NSDictionary<NSString *, NSDictionary *> *volumeCapacity;
@property (strong) NSMutableDictionary<NSString *, NSDictionary *> *previewRecords;
@property (strong) NSMutableArray<NSString *> *recentActivity;
@property (strong) NSTextField *volumeCountLabel;
@property (strong) NSTextField *candidateCountLabel;
@property (strong) NSTextField *protectedCountLabel;
@property (strong) NSTextField *removedCountLabel;
@property NSUInteger sessionRemovedCount;
@property (strong) NSButton *exportReportButton;
@property (strong) NSTask *previewTask;
@property BOOL previewWorker;
@property (strong) DSLease *automationLease;
@property BOOL requiresAutomationLease;
@property (strong) DSResourceSampler *liveSampler;
@property dispatch_queue_t liveSampleQueue;
@property BOOL liveSamplePending;
@property (strong) NSTimer *liveSampleTimer;
@property (strong) NSDictionary *liveSnapshot;
@property (strong) DSSpeedometer *cpuGauge;
@property (strong) DSSpeedometer *memoryGauge;
@property (strong) NSTextField *liveProcessLabel;
@property (strong) NSTextField *liveTotalsLabel;
@property (strong) NSWindow *liveProcessWindow;
@property (strong) NSTextView *liveProcessText;
@property (strong) NSScrollView *dashboardScrollView;
@property (strong) NSView *dashboardDocumentView;
@property (strong) NSButton *analyzeAllButton;
@property (strong) NSPopUpButton *profilePopup;
@property (strong) NSTextField *periodicIntervalTextField;
@property (strong) NSButton *scheduleButton;
@property (strong) NSMutableDictionary<NSString *, DSVolumeTarget *> *dashboardVolumeTargets;
@property (strong) NSMutableDictionary<NSString *, NSButton *> *preferenceCheckboxes;
@property (strong) NSMutableDictionary<NSString *, NSTextField *> *preferenceTextFields;
@property (strong) NSMutableDictionary<NSString *, NSString *> *lastCustomAnalysisFingerprints;
@property (nonatomic, copy) NSString *dashboardStatusMessage;
@property (strong) DSOperationState *activeOperation;
@property (strong) NSTextField *operationStatusLabel;
@property (strong) NSProgressIndicator *operationProgressIndicator;
@property (strong) NSButton *cancelOperationButton;
@property (strong) NSTextField *resourceStatusLabel;
@property (strong) NSTextField *scheduleCountdownLabel;
@property BOOL periodicCleanupSuspendedByResourceGuard;
@property NSTimeInterval resourceSampleWallTime;
@property NSTimeInterval resourceSampleCPUTime;
@property NSUInteger consecutiveResourceBreaches;
- (NSDictionary<NSString *, id> *)diskInfoForVolume:(NSURL *)url error:(NSError **)error;
- (NSString *)mountIdentityFromDiskInfo:(NSDictionary *)info;
- (void)handleUnmountedVolumeURL:(NSURL *)url;
- (NSDictionary<NSString *, id> *)cleanupOptionsSnapshot;
- (NSDictionary<NSString *, id> *)previewVolumeOnWorker:(NSURL *)volume expectedMountIdentity:(NSString *)expectedMountIdentity options:(NSDictionary<NSString *, id> *)options;
- (NSDictionary<NSString *, id> *)cleanVolumeOnWorker:(NSURL *)volume expectedMountIdentity:(NSString *)expectedMountIdentity options:(NSDictionary<NSString *, id> *)options;
- (BOOL)isVolumeExcludedForIdentity:(NSString *)identity;
- (BOOL)allowsAutomaticCleaningForIdentity:(NSString *)identity;
- (BOOL)allowsPeriodicCleaningForIdentity:(NSString *)identity;
- (void)setVolumeRuleForIdentity:(NSString *)identity name:(NSString *)name excluded:(BOOL)excluded allowAutomatic:(BOOL)allowAutomatic;
- (void)setPeriodicCleaning:(BOOL)allowed forIdentity:(NSString *)identity name:(NSString *)name;
- (NSString *)customExtensionsFingerprintForOptions:(NSDictionary<NSString *, id> *)options;
- (void)recordCustomExtensionAnalysisForIdentity:(NSString *)identity options:(NSDictionary<NSString *, id> *)options;
- (BOOL)confirmCurrentCustomExtensionsForIdentity:(NSString *)identity name:(NSString *)name;
- (BOOL)resourceGuardShouldPauseForCPUPercent:(double)cpuPercent residentBytes:(uint64_t)residentBytes consecutiveBreaches:(NSUInteger)consecutiveBreaches;
- (void)suspendPeriodicCleanupForResourceGuardWithWarning:(NSString *)warning;
- (void)configurePeriodicCleanupWithMinutes:(NSInteger)minutes;
- (NSString *)nextPeriodicCleanupLabelAtDate:(NSDate *)date;
- (void)requestNotificationAuthorizationAtLaunch;
- (void)notificationAuthorizationStatusWithCompletionHandler:(void (^)(UNAuthorizationStatus status))completionHandler;
- (void)requestNotificationAuthorizationWithOptions:(UNAuthorizationOptions)options completionHandler:(void (^)(BOOL granted, NSError *error))completionHandler;
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
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id storedValue = [defaults objectForKey:DSPeriodicCleaningInterval];
    NSInteger rawValue = [storedValue respondsToSelector:@selector(integerValue)] ? [storedValue integerValue] : 0;
    NSString *unit = [defaults stringForKey:DSPeriodicCleaningIntervalUnit];
    NSInteger minutes = rawValue;

    /*
     * Releases up to 0.4.5 stored one of four preset values in seconds,
     * while the configurable scheduler stores minutes.  A bare NSNumber is
     * inherently ambiguous (900 can mean 15 minutes in the old format or
     * 900 minutes in the current one), so new writes carry an explicit unit.
     * For an upgrade with no marker, migrate only when the old scheduler's
     * two required switches are still enabled.  A modern value configured
     * while the old scheduler is inactive is then preserved as minutes.
     */
    NSSet<NSNumber *> *legacySeconds = [NSSet setWithArray:@[@(15 * 60), @(60 * 60), @(6 * 60 * 60), @(24 * 60 * 60)]];
    BOOL legacySchedulerStillConfigured = [defaults boolForKey:DSAutomaticCleaning] && [defaults boolForKey:DSPeriodicCleaning];
    BOOL migratedLegacyValue = NO;
    if ([unit isEqualToString:DSPeriodicCleaningIntervalUnitSeconds]) {
        minutes = rawValue / 60;
        migratedLegacyValue = YES;
    } else if (![unit isEqualToString:DSPeriodicCleaningIntervalUnitMinutes]) {
        if (legacySchedulerStillConfigured && [storedValue isKindOfClass:NSNumber.class] && [legacySeconds containsObject:@(rawValue)]) {
            minutes = rawValue / 60;
            migratedLegacyValue = YES;
        }
        [defaults setObject:DSPeriodicCleaningIntervalUnitMinutes forKey:DSPeriodicCleaningIntervalUnit];
    }
    if (migratedLegacyValue) {
        [defaults setInteger:minutes forKey:DSPeriodicCleaningInterval];
        [defaults setObject:DSPeriodicCleaningIntervalUnitMinutes forKey:DSPeriodicCleaningIntervalUnit];
    }
    return MAX(DSMinimumPeriodicCleanupIntervalMinutes, MIN(minutes ?: 60, DSMaximumPeriodicCleanupIntervalMinutes));
}

- (NSTimeInterval)periodicCleanupInterval {
    return [self periodicCleanupIntervalMinutes] * 60;
}

- (BOOL)periodicCleanupIsEnabled {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults boolForKey:DSPeriodicCleaning] && !self.periodicCleanupSuspendedByResourceGuard;
}

- (NSString *)periodicCleanupIntervalLabel {
    NSInteger minutes = [self periodicCleanupIntervalMinutes];
    return [NSString stringWithFormat:@"%ld %@", (long)minutes, minutes == 1 ? @"minuto" : @"minuti"];
}

- (void)configurePeriodicCleanupTimer {
    [self.periodicCleanupTimer invalidate];
    self.periodicCleanupTimer = nil;
    if (![self periodicCleanupIsEnabled]) {
        self.nextPeriodicCleanupDate = nil;
        [self.scheduleCountdownTimer invalidate];
        self.scheduleCountdownTimer = nil;
        return;
    }
    self.nextPeriodicCleanupDate = [NSDate dateWithTimeIntervalSinceNow:[self periodicCleanupInterval]];
    self.periodicCleanupTimer = [NSTimer scheduledTimerWithTimeInterval:[self periodicCleanupInterval]
        target:self selector:@selector(runPeriodicCleanup:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.periodicCleanupTimer forMode:NSRunLoopCommonModes];
    [self.scheduleCountdownTimer invalidate];
    self.scheduleCountdownTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(updateScheduleCountdown:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.scheduleCountdownTimer forMode:NSRunLoopCommonModes];
    [self updateScheduleCountdown:nil];
}

- (NSString *)nextPeriodicCleanupLabelAtDate:(NSDate *)date {
    if (self.periodicCleanupSuspendedByResourceGuard) return @"Prossima pulizia: sospesa per protezione risorse";
    if (![self periodicCleanupIsEnabled] || !self.nextPeriodicCleanupDate) return @"Prossima pulizia: pianificazione ferma";
    NSTimeInterval remaining = MAX(0, [self.nextPeriodicCleanupDate timeIntervalSinceDate:date]);
    NSInteger seconds = (NSInteger)ceil(remaining);
    NSInteger hours = seconds / 3600;
    NSInteger minutes = (seconds % 3600) / 60;
    NSInteger secondsPart = seconds % 60;
    NSString *duration = hours > 0 ? [NSString stringWithFormat:@"%ldh %02ldm", (long)hours, (long)minutes] : [NSString stringWithFormat:@"%ldm %02lds", (long)minutes, (long)secondsPart];
    return [NSString stringWithFormat:@"Prossima pulizia tra %@", duration];
}

- (void)updateScheduleCountdown:(NSTimer *)timer {
    (void)timer;
    NSString *label = [self nextPeriodicCleanupLabelAtDate:[NSDate date]];
    self.scheduleCountdownLabel.stringValue = label;
    self.scheduleCountdownLabel.accessibilityValue = label;
}

- (void)configurePeriodicCleanupWithMinutes:(NSInteger)minutes {
    NSInteger clampedMinutes = MAX(DSMinimumPeriodicCleanupIntervalMinutes, MIN(minutes ?: 60, DSMaximumPeriodicCleanupIntervalMinutes));
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    self.periodicCleanupSuspendedByResourceGuard = NO;
    [defaults setInteger:clampedMinutes forKey:DSPeriodicCleaningInterval];
    [defaults setObject:DSPeriodicCleaningIntervalUnitMinutes forKey:DSPeriodicCleaningIntervalUnit];
    [defaults setBool:YES forKey:DSPeriodicCleaning];
    DSBroadcastPreferences();
    [self configurePeriodicCleanupTimer];
    [self setDashboardStatusMessage:[NSString stringWithFormat:@"Pianificazione avviata: ogni %@. %@.", [self periodicCleanupIntervalLabel], [self nextPeriodicCleanupLabelAtDate:[NSDate date]]]];
    [self rebuildMenu];
}

- (BOOL)resourceGuardShouldPauseForCPUPercent:(double)cpuPercent residentBytes:(uint64_t)residentBytes consecutiveBreaches:(NSUInteger)consecutiveBreaches {
    BOOL exceedsCPU = cpuPercent > DSResourceGuardMaximumCPUPercent;
    BOOL exceedsMemory = residentBytes > DSResourceGuardMaximumResidentBytes;
    return consecutiveBreaches >= 2 && (exceedsCPU || exceedsMemory);
}

- (void)suspendPeriodicCleanupForResourceGuardWithWarning:(NSString *)warning {
    self.periodicCleanupSuspendedByResourceGuard = YES;
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:DSPeriodicCleaning];
    DSBroadcastPreferences();
    [self.periodicCleanupTimer invalidate];
    self.periodicCleanupTimer = nil;
    [self.scheduleCountdownTimer invalidate];
    self.scheduleCountdownTimer = nil;
    self.nextPeriodicCleanupDate = nil;
    [self setDashboardStatusMessage:warning];
    [self notify:warning];
    [self updateScheduleCountdown:nil];
}

- (void)stopResourceMonitorForOperation:(DSOperationState *)operation {
    if (operation && !operation.periodicCleanup) return;
    [self.resourceMonitorTimer invalidate];
    self.resourceMonitorTimer = nil;
    self.periodicResourceSampler = nil;
    self.resourceSampleWallTime = 0;
    self.resourceSampleCPUTime = 0;
    self.consecutiveResourceBreaches = 0;
}

- (void)samplePeriodicResourceUsage:(NSTimer *)timer {
    (void)timer;
    DSOperationState *operation = self.activeOperation;
    if (!operation || !operation.periodicCleanup || [self operationShouldStop:operation]) {
        [self stopResourceMonitorForOperation:operation];
        return;
    }
    NSDictionary *snapshot = [self.periodicResourceSampler sample];
    if (!snapshot || [snapshot[@"unavailable"] unsignedIntegerValue]) return;
    double cpuPercent = snapshot[@"cpuPercent"] == NSNull.null ? 0 : [snapshot[@"cpuPercent"] doubleValue];
    uint64_t residentBytes = [snapshot[@"residentBytes"] unsignedLongLongValue];
    BOOL breach = cpuPercent > DSResourceGuardMaximumCPUPercent || residentBytes > DSResourceGuardMaximumResidentBytes;
    self.consecutiveResourceBreaches = breach ? self.consecutiveResourceBreaches + 1 : 0;
    NSString *resourceStatus = [NSString stringWithFormat:@"Impatto pianificazione e figli: CPU %.0f%% · RSS %.0f MiB%@", cpuPercent, residentBytes / (1024.0 * 1024.0), breach ? @" · soglia superata" : @""];
    self.resourceStatusLabel.stringValue = resourceStatus;
    self.resourceStatusLabel.accessibilityValue = resourceStatus;
    if (![self resourceGuardShouldPauseForCPUPercent:cpuPercent residentBytes:residentBytes consecutiveBreaches:self.consecutiveResourceBreaches]) return;
    @synchronized (operation) { operation.cancellationRequested = YES; }
    NSString *warning = [NSString stringWithFormat:@"Pianificazione sospesa: DriveSweep ha superato la soglia risorse per due campioni (CPU %.0f%% / RAM %.0f MB).", cpuPercent, residentBytes / (1024.0 * 1024.0)];
    [self suspendPeriodicCleanupForResourceGuardWithWarning:warning];
    [self updateOperationUI:operation];
    [self stopResourceMonitorForOperation:operation];
}

- (void)startResourceMonitorForOperation:(DSOperationState *)operation {
    if (!operation.periodicCleanup) return;
    [self stopResourceMonitorForOperation:operation];
    self.periodicResourceSampler = [[DSResourceSampler alloc] init];
    self.periodicResourceSampler.includePeers = NO;
    [self.periodicResourceSampler sample];
    self.resourceStatusLabel.stringValue = @"Impatto pianificazione: misuro CPU e RAM di DriveSweep…";
    self.resourceMonitorTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(samplePeriodicResourceUsage:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.resourceMonitorTimer forMode:NSRunLoopCommonModes];
}

- (void)sharedPreferencesChanged:(NSNotification *)notification {
    if ([notification.object isEqual:[NSString stringWithFormat:@"%d", getpid()]]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSUserDefaults.standardUserDefaults synchronize];
        if (![self periodicCleanupIsEnabled] && self.activeOperation.periodicCleanup) {
            @synchronized (self.activeOperation) { self.activeOperation.cancellationRequested = YES; }
        }
        [self configurePeriodicCleanupTimer];
        [self refreshPreferenceControls];
        [self checkMountedVolumes];
        [self rebuildMenu];
    });
}

- (NSString *)liveProcessDescription:(NSDictionary *)snapshot {
    NSMutableString *text = [NSMutableString stringWithString:@"PID      Processo         CPU/core  Fisica MiB   RSS MiB   Read B/s  Write B/s Thread\n"];
    for (NSDictionary *process in snapshot[@"processes"]) {
        if (![process[@"available"] boolValue]) {
            [text appendFormat:@"%-8d %@ · misure non disponibili\n", [process[@"pid"] intValue], process[@"name"]];
            continue;
        }
        NSString *cpu = process[@"cpuPercent"] == NSNull.null ? @"—" : [NSString stringWithFormat:@"%.1f%%", [process[@"cpuPercent"] doubleValue]];
        NSString *reads = process[@"readBytesPerSecond"] == NSNull.null ? @"—" : [process[@"readBytesPerSecond"] description];
        NSString *writes = process[@"writeBytesPerSecond"] == NSNull.null ? @"—" : [process[@"writeBytesPerSecond"] description];
        [text appendFormat:@"%-8d %-16s %8s %10.1f %9.1f %10s %10s %6s\n", [process[@"pid"] intValue], [process[@"name"] UTF8String], cpu.UTF8String,
            [process[@"physicalBytes"] doubleValue] / (1024 * 1024), [process[@"residentBytes"] doubleValue] / (1024 * 1024), reads.UTF8String, writes.UTF8String, [process[@"threads"] description].UTF8String];
    }
    [text appendString:@"\nCPU: 100% = un core. RAM fisica = physical footprint. RSS può differire.\nCampionamento 1 s; i processi molto brevi possono non comparire.\nIl totale somma le misure dei processi e può includere memoria condivisa.\n"];
    return text;
}

- (void)showLiveProcesses:(id)sender {
    if (!self.liveProcessWindow) {
        self.liveProcessWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 760, 420) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
        self.liveProcessWindow.title = @"DriveSweep · processi live";
        self.liveProcessWindow.releasedWhenClosed = NO;
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:self.liveProcessWindow.contentView.bounds];
        scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        scroll.hasVerticalScroller = YES;
        self.liveProcessText = [[NSTextView alloc] initWithFrame:scroll.bounds];
        self.liveProcessText.editable = NO;
        self.liveProcessText.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
        self.liveProcessText.textContainerInset = NSMakeSize(16, 16);
        self.liveProcessText.autoresizingMask = NSViewWidthSizable;
        scroll.documentView = self.liveProcessText;
        [self.liveProcessWindow.contentView addSubview:scroll];
        [self.liveProcessWindow center];
    }
    self.liveProcessText.string = [self liveProcessDescription:self.liveSnapshot ?: @{}];
    [self.liveProcessWindow makeKeyAndOrderFront:nil];
}

- (void)sampleLiveResources:(NSTimer *)timer {
    if (self.liveSamplePending || !self.liveSampler) return;
    self.liveSamplePending = YES;
    dispatch_async(self.liveSampleQueue, ^{
      @autoreleasepool {
        NSDictionary *snapshot = [self.liveSampler sample];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.liveSamplePending = NO;
            self.liveSnapshot = snapshot;
            id cpu = snapshot[@"cpuPercent"];
            uint64_t memory = [snapshot[@"physicalBytes"] unsignedLongLongValue];
            self.cpuGauge.fraction = cpu == NSNull.null ? 0 : [cpu doubleValue] / (100.0 * MAX(1, [snapshot[@"logicalCPUs"] integerValue]));
            self.cpuGauge.value = cpu == NSNull.null ? @"—" : [NSString stringWithFormat:@"%.1f%%", [cpu doubleValue]];
            self.cpuGauge.caption = @"CPU · 100% = un core";
            self.cpuGauge.accessibilityLabel = @"CPU aggregata dei processi DriveSweep";
            self.cpuGauge.accessibilityValue = self.cpuGauge.value;
            self.memoryGauge.fraction = (double)memory / DSResourceGuardMaximumResidentBytes;
            self.memoryGauge.value = [NSString stringWithFormat:@"%.1f MiB", memory / (1024.0 * 1024)];
            self.memoryGauge.caption = @"RAM · scala 750 MiB";
            self.memoryGauge.accessibilityLabel = @"RAM fisica aggregata dei processi DriveSweep";
            self.memoryGauge.accessibilityValue = self.memoryGauge.value;
            self.cpuGauge.needsDisplay = YES; self.memoryGauge.needsDisplay = YES;
            NSString *read = snapshot[@"readBytesPerSecond"] == NSNull.null ? @"—" : [NSByteCountFormatter stringFromByteCount:[snapshot[@"readBytesPerSecond"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile];
            NSString *write = snapshot[@"writeBytesPerSecond"] == NSNull.null ? @"—" : [NSByteCountFormatter stringFromByteCount:[snapshot[@"writeBytesPerSecond"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile];
            self.liveTotalsLabel.stringValue = [NSString stringWithFormat:@"%lu processi · picco %.1f MiB\nI/O lettura %@/s · scrittura %@/s%@", (unsigned long)[snapshot[@"processes"] count], [snapshot[@"peakPhysicalBytes"] doubleValue] / (1024 * 1024), read, write,
                [snapshot[@"unavailable"] unsignedIntegerValue] || [snapshot[@"warmingProcesses"] unsignedIntegerValue] || [snapshot[@"truncated"] boolValue] ? @" · dati parziali" : @""];
            NSMutableArray *rows = [NSMutableArray array];
            for (NSDictionary *process in snapshot[@"processes"]) {
                [rows addObject:[NSString stringWithFormat:@"PID %@ · %@ · %@", process[@"pid"], process[@"name"], [process[@"available"] boolValue] ? [NSString stringWithFormat:@"%.1f MiB", [process[@"physicalBytes"] doubleValue] / (1024 * 1024)] : @"non disponibile"]];
                if (rows.count == 3) break;
            }
            self.liveProcessLabel.stringValue = [rows componentsJoinedByString:@"\n"];
            if (self.liveProcessWindow.isVisible) self.liveProcessText.string = [self liveProcessDescription:snapshot];
        });
      }
    });
}

- (void)startPeriodicCleanup:(id)sender {
    [self showPeriodicScheduleConfiguration:sender];
}

- (void)stopPeriodicCleanup:(id)sender {
    (void)sender;
    self.periodicCleanupSuspendedByResourceGuard = NO;
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:DSPeriodicCleaning];
    DSBroadcastPreferences();
    [self.periodicCleanupTimer invalidate];
    self.periodicCleanupTimer = nil;
    [self.scheduleCountdownTimer invalidate];
    self.scheduleCountdownTimer = nil;
    self.nextPeriodicCleanupDate = nil;
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

- (NSArray<DSVolumeTarget *> *)configuredPeriodicCleanupTargets {
    NSDictionary<NSString *, id> *options = [self cleanupOptionsSnapshot];
    NSMutableArray<DSVolumeTarget *> *targets = [NSMutableArray array];
    for (NSURL *url in self.eligibleVolumes) {
        NSString *identity = self.eligibleVolumeIdentities[url.path];
        if (!identity.length || [self.scheduledCleanupPaths containsObject:url.path]) continue;
        if ([self isVolumeExcludedForIdentity:identity] || ![self allowsPeriodicCleaningForIdentity:identity] || ![self customExtensionsAreConfirmedForIdentity:identity options:options]) continue;
        [targets addObject:[[DSVolumeTarget alloc] initWithVolumeURL:url mountIdentity:identity]];
    }
    return targets.copy;
}

- (NSArray<DSVolumeTarget *> *)periodicCleanupTargets {
    if (![self periodicCleanupIsEnabled] || self.activeOperation) return @[];
    return [self configuredPeriodicCleanupTargets];
}

- (void)showPeriodicScheduleConfiguration:(id)sender {
    (void)sender;
    NSArray<DSVolumeTarget *> *targets = [self configuredPeriodicCleanupTargets];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (DSVolumeTarget *target in targets) [names addObject:target.volumeURL.lastPathComponent ?: @"Disco esterno"];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Configura pianificazione";
    alert.informativeText = targets.count
        ? [NSString stringWithFormat:@"La pulizia partirà solo sui %lu dischi selezionati: %@. Non parte subito.", (unsigned long)targets.count, [names componentsJoinedByString:@", "]]
        : @"Nessun disco è selezionato: puoi comunque avviare il timer, ma non verrà pulito nulla finché non includerai un disco dal menu Azioni.";
    NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 360, 52)];
    NSTextField *label = [NSTextField labelWithString:@"Ogni quanti minuti?"];
    label.frame = NSMakeRect(0, 28, 180, 20);
    [accessory addSubview:label];
    NSTextField *minutes = [[NSTextField alloc] initWithFrame:NSMakeRect(192, 24, 80, 24)];
    minutes.integerValue = [self periodicCleanupIntervalMinutes];
    minutes.identifier = @"scheduleConfigurationInterval";
    minutes.accessibilityLabel = @"Intervallo pianificazione in minuti";
    [accessory addSubview:minutes];
    NSTextField *hint = [NSTextField labelWithString:@"Da 1 a 10.080 minuti · il countdown sarà visibile in Dashboard."];
    hint.frame = NSMakeRect(0, 2, 360, 18);
    hint.font = [NSFont systemFontOfSize:11];
    hint.textColor = NSColor.secondaryLabelColor;
    [accessory addSubview:hint];
    alert.accessoryView = accessory;
    [alert addButtonWithTitle:@"Avvia pianificazione"];
    [alert addButtonWithTitle:@"Annulla"];
    [NSApp activateIgnoringOtherApps:YES];
    if ([alert runModal] == NSAlertFirstButtonReturn) [self configurePeriodicCleanupWithMinutes:minutes.integerValue];
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
    if (self.requiresAutomationLease && !self.automationLease) {
        [self setDashboardStatusMessage:@"Automazione gestita da un'altra istanza DriveSweep. Le azioni manuali restano disponibili."];
        return;
    }
    if ([self periodicCleanupIsEnabled]) {
        self.nextPeriodicCleanupDate = [NSDate dateWithTimeIntervalSinceNow:[self periodicCleanupInterval]];
        [self updateScheduleCountdown:nil];
    }
    NSArray<DSVolumeTarget *> *targets = [self periodicCleanupTargets];
    if (!targets.count) {
        NSString *message = self.activeOperation
            ? [NSString stringWithFormat:@"Pianificazione saltata: %@ è ancora in corso.", self.activeOperation.volumeName]
            : @"Pianificazione eseguita: nessun disco autorizzato o disponibile.";
        [self setDashboardStatusMessage:message];
        self.statusItem.button.toolTip = message;
        [self rebuildMenu];
        return;
    }
    [self cleanNextPeriodicTarget:targets index:0];
}

- (void)notificationAuthorizationStatusWithCompletionHandler:(void (^)(UNAuthorizationStatus status))completionHandler {
    [[UNUserNotificationCenter currentNotificationCenter]
        getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
            if (completionHandler) completionHandler(settings.authorizationStatus);
        }];
}

- (void)requestNotificationAuthorizationWithOptions:(UNAuthorizationOptions)options completionHandler:(void (^)(BOOL granted, NSError *error))completionHandler {
    [[UNUserNotificationCenter currentNotificationCenter]
        requestAuthorizationWithOptions:options completionHandler:completionHandler];
}

- (void)requestNotificationAuthorizationAtLaunch {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [self notificationAuthorizationStatusWithCompletionHandler:^(UNAuthorizationStatus status) {
        /*
         * Only an undetermined status can display Apple's permission prompt.
         * Denied (including policy-restricted environments) and every already
         * resolved status must be a no-op, so launching DriveSweep cannot
         * repeatedly nag the user.  The persisted sentinel is checked only
         * after that status gate and is written immediately after the actual
         * request call is made.
         */
        if (status != UNAuthorizationStatusNotDetermined ||
            [defaults boolForKey:DSNotificationAuthorizationRequested]) return;
        [self requestNotificationAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
            completionHandler:^(BOOL granted, NSError *error) {
                (void)granted;
                (void)error;
            }];
        [defaults setBool:YES forKey:DSNotificationAuthorizationRequested];
    }];
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
    self.lastCustomAnalysisFingerprints = [NSMutableDictionary dictionary];
    self.cleanupQueue = dispatch_queue_create("com.github.naicud.drivesweep.cleanup", DISPATCH_QUEUE_SERIAL);
    self.discoveryQueue = dispatch_queue_create("com.github.naicud.drivesweep.discovery", DISPATCH_QUEUE_SERIAL);
    self.previewRecords = [NSMutableDictionary dictionary];
    self.recentActivity = [NSMutableArray array];
    self.volumeCapacity = @{};
    self.requiresAutomationLease = YES;
    self.automationLease = [DSLease acquire:@"automation"];
    self.liveSampler = [[DSResourceSampler alloc] init];
    self.liveSampleQueue = dispatch_queue_create("com.github.naicud.drivesweep.resources", DISPATCH_QUEUE_SERIAL);
    self.liveSampleTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(sampleLiveResources:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.liveSampleTimer forMode:NSRunLoopCommonModes];
    [[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(sharedPreferencesChanged:) name:@"com.github.naicud.drivesweep.preferences" object:nil];
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSImage *menuIcon = [NSImage imageWithSystemSymbolName:@"broom.fill" accessibilityDescription:@"DriveSweep"];
    menuIcon.template = YES;
    self.statusItem.button.image = menuIcon;
    self.statusItem.button.toolTip = @"DriveSweep — pulisci dischi esterni";
    if (!menuIcon) self.statusItem.button.title = @"DS";
    [self rebuildMenu];
    [self requestNotificationAuthorizationAtLaunch];

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
    [self.scheduleCountdownTimer invalidate];
    [self.resourceMonitorTimer invalidate];
    [self.liveSampleTimer invalidate];
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
    if (self.previewTask.running) kill(self.previewTask.processIdentifier, SIGKILL);
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
    // Drain stdout before waiting: a full pipe must never deadlock discovery.
    // The watchdog runs independently of both serial worker queues.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (task.running) {
            [task terminate];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                if (task.running) kill(task.processIdentifier, SIGKILL);
            });
        }
    });
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
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
    return [self mountIdentityFromDiskInfo:[self diskInfoForVolume:url error:nil]];
}

- (NSString *)mountIdentityFromDiskInfo:(NSDictionary *)info {
    if (![info isKindOfClass:NSDictionary.class]) return nil;
    id volumeUUID = info[@"VolumeUUID"];
    if (![volumeUUID isKindOfClass:NSString.class]) return nil;
    NSString *normalizedUUID = [volumeUUID stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return normalizedUUID.length ? normalizedUUID : nil;
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

- (NSString *)customExtensionsFingerprintForOptions:(NSDictionary<NSString *, id> *)options {
    if (![self cleanupOption:DSCustomFiles isEnabledInOptions:options]) return @"";
    NSArray<NSString *> *extensions = [[options[DSCustomFileExtensions] allObjects] sortedArrayUsingSelector:@selector(compare:)];
    return [extensions componentsJoinedByString:@"\n"];
}

- (BOOL)customExtensionsAreConfirmedForIdentity:(NSString *)identity options:(NSDictionary<NSString *, id> *)options {
    NSString *fingerprint = [self customExtensionsFingerprintForOptions:options];
    if (!fingerprint.length) return YES;
    return identity.length && [[self volumeRuleForIdentity:identity][DSVolumeRuleCustomExtensionsFingerprint] isEqualToString:fingerprint];
}

- (void)recordCustomExtensionAnalysisForIdentity:(NSString *)identity options:(NSDictionary<NSString *, id> *)options {
    NSString *fingerprint = [self customExtensionsFingerprintForOptions:options];
    if (identity.length && fingerprint.length) {
        if (!self.lastCustomAnalysisFingerprints) self.lastCustomAnalysisFingerprints = [NSMutableDictionary dictionary];
        self.lastCustomAnalysisFingerprints[identity] = fingerprint;
    }
}

- (BOOL)confirmCurrentCustomExtensionsForIdentity:(NSString *)identity name:(NSString *)name {
    NSDictionary<NSString *, id> *options = [self cleanupOptionsSnapshot];
    NSString *fingerprint = [self customExtensionsFingerprintForOptions:options];
    if (!identity.length || !fingerprint.length || ![self.lastCustomAnalysisFingerprints[identity] isEqualToString:fingerprint]) return NO;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *rules = [[self volumeRules] mutableCopy];
    NSMutableDictionary *rule = [[self volumeRuleForIdentity:identity] mutableCopy];
    rule[DSVolumeRuleName] = name ?: @"";
    rule[DSVolumeRuleCustomExtensionsFingerprint] = fingerprint;
    rules[identity] = rule.copy;
    [defaults setObject:rules.copy forKey:DSVolumeRules];
    DSBroadcastPreferences();
    return YES;
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
    DSBroadcastPreferences();
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
    DSBroadcastPreferences();
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
    self.operationStatusLabel.toolTip = status;
}

- (void)publishOperation:(DSOperationState *)operation category:(NSString *)category location:(NSURL *)location categoryFinished:(BOOL)categoryFinished force:(BOOL)force {
    if (!operation) return;
    BOOL shouldPublish = force;
    @synchronized (operation) {
        if (category.length) operation.category = category;
        NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
        if (categoryFinished) operation.completedCategories++;
        if (force || now - operation.lastUpdateTime >= 0.25 || categoryFinished) {
            operation.lastUpdateTime = now;
            if (location) operation.safeLocation = [self safeLocationForURL:location volume:operation.volumeURL];
            shouldPublish = YES;
        }
    }
    if (!shouldPublish) return;
    if (self.previewWorker) {
        NSDictionary *progress = @{ @"progress": @YES, @"category": operation.category ?: @"",
            @"location": operation.safeLocation ?: @"", @"completed": @(operation.completedCategories) };
        NSData *data = [NSJSONSerialization dataWithJSONObject:progress options:0 error:nil];
        fwrite(data.bytes, 1, data.length, stdout);
        fputc('\n', stdout);
        fflush(stdout);
        return;
    }
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
    operation.startedAt = NSDate.timeIntervalSinceReferenceDate;
    operation.volumeIdentity = identity ?: @"";
    operation.volumeName = volume.lastPathComponent ?: @"Disco esterno";
    operation.volumeURL = volume;
    operation.totalCategories = [self enabledCategoryCountForOptions:options];
    operation.safeLocation = @"Verifico il disco";
    self.activeOperation = operation;
    [self rebuildMenu];
    [self publishOperation:operation category:nil location:nil categoryFinished:NO force:YES];
    return operation;
}

- (void)finishOperation:(DSOperationState *)operation result:(NSDictionary<NSString *, id> *)result {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (operation != self.activeOperation) return;
        [self stopResourceMonitorForOperation:operation];
        BOOL cancelled = [result[@"cancelled"] boolValue] || [self operationShouldStop:operation];
        NSString *message = cancelled
            ? operation.kind == DSOperationKindPreview
                ? [NSString stringWithFormat:@"Analisi annullata su %@. Nessun file modificato.", operation.volumeName]
                : [NSString stringWithFormat:@"Operazione annullata su %@: %lu elementi già rimossi.", operation.volumeName, (unsigned long)[result[@"removed"] unsignedIntegerValue]]
            : nil;
        if (message.length && !self.periodicCleanupSuspendedByResourceGuard) [self setDashboardStatusMessage:message];
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
    self.mountGeneration++;
    [self checkMountedVolumes];
}

- (void)handleUnmountedVolumeURL:(NSURL *)url {
    NSString *path = url.path;
    if (!path.length) return;
    self.mountGeneration++;

    NSString *identity = self.eligibleVolumeIdentities[path];
    DSOperationState *operation = self.activeOperation;
    BOOL samePath = operation.volumeURL.path.length && [operation.volumeURL.path isEqualToString:path];
    BOOL sameIdentity = operation.volumeIdentity.length && identity.length && [operation.volumeIdentity isEqualToString:identity];
    if (identity.length) {
        [self.previewRecords removeObjectForKey:identity];
        [self.lastCustomAnalysisFingerprints removeObjectForKey:identity];
        [self.handledMountIdentities removeObject:identity];
    }
    if (operation && (samePath || sameIdentity)) {
        @synchronized (operation) { operation.cancellationRequested = YES; }
        if (operation.volumeIdentity.length) [self.lastCustomAnalysisFingerprints removeObjectForKey:operation.volumeIdentity];
        if (sameIdentity && operation.volumeURL.path.length) [self.scheduledCleanupPaths removeObject:operation.volumeURL.path];
    }
    [self.scheduledCleanupPaths removeObject:path];
}

- (void)volumeUnmounted:(NSNotification *)notification {
    NSURL *url = notification.userInfo[NSWorkspaceVolumeURLKey];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self handleUnmountedVolumeURL:url];
        [self checkMountedVolumes];
    });
}

- (void)checkMountedVolumes {
    if (self.requiresAutomationLease && !self.automationLease) self.automationLease = [DSLease acquire:@"automation"];
    if (self.discoveryRunning) { self.discoveryRequested = YES; return; }
    self.discoveryRunning = YES;
    NSUInteger generation = self.mountGeneration;
    dispatch_queue_t queue = self.discoveryQueue ?: self.cleanupQueue;
    dispatch_async(queue, ^{
      @autoreleasepool {
        NSArray<NSURL *> *volumes = [self externalVolumes];
        NSMutableDictionary<NSString *, NSString *> *identities = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSDictionary *> *capacity = [NSMutableDictionary dictionary];
        for (NSURL *url in volumes) {
            NSString *identity = [self mountIdentityForVolume:url];
            if (identity) identities[url.path] = identity;
            NSDictionary *values = [url resourceValuesForKeys:@[NSURLVolumeTotalCapacityKey, NSURLVolumeAvailableCapacityKey, NSURLVolumeLocalizedFormatDescriptionKey] error:nil];
            if (values) capacity[url.path] = values;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.discoveryRunning = NO;
            if (generation != self.mountGeneration) {
                self.discoveryRequested = NO;
                [self checkMountedVolumes];
                return;
            }
            self.eligibleVolumes = volumes;
            self.eligibleVolumeIdentities = identities;
            self.volumeCapacity = capacity.copy;
            NSSet *mountedIdentities = [NSSet setWithArray:identities.allValues];
            for (NSString *identity in self.previewRecords.allKeys.copy) {
                if (![mountedIdentities containsObject:identity]) [self.previewRecords removeObjectForKey:identity];
            }
            [self rebuildMenu];
            if ((!self.requiresAutomationLease || self.automationLease) && [[NSUserDefaults standardUserDefaults] boolForKey:DSAutomaticCleaning]) {
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
            if (self.discoveryRequested) {
                self.discoveryRequested = NO;
                [self checkMountedVolumes];
            }
        });
      }
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
      @autoreleasepool {
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
        if (itemIsDirectory && DSIsProtectedTraversalRootDirectory(item.lastPathComponent)) {
            [enumerator skipDescendants];
            continue;
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
        else if (removeError.code != NSFileNoSuchFileError) [errors addObject:[NSString stringWithFormat:@"%@ (%@)", item.lastPathComponent, removeError.localizedDescription]];
        if (itemIsDirectory) [enumerator skipDescendants];
      }
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
        else if (removeError.code != NSFileNoSuchFileError) [errors addObject:[NSString stringWithFormat:@"%@ (%@)", rootItem.lastPathComponent, removeError.localizedDescription]];
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
    if (removeError.code != NSFileNoSuchFileError) [errors addObject:[NSString stringWithFormat:@"%@ (%@)", name, removeError.localizedDescription]];
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
    DSBroadcastPreferences();
    [self refreshPreferenceControls];
    [self rebuildMenu];
}

- (void)resetSafeDefaults:(id)sender {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary<NSString *, id> *safe = DSDefaultPreferences();
    self.periodicCleanupSuspendedByResourceGuard = NO;
    [defaults setBool:[safe[DSAutomaticCleaning] boolValue] forKey:DSAutomaticCleaning];
    [defaults setBool:[safe[DSPeriodicCleaning] boolValue] forKey:DSPeriodicCleaning];
    [defaults setObject:safe[DSPeriodicCleaningInterval] forKey:DSPeriodicCleaningInterval];
    [defaults setObject:DSPeriodicCleaningIntervalUnitMinutes forKey:DSPeriodicCleaningIntervalUnit];
    for (NSString *key in DSCleanupPreferenceKeys()) [defaults setBool:[safe[key] boolValue] forKey:key];
    [defaults setObject:safe[DSAppleDoubleExtensions] forKey:DSAppleDoubleExtensions];
    [defaults setObject:safe[DSCustomFileExtensions] forKey:DSCustomFileExtensions];
    [defaults setObject:safe[DSCleanupProfile] forKey:DSCleanupProfile];
    DSBroadcastPreferences();
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
      @autoreleasepool {
        if ([self operationShouldStop:operation]) break;
        NSURL *entryURL = [NSURL fileURLWithFileSystemRepresentation:entry->fts_accpath isDirectory:NO relativeToURL:nil];
        [self publishOperation:operation category:nil location:entryURL categoryFinished:NO force:NO];
        if (entry->fts_info == FTS_D) {
            NSNumber *isPackage = nil;
            NSURL *directoryURL = [NSURL fileURLWithFileSystemRepresentation:entry->fts_path isDirectory:YES relativeToURL:nil];
            [directoryURL getResourceValue:&isPackage forKey:NSURLIsPackageKey error:nil];
            NSString *directoryName = [NSString stringWithUTF8String:entry->fts_name];
            if (isPackage.boolValue || DSIsProtectedTraversalRootDirectory(directoryName)) {
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
        else if (errno != ENOENT) [errors addObject:[NSString stringWithFormat:@"%@ (%s)", name, strerror(errno)]];
      }
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
      @autoreleasepool {
        if ([self operationShouldStop:operation]) break;
        NSURL *entryURL = [NSURL fileURLWithFileSystemRepresentation:entry->fts_path isDirectory:entry->fts_info == FTS_D relativeToURL:nil];
        [self publishOperation:operation category:nil location:entryURL categoryFinished:NO force:NO];
        if (entry->fts_info == FTS_D) {
            NSNumber *isPackage = nil;
            [entryURL getResourceValue:&isPackage forKey:NSURLIsPackageKey error:nil];
            NSString *directoryName = [NSString stringWithUTF8String:entry->fts_name];
            if (isPackage.boolValue || DSIsProtectedTraversalRootDirectory(directoryName)) fts_set(tree, entry, FTS_SKIP);
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
        if (!DSIsCustomExtensionCandidate(name, extensions)) continue;
        if (unlink(entry->fts_accpath) == 0) { removed++; [self recordRemovalForOperation:operation]; }
        else if (errno != ENOENT) [errors addObject:[NSString stringWithFormat:@"%@ (%s)", name, strerror(errno)]];
      }
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
        if (isDirectory.boolValue && DSIsProtectedTraversalRootDirectory(item.lastPathComponent)) {
            [enumerator skipDescendants];
            continue;
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
        if (entry->fts_info == FTS_D) {
            NSNumber *isPackage = nil;
            NSURL *directoryURL = [NSURL fileURLWithFileSystemRepresentation:entry->fts_path isDirectory:YES relativeToURL:nil];
            [directoryURL getResourceValue:&isPackage forKey:NSURLIsPackageKey error:nil];
            NSString *directoryName = [NSString stringWithUTF8String:entry->fts_name];
            if (isPackage.boolValue || DSIsProtectedTraversalRootDirectory(directoryName)) fts_set(tree, entry, FTS_SKIP);
            continue;
        }
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
    uint64_t candidateBytes = 0;
    NSSet<NSString *> *protectedExtensions = options[DSAppleDoubleExtensions];
    NSDictionary<NSString *, NSString *> *fileNames = @{ DSDSStore: @".DS_Store", DSApdisk: @".apdisk", DSVolumeIcon: @".VolumeIcon.icns", DSDesktopIni: @"Desktop.ini", DSThumbsDb: @"Thumbs.db" };
    FTSENT *entry = nil;
    while ((entry = fts_read(tree))) {
      @autoreleasepool {
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
        BOOL candidate = NO;
        if ([self cleanupOption:DSAppleDouble isEnabledInOptions:options] && [name hasPrefix:@"._"]) {
            NSString *extension = [[name substringFromIndex:2].pathExtension lowercaseString];
            if ([protectedExtensions containsObject:extension]) protectedCount++;
            else { counts[DSAppleDouble] = @([counts[DSAppleDouble] unsignedIntegerValue] + 1); candidate = YES; }
        }
        if ([self cleanupOption:DSCustomFiles isEnabledInOptions:options] &&
            DSIsCustomExtensionCandidate(name, options[DSCustomFileExtensions])) {
            counts[DSCustomFiles] = @([counts[DSCustomFiles] unsignedIntegerValue] + 1);
            candidate = YES;
        }
        for (NSString *key in fileNames) {
            if ([self cleanupOption:key isEnabledInOptions:options] && [name isEqualToString:fileNames[key]]) {
                counts[key] = @([counts[key] unsignedIntegerValue] + 1);
                candidate = YES;
            }
        }
        if (candidate && entry->fts_statp->st_size > 0) candidateBytes += (uint64_t)entry->fts_statp->st_size;
      }
    }
    fts_close(tree);
    return @{ @"cancelled": @([self operationShouldStop:operation]), @"counts": counts.copy, @"protected": @(protectedCount), @"candidateFileBytes": @(candidateBytes) };
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
    BOOL needsFileTraversal = NO;
    for (NSString *key in @[DSAppleDouble, DSCustomFiles, DSDSStore, DSApdisk, DSVolumeIcon, DSDesktopIni, DSThumbsDb, DSAppleDoubleDirectories]) {
        if ([self cleanupOption:key isEnabledInOptions:options]) { needsFileTraversal = YES; break; }
    }
    NSDictionary<NSString *, id> *filePreview = needsFileTraversal
        ? [self previewFileCountsOnePassFromVolume:volume options:options errors:errors operation:operation]
        : @{ @"counts": @{}, @"protected": @0, @"candidateFileBytes": @0 };
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
    return @{ @"success": @(errors.count == 0), @"cancelled": @NO, @"counts": counts.copy, @"protectedAppleDouble": @(protectedAppleDouble), @"candidateFileBytes": filePreview[@"candidateFileBytes"] ?: @0, @"errors": errors.copy };
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

- (BOOL)automaticCleanupStillAllowedForOperation:(DSOperationState *)operation identity:(NSString *)identity options:(NSDictionary<NSString *, id> *)options {
    if (!operation.automaticCleanup) return YES;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (operation.periodicCleanup) {
        NSDictionary<NSString *, id> *currentOptions = [self cleanupOptionsSnapshot];
        BOOL operationUsesCustomFiles = [self cleanupOption:DSCustomFiles isEnabledInOptions:options];
        BOOL customRulesStillMatch = !operationUsesCustomFiles ||
            ([self cleanupOption:DSCustomFiles isEnabledInOptions:currentOptions] &&
             [currentOptions[DSCustomFileExtensions] isEqual:options[DSCustomFileExtensions]]);
        return [defaults boolForKey:DSPeriodicCleaning] &&
            [self allowsPeriodicCleaningForIdentity:identity] &&
            customRulesStillMatch &&
            [self customExtensionsAreConfirmedForIdentity:identity options:options];
    }
    return [defaults boolForKey:DSAutomaticCleaning] && [self allowsAutomaticCleaningForIdentity:identity];
}

- (NSDictionary<NSString *, id> *)cleanVolumeOnWorker:(NSURL *)volume expectedMountIdentity:(NSString *)expectedMountIdentity options:(NSDictionary<NSString *, id> *)options operation:(DSOperationState *)operation {
    __attribute__((objc_precise_lifetime)) DSLease *lease = [DSLease acquire:@"cleanup"];
    if (!lease) return @{ @"success": @NO, @"busy": @YES, @"removed": @0, @"errors": @[@"Un'altra istanza app/CLI sta già pulendo. Riprova quando termina."] };
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
    if (![self automaticCleanupStillAllowedForOperation:operation identity:expectedMountIdentity options:options]) {
        return @{ @"success": @NO, @"removed": @0, @"appleDoubleProcessed": @NO, @"errors": @[@"La pulizia automatica non è più autorizzata."] };
    }
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    NSUInteger removed = 0;
    BOOL appleDoubleProcessed = [self cleanupOption:DSAppleDouble isEnabledInOptions:options];
    if (appleDoubleProcessed) {
        if (![self automaticCleanupStillAllowedForOperation:operation identity:expectedMountIdentity options:options]) return @{ @"success": @NO, @"removed": @0, @"appleDoubleProcessed": @NO, @"errors": @[@"La pulizia automatica non è più autorizzata."] };
        if (![self volume:volume matchesExpectedMountIdentity:expectedMountIdentity]) return [self mountChangedCleanupResultWithRemoved:removed];
        [self publishOperation:operation category:DSAppleDouble location:volume categoryFinished:NO force:YES];
        removed += [self removeAppleDoubleFilesFromVolume:volume protectedExtensions:options[DSAppleDoubleExtensions] errors:errors operation:operation];
        if ([self operationShouldStop:operation]) return [self cancelledCleanupResult:removed errors:errors];
        [self publishOperation:operation category:DSAppleDouble location:nil categoryFinished:YES force:YES];
    }
    if ([self cleanupOption:DSCustomFiles isEnabledInOptions:options]) {
        if (![self automaticCleanupStillAllowedForOperation:operation identity:expectedMountIdentity options:options]) return @{ @"success": @NO, @"removed": @(removed), @"appleDoubleProcessed": @(appleDoubleProcessed), @"errors": @[@"La pulizia automatica non è più autorizzata."] };
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
        if (![self automaticCleanupStillAllowedForOperation:operation identity:expectedMountIdentity options:options]) return @{ @"success": @NO, @"removed": @(removed), @"appleDoubleProcessed": @(appleDoubleProcessed), @"errors": @[@"La pulizia automatica non è più autorizzata."] };
        if (![self volume:volume matchesExpectedMountIdentity:expectedMountIdentity]) return [self mountChangedCleanupResultWithRemoved:removed];
        [self publishOperation:operation category:key location:volume categoryFinished:NO force:YES];
        removed += [self removeNamedFiles:entry[1] fromVolume:volume directoriesOnly:[entry[2] boolValue] errors:errors operation:operation];
        if ([self operationShouldStop:operation]) return [self cancelledCleanupResult:removed errors:errors];
        [self publishOperation:operation category:key location:nil categoryFinished:YES force:YES];
    }
    NSDictionary<NSString *, NSString *> *rootCategories = @{ DSTrashes: @".Trashes", DSSpotlight: @".Spotlight-V100", DSFileEvents: @".fseventsd", DSTemporaryItems: @".TemporaryItems" };
    for (NSString *key in rootCategories) {
        if (![self cleanupOption:key isEnabledInOptions:options]) continue;
        if (![self automaticCleanupStillAllowedForOperation:operation identity:expectedMountIdentity options:options]) return @{ @"success": @NO, @"removed": @(removed), @"appleDoubleProcessed": @(appleDoubleProcessed), @"errors": @[@"La pulizia automatica non è più autorizzata."] };
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
    [self startResourceMonitorForOperation:operation];
    [self.scheduledCleanupPaths addObject:volume.path];
    [self setDashboardStatusMessage:[NSString stringWithFormat:@"Pulizia di %@ in corso…", volume.lastPathComponent]];
    [self rebuildMenu];
    dispatch_async(self.cleanupQueue, ^{
        NSDictionary<NSString *, id> *result = [self cleanVolumeOnWorker:volume expectedMountIdentity:expectedMountIdentity options:options operation:operation];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.scheduledCleanupPaths removeObject:volume.path];
            BOOL success = [result[@"success"] boolValue] && ![self operationShouldStop:operation];
            NSUInteger removed = [result[@"removed"] unsignedIntegerValue];
            NSArray<NSString *> *errors = result[@"errors"];
            BOOL cancelled = [result[@"cancelled"] boolValue] || [self operationShouldStop:operation];
            self.sessionRemovedCount += removed;
            [self.previewRecords removeObjectForKey:expectedMountIdentity];
            NSString *details = [NSString stringWithFormat:@"%lu elementi rimossi", (unsigned long)removed];
            NSString *message = (cancelled && self.periodicCleanupSuspendedByResourceGuard)
                ? [NSString stringWithFormat:@"Pulizia di %@ interrotta (%@). Pianificazione sospesa per protezione risorse: riattivala quando il carico è rientrato.", volume.lastPathComponent, details]
                : cancelled
                ? [NSString stringWithFormat:@"Pulizia di %@ annullata (%@).", volume.lastPathComponent, details]
                : success
                ? [NSString stringWithFormat:@"%@ pulito (%@; %@).", volume.lastPathComponent, source, details]
                : [NSString stringWithFormat:@"Pulizia di %@ non completata: %@", volume.lastPathComponent, [errors componentsJoinedByString:@"; "]];
            [self setDashboardStatusMessage:message];
            [self addRecentActivity:message];
            self.statusItem.button.toolTip = message;
            if (!success || ![source isEqualToString:@"controllo automatico"]) [self notify:message];
            [self rebuildMenu];
            if (periodicAutomatic && completion) {
                /*
                 * finishOperation enqueues its UI cleanup on the main queue.
                 * Keep that block ahead of a periodic chain continuation so
                 * the next selected volume cannot observe the previous
                 * operation as still active and get skipped by cleanVolume:.
                 */
                [self finishOperation:operation result:result];
                dispatch_async(dispatch_get_main_queue(), ^{ completion(success); });
            } else {
                if (completion) completion(success);
                [self finishOperation:operation result:result];
            }
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
        NSDictionary<NSString *, id> *report = [self previewInSubprocess:volume identity:expectedMountIdentity options:options operation:operation];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishOperation:operation result:report];
            if ([report[@"success"] boolValue] && ![self operationShouldStop:operation] && [self.eligibleVolumeIdentities[volume.path] isEqualToString:expectedMountIdentity]) [self recordCustomExtensionAnalysisForIdentity:expectedMountIdentity options:options];
            if (![self operationShouldStop:operation] || [report[@"cancelled"] boolValue]) [self recordPreview:report volume:volume identity:expectedMountIdentity options:options elapsed: NSDate.timeIntervalSinceReferenceDate - operation.startedAt];
            [self showDashboard:nil];
        });
    });
}

- (NSDictionary *)previewInSubprocess:(NSURL *)volume identity:(NSString *)identity options:(NSDictionary *)options operation:(DSOperationState *)operation {
    // Read-only scanning is isolated from the UI and destructive cleanup queue.
    // A filesystem call can block in the kernel; cancelling abandons that child,
    // never a deletion in progress. Keep at most one unreaped child.
    if (self.previewTask.running) return @{ @"success": @NO, @"counts": @{}, @"errors": @[@"Le risorse della precedente analisi sono ancora in attesa del filesystem. Riprova quando il disco risponde."] };
    NSMutableDictionary *wireOptions = [options mutableCopy];
    for (NSString *key in @[DSAppleDoubleExtensions, DSCustomFileExtensions]) {
        NSSet *set = options[key];
        wireOptions[key] = set.allObjects ?: @[];
    }
    NSData *input = [NSJSONSerialization dataWithJSONObject:wireOptions options:0 error:nil];
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = NSBundle.mainBundle.executableURL;
    task.arguments = @[@"--preview-worker", volume.path, identity ?: @""];
    NSPipe *stdinPipe = [NSPipe pipe];
    NSPipe *stdoutPipe = [NSPipe pipe];
    task.standardInput = stdinPipe;
    task.standardOutput = stdoutPipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSObject *lock = [[NSObject alloc] init];
    NSMutableData *buffer = [NSMutableData data];
    __block NSDictionary *report = nil;
    __block BOOL eof = NO;
    __block BOOL overflow = NO;
    stdoutPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *chunk = handle.availableData;
        @synchronized (lock) {
            if (!chunk.length) { eof = YES; handle.readabilityHandler = nil; return; }
            if (buffer.length + chunk.length > 1024 * 1024) { overflow = YES; return; }
            [buffer appendData:chunk];
            while (buffer.length) {
                const char *bytes = buffer.bytes;
                const char *newline = memchr(bytes, '\n', buffer.length);
                if (!newline) break;
                NSUInteger length = (NSUInteger)(newline - bytes);
                NSData *line = [buffer subdataWithRange:NSMakeRange(0, length)];
                [buffer replaceBytesInRange:NSMakeRange(0, length + 1) withBytes:NULL length:0];
                NSDictionary *message = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
                if (![message isKindOfClass:NSDictionary.class]) continue;
                if ([message[@"progress"] boolValue]) {
                    @synchronized (operation) {
                        operation.category = message[@"category"];
                        operation.safeLocation = message[@"location"];
                        operation.completedCategories = [message[@"completed"] unsignedIntegerValue];
                    }
                    dispatch_async(dispatch_get_main_queue(), ^{ [self updateOperationUI:operation]; });
                } else report = message;
            }
        }
    };
    NSError *error = nil;
    if (!input || ![task launchAndReturnError:&error]) {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil;
        return @{ @"success": @NO, @"counts": @{}, @"errors": @[error.localizedDescription ?: @"Avvio analisi non riuscito."] };
    }
    self.previewTask = task;
    [stdinPipe.fileHandleForWriting writeData:input];
    [stdinPipe.fileHandleForWriting closeFile];
    while (YES) {
        BOOL finished = NO, tooLarge = NO;
        @synchronized (lock) { finished = eof && !task.running; tooLarge = overflow; }
        if ([self operationShouldStop:operation] || tooLarge) {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil;
            if (task.running) [task terminate];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                if (task.running) kill(task.processIdentifier, SIGKILL);
            });
            return [self operationShouldStop:operation]
                ? @{ @"success": @NO, @"cancelled": @YES, @"counts": @{}, @"protectedAppleDouble": @0, @"errors": @[] }
                : @{ @"success": @NO, @"counts": @{}, @"errors": @[@"Analisi interrotta: troppe informazioni diagnostiche."] };
        }
        if (finished) break;
        [NSThread sleepForTimeInterval:0.05];
    }
    stdoutPipe.fileHandleForReading.readabilityHandler = nil;
    @synchronized (lock) {
        return report ?: @{ @"success": @NO, @"counts": @{}, @"errors": @[@"Il processo di analisi è terminato senza un report valido."] };
    }
}

- (void)addRecentActivity:(NSString *)message {
    if (!self.recentActivity) self.recentActivity = [NSMutableArray array];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"HH:mm";
    [self.recentActivity insertObject:[NSString stringWithFormat:@"%@  %@", [formatter stringFromDate:NSDate.date], message] atIndex:0];
    while (self.recentActivity.count > 8) [self.recentActivity removeLastObject];
}

- (void)recordPreview:(NSDictionary *)report volume:(NSURL *)volume identity:(NSString *)identity options:(NSDictionary *)options elapsed:(NSTimeInterval)elapsed {
    // A report belongs to one mounted UUID and one exact options snapshot.
    if (!identity.length || ![self.eligibleVolumeIdentities[volume.path] isEqualToString:identity]) return;
    if (!self.previewRecords) self.previewRecords = [NSMutableDictionary dictionary];
    self.previewRecords[identity] = @{ @"report": report, @"options": options, @"date": NSDate.date, @"elapsed": @(elapsed), @"name": volume.lastPathComponent ?: @"Disco" };
    NSString *message = [NSString stringWithFormat:@"%@ · analisi %@ in %.2f s", volume.lastPathComponent,
        [report[@"cancelled"] boolValue] ? @"annullata" : [report[@"success"] boolValue] ? @"completata" : @"parziale", elapsed];
    [self setDashboardStatusMessage:message];
    [self addRecentActivity:message];
    [self refreshDashboard];
}

- (NSDictionary *)currentPreviewForIdentity:(NSString *)identity {
    NSDictionary *record = identity.length ? self.previewRecords[identity] : nil;
    return [record[@"options"] isEqual:[self cleanupOptionsSnapshot]] ? record : nil;
}

- (void)showReportFromDashboard:(NSButton *)sender {
    DSVolumeTarget *target = [self volumeTargetForDashboardButton:sender];
    NSDictionary *record = [self currentPreviewForIdentity:target.mountIdentity];
    if (record) [self showPreviewReport:record[@"report"] options:record[@"options"] volume:target.volumeURL];
}

- (NSData *)dashboardReportData {
    NSMutableArray *volumes = [NSMutableArray array];
    for (NSURL *volume in self.eligibleVolumes) {
        NSDictionary *record = [self currentPreviewForIdentity:self.eligibleVolumeIdentities[volume.path]];
        if (!record) continue;
        NSDictionary *report = record[@"report"];
        [volumes addObject:@{ @"volume": record[@"name"], @"analyzedAt": @([record[@"date"] timeIntervalSince1970]),
            @"durationSeconds": record[@"elapsed"], @"complete": report[@"success"] ?: @NO,
            @"cancelled": report[@"cancelled"] ?: @NO, @"counts": report[@"counts"] ?: @{},
            @"protectedAppleDouble": report[@"protectedAppleDouble"] ?: @0,
            @"candidateFileBytes": report[@"candidateFileBytes"] ?: @0, @"errorCount": @([report[@"errors"] count]) }];
    }
    return [NSJSONSerialization dataWithJSONObject:@{ @"app": @"DriveSweep", @"schemaVersion": @1,
        @"note": @"Snapshot di analisi, non garanzia dei file attuali. Dimensioni logiche dei soli file, cartelle escluse; non spazio recuperabile.",
        @"volumes": volumes } options:NSJSONWritingPrettyPrinted error:nil];
}

- (void)exportDashboardReport:(id)sender {
    NSData *data = [self dashboardReportData];
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = @"DriveSweep-report.json";
    panel.title = @"Esporta analisi dei dischi";
    if ([panel runModal] != NSModalResponseOK) return;
    NSError *error = nil;
    if (![data writeToURL:panel.URL options:NSDataWritingAtomic error:&error]) {
        [self setDashboardStatusMessage:[NSString stringWithFormat:@"Esportazione non riuscita: %@", error.localizedDescription]];
    } else [self setDashboardStatusMessage:@"Report salvato. I dati restano sul tuo Mac."];
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
    NSString *periodicStatus = self.periodicCleanupSuspendedByResourceGuard
        ? @"Pulizia periodica sospesa — soglia risorse superata"
        : [self periodicCleanupIsEnabled]
        ? [NSString stringWithFormat:@"Pulizia periodica attiva — ogni %@", [self periodicCleanupIntervalLabel]]
        : @"Pulizia periodica disattivata";
    NSMenuItem *periodicItem = [[NSMenuItem alloc] initWithTitle:periodicStatus action:nil keyEquivalent:@""];
    periodicItem.enabled = NO;
    [menu addItem:periodicItem];
    NSString *periodicToggleTitle = self.periodicCleanupSuspendedByResourceGuard ? @"Riattiva pianificazione…" : ([self periodicCleanupIsEnabled] ? @"Ferma pianificazione" : @"Avvia pianificazione");
    NSMenuItem *periodicToggle = [[NSMenuItem alloc] initWithTitle:periodicToggleTitle action:@selector(togglePeriodicCleanup:) keyEquivalent:@""];
    periodicToggle.target = self;
    [menu addItem:periodicToggle];
    NSMenuItem *periodicConfigure = [[NSMenuItem alloc] initWithTitle:@"Configura pianificazione…" action:@selector(showPeriodicScheduleConfiguration:) keyEquivalent:@""];
    periodicConfigure.target = self;
    [menu addItem:periodicConfigure];
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
    if (self.activeOperation) return;
    NSMutableArray<DSVolumeTarget *> *targets = [NSMutableArray array];
    for (NSURL *volume in self.eligibleVolumes) {
        NSString *identity = self.eligibleVolumeIdentities[volume.path];
        if (identity.length && ![self isVolumeExcludedForIdentity:identity]) {
            [targets addObject:[[DSVolumeTarget alloc] initWithVolumeURL:volume mountIdentity:identity]];
        }
    }
    if (!targets.count) {
        [self notify:@"Non ci sono dischi esterni idonei da analizzare."];
        return;
    }
    [self previewTargets:targets index:0 options:[self cleanupOptionsSnapshot]];
}

- (void)previewTargets:(NSArray<DSVolumeTarget *> *)targets index:(NSUInteger)index options:(NSDictionary *)options {
    if (index >= targets.count) return;
    DSVolumeTarget *target = targets[index];
    DSOperationState *operation = [self beginOperationKind:DSOperationKindPreview volume:target.volumeURL identity:target.mountIdentity options:options];
    if (!operation) return;
    [self refreshDashboard];
    dispatch_async(self.cleanupQueue, ^{
        NSDictionary *report = [self previewInSubprocess:target.volumeURL identity:target.mountIdentity options:options operation:operation];
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([report[@"success"] boolValue] && ![self operationShouldStop:operation] && [self.eligibleVolumeIdentities[target.volumeURL.path] isEqualToString:target.mountIdentity]) [self recordCustomExtensionAnalysisForIdentity:target.mountIdentity options:options];
            if (![self operationShouldStop:operation] || [report[@"cancelled"] boolValue]) [self recordPreview:report volume:target.volumeURL identity:target.mountIdentity options:options elapsed: NSDate.timeIntervalSinceReferenceDate - operation.startedAt];
            [self finishOperation:operation result:report];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (![report[@"cancelled"] boolValue] && ![self operationShouldStop:operation]) {
                    [self previewTargets:targets index:index + 1 options:options];
                }
            });
        });
    });
}

- (void)cleanAll:(id)sender {
    // Keep the old selector safe for an already-built menu: the global action is preview-only.
    [self previewAll:sender];
}

- (void)cleanFromMenu:(NSMenuItem *)sender {
    DSVolumeTarget *target = sender.representedObject;
    if (![self confirmManualCleanupForTarget:target]) return;
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
    if (![self confirmManualCleanupForTarget:target]) return;
    [self cleanVolume:target.volumeURL source:@"manuale" expectedMountIdentity:target.mountIdentity completion:nil];
}

- (void)cleanAndEjectFromDashboardButton:(NSButton *)sender {
    DSVolumeTarget *target = [self volumeTargetForDashboardButton:sender];
    if (![self confirmManualCleanupForTarget:target]) return;
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

- (void)confirmCustomExtensionsFromMenu:(NSMenuItem *)sender {
    DSVolumeTarget *target = sender.representedObject;
    if (!target.mountIdentity.length) return;
    if ([self confirmCurrentCustomExtensionsForIdentity:target.mountIdentity name:target.volumeURL.lastPathComponent]) {
        [self setDashboardStatusMessage:[NSString stringWithFormat:@"Regole file personalizzate confermate per %@.", target.volumeURL.lastPathComponent]];
        [self notify:@"Regole file personalizzate confermate per la pianificazione."];
    } else {
        [self setDashboardStatusMessage:@"Analizza prima il disco con le estensioni correnti, poi conferma le regole per la pianificazione."];
        [self notify:@"Conferma non disponibile: analizza prima il disco con le estensioni correnti."];
    }
    [self rebuildMenu];
}

- (void)cleanAndEject:(NSMenuItem *)sender {
    DSVolumeTarget *target = sender.representedObject;
    if (![self confirmManualCleanupForTarget:target]) return;
    [self cleanVolume:target.volumeURL source:@"prima dell'espulsione" expectedMountIdentity:target.mountIdentity completion:^(BOOL success) {
        if (!success) {
            [self notify:[NSString stringWithFormat:@"%@ non è stato espulso: la pulizia non è stata completata.", target.volumeURL.lastPathComponent]];
            return;
        }
        [self ejectVolumeTarget:target];
    }];
}

- (BOOL)confirmManualCleanupForTarget:(DSVolumeTarget *)target {
    if (!target.mountIdentity.length || self.activeOperation || [self isVolumeExcludedForIdentity:target.mountIdentity]) return NO;
    NSDictionary *options = [self cleanupOptionsSnapshot];
    NSMutableArray *categories = [NSMutableArray array];
    for (NSString *key in DSCleanupPreferenceKeys()) {
        if ([self cleanupOption:key isEnabledInOptions:options]) [categories addObject:DSCleanupReportLabel(key)];
    }
    if (!categories.count) {
        [self setDashboardStatusMessage:@"Nessuna categoria selezionata. Configura le preferenze prima di pulire."];
        return NO;
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = [NSString stringWithFormat:@"Pulire %@?", target.volumeURL.lastPathComponent];
    alert.informativeText = [NSString stringWithFormat:@"Categorie selezionate:\n%@\n\nLa rimozione è definitiva. AppleDouble può contenere metadati utili; il cestino e le estensioni personalizzate possono contenere dati personali. Termina le copie e verifica il backup prima di procedere. L'analisi è uno snapshot: i file possono essere cambiati.", [categories componentsJoinedByString:@" · "]];
    [alert addButtonWithTitle:@"Annulla"];
    [alert addButtonWithTitle:@"Pulisci"];
    [NSApp activateIgnoringOtherApps:YES];
    return [alert runModal] == NSAlertSecondButtonReturn;
}

- (BOOL)ejectVerifiedVolumeTarget:(DSVolumeTarget *)target error:(NSError **)error {
    if (![self volume:target.volumeURL matchesExpectedMountIdentity:target.mountIdentity]) {
        if (error) *error = [NSError errorWithDomain:@"DriveSweep" code:3 userInfo:@{NSLocalizedDescriptionKey: @"UUID cambiato: espulsione bloccata."}];
        return NO;
    }
    return [[NSWorkspace sharedWorkspace] unmountAndEjectDeviceAtURL:target.volumeURL error:error];
}

- (void)ejectVolumeTarget:(DSVolumeTarget *)target {
    NSError *error = nil;
    if (![self ejectVerifiedVolumeTarget:target error:&error]) {
        [self notify:[NSString stringWithFormat:@"Non riesco a espellere %@: %@", target.volumeURL.lastPathComponent, error.localizedDescription]];
    }
}

- (void)showDashboard:(id)sender {
    if (!self.dashboardWindow) {
        self.dashboardWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 960, 940)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        // Keep the retained dashboard instance valid after the user closes it.
        // applicationShouldHandleReopen: reuses this window instead of allocating
        // a new controller, so AppKit must not release it on close.
        self.dashboardWindow.releasedWhenClosed = NO;
        self.dashboardWindow.title = @"DriveSweep";
        self.dashboardWindow.minSize = NSMakeSize(780, 850);
        self.dashboardWindow.delegate = self;
        [self.dashboardWindow center];

        NSView *content = self.dashboardWindow.contentView;
        NSTextField *title = DSLabel(@"DriveSweep", 32, NSFontWeightBold, NSColor.labelColor);
        NSTextField *badge = DSLabel(@"V3.1  /  GRATIS · LOCALE", 11, NSFontWeightSemibold, NSColor.controlAccentColor);
        NSStackView *heading = DSStack(@[title, badge], NSUserInterfaceLayoutOrientationHorizontal, 20);
        NSTextField *description = DSLabel(@"Dischi in ordine. File sotto controllo.", 17, NSFontWeightMedium, NSColor.secondaryLabelColor);
        NSStackView *hero = DSStack(@[heading, description], NSUserInterfaceLayoutOrientationVertical, 5);

        self.volumeCountLabel = DSLabel(@"0", 30, NSFontWeightSemibold, NSColor.labelColor);
        self.candidateCountLabel = DSLabel(@"—", 30, NSFontWeightSemibold, NSColor.controlAccentColor);
        self.protectedCountLabel = DSLabel(@"—", 30, NSFontWeightSemibold, NSColor.labelColor);
        self.removedCountLabel = DSLabel(@"0", 30, NSFontWeightSemibold, NSColor.labelColor);
        NSMutableArray<NSView *> *metrics = [NSMutableArray array];
        NSArray *values = @[self.volumeCountLabel, self.candidateCountLabel, self.protectedCountLabel, self.removedCountLabel];
        NSArray *names = @[@"Dischi collegati", @"Candidati rilevati", @"AppleDouble protetti", @"Rimossi nella sessione"];
        for (NSUInteger i = 0; i < values.count; i++) {
            [(NSTextField *)values[i] setFont:[NSFont monospacedDigitSystemFontOfSize:30 weight:NSFontWeightSemibold]];
            NSView *tile = [[DSSurfaceView alloc] init];
            tile.wantsLayer = YES;
            tile.layer.backgroundColor = NSColor.controlBackgroundColor.CGColor;
            tile.layer.cornerRadius = 14;
            NSStackView *labels = DSStack(@[values[i], DSLabel(names[i], 11, NSFontWeightMedium, NSColor.secondaryLabelColor)], NSUserInterfaceLayoutOrientationVertical, 4);
            labels.translatesAutoresizingMaskIntoConstraints = NO;
            [tile addSubview:labels];
            [NSLayoutConstraint activateConstraints:@[
                [tile.heightAnchor constraintEqualToConstant:96],
                [labels.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:18],
                [labels.centerYAnchor constraintEqualToAnchor:tile.centerYAnchor],
                [labels.trailingAnchor constraintLessThanOrEqualToAnchor:tile.trailingAnchor constant:-10]
            ]];
            [metrics addObject:tile];
        }
        NSStackView *summary = DSStack(metrics, NSUserInterfaceLayoutOrientationHorizontal, 12);
        summary.distribution = NSStackViewDistributionFillEqually;

        self.dashboardStatusLabel = DSLabel(@"Collega un disco per iniziare.", 12, NSFontWeightMedium, NSColor.secondaryLabelColor);
        self.analyzeAllButton = [NSButton buttonWithTitle:@"Analizza tutti" target:self action:@selector(previewAll:)];
        self.analyzeAllButton.bezelStyle = NSBezelStyleRounded;
        self.analyzeAllButton.keyEquivalent = @"r";
        self.analyzeAllButton.image = [NSImage imageWithSystemSymbolName:@"magnifyingglass" accessibilityDescription:nil];
        self.analyzeAllButton.imagePosition = NSImageLeft;
        self.analyzeAllButton.accessibilityLabel = @"Analizza tutti i dischi esterni";
        NSButton *preferences = [NSButton buttonWithTitle:@"Preferenze…" target:self action:@selector(showPreferences:)];
        preferences.bezelStyle = NSBezelStyleRounded;
        self.scheduleButton = [NSButton buttonWithTitle:@"Avvia pianificazione" target:self action:@selector(togglePeriodicCleanup:)];
        self.scheduleButton.bezelStyle = NSBezelStyleRounded;
        self.scheduleButton.accessibilityLabel = @"Avvia o ferma pulizia periodica";
        self.exportReportButton = [NSButton buttonWithTitle:@"Esporta report" target:self action:@selector(exportDashboardReport:)];
        self.exportReportButton.bezelStyle = NSBezelStyleRounded;
        NSStackView *toolbar = DSStack(@[self.analyzeAllButton, self.scheduleButton, self.exportReportButton, preferences], NSUserInterfaceLayoutOrientationHorizontal, 10);

        self.operationStatusLabel = DSLabel(@"Pronto. L'analisi non modifica i file.", 12, NSFontWeightMedium, NSColor.labelColor);
        self.operationProgressIndicator = [[NSProgressIndicator alloc] init];
        self.operationProgressIndicator.indeterminate = YES;
        self.operationProgressIndicator.hidden = YES;
        self.cancelOperationButton = [NSButton buttonWithTitle:@"Annulla" target:self action:@selector(cancelActiveOperation:)];
        self.cancelOperationButton.bezelStyle = NSBezelStyleRounded;
        self.cancelOperationButton.hidden = YES;
        NSStackView *operationRow = DSStack(@[self.operationStatusLabel, self.cancelOperationButton], NSUserInterfaceLayoutOrientationHorizontal, 12);
        [self.operationStatusLabel setContentCompressionResistancePriority:250 forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self.cancelOperationButton setContentCompressionResistancePriority:1000 forOrientation:NSLayoutConstraintOrientationHorizontal];
        self.scheduleCountdownLabel = DSLabel(@"Prossima pulizia: pianificazione ferma", 11, NSFontWeightMedium, NSColor.secondaryLabelColor);
        self.scheduleCountdownLabel.accessibilityLabel = @"Prossima pulizia pianificata";
        self.resourceStatusLabel = DSLabel(@"Un disco alla volta · protezione CPU/RAM per la pianificazione", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
        self.resourceStatusLabel.accessibilityLabel = @"Impatto hardware della pianificazione";
        NSStackView *activity = DSStack(@[operationRow, self.operationProgressIndicator, self.scheduleCountdownLabel, self.resourceStatusLabel], NSUserInterfaceLayoutOrientationVertical, 6);

        self.cpuGauge = [[DSSpeedometer alloc] init];
        self.memoryGauge = [[DSSpeedometer alloc] init];
        self.cpuGauge.accessibilityElement = YES;
        self.memoryGauge.accessibilityElement = YES;
        self.cpuGauge.caption = @"CPU · 100% = un core";
        self.memoryGauge.caption = @"RAM · scala 750 MiB";
        self.liveTotalsLabel = [NSTextField wrappingLabelWithString:@"Misuro le risorse di DriveSweep e dei processi figli…"];
        self.liveTotalsLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        self.liveProcessLabel = [NSTextField wrappingLabelWithString:@""];
        self.liveProcessLabel.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
        self.liveProcessLabel.textColor = NSColor.secondaryLabelColor;
        NSButton *details = [NSButton buttonWithTitle:@"Processi live…" target:self action:@selector(showLiveProcesses:)];
        details.bezelStyle = NSBezelStyleRounded;
        NSStackView *liveDetails = DSStack(@[self.liveTotalsLabel, self.liveProcessLabel, details], NSUserInterfaceLayoutOrientationVertical, 7);
        NSStackView *resources = DSStack(@[self.cpuGauge, self.memoryGauge, liveDetails], NSUserInterfaceLayoutOrientationHorizontal, 18);
        [NSLayoutConstraint activateConstraints:@[
            [self.cpuGauge.widthAnchor constraintEqualToConstant:170],
            [self.memoryGauge.widthAnchor constraintEqualToConstant:170],
            [self.cpuGauge.heightAnchor constraintEqualToConstant:138],
            [self.memoryGauge.heightAnchor constraintEqualToConstant:138],
            [liveDetails.widthAnchor constraintEqualToAnchor:resources.widthAnchor constant:-376],
            [self.liveTotalsLabel.widthAnchor constraintEqualToAnchor:liveDetails.widthAnchor],
            [self.liveProcessLabel.widthAnchor constraintEqualToAnchor:liveDetails.widthAnchor]
        ]];

        self.dashboardScrollView = [[NSScrollView alloc] init];
        self.dashboardScrollView.hasVerticalScroller = YES;
        self.dashboardScrollView.autohidesScrollers = YES;
        self.dashboardScrollView.drawsBackground = NO;
        self.dashboardScrollView.borderType = NSNoBorder;
        self.dashboardDocumentView = [[DSFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 896, 100)];
        self.dashboardDocumentView.autoresizingMask = NSViewWidthSizable;
        self.dashboardScrollView.documentView = self.dashboardDocumentView;
        NSTextField *privacy = DSLabel(@"Solo dischi esterni fisici · nessun account · nessuna telemetria · Apache 2.0", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
        NSStackView *layout = DSStack(@[hero, summary, toolbar, self.dashboardStatusLabel, activity, resources, self.dashboardScrollView, privacy], NSUserInterfaceLayoutOrientationVertical, 18);
        layout.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:layout];
        [NSLayoutConstraint activateConstraints:@[
            [layout.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:28],
            [layout.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-28],
            [layout.topAnchor constraintEqualToAnchor:content.topAnchor constant:26],
            [layout.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-20],
            [summary.widthAnchor constraintEqualToAnchor:layout.widthAnchor],
            [self.dashboardStatusLabel.widthAnchor constraintEqualToAnchor:layout.widthAnchor],
            [activity.widthAnchor constraintEqualToAnchor:layout.widthAnchor],
            [resources.widthAnchor constraintEqualToAnchor:layout.widthAnchor],
            [operationRow.widthAnchor constraintEqualToAnchor:activity.widthAnchor],
            [self.scheduleCountdownLabel.widthAnchor constraintEqualToAnchor:activity.widthAnchor],
            [self.resourceStatusLabel.widthAnchor constraintEqualToAnchor:activity.widthAnchor],
            [self.operationProgressIndicator.widthAnchor constraintEqualToAnchor:activity.widthAnchor],
            [self.dashboardScrollView.widthAnchor constraintEqualToAnchor:layout.widthAnchor],
            [self.dashboardScrollView.heightAnchor constraintGreaterThanOrEqualToConstant:180]
        ]];
        [self.dashboardScrollView setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
        [self.dashboardScrollView setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    }
    [self refreshDashboard];
    [self.dashboardWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)windowDidResize:(NSNotification *)notification {
    if (notification.object == self.dashboardWindow) [self refreshDashboard];
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
    if ([[self cleanupOptionsSnapshot][DSCustomFiles] boolValue]) {
        NSMenuItem *confirmCustom = [[NSMenuItem alloc] initWithTitle:@"Conferma file personalizzati dopo analisi" action:@selector(confirmCustomExtensionsFromMenu:) keyEquivalent:@""];
        confirmCustom.target = self; confirmCustom.representedObject = target; confirmCustom.enabled = identity.length > 0 && !excluded;
        [menu addItem:confirmCustom];
    }
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
    NSView *card = [[DSSurfaceView alloc] initWithFrame:frame];
    card.wantsLayer = YES;
    card.layer.backgroundColor = NSColor.controlBackgroundColor.CGColor;
    card.layer.cornerRadius = 16;
    CGFloat width = frame.size.width;
    CGFloat height = frame.size.height;
    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(20, height - 64, 38, 38)];
    icon.image = [NSImage imageWithSystemSymbolName:@"externaldrive.fill" accessibilityDescription:@"Disco esterno"];
    icon.contentTintColor = NSColor.controlAccentColor;
    icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    [card addSubview:icon];

    NSTextField *name = [NSTextField labelWithString:volume.lastPathComponent ?: @"Disco esterno"];
    name.frame = NSMakeRect(74, height - 46, width * 0.48 - 74, 24);
    name.font = [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
    name.lineBreakMode = NSLineBreakByTruncatingTail;
    name.toolTip = volume.lastPathComponent;
    [card addSubview:name];

    NSString *rule = [self volumeRuleSummaryForIdentity:identity];
    if ([self.scheduledCleanupPaths containsObject:volume.path]) rule = @"Pulizia in corso…";
    if (self.activeOperation) {
        rule = [self.activeOperation.volumeIdentity isEqualToString:identity]
            ? [self operationStatusText:self.activeOperation]
            : [NSString stringWithFormat:@"In attesa: %@ in corso", self.activeOperation.volumeName];
    }
    NSTextField *status = [NSTextField labelWithString:rule];
    status.frame = NSMakeRect(74, height - 67, width * 0.48 - 74, 20);
    status.font = [NSFont systemFontOfSize:12];
    status.textColor = [self isVolumeExcludedForIdentity:identity] ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
    status.lineBreakMode = NSLineBreakByTruncatingTail;
    status.toolTip = rule;
    [card addSubview:status];

    NSDictionary *capacity = self.volumeCapacity[volume.path];
    int64_t total = [capacity[NSURLVolumeTotalCapacityKey] longLongValue];
    int64_t available = [capacity[NSURLVolumeAvailableCapacityKey] longLongValue];
    NSString *capacityText = total > 0 ? [NSString stringWithFormat:@"%@ liberi di %@",
        [NSByteCountFormatter stringFromByteCount:available countStyle:NSByteCountFormatterCountStyleFile],
        [NSByteCountFormatter stringFromByteCount:total countStyle:NSByteCountFormatterCountStyleFile]] : @"Capacità non disponibile";
    NSTextField *capacityLabel = DSLabel(capacityText, 12, NSFontWeightMedium, NSColor.labelColor);
    capacityLabel.frame = NSMakeRect(width * 0.52, height - 40, width * 0.48 - 24, 18);
    capacityLabel.alignment = NSTextAlignmentRight;
    [card addSubview:capacityLabel];
    DSCapacityBar *bar = [[DSCapacityBar alloc] initWithFrame:NSMakeRect(width * 0.52, height - 58, width * 0.48 - 24, 7)];
    bar.usedFraction = total > 0 ? (double)(total - available) / (double)total : 0;
    bar.accessibilityElement = YES;
    bar.accessibilityLabel = @"Spazio utilizzato sul disco";
    bar.accessibilityValue = total > 0 ? [NSString stringWithFormat:@"%.0f percento", bar.usedFraction * 100] : @"Non disponibile";
    [card addSubview:bar];
    NSString *format = capacity[NSURLVolumeLocalizedFormatDescriptionKey] ?: @"Disco fisico esterno";
    NSTextField *formatLabel = DSLabel(format, 10, NSFontWeightRegular, NSColor.secondaryLabelColor);
    formatLabel.frame = NSMakeRect(width * 0.52, height - 76, width * 0.48 - 24, 14);
    formatLabel.alignment = NSTextAlignmentRight;
    [card addSubview:formatLabel];

    NSDictionary *record = [self currentPreviewForIdentity:identity];
    NSDictionary *report = record[@"report"];
    NSString *reportTitle = @"Inizia con un'analisi";
    NSString *reportDetail = @"Scopri i metadati presenti. Nessun file viene modificato durante l'analisi.";
    if (record) {
        NSUInteger count = 0;
        NSMutableArray *categories = [NSMutableArray array];
        for (NSString *key in DSCleanupPreferenceKeys()) {
            NSUInteger value = [report[@"counts"][key] unsignedIntegerValue];
            count += value;
            if (value) [categories addObject:[NSString stringWithFormat:@"%@: %lu", DSCleanupReportLabel(key), (unsigned long)value]];
        }
        NSString *size = [NSByteCountFormatter stringFromByteCount:[report[@"candidateFileBytes"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile];
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"HH:mm";
        NSString *state = [report[@"cancelled"] boolValue] ? @"Annullata" : [report[@"success"] boolValue] ? @"Analizzata" : @"Parziale";
        reportTitle = [NSString stringWithFormat:@"%@ %@ · %lu candidati · %lu protetti · %.2f s", state, [formatter stringFromDate:record[@"date"]], (unsigned long)count,
            (unsigned long)[report[@"protectedAppleDouble"] unsignedIntegerValue], [record[@"elapsed"] doubleValue]];
        reportDetail = [NSString stringWithFormat:@"%@\n%@ di file candidati (cartelle escluse). %@", categories.count ? [categories componentsJoinedByString:@"  ·  "] : @"Nessun candidato rilevato nelle categorie selezionate.", size,
            [report[@"errors"] count] ? @"Sono presenti errori: apri i dettagli." : @"Snapshot: riesegui dopo nuove copie."];
        if ([report[@"cancelled"] boolValue]) {
            reportTitle = [NSString stringWithFormat:@"Analisi annullata alle %@ · nessun file modificato", [formatter stringFromDate:record[@"date"]]];
            reportDetail = @"Nessun conteggio finale disponibile. Puoi rieseguire l'analisi quando vuoi.";
        }
    } else if (self.previewRecords[identity]) {
        reportTitle = @"Opzioni cambiate · riesegui l'analisi";
    }
    NSTextField *reportLabel = DSLabel(reportTitle, 13, NSFontWeightSemibold, NSColor.labelColor);
    reportLabel.frame = NSMakeRect(24, 102, width - 48, 22);
    reportLabel.toolTip = reportTitle;
    [card addSubview:reportLabel];
    NSTextField *detail = [NSTextField wrappingLabelWithString:reportDetail];
    detail.font = [NSFont systemFontOfSize:11];
    detail.textColor = NSColor.secondaryLabelColor;
    detail.frame = NSMakeRect(24, 55, width - 48, 42);
    detail.toolTip = reportDetail;
    [card addSubview:detail];

    BOOL excluded = [self isVolumeExcludedForIdentity:identity];
    BOOL identityVerified = identity.length > 0;
    BOOL busy = [self.scheduledCleanupPaths containsObject:volume.path] || self.activeOperation != nil;
    BOOL actionsEnabled = identityVerified && !excluded && !busy;
    NSButton *analyze = [self dashboardButtonWithTitle:@"Analizza" action:@selector(previewFromDashboardButton:) identity:identity frame:NSMakeRect(18, 15, 104, 30) enabled:actionsEnabled];
    analyze.image = [NSImage imageWithSystemSymbolName:@"magnifyingglass" accessibilityDescription:nil];
    analyze.imagePosition = NSImageLeft;
    analyze.accessibilityLabel = [NSString stringWithFormat:@"Analizza %@", volume.lastPathComponent];
    [card addSubview:analyze];
    [card addSubview:[self dashboardButtonWithTitle:@"Dettagli" action:@selector(showReportFromDashboard:) identity:identity frame:NSMakeRect(126, 15, 94, 30) enabled:record != nil]];
    [card addSubview:[self dashboardButtonWithTitle:@"Pulisci ed espelli" action:@selector(cleanAndEjectFromDashboardButton:) identity:identity frame:NSMakeRect(width - 300, 15, 150, 30) enabled:actionsEnabled]];
    NSButton *actions = [self dashboardActionsButtonForVolume:volume identity:identity enabled:actionsEnabled];
    actions.frame = NSMakeRect(width - 146, 15, 126, 30);
    [card addSubview:actions];
    return card;
}

- (void)refreshDashboard {
    if (!self.dashboardStatusLabel || !self.dashboardDocumentView) return;
    self.scheduleButton.title = [self periodicCleanupIsEnabled] ? @"Ferma pianificazione" : @"Avvia pianificazione";
    [self updateScheduleCountdown:nil];
    NSArray<NSURL *> *volumes = self.eligibleVolumes;
    self.volumeCountLabel.stringValue = [NSString stringWithFormat:@"%lu", (unsigned long)volumes.count];
    NSUInteger candidates = 0, protected = 0, reports = 0;
    for (NSURL *volume in volumes) {
        NSString *identity = self.eligibleVolumeIdentities[volume.path];
        NSDictionary *record = [self currentPreviewForIdentity:identity];
        NSDictionary *report = record[@"report"];
        if (!record || ![report[@"success"] boolValue] || [self isVolumeExcludedForIdentity:identity]) continue;
        reports++;
        for (NSNumber *count in [report[@"counts"] allValues]) candidates += count.unsignedIntegerValue;
        protected += [report[@"protectedAppleDouble"] unsignedIntegerValue];
    }
    self.candidateCountLabel.stringValue = reports ? [NSString stringWithFormat:@"%lu", (unsigned long)candidates] : @"—";
    self.protectedCountLabel.stringValue = reports ? [NSString stringWithFormat:@"%lu", (unsigned long)protected] : @"—";
    self.candidateCountLabel.toolTip = @"Somma degli snapshot di analisi completi, con le opzioni correnti. Riesegui dopo nuove copie.";
    self.removedCountLabel.stringValue = [NSString stringWithFormat:@"%lu", (unsigned long)self.sessionRemovedCount];
    NSUInteger exportable = 0;
    for (NSURL *volume in volumes) if ([self currentPreviewForIdentity:self.eligibleVolumeIdentities[volume.path]]) exportable++;
    self.exportReportButton.enabled = exportable > 0;
    if (!self.activeOperation) self.operationStatusLabel.stringValue = @"Pronto. L'analisi non modifica i file.";
    CGFloat width = MAX(700, self.dashboardScrollView.contentSize.width);
    [self.dashboardVolumeTargets removeAllObjects];
    for (NSView *subview in [self.dashboardDocumentView.subviews copy]) [subview removeFromSuperview];
    if (volumes.count == 0) {
        self.dashboardStatusLabel.stringValue = self.dashboardStatusMessage.length ? self.dashboardStatusMessage : @"Nessun disco esterno idoneo collegato.";
        self.analyzeAllButton.enabled = NO;
        NSImageView *illustration = [[NSImageView alloc] initWithFrame:NSMakeRect(width / 2 - 30, 24, 60, 54)];
        illustration.image = [NSImage imageWithSystemSymbolName:@"externaldrive.badge.plus" accessibilityDescription:nil];
        illustration.contentTintColor = NSColor.controlAccentColor;
        [self.dashboardDocumentView addSubview:illustration];
        NSTextField *emptyTitle = DSLabel(@"Il prossimo disco, pronto a partire.", 20, NSFontWeightSemibold, NSColor.labelColor);
        emptyTitle.frame = NSMakeRect(16, 96, width - 32, 28);
        emptyTitle.alignment = NSTextAlignmentCenter;
        [self.dashboardDocumentView addSubview:emptyTitle];
        NSTextField *empty = [NSTextField wrappingLabelWithString:@"Collega una chiavetta, una SD o un disco esterno scrivibile.\nDriveSweep verifica il dispositivo prima di mostrarti le azioni disponibili.\nIl disco interno, le immagini disco e le unità di rete restano esclusi."];
        empty.frame = NSMakeRect(30, 137, width - 60, 64);
        empty.alignment = NSTextAlignmentCenter;
        empty.textColor = NSColor.secondaryLabelColor;
        [self.dashboardDocumentView addSubview:empty];
        self.dashboardDocumentView.frame = NSMakeRect(0, 0, width, 224);
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
    self.analyzeAllButton.enabled = actionableCount > 0 && !self.activeOperation;
    CGFloat y = 6;
    for (NSURL *volume in volumes) {
        NSString *identity = self.eligibleVolumeIdentities[volume.path];
        [self.dashboardDocumentView addSubview:[self dashboardCardForVolume:volume identity:identity frame:NSMakeRect(0, y, width - 4, 220)]];
        y += 234;
    }
    if (self.recentActivity.count) {
        NSTextField *heading = DSLabel(@"Attività della sessione", 13, NSFontWeightSemibold, NSColor.labelColor);
        heading.frame = NSMakeRect(8, y + 10, width - 20, 22);
        [self.dashboardDocumentView addSubview:heading];
        y += 40;
        for (NSString *message in self.recentActivity) {
            NSTextField *event = DSLabel(message, 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
            event.frame = NSMakeRect(8, y, width - 24, 20);
            event.toolTip = message;
            [self.dashboardDocumentView addSubview:event];
            y += 26;
        }
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
    /* Keep comma-separated custom extensions editable as plain text.  The
     * normalized array is committed only when editing ends, otherwise typing
     * `tmp,bak` is rewritten after each keystroke and the caret jumps. */
    field.continuous = ![key isEqualToString:DSCustomFileExtensions];
    if ([key isEqualToString:DSCustomFileExtensions]) {
        field.placeholderString = @"tmp, bak";
        field.delegate = (id<NSTextFieldDelegate>)self;
    }
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
        [document addSubview:[self preferenceLabel:@"Intervallo in minuti (da 1 a 10.080):" y:1136 height:20 font:[NSFont systemFontOfSize:11] color:NSColor.secondaryLabelColor]];
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
    if ([sender.identifier isEqualToString:DSPeriodicCleaning] && sender.state == NSControlStateValueOn) {
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:DSPeriodicCleaning];
        [self showPeriodicScheduleConfiguration:sender];
    } else if ([sender.identifier isEqualToString:DSAutomaticCleaning] || [sender.identifier isEqualToString:DSPeriodicCleaning]) {
        [self configurePeriodicCleanupTimer];
    }
    [self refreshPreferenceControls];
    DSBroadcastPreferences();
    [self rebuildMenu];
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    NSTextField *field = notification.object;
    if ([field isKindOfClass:NSTextField.class] && [field.identifier isEqualToString:DSCustomFileExtensions]) {
        [self saveTextPreference:field];
    }
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
    DSBroadcastPreferences();
    [self rebuildMenu];
}

- (void)savePeriodicInterval:(NSTextField *)sender {
    NSInteger minutes = MAX(DSMinimumPeriodicCleanupIntervalMinutes, MIN(sender.integerValue ?: 60, DSMaximumPeriodicCleanupIntervalMinutes));
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:minutes forKey:DSPeriodicCleaningInterval];
    [defaults setObject:DSPeriodicCleaningIntervalUnitMinutes forKey:DSPeriodicCleaningIntervalUnit];
    sender.stringValue = [NSString stringWithFormat:@"%ld", (long)minutes];
    DSBroadcastPreferences();
    [self configurePeriodicCleanupTimer];
    [self rebuildMenu];
}

@end

#import "CLI.inc"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [[NSUserDefaults standardUserDefaults] registerDefaults:DSDefaultPreferences()];
        if (argc >= 2 && strcmp(argv[1], "--cli") == 0) {
            NSArray *arguments = NSProcessInfo.processInfo.arguments;
            return DSRunCLI([arguments subarrayWithRange:NSMakeRange(2, arguments.count - 2)]);
        }
        if (argc == 4 && strcmp(argv[1], "--preview-worker") == 0) {
            NSData *input = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
            NSMutableDictionary *options = [[NSJSONSerialization JSONObjectWithData:input options:NSJSONReadingMutableContainers error:nil] mutableCopy];
            if (![options isKindOfClass:NSMutableDictionary.class]) return 2;
            for (NSString *key in @[DSAppleDoubleExtensions, DSCustomFileExtensions]) {
                id values = options[key];
                if (![values isKindOfClass:NSArray.class]) return 2;
                options[key] = [NSSet setWithArray:values];
            }
            DriveSweepController *controller = [[DriveSweepController alloc] init];
            controller.previewWorker = YES;
            DSOperationState *operation = [[DSOperationState alloc] init];
            operation.volumeURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];
            operation.volumeName = operation.volumeURL.lastPathComponent;
            operation.totalCategories = [controller enabledCategoryCountForOptions:options];
            NSDictionary *report = [controller previewVolumeOnWorker:operation.volumeURL expectedMountIdentity:[NSString stringWithUTF8String:argv[3]] options:options operation:operation];
            NSData *data = [NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
            if (!data) return 2;
            fwrite(data.bytes, 1, data.length, stdout);
            fputc('\n', stdout);
            return 0;
        }
        NSApplication *app = [NSApplication sharedApplication];
        DriveSweepController *controller = [[DriveSweepController alloc] init];
        app.delegate = controller;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
