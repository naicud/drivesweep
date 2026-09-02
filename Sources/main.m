#import <Cocoa/Cocoa.h>
#import <UserNotifications/UserNotifications.h>

static NSString *const DSAutomaticCleaning = @"automaticCleaning";
static NSString *const DSAppleDouble = @"appleDouble";
static NSString *const DSDSStore = @"dsStore";
static NSString *const DSTrashes = @"trashes";
static NSString *const DSSpotlight = @"spotlight";
static NSString *const DSFileEvents = @"fileEvents";
static NSString *const DSExcludedVolumes = @"excludedVolumes";

@interface DriveSweepController : NSObject <NSApplicationDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) NSWindow *preferencesWindow;
@property (strong) NSMutableSet<NSString *> *handledMounts;
@property (strong) NSTimer *scanTimer;
@end

@implementation DriveSweepController

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        DSAutomaticCleaning: @YES,
        DSAppleDouble: @YES,
        DSDSStore: @YES,
        DSTrashes: @YES,
        DSSpotlight: @NO,
        DSFileEvents: @NO,
        DSExcludedVolumes: @""
    }];

    self.handledMounts = [NSMutableSet set];
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.image = [NSImage imageNamed:@"AppIcon"];
    self.statusItem.button.toolTip = @"DriveSweep — pulisci dischi esterni";
    self.statusItem.button.title = @"";
    [self rebuildMenu];
    [[UNUserNotificationCenter currentNotificationCenter]
        requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
        completionHandler:^(BOOL granted, NSError *error) {}];

    NSNotificationCenter *workspaceCenter = [[NSWorkspace sharedWorkspace] notificationCenter];
    [workspaceCenter addObserver:self selector:@selector(volumeMounted:) name:NSWorkspaceDidMountNotification object:nil];
    [workspaceCenter addObserver:self selector:@selector(volumeUnmounted:) name:NSWorkspaceDidUnmountNotification object:nil];
    self.scanTimer = [NSTimer scheduledTimerWithTimeInterval:15 target:self selector:@selector(checkMountedVolumes) userInfo:nil repeats:YES];
    [self checkMountedVolumes];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.scanTimer invalidate];
}

- (NSArray<NSURL *> *)externalVolumes {
    NSArray *keys = @[NSURLVolumeNameKey, NSURLVolumeIsReadOnlyKey];
    NSArray<NSURL *> *mounted = [[NSFileManager defaultManager]
        mountedVolumeURLsIncludingResourceValuesForKeys:keys
        options:NSVolumeEnumerationSkipHiddenVolumes];
    NSMutableArray<NSURL *> *external = [NSMutableArray array];
    for (NSURL *url in mounted) {
        if ([self isEligibleExternalVolume:url]) [external addObject:url];
    }
    return external;
}

- (BOOL)isEligibleExternalVolume:(NSURL *)url {
    NSNumber *readOnly = nil;
    [url getResourceValue:&readOnly forKey:NSURLVolumeIsReadOnlyKey error:nil];
    if (readOnly.boolValue) return NO;

    NSString *name = url.lastPathComponent ?: @"";
    NSString *excluded = [[NSUserDefaults standardUserDefaults] stringForKey:DSExcludedVolumes] ?: @"";
    for (NSString *rawCandidate in [excluded componentsSeparatedByString:@","]) {
        NSString *candidate = [rawCandidate stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (candidate.length && [candidate caseInsensitiveCompare:name] == NSOrderedSame) return NO;
    }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/diskutil"];
    task.arguments = @[@"info", url.path];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exception) {
        return NO;
    }
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    NSString *info = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    return [info rangeOfString:@"Device Location:        External"].location != NSNotFound;
}

- (void)volumeMounted:(NSNotification *)notification {
    NSURL *url = notification.userInfo[NSWorkspaceVolumeURLKey];
    if (!url || ![self isEligibleExternalVolume:url]) return;
    [self rebuildMenu];
    if ([[NSUserDefaults standardUserDefaults] boolForKey:DSAutomaticCleaning]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self cleanVolumeIfNeeded:url source:@"montaggio automatico"];
        });
    }
}

- (void)volumeUnmounted:(NSNotification *)notification {
    NSURL *url = notification.userInfo[NSWorkspaceVolumeURLKey];
    if (url) [self.handledMounts removeObject:url.path];
    [self rebuildMenu];
}

- (void)checkMountedVolumes {
    for (NSURL *url in [self externalVolumes]) {
        if ([[NSUserDefaults standardUserDefaults] boolForKey:DSAutomaticCleaning]) {
            [self cleanVolumeIfNeeded:url source:@"controllo automatico"];
        }
    }
    [self rebuildMenu];
}

- (void)cleanVolumeIfNeeded:(NSURL *)url source:(NSString *)source {
    if ([self.handledMounts containsObject:url.path]) return;
    [self.handledMounts addObject:url.path];
    [self cleanVolume:url source:source];
}

- (NSUInteger)removeNamedFiles:(NSString *)name fromVolume:(NSURL *)volume directoriesOnly:(BOOL)directoriesOnly {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [manager enumeratorAtURL:volume
        includingPropertiesForKeys:@[NSURLIsDirectoryKey]
        options:NSDirectoryEnumerationSkipsPackageDescendants
        errorHandler:^BOOL(NSURL *url, NSError *error) { return YES; }];
    NSUInteger removed = 0;
    NSURL *item = nil;
    while ((item = [enumerator nextObject])) {
        NSNumber *isDirectory = nil;
        [item getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
        if (isDirectory.boolValue && [@[@".Trashes", @".Spotlight-V100", @".fseventsd"] containsObject:item.lastPathComponent]) {
            [enumerator skipDescendants];
        }
        if (![item.lastPathComponent isEqualToString:name]) continue;
        if (directoriesOnly != isDirectory.boolValue) continue;
        if ([manager removeItemAtURL:item error:nil]) removed++;
        if (isDirectory.boolValue) [enumerator skipDescendants];
    }
    NSURL *rootItem = [volume URLByAppendingPathComponent:name];
    if ([manager fileExistsAtPath:rootItem.path] && [manager removeItemAtURL:rootItem error:nil]) removed++;
    return removed;
}

- (NSUInteger)removeRootDirectory:(NSString *)name fromVolume:(NSURL *)volume {
    NSURL *target = [volume URLByAppendingPathComponent:name];
    if (![[NSFileManager defaultManager] fileExistsAtPath:target.path]) return 0;
    return [[NSFileManager defaultManager] removeItemAtURL:target error:nil] ? 1 : 0;
}

- (void)runDotClean:(NSURL *)volume {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/dot_clean"];
    task.arguments = @[@"-m", volume.path];
    task.standardOutput = [NSPipe pipe];
    task.standardError = [NSPipe pipe];
    @try { [task launch]; [task waitUntilExit]; } @catch (NSException *exception) { }
}

- (void)cleanVolume:(NSURL *)volume source:(NSString *)source {
    if (![self isEligibleExternalVolume:volume]) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSUInteger removed = 0;
    if ([defaults boolForKey:DSAppleDouble]) [self runDotClean:volume];
    if ([defaults boolForKey:DSDSStore]) removed += [self removeNamedFiles:@".DS_Store" fromVolume:volume directoriesOnly:NO];
    if ([defaults boolForKey:DSTrashes]) removed += [self removeRootDirectory:@".Trashes" fromVolume:volume];
    if ([defaults boolForKey:DSSpotlight]) removed += [self removeRootDirectory:@".Spotlight-V100" fromVolume:volume];
    if ([defaults boolForKey:DSFileEvents]) removed += [self removeRootDirectory:@".fseventsd" fromVolume:volume];
    [self notify:[NSString stringWithFormat:@"%@ pulito (%@).", volume.lastPathComponent, source]];
    [self rebuildMenu];
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
    NSMenuItem *cleanAll = [[NSMenuItem alloc] initWithTitle:@"Pulisci tutti i dischi esterni" action:@selector(cleanAll:) keyEquivalent:@"c"];
    cleanAll.target = self;
    [menu addItem:cleanAll];

    NSArray<NSURL *> *volumes = [self externalVolumes];
    if (volumes.count) {
        [menu addItem:[NSMenuItem separatorItem]];
        for (NSURL *url in volumes) {
            NSMenuItem *volumeItem = [[NSMenuItem alloc] initWithTitle:url.lastPathComponent action:nil keyEquivalent:@""];
            NSMenu *submenu = [[NSMenu alloc] initWithTitle:url.lastPathComponent];
            NSMenuItem *clean = [[NSMenuItem alloc] initWithTitle:@"Pulisci ora" action:@selector(cleanFromMenu:) keyEquivalent:@""];
            clean.target = self; clean.representedObject = url;
            NSMenuItem *eject = [[NSMenuItem alloc] initWithTitle:@"Pulisci ed espelli" action:@selector(cleanAndEject:) keyEquivalent:@""];
            eject.target = self; eject.representedObject = url;
            [submenu addItem:clean]; [submenu addItem:eject];
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
}

- (void)cleanAll:(id)sender { for (NSURL *url in [self externalVolumes]) [self cleanVolume:url source:@"manuale"]; }
- (void)cleanFromMenu:(NSMenuItem *)sender { [self cleanVolume:sender.representedObject source:@"manuale"]; }

- (void)cleanAndEject:(NSMenuItem *)sender {
    NSURL *url = sender.representedObject;
    [self cleanVolume:url source:@"prima dell'espulsione"];
    NSError *error = nil;
    if (![[NSWorkspace sharedWorkspace] unmountAndEjectDeviceAtURL:url error:&error]) {
        [self notify:[NSString stringWithFormat:@"Non riesco a espellere %@: %@", url.lastPathComponent, error.localizedDescription]];
    }
}

- (NSButton *)checkbox:(NSString *)title key:(NSString *)key y:(CGFloat)y {
    NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(24, y, 390, 24)];
    button.buttonType = NSButtonTypeSwitch;
    button.title = title;
    button.state = [[NSUserDefaults standardUserDefaults] boolForKey:key] ? NSControlStateValueOn : NSControlStateValueOff;
    button.target = self;
    button.action = @selector(saveCheckbox:);
    button.identifier = key;
    return button;
}

- (void)showPreferences:(id)sender {
    if (!self.preferencesWindow) {
        self.preferencesWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 440, 330)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
            backing:NSBackingStoreBuffered defer:NO];
        self.preferencesWindow.title = @"Preferenze DriveSweep";
        NSView *content = self.preferencesWindow.contentView;
        [content addSubview:[self checkbox:@"Pulisci automaticamente quando collego un disco" key:DSAutomaticCleaning y:280]];
        [content addSubview:[self checkbox:@"Rimuovi file ._* (AppleDouble)" key:DSAppleDouble y:242]];
        [content addSubview:[self checkbox:@"Rimuovi .DS_Store" key:DSDSStore y:210]];
        [content addSubview:[self checkbox:@"Svuota .Trashes del disco" key:DSTrashes y:178]];
        [content addSubview:[self checkbox:@"Rimuovi indice Spotlight (.Spotlight-V100)" key:DSSpotlight y:146]];
        [content addSubview:[self checkbox:@"Rimuovi registro eventi (.fseventsd)" key:DSFileEvents y:114]];
        NSTextField *label = [NSTextField labelWithString:@"Escludi dischi (nomi separati da virgola):"];
        label.frame = NSMakeRect(24, 78, 390, 20); [content addSubview:label];
        NSTextField *excluded = [[NSTextField alloc] initWithFrame:NSMakeRect(24, 48, 390, 24)];
        excluded.stringValue = [[NSUserDefaults standardUserDefaults] stringForKey:DSExcludedVolumes] ?: @"";
        excluded.identifier = DSExcludedVolumes; excluded.target = self; excluded.action = @selector(saveExcluded:);
        [content addSubview:excluded];
        NSTextField *note = [NSTextField labelWithString:@"Per sicurezza DriveSweep non pulisce mai dischi interni, immagini disco o volumi in sola lettura."];
        note.frame = NSMakeRect(24, 16, 400, 20); note.font = [NSFont systemFontOfSize:11]; note.textColor = NSColor.secondaryLabelColor;
        [content addSubview:note];
    }
    [self.preferencesWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)saveCheckbox:(NSButton *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:(sender.state == NSControlStateValueOn) forKey:sender.identifier];
    [self rebuildMenu];
}
- (void)saveExcluded:(NSTextField *)sender { [[NSUserDefaults standardUserDefaults] setObject:sender.stringValue forKey:DSExcludedVolumes]; [self rebuildMenu]; }

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        DriveSweepController *controller = [[DriveSweepController alloc] init];
        app.delegate = controller;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
