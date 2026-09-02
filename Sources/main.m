#import <Cocoa/Cocoa.h>
#import <UserNotifications/UserNotifications.h>
#import <errno.h>
#import <fts.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *const DSAutomaticCleaning = @"automaticCleaning";
static NSString *const DSAppleDouble = @"appleDouble";
static NSString *const DSAppleDoubleExtensions = @"appleDoubleExtensions";
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

@interface DriveSweepController : NSObject <NSApplicationDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) NSWindow *dashboardWindow;
@property (strong) NSTextField *dashboardStatusLabel;
@property (strong) NSWindow *preferencesWindow;
@property (strong) NSTimer *scanTimer;
@property (strong) NSArray<NSURL *> *eligibleVolumes;
@property (strong) NSDictionary<NSString *, NSString *> *eligibleVolumeIdentities;
@property (strong) NSMutableSet<NSString *> *scheduledCleanupPaths;
@property (strong) NSMutableSet<NSString *> *handledMountIdentities;
@property dispatch_queue_t cleanupQueue;
@end

@implementation DriveSweepController

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        DSAutomaticCleaning: @NO,
        DSAppleDouble: @NO,
        DSAppleDoubleExtensions: @"",
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
        DSExcludedVolumes: @""
    }];

    self.eligibleVolumes = @[];
    self.eligibleVolumeIdentities = @{};
    self.scheduledCleanupPaths = [NSMutableSet set];
    self.handledMountIdentities = [NSMutableSet set];
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
        completionHandler:^(BOOL granted, NSError *error) {}];

    NSNotificationCenter *workspaceCenter = [[NSWorkspace sharedWorkspace] notificationCenter];
    [workspaceCenter addObserver:self selector:@selector(volumeMounted:) name:NSWorkspaceDidMountNotification object:nil];
    [workspaceCenter addObserver:self selector:@selector(volumeUnmounted:) name:NSWorkspaceDidUnmountNotification object:nil];
    self.scanTimer = [NSTimer scheduledTimerWithTimeInterval:15 target:self selector:@selector(checkMountedVolumes) userInfo:nil repeats:YES];
    [self checkMountedVolumes];
    [self showDashboard:nil];
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
        if ([self isEligibleExternalVolume:url error:nil]) [external addObject:url];
    }
    return external;
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

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/diskutil"];
    task.arguments = @[@"info", @"-plist", url.path];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        if (error) *error = launchError;
        return NO;
    }
    [task waitUntilExit];
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    if (task.terminationStatus != 0) {
        if (error) *error = [NSError errorWithDomain:@"DriveSweep" code:1 userInfo:@{NSLocalizedDescriptionKey: @"diskutil non ha potuto verificare il disco."}];
        return NO;
    }
    NSError *plistError = nil;
    NSDictionary *info = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:&plistError];
    if (![info isKindOfClass:NSDictionary.class]) {
        if (error) *error = plistError ?: [NSError errorWithDomain:@"DriveSweep" code:2 userInfo:@{NSLocalizedDescriptionKey: @"diskutil ha restituito dati non validi."}];
        return NO;
    }
    NSNumber *internal = info[@"Internal"];
    NSNumber *removableOrExternal = info[@"RemovableMediaOrExternalDevice"];
    NSNumber *systemImage = info[@"SystemImage"];
    NSNumber *writable = info[@"WritableVolume"];
    NSString *deviceIdentifier = info[@"DeviceIdentifier"];
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
                    if (!identity || [self.handledMountIdentities containsObject:identity]) continue;
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

- (NSUInteger)removeNamedFiles:(NSString *)name fromVolume:(NSURL *)volume directoriesOnly:(BOOL)directoriesOnly errors:(NSMutableArray<NSString *> *)errors {
    NSFileManager *manager = [NSFileManager defaultManager];
    struct stat rootStatus;
    if (lstat(volume.fileSystemRepresentation, &rootStatus) != 0) {
        [errors addObject:[NSString stringWithFormat:@"%@ (%s)", volume.lastPathComponent, strerror(errno)]];
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
        if (![item.lastPathComponent isEqualToString:name]) continue;
        if (directoriesOnly != isDirectory.boolValue) continue;
        NSError *removeError = nil;
        if ([manager removeItemAtURL:item error:&removeError]) removed++;
        else if (removeError) [errors addObject:[NSString stringWithFormat:@"%@ (%@)", item.lastPathComponent, removeError.localizedDescription]];
        if (isDirectory.boolValue) [enumerator skipDescendants];
    }
    NSURL *rootItem = [volume URLByAppendingPathComponent:name];
    BOOL rootIsDirectory = NO;
    if ([manager fileExistsAtPath:rootItem.path isDirectory:&rootIsDirectory] && directoriesOnly == rootIsDirectory) {
        NSError *removeError = nil;
        if ([manager removeItemAtURL:rootItem error:&removeError]) removed++;
        else if (removeError) [errors addObject:[NSString stringWithFormat:@"%@ (%@)", rootItem.lastPathComponent, removeError.localizedDescription]];
    }
    return removed;
}

- (NSUInteger)removeRootDirectory:(NSString *)name fromVolume:(NSURL *)volume errors:(NSMutableArray<NSString *> *)errors {
    NSURL *target = [volume URLByAppendingPathComponent:name];
    BOOL isDirectory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:target.path isDirectory:&isDirectory] || !isDirectory) return 0;
    NSError *removeError = nil;
    if ([[NSFileManager defaultManager] removeItemAtURL:target error:&removeError]) return 1;
    if (removeError) [errors addObject:[NSString stringWithFormat:@"%@ (%@)", name, removeError.localizedDescription]];
    return 0;
}

- (NSSet<NSString *> *)protectedAppleDoubleExtensions {
    NSString *value = [[NSUserDefaults standardUserDefaults] stringForKey:DSAppleDoubleExtensions] ?: @"";
    NSMutableSet<NSString *> *extensions = [NSMutableSet set];
    for (NSString *rawExtension in [value componentsSeparatedByString:@","]) {
        NSString *extension = [[rawExtension stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
        if ([extension hasPrefix:@"."]) extension = [extension substringFromIndex:1];
        if (extension.length) [extensions addObject:extension];
    }
    return extensions;
}

- (NSUInteger)removeAppleDoubleFilesFromVolume:(NSURL *)volume protectedExtensions:(NSSet<NSString *> *)protectedExtensions errors:(NSMutableArray<NSString *> *)errors {
    char *paths[] = { (char *)volume.fileSystemRepresentation, NULL };
    FTS *tree = fts_open(paths, FTS_NOCHDIR | FTS_PHYSICAL | FTS_XDEV, NULL);
    if (!tree) {
        [errors addObject:[NSString stringWithFormat:@"%@ (%s)", volume.lastPathComponent, strerror(errno)]];
        return 0;
    }
    NSUInteger removed = 0;
    FTSENT *entry = nil;
    while ((entry = fts_read(tree))) {
        if (entry->fts_info == FTS_DNR || entry->fts_info == FTS_ERR) {
            [errors addObject:[NSString stringWithFormat:@"%s (%s)", entry->fts_path, strerror(entry->fts_errno)]];
            continue;
        }
        if (entry->fts_info != FTS_F) continue;
        NSString *name = [NSString stringWithUTF8String:entry->fts_name];
        if (![name hasPrefix:@"._"]) continue;
        NSString *extension = [[name substringFromIndex:2].pathExtension lowercaseString];
        if ([protectedExtensions containsObject:extension]) continue;
        if (unlink(entry->fts_accpath) == 0) removed++;
        else [errors addObject:[NSString stringWithFormat:@"%@ (%s)", name, strerror(errno)]];
    }
    fts_close(tree);
    return removed;
}

- (NSDictionary<NSString *, id> *)cleanVolumeOnWorker:(NSURL *)volume {
    return [self cleanVolumeOnWorker:volume expectedMountIdentity:nil];
}

- (NSDictionary<NSString *, id> *)cleanVolumeOnWorker:(NSURL *)volume expectedMountIdentity:(NSString *)expectedMountIdentity {
    NSError *eligibilityError = nil;
    if (![self isEligibleExternalVolume:volume error:&eligibilityError]) {
        NSString *message = eligibilityError.localizedDescription ?: @"Il disco non è più un volume esterno fisico scrivibile.";
        return @{ @"success": @NO, @"removed": @0, @"appleDoubleProcessed": @NO, @"errors": @[message] };
    }
    if (expectedMountIdentity && ![[self mountIdentityForVolume:volume] isEqualToString:expectedMountIdentity]) {
        return @{ @"success": @NO, @"removed": @0, @"appleDoubleProcessed": @NO, @"errors": @[@"Il disco è stato smontato o la sua identità è cambiata prima della pulizia."] };
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    NSUInteger removed = 0;
    BOOL appleDoubleProcessed = [defaults boolForKey:DSAppleDouble];
    if (appleDoubleProcessed) removed += [self removeAppleDoubleFilesFromVolume:volume protectedExtensions:[self protectedAppleDoubleExtensions] errors:errors];
    if ([defaults boolForKey:DSDSStore]) removed += [self removeNamedFiles:@".DS_Store" fromVolume:volume directoriesOnly:NO errors:errors];
    if ([defaults boolForKey:DSTrashes]) removed += [self removeRootDirectory:@".Trashes" fromVolume:volume errors:errors];
    if ([defaults boolForKey:DSSpotlight]) removed += [self removeRootDirectory:@".Spotlight-V100" fromVolume:volume errors:errors];
    if ([defaults boolForKey:DSFileEvents]) removed += [self removeRootDirectory:@".fseventsd" fromVolume:volume errors:errors];
    if ([defaults boolForKey:DSApdisk]) removed += [self removeNamedFiles:@".apdisk" fromVolume:volume directoriesOnly:NO errors:errors];
    if ([defaults boolForKey:DSVolumeIcon]) removed += [self removeNamedFiles:@".VolumeIcon.icns" fromVolume:volume directoriesOnly:NO errors:errors];
    if ([defaults boolForKey:DSDesktopIni]) removed += [self removeNamedFiles:@"Desktop.ini" fromVolume:volume directoriesOnly:NO errors:errors];
    if ([defaults boolForKey:DSThumbsDb]) removed += [self removeNamedFiles:@"Thumbs.db" fromVolume:volume directoriesOnly:NO errors:errors];
    if ([defaults boolForKey:DSTemporaryItems]) removed += [self removeRootDirectory:@".TemporaryItems" fromVolume:volume errors:errors];
    if ([defaults boolForKey:DSAppleDoubleDirectories]) removed += [self removeNamedFiles:@".AppleDouble" fromVolume:volume directoriesOnly:YES errors:errors];
    return @{ @"success": @(errors.count == 0), @"removed": @(removed), @"appleDoubleProcessed": @(appleDoubleProcessed), @"errors": errors };
}

- (void)cleanVolume:(NSURL *)volume source:(NSString *)source expectedMountIdentity:(NSString *)expectedMountIdentity completion:(void (^)(BOOL success))completion {
    if (!expectedMountIdentity.length) {
        NSString *message = [NSString stringWithFormat:@"Pulizia di %@ annullata: non è stato possibile verificare l'identità del disco.", volume.lastPathComponent];
        [self notify:message];
        if (completion) completion(NO);
        return;
    }
    if ([self.scheduledCleanupPaths containsObject:volume.path]) {
        if (completion) {
            [self notify:[NSString stringWithFormat:@"La pulizia di %@ è già in corso.", volume.lastPathComponent]];
            completion(NO);
        }
        return;
    }
    [self.scheduledCleanupPaths addObject:volume.path];
    dispatch_async(self.cleanupQueue, ^{
        NSDictionary<NSString *, id> *result = [self cleanVolumeOnWorker:volume expectedMountIdentity:expectedMountIdentity];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.scheduledCleanupPaths removeObject:volume.path];
            BOOL success = [result[@"success"] boolValue];
            NSUInteger removed = [result[@"removed"] unsignedIntegerValue];
            NSArray<NSString *> *errors = result[@"errors"];
            NSString *details = [NSString stringWithFormat:@"%lu elementi rimossi", (unsigned long)removed];
            NSString *message = success
                ? [NSString stringWithFormat:@"%@ pulito (%@; %@).", volume.lastPathComponent, source, details]
                : [NSString stringWithFormat:@"Pulizia di %@ non completata: %@", volume.lastPathComponent, [errors componentsJoinedByString:@"; "]];
            self.statusItem.button.toolTip = message;
            if (!success || ![source isEqualToString:@"controllo automatico"]) [self notify:message];
            [self rebuildMenu];
            if (completion) completion(success);
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
    NSMenuItem *open = [[NSMenuItem alloc] initWithTitle:@"Apri DriveSweep" action:@selector(showDashboard:) keyEquivalent:@"o"];
    open.target = self;
    [menu addItem:open];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *cleanAll = [[NSMenuItem alloc] initWithTitle:@"Pulisci tutti i dischi esterni" action:@selector(cleanAll:) keyEquivalent:@"c"];
    cleanAll.target = self;
    [menu addItem:cleanAll];

    NSArray<NSURL *> *volumes = self.eligibleVolumes;
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
    [self refreshDashboard];
}

- (void)cleanAll:(id)sender {
    for (NSURL *url in self.eligibleVolumes) {
        [self cleanVolume:url source:@"manuale" expectedMountIdentity:self.eligibleVolumeIdentities[url.path] completion:nil];
    }
}

- (void)cleanFromMenu:(NSMenuItem *)sender {
    NSURL *url = sender.representedObject;
    [self cleanVolume:url source:@"manuale" expectedMountIdentity:self.eligibleVolumeIdentities[url.path] completion:nil];
}

- (void)cleanAndEject:(NSMenuItem *)sender {
    NSURL *url = sender.representedObject;
    [self cleanVolume:url source:@"prima dell'espulsione" expectedMountIdentity:self.eligibleVolumeIdentities[url.path] completion:^(BOOL success) {
        if (!success) {
            [self notify:[NSString stringWithFormat:@"%@ non è stato espulso: la pulizia non è stata completata.", url.lastPathComponent]];
            return;
        }
        NSError *error = nil;
        if (![[NSWorkspace sharedWorkspace] unmountAndEjectDeviceAtURL:url error:&error]) {
            [self notify:[NSString stringWithFormat:@"Non riesco a espellere %@: %@", url.lastPathComponent, error.localizedDescription]];
        }
    }];
}

- (void)showDashboard:(id)sender {
    if (!self.dashboardWindow) {
        self.dashboardWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 500, 260)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
            backing:NSBackingStoreBuffered defer:NO];
        self.dashboardWindow.title = @"DriveSweep";
        self.dashboardWindow.minSize = NSMakeSize(500, 260);

        NSView *content = self.dashboardWindow.contentView;
        NSTextField *title = [NSTextField labelWithString:@"DriveSweep è attivo"];
        title.frame = NSMakeRect(28, 190, 440, 32);
        title.font = [NSFont boldSystemFontOfSize:24];
        [content addSubview:title];

        NSTextField *description = [NSTextField wrappingLabelWithString:@"Pulisce solo i dischi fisici esterni. Quando hai finito di copiare i file, usa “Pulisci ed espelli” dal menu della scopa nella barra menu."];
        description.frame = NSMakeRect(28, 132, 444, 46);
        description.font = [NSFont systemFontOfSize:13];
        [content addSubview:description];

        self.dashboardStatusLabel = [NSTextField labelWithString:@""];
        self.dashboardStatusLabel.frame = NSMakeRect(28, 94, 444, 24);
        self.dashboardStatusLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        [content addSubview:self.dashboardStatusLabel];

        NSButton *clean = [[NSButton alloc] initWithFrame:NSMakeRect(28, 36, 176, 34)];
        clean.title = @"Pulisci tutti";
        clean.bezelStyle = NSBezelStyleRounded;
        clean.target = self;
        clean.action = @selector(cleanAll:);
        [content addSubview:clean];

        NSButton *preferences = [[NSButton alloc] initWithFrame:NSMakeRect(216, 36, 120, 34)];
        preferences.title = @"Preferenze…";
        preferences.bezelStyle = NSBezelStyleRounded;
        preferences.target = self;
        preferences.action = @selector(showPreferences:);
        [content addSubview:preferences];
    }
    [self refreshDashboard];
    [self.dashboardWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)refreshDashboard {
    if (!self.dashboardStatusLabel) return;
    NSArray<NSURL *> *volumes = self.eligibleVolumes;
    if (volumes.count == 0) {
        self.dashboardStatusLabel.stringValue = @"Nessun disco esterno idoneo collegato.";
        return;
    }
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSURL *volume in volumes) [names addObject:volume.lastPathComponent];
    self.dashboardStatusLabel.stringValue = [NSString stringWithFormat:@"Dischi esterni rilevati: %@", [names componentsJoinedByString:@", "]];
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

- (NSTextField *)preferenceTextField:(NSString *)key y:(CGFloat)y {
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(24, y, 390, 24)];
    field.stringValue = [[NSUserDefaults standardUserDefaults] stringForKey:key] ?: @"";
    field.identifier = key;
    field.target = self;
    field.action = @selector(saveTextPreference:);
    return field;
}

- (void)showPreferences:(id)sender {
    if (!self.preferencesWindow) {
        self.preferencesWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 440, 610)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
            backing:NSBackingStoreBuffered defer:NO];
        self.preferencesWindow.title = @"Preferenze DriveSweep";
        NSView *content = self.preferencesWindow.contentView;
        [content addSubview:[self checkbox:@"Pulisci automaticamente quando collego un disco" key:DSAutomaticCleaning y:560]];
        [content addSubview:[self checkbox:@"Rimuovi file ._* (AppleDouble)" key:DSAppleDouble y:530]];
        NSTextField *extensionsLabel = [NSTextField labelWithString:@"Mantieni AppleDouble per estensioni (es. eps, psd):"];
        extensionsLabel.frame = NSMakeRect(24, 505, 390, 20); [content addSubview:extensionsLabel];
        [content addSubview:[self preferenceTextField:DSAppleDoubleExtensions y:477]];
        [content addSubview:[self checkbox:@"Rimuovi .DS_Store" key:DSDSStore y:445]];
        [content addSubview:[self checkbox:@"Svuota .Trashes del disco" key:DSTrashes y:417]];
        [content addSubview:[self checkbox:@"Rimuovi indice Spotlight (.Spotlight-V100)" key:DSSpotlight y:389]];
        [content addSubview:[self checkbox:@"Rimuovi registro eventi (.fseventsd)" key:DSFileEvents y:361]];
        [content addSubview:[self checkbox:@"Rimuovi file .apdisk" key:DSApdisk y:333]];
        [content addSubview:[self checkbox:@"Rimuovi .VolumeIcon.icns" key:DSVolumeIcon y:305]];
        [content addSubview:[self checkbox:@"Rimuovi Desktop.ini" key:DSDesktopIni y:277]];
        [content addSubview:[self checkbox:@"Rimuovi Thumbs.db" key:DSThumbsDb y:249]];
        [content addSubview:[self checkbox:@"Rimuovi .TemporaryItems del disco" key:DSTemporaryItems y:221]];
        [content addSubview:[self checkbox:@"Rimuovi cartelle .AppleDouble" key:DSAppleDoubleDirectories y:193]];
        NSTextField *label = [NSTextField labelWithString:@"Escludi dischi (nomi separati da virgola):"];
        label.frame = NSMakeRect(24, 154, 390, 20); [content addSubview:label];
        [content addSubview:[self preferenceTextField:DSExcludedVolumes y:126]];
        NSTextField *note = [NSTextField labelWithString:@"Per sicurezza DriveSweep non pulisce mai dischi interni, immagini disco o volumi in sola lettura."];
        note.frame = NSMakeRect(24, 38, 400, 20); note.font = [NSFont systemFontOfSize:11]; note.textColor = NSColor.secondaryLabelColor;
        [content addSubview:note];
        NSTextField *warning = [NSTextField wrappingLabelWithString:@"Le pulizie aggiuntive sono disattivate per default. Abilitali solo dopo avere verificato che quei metadati non servano ai tuoi file."];
        warning.frame = NSMakeRect(24, 4, 400, 30); warning.font = [NSFont systemFontOfSize:11]; warning.textColor = NSColor.secondaryLabelColor;
        [content addSubview:warning];
    }
    [self.preferencesWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)saveCheckbox:(NSButton *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:(sender.state == NSControlStateValueOn) forKey:sender.identifier];
    [self rebuildMenu];
}
- (void)saveTextPreference:(NSTextField *)sender { [[NSUserDefaults standardUserDefaults] setObject:sender.stringValue forKey:sender.identifier]; [self rebuildMenu]; }

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
