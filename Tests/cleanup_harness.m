#define main DriveSweepApplicationMain
#import "../Sources/main.m"
#undef main

@interface TestDriveSweepController : DriveSweepController
@property(nonatomic) NSUInteger presentedAlertCount;
@property(nonatomic) NSUInteger dashboardPresentationCount;
@property(nonatomic, copy) NSString *testMountIdentity;
@property(nonatomic) NSUInteger mountIdentityChecks;
@property(nonatomic) NSUInteger changeIdentityAfterChecks;
@property(nonatomic, copy) NSDictionary<NSString *, id> *testDiskInfo;
@property(nonatomic, copy) NSURL *capturedPreviewVolume;
@property(nonatomic, copy) NSString *capturedPreviewIdentity;
@property(nonatomic, copy) NSURL *capturedPeriodicVolume;
@property(nonatomic, copy) NSString *capturedPeriodicIdentity;
@property(nonatomic, copy) NSString *capturedPeriodicSource;
@property(nonatomic) BOOL runActualPeriodicCleanup;
@property(nonatomic) UNAuthorizationStatus testNotificationAuthorizationStatus;
@property(nonatomic) NSUInteger notificationAuthorizationStatusQueryCount;
@property(nonatomic) NSUInteger notificationAuthorizationRequestCount;
@end

@implementation TestDriveSweepController

- (BOOL)isEligibleExternalVolume:(NSURL *)url error:(NSError **)error {
    if (self.testDiskInfo) return [super isEligibleExternalVolume:url error:error];
    return YES;
}

- (NSDictionary<NSString *, id> *)diskInfoForVolume:(NSURL *)url error:(NSError **)error {
    if (self.testDiskInfo) return self.testDiskInfo;
    return [super diskInfoForVolume:url error:error];
}

- (NSString *)mountIdentityForVolume:(NSURL *)url {
    self.mountIdentityChecks++;
    return self.mountIdentityChecks > self.changeIdentityAfterChecks ? @"replacement-volume-uuid" : self.testMountIdentity;
}

- (void)presentAlertModally:(NSAlert *)alert {
    self.presentedAlertCount += 1;
}

- (void)notify:(NSString *)message {
    (void)message;
}

- (void)notificationAuthorizationStatusWithCompletionHandler:(void (^)(UNAuthorizationStatus status))completionHandler {
    self.notificationAuthorizationStatusQueryCount += 1;
    if (completionHandler) completionHandler(self.testNotificationAuthorizationStatus);
}

- (void)requestNotificationAuthorizationWithOptions:(UNAuthorizationOptions)options completionHandler:(void (^)(BOOL granted, NSError *error))completionHandler {
    (void)options;
    self.notificationAuthorizationRequestCount += 1;
    if (completionHandler) completionHandler(YES, nil);
}

- (void)showDashboard:(id)sender {
    self.dashboardPresentationCount += 1;
}

- (void)previewVolume:(NSURL *)volume expectedMountIdentity:(NSString *)expectedMountIdentity {
    self.capturedPreviewVolume = volume;
    self.capturedPreviewIdentity = expectedMountIdentity;
}

- (void)cleanVolume:(NSURL *)volume source:(NSString *)source expectedMountIdentity:(NSString *)expectedMountIdentity completion:(void (^)(BOOL success))completion {
    self.capturedPeriodicVolume = volume;
    self.capturedPeriodicIdentity = expectedMountIdentity;
    self.capturedPeriodicSource = source;
    if (self.runActualPeriodicCleanup) {
        [super cleanVolume:volume source:source expectedMountIdentity:expectedMountIdentity completion:completion];
        return;
    }
    if (completion) completion(YES);
}

@end

@interface DriveSweepController (DashboardLifecycleRegression)
- (void)showDashboard:(id)sender;
- (void)showPreferences:(id)sender;
- (NSPopUpButton *)dashboardActionsButtonForVolume:(NSURL *)volume identity:(NSString *)identity enabled:(BOOL)enabled;
- (void)previewFromMenu:(NSMenuItem *)sender;
- (NSArray<DSVolumeTarget *> *)periodicCleanupTargets;
- (void)runPeriodicCleanup:(NSTimer *)timer;
- (void)configurePeriodicCleanupTimer;
- (void)stopPeriodicCleanup:(id)sender;
- (void)configurePeriodicCleanupWithMinutes:(NSInteger)minutes;
- (NSString *)nextPeriodicCleanupLabelAtDate:(NSDate *)date;
- (BOOL)resourceGuardShouldPauseForCPUPercent:(double)cpuPercent residentBytes:(uint64_t)residentBytes consecutiveBreaches:(NSUInteger)consecutiveBreaches;
- (NSTextField *)preferenceTextField:(NSString *)key y:(CGFloat)y;
- (void)saveTextPreference:(NSTextField *)sender;
- (void)suspendPeriodicCleanupForResourceGuardWithWarning:(NSString *)warning;
@end

@interface DriveSweepController (CustomExtensionCleanupRegression)
- (NSSet<NSString *> *)normalizedCustomFileExtensionsFromValue:(id)value;
@end

@interface DriveSweepController (MountIdentitySafetyRegression)
- (NSString *)mountIdentityFromDiskInfo:(NSDictionary *)info;
- (void)handleUnmountedVolumeURL:(NSURL *)url;
@end

static BOOL NotificationAuthorizationLaunchRegression(TestDriveSweepController *controller, NSUserDefaults *defaults) {
    id savedSentinel = [defaults objectForKey:DSNotificationAuthorizationRequested];
    [defaults removeObjectForKey:DSNotificationAuthorizationRequested];
    controller.notificationAuthorizationRequestCount = 0;
    controller.notificationAuthorizationStatusQueryCount = 0;
    controller.testNotificationAuthorizationStatus = UNAuthorizationStatusNotDetermined;

    [controller requestNotificationAuthorizationAtLaunch];
    BOOL undeterminedRequestsOnce = controller.notificationAuthorizationRequestCount == 1 &&
        [defaults boolForKey:DSNotificationAuthorizationRequested];
    [controller requestNotificationAuthorizationAtLaunch];
    BOOL persistedSentinelPreventsRepeat = controller.notificationAuthorizationRequestCount == 1;

    [defaults removeObjectForKey:DSNotificationAuthorizationRequested];
    controller.testNotificationAuthorizationStatus = UNAuthorizationStatusDenied;
    [controller requestNotificationAuthorizationAtLaunch];
    [controller requestNotificationAuthorizationAtLaunch];
    BOOL deniedDoesNotPromptOrWriteSentinel = controller.notificationAuthorizationRequestCount == 1 &&
        ![defaults boolForKey:DSNotificationAuthorizationRequested];

    controller.testNotificationAuthorizationStatus = UNAuthorizationStatusAuthorized;
    [controller requestNotificationAuthorizationAtLaunch];
    BOOL authorizedDoesNotPrompt = controller.notificationAuthorizationRequestCount == 1 &&
        ![defaults boolForKey:DSNotificationAuthorizationRequested];

    if (savedSentinel) [defaults setObject:savedSentinel forKey:DSNotificationAuthorizationRequested];
    else [defaults removeObjectForKey:DSNotificationAuthorizationRequested];
    return undeterminedRequestsOnce && persistedSentinelPreventsRepeat &&
        deniedDoesNotPromptOrWriteSentinel && authorizedDoesNotPrompt &&
        controller.notificationAuthorizationStatusQueryCount == 5;
}

static BOOL DashboardReopenAfterCloseRegression(void) {
    NSApplication *application = [NSApplication sharedApplication];
    [application setActivationPolicy:NSApplicationActivationPolicyRegular];
    DriveSweepController *controller = [[DriveSweepController alloc] init];
    [controller showDashboard:nil];
    BOOL created = controller.dashboardWindow != nil;
    BOOL retainedForReopen = !controller.dashboardWindow.releasedWhenClosed;
    BOOL lifecycleStable = YES;
    for (NSUInteger cycle = 0; cycle < 20; cycle++) {
        NSWindow *window = controller.dashboardWindow;
        [window performClose:nil];
        BOOL hidden = !window.isVisible;
        window = nil;
        BOOL handled = [controller applicationShouldHandleReopen:application hasVisibleWindows:NO];
        if (!hidden || !handled || !controller.dashboardWindow.isVisible) {
            lifecycleStable = NO;
            break;
        }
    }
    [controller.dashboardWindow orderOut:nil];
    [controller showPreferences:nil];
    BOOL preferencesRetained = controller.preferencesWindow != nil && !controller.preferencesWindow.releasedWhenClosed;
    BOOL preferencesLifecycleStable = YES;
    for (NSUInteger cycle = 0; cycle < 5; cycle++) {
        NSWindow *preferences = controller.preferencesWindow;
        [preferences performClose:nil];
        BOOL hidden = !preferences.isVisible;
        preferences = nil;
        [controller showPreferences:nil];
        if (!hidden || !controller.preferencesWindow.isVisible) {
            preferencesLifecycleStable = NO;
            break;
        }
    }
    [controller.preferencesWindow orderOut:nil];
    return created && retainedForReopen && lifecycleStable && preferencesRetained && preferencesLifecycleStable;
}

static BOOL CreateDirectory(NSFileManager *manager, NSString *path) {
    return [manager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
}

static BOOL RunChmod(NSArray<NSString *> *arguments) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/chmod"];
    task.arguments = arguments;
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) return NO;
    [task waitUntilExit];
    return task.terminationStatus == 0;
}

static BOOL DenyFixtureDirectoryTraversal(NSString *path) {
    NSString *entry = [NSString stringWithFormat:@"user:%@ deny list,search,readattr,readextattr,readsecurity", NSUserName()];
    return RunChmod(@[@"+a", entry, path]);
}

static BOOL RestoreFixtureDirectoryTraversal(NSString *path) {
    return RunChmod(@[@"-N", path]) && chmod(path.fileSystemRepresentation, 0700) == 0;
}

static BOOL CustomExtensionCleanupRegression(TestDriveSweepController *controller, NSUserDefaults *defaults) {
    NSString *customFilesKey = @"customFiles";
    NSString *customExtensionsKey = @"customFileExtensions";
    NSArray<NSString *> *preferenceKeys = [DSCleanupPreferenceKeys() arrayByAddingObjectsFromArray:@[customExtensionsKey]];
    NSMutableDictionary<NSString *, id> *savedValues = [NSMutableDictionary dictionary];
    for (NSString *key in preferenceKeys) {
        id value = [defaults objectForKey:key];
        savedValues[key] = value ?: [NSNull null];
    }
    id savedRules = [defaults objectForKey:@"volumeRules"] ?: [NSNull null];
    BOOL savedPeriodicEnabled = [defaults boolForKey:@"periodicCleaning"];

    char template[] = "/private/tmp/drivesweep-custom.XXXXXX";
    char *temporaryPath = mkdtemp(template);
    if (!temporaryPath) return NO;
    NSString *root = [NSString stringWithUTF8String:temporaryPath];
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *nested = [root stringByAppendingPathComponent:@"nested"];
    NSString *package = [root stringByAppendingPathComponent:@"Bundle.app"];
    NSString *trash = [root stringByAppendingPathComponent:@".Trashes"];
    NSString *temporaryItems = [root stringByAppendingPathComponent:@".TemporaryItems"];
    NSString *folder = [root stringByAppendingPathComponent:@"folder.tmp"];
    NSString *wanted = [root stringByAppendingPathComponent:@"wanted.TMP"];
    NSString *nestedWanted = [nested stringByAppendingPathComponent:@"nested.BaK"];
    NSString *appleDoubleCustom = [root stringByAppendingPathComponent:@"._hidden.tmp"];
    NSString *builtInDSStore = [root stringByAppendingPathComponent:@".DS_Store"];
    NSString *builtInApdisk = [root stringByAppendingPathComponent:@".apdisk"];
    NSString *builtInVolumeIcon = [root stringByAppendingPathComponent:@".VolumeIcon.icns"];
    NSString *builtInDesktopIni = [root stringByAppendingPathComponent:@"Desktop.ini"];
    NSString *builtInThumbsDb = [root stringByAppendingPathComponent:@"Thumbs.db"];
    NSString *sentinel = [root stringByAppendingPathComponent:@"keep.txt"];
    NSString *packagePayload = [package stringByAppendingPathComponent:@"inside.tmp"];
    NSString *trashPayload = [trash stringByAppendingPathComponent:@"inside.tmp"];
    NSString *temporaryPayload = [temporaryItems stringByAppendingPathComponent:@"inside.tmp"];
    NSString *trashAppleDouble = [trash stringByAppendingPathComponent:@"._inside.tmp"];
    NSString *temporaryAppleDouble = [temporaryItems stringByAppendingPathComponent:@"._inside.tmp"];
    NSString *trashDSStore = [trash stringByAppendingPathComponent:@".DS_Store"];
    NSString *temporaryDSStore = [temporaryItems stringByAppendingPathComponent:@".DS_Store"];
    NSString *lateCustom = [root stringByAppendingPathComponent:@"late.tmp"];
    NSString *symlink = [root stringByAppendingPathComponent:@"link.tmp"];
    NSString *fifo = [root stringByAppendingPathComponent:@"pipe.tmp"];
    BOOL fixtureReady =
        CreateDirectory(manager, nested) &&
        CreateDirectory(manager, package) &&
        CreateDirectory(manager, trash) &&
        CreateDirectory(manager, temporaryItems) &&
        CreateDirectory(manager, folder) &&
        [@"payload" writeToFile:wanted atomically:YES encoding:NSUTF8StringEncoding error:nil] &&
        [@"payload" writeToFile:nestedWanted atomically:YES encoding:NSUTF8StringEncoding error:nil] &&
        [@"appledouble" writeToFile:appleDoubleCustom atomically:YES encoding:NSUTF8StringEncoding error:nil] &&
        [@"metadata" writeToFile:builtInDSStore atomically:YES encoding:NSUTF8StringEncoding error:nil] &&
        [@"metadata" writeToFile:builtInApdisk atomically:YES encoding:NSUTF8StringEncoding error:nil] &&
        [@"metadata" writeToFile:builtInVolumeIcon atomically:YES encoding:NSUTF8StringEncoding error:nil] &&
        [@"metadata" writeToFile:builtInDesktopIni atomically:YES encoding:NSUTF8StringEncoding error:nil] &&
        [@"metadata" writeToFile:builtInThumbsDb atomically:YES encoding:NSUTF8StringEncoding error:nil] &&
        [@"sentinel" writeToFile:sentinel atomically:YES encoding:NSUTF8StringEncoding error:nil] &&
        [@"package" writeToFile:packagePayload atomically:YES encoding:NSUTF8StringEncoding error:nil] &&
        [@"trash" writeToFile:trashPayload atomically:YES encoding:NSUTF8StringEncoding error:nil] &&
        [@"temporary" writeToFile:temporaryPayload atomically:YES encoding:NSUTF8StringEncoding error:nil] &&
        [@"appledouble" writeToFile:trashAppleDouble atomically:YES encoding:NSUTF8StringEncoding error:nil] &&
        [@"appledouble" writeToFile:temporaryAppleDouble atomically:YES encoding:NSUTF8StringEncoding error:nil] &&
        [@"metadata" writeToFile:trashDSStore atomically:YES encoding:NSUTF8StringEncoding error:nil] &&
        [@"metadata" writeToFile:temporaryDSStore atomically:YES encoding:NSUTF8StringEncoding error:nil] &&
        [manager createSymbolicLinkAtPath:symlink withDestinationPath:sentinel error:nil] &&
        mkfifo(fifo.fileSystemRepresentation, 0600) == 0;
    if (!fixtureReady) {
        [manager removeItemAtPath:root error:nil];
        return NO;
    }

    NSSet<NSString *> *normalized = [controller normalizedCustomFileExtensionsFromValue:@[
        @".TMP", @"bak", @"bad/name", @"wild*card", @"question?mark", @"has space", @"", @".",
        [@"long" stringByPaddingToLength:65 withString:@"x" startingAtIndex:0]
    ]];
    BOOL validated = [normalized isEqualToSet:[NSSet setWithObjects:@"tmp", @"bak", nil]];

    for (NSString *key in DSCleanupPreferenceKeys()) [defaults setBool:NO forKey:key];
    [defaults setBool:YES forKey:customFilesKey];
    [defaults setObject:@[@".TMP", @"bak", @"bad/name", @"wild*card"] forKey:customExtensionsKey];
    NSDictionary<NSString *, id> *snapshot = [controller cleanupOptionsSnapshot];
    NSSet<NSString *> *snapshotExtensions = snapshot[customExtensionsKey];
    BOOL snapshotIsImmutable = [snapshotExtensions isEqualToSet:[NSSet setWithObjects:@"tmp", @"bak", nil]];
    NSString *customIdentity = @"custom-extension-fixture-uuid";
    controller.eligibleVolumes = @[[NSURL fileURLWithPath:root]];
    controller.eligibleVolumeIdentities = @{ root: customIdentity };
    [controller setPeriodicCleaning:YES forIdentity:customIdentity name:@"Custom fixture"];
    [defaults setBool:YES forKey:@"periodicCleaning"];
    BOOL periodicRequiresCustomConfirmation = [controller periodicCleanupTargets].count == 0;
    [controller recordCustomExtensionAnalysisForIdentity:customIdentity options:snapshot];
    BOOL confirmationAccepted = [controller confirmCurrentCustomExtensionsForIdentity:customIdentity name:@"Custom fixture"];
    BOOL periodicUsesConfirmedCustomRules = [controller periodicCleanupTargets].count == 1;
    [defaults setObject:@[@"zzz"] forKey:customExtensionsKey];
    BOOL changingExtensionsInvalidatesPeriodicConsent = [controller periodicCleanupTargets].count == 0;
    controller.testMountIdentity = customIdentity;
    controller.mountIdentityChecks = 0;
    controller.changeIdentityAfterChecks = NSUIntegerMax;
    DSOperationState *staleCustomRuleOperation = [[DSOperationState alloc] init];
    staleCustomRuleOperation.automaticCleanup = YES;
    staleCustomRuleOperation.periodicCleanup = YES;
    NSDictionary<NSString *, id> *staleCustomRuleResult = [controller cleanVolumeOnWorker:[NSURL fileURLWithPath:root] expectedMountIdentity:customIdentity options:snapshot operation:staleCustomRuleOperation];
    BOOL periodicRechecksChangedCustomRules = ![staleCustomRuleResult[@"success"] boolValue] &&
        [[staleCustomRuleResult[@"errors"] componentsJoinedByString:@"; "] containsString:@"non è più autorizzata"];
    [defaults setObject:@[@"tmp", @"bak"] forKey:customExtensionsKey];
    [defaults setBool:NO forKey:customFilesKey];
    NSDictionary<NSString *, id> *disabledCustomRuleResult = [controller cleanVolumeOnWorker:[NSURL fileURLWithPath:root] expectedMountIdentity:customIdentity options:snapshot operation:staleCustomRuleOperation];
    BOOL periodicRechecksDisabledCustomRule = ![disabledCustomRuleResult[@"success"] boolValue] &&
        [[disabledCustomRuleResult[@"errors"] componentsJoinedByString:@"; "] containsString:@"non è più autorizzata"] &&
        [manager fileExistsAtPath:wanted] && [manager fileExistsAtPath:nestedWanted];

    NSDictionary<NSString *, id> *preview = [controller previewVolumeOnWorker:[NSURL fileURLWithPath:root] expectedMountIdentity:nil options:snapshot];
    NSUInteger previewCount = [preview[@"counts"][customFilesKey] unsignedIntegerValue];
    BOOL previewIsSafe = [preview[@"success"] boolValue] && previewCount == 2 && [preview[@"errors"] count] == 0;

    NSDictionary<NSString *, id> *cleanup = [controller cleanVolumeOnWorker:[NSURL fileURLWithPath:root] expectedMountIdentity:nil options:snapshot];
    BOOL cleanupIsSafe = [cleanup[@"success"] boolValue] &&
        [cleanup[@"removed"] unsignedIntegerValue] == 2 &&
        ![manager fileExistsAtPath:wanted] &&
        ![manager fileExistsAtPath:nestedWanted] &&
        [manager fileExistsAtPath:sentinel] &&
        [manager fileExistsAtPath:folder] &&
        [manager fileExistsAtPath:packagePayload] &&
        [manager fileExistsAtPath:trashPayload] &&
        [manager fileExistsAtPath:temporaryPayload] &&
        [manager fileExistsAtPath:appleDoubleCustom] &&
        [manager fileExistsAtPath:builtInDSStore] &&
        [manager fileExistsAtPath:builtInApdisk] &&
        [manager fileExistsAtPath:builtInVolumeIcon] &&
        [manager fileExistsAtPath:builtInDesktopIni] &&
        [manager fileExistsAtPath:builtInThumbsDb] &&
        [manager fileExistsAtPath:trashAppleDouble] &&
        [manager fileExistsAtPath:temporaryAppleDouble] &&
        [manager fileExistsAtPath:trashDSStore] &&
        [manager fileExistsAtPath:temporaryDSStore] &&
        [manager fileExistsAtPath:symlink] &&
        [manager fileExistsAtPath:fifo];

    [@"late custom" writeToFile:lateCustom atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSMutableDictionary<NSString *, id> *overlapOptions = [snapshot mutableCopy];
    overlapOptions[DSAppleDouble] = @YES;
    overlapOptions[DSCustomFiles] = @YES;
    overlapOptions[DSDSStore] = @YES;
    overlapOptions[DSApdisk] = @YES;
    overlapOptions[DSVolumeIcon] = @YES;
    overlapOptions[DSDesktopIni] = @YES;
    overlapOptions[DSThumbsDb] = @YES;
    overlapOptions[DSAppleDoubleExtensions] = [NSSet set];
    overlapOptions[DSCustomFileExtensions] = [NSSet setWithObjects:@"tmp", @"ds_store", @"store", @"apdisk", @"icns", @"ini", @"db", nil];
    NSDictionary<NSString *, id> *overlapPreview = [controller previewVolumeOnWorker:[NSURL fileURLWithPath:root] expectedMountIdentity:nil options:overlapOptions];
    NSDictionary<NSString *, NSNumber *> *overlapCounts = overlapPreview[@"counts"];
    BOOL previewSeparatesOverlappingCategories =
        [overlapPreview[@"success"] boolValue] &&
        [overlapPreview[@"errors"] count] == 0 &&
        [overlapCounts[DSAppleDouble] unsignedIntegerValue] == 1 &&
        [overlapCounts[DSCustomFiles] unsignedIntegerValue] == 1 &&
        [overlapCounts[DSDSStore] unsignedIntegerValue] == 1 &&
        [overlapCounts[DSApdisk] unsignedIntegerValue] == 1 &&
        [overlapCounts[DSVolumeIcon] unsignedIntegerValue] == 1 &&
        [overlapCounts[DSDesktopIni] unsignedIntegerValue] == 1 &&
        [overlapCounts[DSThumbsDb] unsignedIntegerValue] == 1;
    NSDictionary<NSString *, id> *overlapCleanup = [controller cleanVolumeOnWorker:[NSURL fileURLWithPath:root] expectedMountIdentity:nil options:overlapOptions];
    BOOL cleanupSeparatesOverlappingCategories =
        [overlapCleanup[@"success"] boolValue] &&
        [overlapCleanup[@"removed"] unsignedIntegerValue] == 7 &&
        ![manager fileExistsAtPath:appleDoubleCustom] &&
        ![manager fileExistsAtPath:lateCustom] &&
        ![manager fileExistsAtPath:builtInDSStore] &&
        ![manager fileExistsAtPath:builtInApdisk] &&
        ![manager fileExistsAtPath:builtInVolumeIcon] &&
        ![manager fileExistsAtPath:builtInDesktopIni] &&
        ![manager fileExistsAtPath:builtInThumbsDb] &&
        [manager fileExistsAtPath:trashAppleDouble] &&
        [manager fileExistsAtPath:temporaryAppleDouble] &&
        [manager fileExistsAtPath:trashDSStore] &&
        [manager fileExistsAtPath:temporaryDSStore] &&
        [overlapCleanup[@"errors"] count] == 0;

    [manager removeItemAtPath:root error:nil];
    for (NSString *key in preferenceKeys) {
        id value = savedValues[key];
        if (value == [NSNull null]) [defaults removeObjectForKey:key];
        else [defaults setObject:value forKey:key];
    }
    if (savedRules == [NSNull null]) [defaults removeObjectForKey:@"volumeRules"];
    else [defaults setObject:savedRules forKey:@"volumeRules"];
    [defaults setBool:savedPeriodicEnabled forKey:@"periodicCleaning"];
    return validated && snapshotIsImmutable && periodicRequiresCustomConfirmation && confirmationAccepted && periodicUsesConfirmedCustomRules && changingExtensionsInvalidatesPeriodicConsent && periodicRechecksChangedCustomRules && periodicRechecksDisabledCustomRule && previewIsSafe && cleanupIsSafe && previewSeparatesOverlappingCategories && cleanupSeparatesOverlappingCategories;
}

static BOOL MountIdentitySafetyRegression(TestDriveSweepController *controller, NSUserDefaults *defaults) {
    char template[] = "/private/tmp/drivesweep-identity.XXXXXX";
    char *temporaryPath = mkdtemp(template);
    if (!temporaryPath) return NO;
    NSString *root = [NSString stringWithUTF8String:temporaryPath];
    NSURL *volume = [NSURL fileURLWithPath:root];
    NSString *volumeIdentity = @"volume-identity-fixture";
    BOOL volumeUUIDIsAccepted = [[controller mountIdentityFromDiskInfo:@{
        @"VolumeUUID": volumeIdentity,
        @"DiskUUID": @"disk-identity-fixture"
    }] isEqualToString:volumeIdentity];
    BOOL diskUUIDFallbackIsRejected = [controller mountIdentityFromDiskInfo:@{
        @"DiskUUID": @"disk-identity-fixture"
    }] == nil;
    BOOL malformedVolumeUUIDIsRejected = [controller mountIdentityFromDiskInfo:@{
        @"VolumeUUID": @42
    }] == nil;

    BOOL savedAutomatic = [defaults boolForKey:DSAutomaticCleaning];
    BOOL savedPeriodic = [defaults boolForKey:DSPeriodicCleaning];
    NSArray<NSURL *> *savedEligibleVolumes = controller.eligibleVolumes;
    NSDictionary<NSString *, NSString *> *savedIdentities = controller.eligibleVolumeIdentities;
    NSMutableSet<NSString *> *savedScheduledPaths = [controller.scheduledCleanupPaths mutableCopy];
    DSOperationState *savedOperation = controller.activeOperation;
    NSMutableDictionary<NSString *, NSString *> *savedFingerprints = [controller.lastCustomAnalysisFingerprints mutableCopy];

    [defaults setBool:YES forKey:DSAutomaticCleaning];
    [defaults setBool:YES forKey:DSPeriodicCleaning];
    controller.activeOperation = nil;
    controller.eligibleVolumes = @[volume];
    controller.eligibleVolumeIdentities = @{};
    controller.scheduledCleanupPaths = [NSMutableSet set];
    controller.lastCustomAnalysisFingerprints = [NSMutableDictionary dictionary];
    BOOL unsafeIdentityBlocksAutomaticAndPeriodic =
        ![controller allowsAutomaticCleaningForIdentity:nil] &&
        ![controller allowsPeriodicCleaningForIdentity:nil] &&
        [controller periodicCleanupTargets].count == 0;
    DSOperationState *unsafeAutomaticOperation = [[DSOperationState alloc] init];
    unsafeAutomaticOperation.automaticCleanup = YES;
    unsafeAutomaticOperation.periodicCleanup = YES;
    NSDictionary<NSString *, id> *unsafeAutomaticResult = [controller cleanVolumeOnWorker:volume
        expectedMountIdentity:nil options:@{} operation:unsafeAutomaticOperation];
    BOOL unsafeIdentityBlocksWorker = ![unsafeAutomaticResult[@"success"] boolValue] &&
        [[unsafeAutomaticResult[@"errors"] componentsJoinedByString:@"; "] containsString:@"non è più autorizzata"];

    DSOperationState *samePathOperation = [[DSOperationState alloc] init];
    samePathOperation.volumeURL = volume;
    samePathOperation.volumeIdentity = volumeIdentity;
    controller.activeOperation = samePathOperation;
    controller.eligibleVolumeIdentities = @{ volume.path: volumeIdentity };
    controller.scheduledCleanupPaths = [NSMutableSet setWithObject:volume.path];
    controller.lastCustomAnalysisFingerprints = [@{ volumeIdentity: @"analisi-da-invalidare" } mutableCopy];
    [controller handleUnmountedVolumeURL:volume];
    BOOL unmountCancelsByPathAndInvalidatesFingerprint = samePathOperation.cancellationRequested &&
        ![controller.lastCustomAnalysisFingerprints[volumeIdentity] length] &&
        ![controller.scheduledCleanupPaths containsObject:volume.path];

    NSURL *identityOnlyUnmount = [volume URLByAppendingPathComponent:@"remounted" isDirectory:YES];
    DSOperationState *sameIdentityOperation = [[DSOperationState alloc] init];
    sameIdentityOperation.volumeURL = volume;
    sameIdentityOperation.volumeIdentity = volumeIdentity;
    controller.activeOperation = sameIdentityOperation;
    controller.eligibleVolumeIdentities = @{ identityOnlyUnmount.path: volumeIdentity };
    controller.scheduledCleanupPaths = [NSMutableSet setWithObject:volume.path];
    controller.lastCustomAnalysisFingerprints = [@{ volumeIdentity: @"analisi-da-invalidare-2" } mutableCopy];
    [controller handleUnmountedVolumeURL:identityOnlyUnmount];
    BOOL unmountCancelsByIdentity = sameIdentityOperation.cancellationRequested &&
        ![controller.lastCustomAnalysisFingerprints[volumeIdentity] length];

    DSOperationState *unrelatedOperation = [[DSOperationState alloc] init];
    unrelatedOperation.volumeURL = volume;
    unrelatedOperation.volumeIdentity = @"different-identity";
    NSURL *unrelatedUnmount = [volume URLByAppendingPathComponent:@"unrelated" isDirectory:YES];
    controller.activeOperation = unrelatedOperation;
    controller.eligibleVolumeIdentities = @{ unrelatedUnmount.path: @"unrelated-identity" };
    controller.lastCustomAnalysisFingerprints = [@{ unrelatedOperation.volumeIdentity: @"must-survive" } mutableCopy];
    [controller handleUnmountedVolumeURL:unrelatedUnmount];
    BOOL unrelatedUnmountDoesNotCancelOrInvalidate = !unrelatedOperation.cancellationRequested &&
        [controller.lastCustomAnalysisFingerprints[unrelatedOperation.volumeIdentity] isEqualToString:@"must-survive"];

    controller.eligibleVolumes = savedEligibleVolumes;
    controller.eligibleVolumeIdentities = savedIdentities;
    controller.scheduledCleanupPaths = savedScheduledPaths ?: [NSMutableSet set];
    controller.activeOperation = savedOperation;
    controller.lastCustomAnalysisFingerprints = savedFingerprints ?: [NSMutableDictionary dictionary];
    [defaults setBool:savedAutomatic forKey:DSAutomaticCleaning];
    [defaults setBool:savedPeriodic forKey:DSPeriodicCleaning];
    [[NSFileManager defaultManager] removeItemAtPath:root error:nil];
    return volumeUUIDIsAccepted && diskUUIDFallbackIsRejected && malformedVolumeUUIDIsRejected &&
        unsafeIdentityBlocksAutomaticAndPeriodic && unsafeIdentityBlocksWorker &&
        unmountCancelsByPathAndInvalidatesFingerprint && unmountCancelsByIdentity &&
        unrelatedUnmountDoesNotCancelOrInvalidate;
}

int main(void) {
    @autoreleasepool {
        char template[] = "/private/tmp/drivesweep-cleanup.XXXXXX";
        char *temporaryPath = mkdtemp(template);
        if (!temporaryPath) return 1;

        NSFileManager *manager = [NSFileManager defaultManager];
        NSString *root = [NSString stringWithUTF8String:temporaryPath];
        NSString *nested = [root stringByAppendingPathComponent:@"nested"];
        if (!CreateDirectory(manager, nested) ||
            !CreateDirectory(manager, [root stringByAppendingPathComponent:@".Trashes"]) ||
            !CreateDirectory(manager, [root stringByAppendingPathComponent:@".Spotlight-V100"]) ||
            !CreateDirectory(manager, [root stringByAppendingPathComponent:@".fseventsd"]) ||
            !CreateDirectory(manager, [root stringByAppendingPathComponent:@".TemporaryItems"]) ||
            !CreateDirectory(manager, [root stringByAppendingPathComponent:@".AppleDouble"]) ||
            !CreateDirectory(manager, [nested stringByAppendingPathComponent:@".apdisk"])) return 1;
        [@"metadata" writeToFile:[nested stringByAppendingPathComponent:@".DS_Store"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [@"payload" writeToFile:[root stringByAppendingPathComponent:@"photo.jpg"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [@"appledouble" writeToFile:[root stringByAppendingPathComponent:@"._photo.jpg"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [@"legacy" writeToFile:[root stringByAppendingPathComponent:@"keep.eps"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [@"appledouble" writeToFile:[root stringByAppendingPathComponent:@"._keep.eps"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        for (NSString *name in @[@".apdisk", @".VolumeIcon.icns", @"Desktop.ini", @"Thumbs.db", @"purge.cache"]) {
            [@"metadata" writeToFile:[root stringByAppendingPathComponent:name] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        [@"sentinel" writeToFile:[root stringByAppendingPathComponent:@"keep.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [@"sentinel" writeToFile:[nested stringByAppendingPathComponent:@".apdisk/keep.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSString *benchmarkRoot = [root stringByAppendingPathComponent:@"benchmark"];
        if (!CreateDirectory(manager, benchmarkRoot)) return 1;
        for (NSUInteger directoryIndex = 0; directoryIndex < 1200; directoryIndex++) {
            NSString *directory = [benchmarkRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"d-%04lu", (unsigned long)directoryIndex]];
            if (!CreateDirectory(manager, directory)) return 1;
            for (NSUInteger fileIndex = 0; fileIndex < 10; fileIndex++) {
                NSString *path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"entry-%02lu.dat", (unsigned long)fileIndex]];
                if (![@"payload" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]) return 1;
            }
        }

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSDictionary<NSString *, id> *registeredDefaults = DSDefaultPreferences();
        if (![registeredDefaults[DSAppleDouble] boolValue] ||
            [registeredDefaults[DSAutomaticCleaning] boolValue] ||
            [registeredDefaults[DSCustomFiles] boolValue] ||
            [registeredDefaults[DSCustomFileExtensions] count] != 0) return 1;
        TestDriveSweepController *controller = [[TestDriveSweepController alloc] init];
        BOOL notificationAuthorizationLaunch = NotificationAuthorizationLaunchRegression(controller, defaults);
        controller.testDiskInfo = @{
            @"Internal": @NO,
            @"RemovableMediaOrExternalDevice": @YES,
            @"SystemImage": @NO,
            @"WritableVolume": @YES,
            @"DeviceIdentifier": @"disk-image-fixture",
            @"BusProtocol": @"Disk Image"
        };
        BOOL rejectsDiskImages = ![controller isEligibleExternalVolume:[NSURL fileURLWithPath:root] error:nil];
        controller.testDiskInfo = nil;
        BOOL dockLifecycle = ![controller applicationShouldTerminateAfterLastWindowClosed:NSApp] &&
            [controller applicationShouldHandleReopen:NSApp hasVisibleWindows:NO] &&
            controller.dashboardPresentationCount == 1;
        BOOL dashboardReopenAfterClose = DashboardReopenAfterCloseRegression();
        [controller applyCleanupProfile:DSProfileMacMetadata];
        NSDictionary<NSString *, id> *macMetadataOptions = [controller cleanupOptionsSnapshot];
        [controller applyCleanupProfile:DSProfileCrossPlatform];
        NSDictionary<NSString *, id> *crossPlatformOptions = [controller cleanupOptionsSnapshot];
        BOOL profileSnapshots =
            ![macMetadataOptions[DSAppleDouble] boolValue] &&
            [macMetadataOptions[DSDSStore] boolValue] &&
            ![macMetadataOptions[DSTrashes] boolValue] &&
            [crossPlatformOptions[DSAppleDouble] boolValue] &&
            [crossPlatformOptions[DSDSStore] boolValue] &&
            ![crossPlatformOptions[DSTrashes] boolValue];

        BOOL savedAutomaticCleaning = [defaults boolForKey:@"automaticCleaning"];
        BOOL savedPeriodicCleaning = [defaults boolForKey:@"periodicCleaning"];
        [defaults setBool:YES forKey:@"automaticCleaning"];
        [defaults setBool:YES forKey:@"periodicCleaning"];
        [defaults removeObjectForKey:@"periodicCleaningIntervalUnit"];
        [defaults setInteger:15 * 60 forKey:@"periodicCleaningInterval"];
        BOOL migratesLegacyPeriodicSeconds = [controller periodicCleanupIntervalMinutes] == 15 &&
            [defaults integerForKey:@"periodicCleaningInterval"] == 15 &&
            [[defaults stringForKey:@"periodicCleaningIntervalUnit"] isEqualToString:@"minutes"];
        [defaults setBool:savedAutomaticCleaning forKey:@"automaticCleaning"];
        [defaults setBool:savedPeriodicCleaning forKey:@"periodicCleaning"];
        [defaults setObject:@"minutes" forKey:@"periodicCleaningIntervalUnit"];
        [defaults setInteger:900 forKey:@"periodicCleaningInterval"];
        BOOL preservesModernMinuteInterval = [controller periodicCleanupIntervalMinutes] == 900;
        [defaults setInteger:-1 forKey:@"periodicCleaningInterval"];
        BOOL clampsShortPeriodicInterval = [controller periodicCleanupIntervalMinutes] == 1;
        [defaults setInteger:1 forKey:@"periodicCleaningInterval"];
        BOOL acceptsOneMinutePeriodicInterval = [controller periodicCleanupIntervalMinutes] == 1 && [controller periodicCleanupInterval] == 60;
        [defaults setInteger:7 * 24 * 60 * 60 forKey:@"periodicCleaningInterval"];
        BOOL clampsLongPeriodicInterval = [controller periodicCleanupIntervalMinutes] == 10080;
        [defaults setInteger:60 forKey:@"periodicCleaningInterval"];

        [defaults setBool:NO forKey:@"periodicCleaning"];
        [controller configurePeriodicCleanupWithMinutes:17];
        BOOL configuredScheduleUsesChosenInterval = [defaults boolForKey:@"periodicCleaning"] &&
            [controller periodicCleanupIntervalMinutes] == 17 &&
            controller.periodicCleanupTimer != nil &&
            [[controller nextPeriodicCleanupLabelAtDate:[NSDate date]] hasPrefix:@"Prossima pulizia tra "];
        [controller stopPeriodicCleanup:nil];

        BOOL resourceGuardThresholds =
            ![controller resourceGuardShouldPauseForCPUPercent:42 residentBytes:64ULL * 1024 * 1024 consecutiveBreaches:0] &&
            ![controller resourceGuardShouldPauseForCPUPercent:81 residentBytes:64ULL * 1024 * 1024 consecutiveBreaches:1] &&
            [controller resourceGuardShouldPauseForCPUPercent:81 residentBytes:64ULL * 1024 * 1024 consecutiveBreaches:2] &&
            [controller resourceGuardShouldPauseForCPUPercent:4 residentBytes:800ULL * 1024 * 1024 consecutiveBreaches:2];
        [defaults setBool:YES forKey:@"periodicCleaning"];
        controller.periodicCleanupSuspendedByResourceGuard = NO;
        controller.periodicCleanupTimer = [NSTimer timerWithTimeInterval:60 target:controller selector:@selector(description) userInfo:nil repeats:NO];
        controller.scheduleCountdownTimer = [NSTimer timerWithTimeInterval:1 target:controller selector:@selector(description) userInfo:nil repeats:NO];
        controller.nextPeriodicCleanupDate = [NSDate dateWithTimeIntervalSinceNow:60];
        NSString *resourceWarning = @"Pianificazione sospesa: soglia risorse superata.";
        [controller suspendPeriodicCleanupForResourceGuardWithWarning:resourceWarning];
        BOOL resourceGuardSuspendsScheduler = controller.periodicCleanupSuspendedByResourceGuard &&
            ![defaults boolForKey:@"periodicCleaning"] &&
            controller.periodicCleanupTimer == nil &&
            controller.scheduleCountdownTimer == nil &&
            controller.nextPeriodicCleanupDate == nil &&
            [controller.dashboardStatusMessage isEqualToString:resourceWarning] &&
            [[controller nextPeriodicCleanupLabelAtDate:[NSDate date]] containsString:@"sospesa per protezione risorse"];
        DSOperationState *resourceCancelledOperation = [[DSOperationState alloc] init];
        resourceCancelledOperation.periodicCleanup = YES;
        resourceCancelledOperation.volumeName = @"Fixture";
        resourceCancelledOperation.cancellationRequested = YES;
        controller.activeOperation = resourceCancelledOperation;
        [controller finishOperation:resourceCancelledOperation result:@{ @"cancelled": @YES, @"removed": @0 }];
        NSDate *resourceFinishDeadline = [NSDate dateWithTimeIntervalSinceNow:1];
        while (controller.activeOperation && resourceFinishDeadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        BOOL resourceWarningSurvivesCancellation = !controller.activeOperation &&
            [controller.dashboardStatusMessage isEqualToString:resourceWarning];
        [controller configurePeriodicCleanupWithMinutes:17];
        BOOL resourceGuardCanResume = !controller.periodicCleanupSuspendedByResourceGuard && [defaults boolForKey:@"periodicCleaning"];
        controller.resourceMonitorTimer = [NSTimer timerWithTimeInterval:60 target:controller selector:@selector(description) userInfo:nil repeats:NO];
        [controller stopResourceMonitorForOperation:nil];
        BOOL orphanedResourceMonitorIsStopped = controller.resourceMonitorTimer == nil;

        NSString *testIdentity = @"drivesweep-harness-volume-uuid";
        [controller setVolumeRuleForIdentity:testIdentity name:@"Fixture" excluded:NO allowAutomatic:YES];
        BOOL uuidRules = [controller allowsAutomaticCleaningForIdentity:testIdentity] && ![controller isVolumeExcludedForIdentity:testIdentity];
        [controller setVolumeRuleForIdentity:testIdentity name:@"Fixture" excluded:YES allowAutomatic:YES];
        uuidRules = uuidRules && ![controller allowsAutomaticCleaningForIdentity:testIdentity] && [controller isVolumeExcludedForIdentity:testIdentity];
        [controller setVolumeRuleForIdentity:testIdentity name:@"Fixture" excluded:NO allowAutomatic:NO];
        uuidRules = uuidRules && [controller volumeRuleForIdentity:testIdentity].count == 0;

        [defaults setBool:YES forKey:DSAppleDouble];
        [defaults setBool:YES forKey:DSDSStore];
        [defaults setObject:@"eps" forKey:DSAppleDoubleExtensions];
        [defaults setBool:YES forKey:DSTrashes];
        [defaults setBool:YES forKey:DSSpotlight];
        [defaults setBool:YES forKey:DSFileEvents];
        [defaults setBool:YES forKey:DSApdisk];
        [defaults setBool:YES forKey:DSVolumeIcon];
        [defaults setBool:YES forKey:DSDesktopIni];
        [defaults setBool:YES forKey:DSThumbsDb];
        [defaults setBool:YES forKey:DSTemporaryItems];
        [defaults setBool:YES forKey:DSAppleDoubleDirectories];
        [defaults setObject:@"eps" forKey:DSAppleDoubleExtensions];

        NSURL *volume = [NSURL fileURLWithPath:root];
        NSDictionary<NSString *, id> *options = [controller cleanupOptionsSnapshot];
        NSPopUpButton *actionsButton = [controller dashboardActionsButtonForVolume:volume identity:@"fixture-volume-uuid" enabled:YES];
        NSMenuItem *analyzeItem = actionsButton.menu.itemArray[1];
        [controller previewFromMenu:analyzeItem];
        BOOL dashboardAnalyzeCapturesTarget =
            [controller.capturedPreviewVolume.path isEqualToString:volume.path] &&
            [controller.capturedPreviewIdentity isEqualToString:@"fixture-volume-uuid"];

        NSString *periodicIdentity = @"periodic-fixture-uuid";
        controller.eligibleVolumes = @[volume];
        controller.eligibleVolumeIdentities = @{ volume.path: periodicIdentity };
        [controller setVolumeRuleForIdentity:periodicIdentity name:@"Fixture" excluded:NO allowAutomatic:NO];
        [controller setPeriodicCleaning:YES forIdentity:periodicIdentity name:@"Fixture"];
        [defaults setBool:NO forKey:DSAutomaticCleaning];
        [defaults setBool:YES forKey:@"periodicCleaning"];
        NSArray<DSVolumeTarget *> *periodicTargets = [controller periodicCleanupTargets];
        BOOL periodicTargetsRequireSeparateConsent = periodicTargets.count == 1 &&
            [periodicTargets.firstObject.volumeURL.path isEqualToString:volume.path] &&
            [periodicTargets.firstObject.mountIdentity isEqualToString:periodicIdentity];
        [controller setPeriodicCleaning:NO forIdentity:periodicIdentity name:@"Fixture"];
        BOOL periodicTargetsRequirePerDiskSelection = [controller periodicCleanupTargets].count == 0;
        [controller setPeriodicCleaning:YES forIdentity:periodicIdentity name:@"Fixture"];
        [controller runPeriodicCleanup:nil];
        BOOL periodicRunUsesAuthorizedTarget =
            [controller.capturedPeriodicVolume.path isEqualToString:volume.path] &&
            [controller.capturedPeriodicIdentity isEqualToString:periodicIdentity] &&
            [controller.capturedPeriodicSource isEqualToString:@"pulizia periodica"];
        [controller configurePeriodicCleanupTimer];
        BOOL periodicTimerEnabled = controller.periodicCleanupTimer != nil;
        [controller stopPeriodicCleanup:nil];
        BOOL periodicTimerDisabled = controller.periodicCleanupTimer == nil && ![defaults boolForKey:@"periodicCleaning"];
        [controller setPeriodicCleaning:NO forIdentity:periodicIdentity name:@"Fixture"];
        controller.scheduleCountdownTimer = [NSTimer timerWithTimeInterval:60 target:controller selector:@selector(description) userInfo:nil repeats:NO];
        [controller applicationWillTerminate:[NSNotification notificationWithName:@"DriveSweepHarnessTermination" object:nil]];
        BOOL countdownTimerStopsOnTermination = !controller.scheduleCountdownTimer.isValid;

        NSTextField *customExtensionsField = [controller preferenceTextField:@"customFileExtensions" y:0];
        customExtensionsField.stringValue = @"tmp,bak";
        BOOL customExtensionsRemainEditable = !customExtensionsField.continuous && (id)customExtensionsField.delegate == (id)controller && [customExtensionsField.stringValue isEqualToString:@"tmp,bak"];
        [controller saveTextPreference:customExtensionsField];
        BOOL customExtensionsCommitOnSave = [[defaults objectForKey:@"customFileExtensions"] isEqual:@[@"bak", @"tmp"]];

        NSString *periodicRoot = [root stringByAppendingPathComponent:@"periodic-e2e"];
        if (!CreateDirectory(manager, periodicRoot) ||
            ![@"metadata" writeToFile:[periodicRoot stringByAppendingPathComponent:@".DS_Store"] atomically:YES encoding:NSUTF8StringEncoding error:nil] ||
            ![@"sentinel" writeToFile:[periodicRoot stringByAppendingPathComponent:@"keep.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil]) return 1;
        NSURL *periodicVolume = [NSURL fileURLWithPath:periodicRoot];
        controller.cleanupQueue = dispatch_queue_create("com.github.naicud.drivesweep.periodic-test", DISPATCH_QUEUE_SERIAL);
        controller.scheduledCleanupPaths = [NSMutableSet set];
        controller.eligibleVolumes = @[periodicVolume];
        controller.eligibleVolumeIdentities = @{ periodicVolume.path: periodicIdentity };
        controller.testMountIdentity = periodicIdentity;
        controller.mountIdentityChecks = 0;
        controller.changeIdentityAfterChecks = NSUIntegerMax;
        [controller setVolumeRuleForIdentity:periodicIdentity name:@"Periodic fixture" excluded:NO allowAutomatic:NO];
        [controller setPeriodicCleaning:YES forIdentity:periodicIdentity name:@"Periodic fixture"];
        for (NSString *key in DSCleanupPreferenceKeys()) [defaults setBool:NO forKey:key];
        [defaults setBool:YES forKey:DSDSStore];
        [defaults setBool:NO forKey:DSAutomaticCleaning];
        [defaults setBool:YES forKey:@"periodicCleaning"];
        controller.runActualPeriodicCleanup = YES;
        [controller runPeriodicCleanup:nil];
        NSDate *periodicDeadline = [NSDate dateWithTimeIntervalSinceNow:3];
        while ([manager fileExistsAtPath:[periodicRoot stringByAppendingPathComponent:@".DS_Store"]] && periodicDeadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        }
        BOOL periodicEndToEndCleanup =
            ![manager fileExistsAtPath:[periodicRoot stringByAppendingPathComponent:@".DS_Store"]] &&
            [manager fileExistsAtPath:[periodicRoot stringByAppendingPathComponent:@"keep.txt"]];

        /*
         * A scheduled run is serialized across selected disks.  Exercise the
         * real worker/completion path with two fixtures so the next target is
         * not attempted while the previous DSOperationState is still active.
         * This intentionally runs only under /private/tmp.
         */
        NSString *periodicSecondRoot = [root stringByAppendingPathComponent:@"periodic-e2e-second"];
        if (!CreateDirectory(manager, periodicSecondRoot) ||
            ![@"metadata" writeToFile:[periodicSecondRoot stringByAppendingPathComponent:@".DS_Store"] atomically:YES encoding:NSUTF8StringEncoding error:nil] ||
            ![@"sentinel" writeToFile:[periodicSecondRoot stringByAppendingPathComponent:@"keep.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil]) return 1;
        NSURL *periodicSecondVolume = [NSURL fileURLWithPath:periodicSecondRoot];
        controller.activeOperation = nil;
        controller.scheduledCleanupPaths = [NSMutableSet set];
        controller.eligibleVolumes = @[periodicVolume, periodicSecondVolume];
        controller.eligibleVolumeIdentities = @{ periodicVolume.path: periodicIdentity, periodicSecondVolume.path: periodicIdentity };
        controller.mountIdentityChecks = 0;
        [controller runPeriodicCleanup:nil];
        NSDate *multiVolumeDeadline = [NSDate dateWithTimeIntervalSinceNow:3];
        while (([manager fileExistsAtPath:[periodicRoot stringByAppendingPathComponent:@".DS_Store"]] ||
                 [manager fileExistsAtPath:[periodicSecondRoot stringByAppendingPathComponent:@".DS_Store"]]) &&
               multiVolumeDeadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        }
        BOOL periodicCleansAllSelectedVolumes =
            ![manager fileExistsAtPath:[periodicRoot stringByAppendingPathComponent:@".DS_Store"]] &&
            ![manager fileExistsAtPath:[periodicSecondRoot stringByAppendingPathComponent:@".DS_Store"]] &&
            [manager fileExistsAtPath:[periodicSecondRoot stringByAppendingPathComponent:@"keep.txt"]];

        /* Exercise the actual NSTimer -> main run loop -> selector path. */
        [@"metadata" writeToFile:[periodicSecondRoot stringByAppendingPathComponent:@".DS_Store"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        controller.activeOperation = nil;
        controller.scheduledCleanupPaths = [NSMutableSet set];
        controller.eligibleVolumes = @[periodicSecondVolume];
        controller.eligibleVolumeIdentities = @{ periodicSecondVolume.path: periodicIdentity };
        [controller.periodicCleanupTimer invalidate];
        controller.periodicCleanupTimer = [NSTimer scheduledTimerWithTimeInterval:0.02
            target:controller selector:@selector(runPeriodicCleanup:) userInfo:nil repeats:NO];
        [[NSRunLoop mainRunLoop] addTimer:controller.periodicCleanupTimer forMode:NSRunLoopCommonModes];
        NSDate *timerDeadline = [NSDate dateWithTimeIntervalSinceNow:3];
        while ([manager fileExistsAtPath:[periodicSecondRoot stringByAppendingPathComponent:@".DS_Store"]] && timerDeadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        }
        BOOL periodicNSTimerE2E =
            ![manager fileExistsAtPath:[periodicSecondRoot stringByAppendingPathComponent:@".DS_Store"]] &&
            [manager fileExistsAtPath:[periodicSecondRoot stringByAppendingPathComponent:@"keep.txt"]];

        /* A valid tick with no selected target must leave an observable status. */
        [controller.periodicCleanupTimer invalidate];
        controller.activeOperation = nil;
        controller.eligibleVolumes = @[periodicSecondVolume];
        controller.eligibleVolumeIdentities = @{ periodicSecondVolume.path: periodicIdentity };
        [controller setPeriodicCleaning:NO forIdentity:periodicIdentity name:@"Periodic fixture"];
        [defaults setBool:YES forKey:@"periodicCleaning"];
        controller.periodicCleanupTimer = [NSTimer scheduledTimerWithTimeInterval:0.02
            target:controller selector:@selector(runPeriodicCleanup:) userInfo:nil repeats:NO];
        [[NSRunLoop mainRunLoop] addTimer:controller.periodicCleanupTimer forMode:NSRunLoopCommonModes];
        NSDate *noTargetDeadline = [NSDate dateWithTimeIntervalSinceNow:1];
        while (controller.periodicCleanupTimer.isValid && noTargetDeadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        }
        BOOL noTargetTickIsVisible = [controller.dashboardStatusMessage containsString:@"nessun disco autorizzato o disponibile"];
        [controller setPeriodicCleaning:YES forIdentity:periodicIdentity name:@"Periodic fixture"];
        controller.runActualPeriodicCleanup = NO;
        [controller setPeriodicCleaning:NO forIdentity:periodicIdentity name:@"Periodic fixture"];
        [controller showPreviewReport:@{
            @"success": @YES,
            @"counts": @{},
            @"protectedAppleDouble": @0,
            @"errors": @[]
        } options:options volume:volume];
        BOOL alertPresentationSeam = controller.presentedAlertCount == 1;
        DSOperationState *previewOperation = [[DSOperationState alloc] init];
        previewOperation.volumeURL = volume;
        previewOperation.volumeName = @"Fixture";
        previewOperation.totalCategories = [controller enabledCategoryCountForOptions:options];
        NSUInteger traversalBeforePreview = DSPreviewFileTraversalCount;
        NSTimeInterval previewStarted = NSDate.timeIntervalSinceReferenceDate;
        NSDictionary<NSString *, id> *preview = [controller previewVolumeOnWorker:volume expectedMountIdentity:nil options:options operation:previewOperation];
        NSTimeInterval previewElapsed = NSDate.timeIntervalSinceReferenceDate - previewStarted;
        fprintf(stderr, "DriveSweep preview fixture (1200 dirs, 12000 entries): %.3fs\n", previewElapsed);
        NSDictionary<NSString *, NSNumber *> *counts = preview[@"counts"];
        BOOL previewed = [preview[@"success"] boolValue] &&
            [counts[DSAppleDouble] unsignedIntegerValue] == 1 &&
            [preview[@"protectedAppleDouble"] unsignedIntegerValue] == 1 &&
            [counts[DSDSStore] unsignedIntegerValue] == 1 &&
            [counts[DSTrashes] unsignedIntegerValue] == 1 &&
            [counts[DSSpotlight] unsignedIntegerValue] == 1 &&
            [counts[DSFileEvents] unsignedIntegerValue] == 1 &&
            [counts[DSApdisk] unsignedIntegerValue] == 1 &&
            [counts[DSVolumeIcon] unsignedIntegerValue] == 1 &&
            [counts[DSDesktopIni] unsignedIntegerValue] == 1 &&
            [counts[DSThumbsDb] unsignedIntegerValue] == 1 &&
            [counts[DSTemporaryItems] unsignedIntegerValue] == 1 &&
            [counts[DSAppleDoubleDirectories] unsignedIntegerValue] == 1 &&
            previewOperation.completedCategories == previewOperation.totalCategories &&
            DSPreviewFileTraversalCount == traversalBeforePreview + 1 &&
            [manager fileExistsAtPath:[nested stringByAppendingPathComponent:@".DS_Store"]] &&
            [manager fileExistsAtPath:[root stringByAppendingPathComponent:@"._photo.jpg"]] &&
            [manager fileExistsAtPath:[root stringByAppendingPathComponent:@"._keep.eps"]];

        NSArray<NSString *> *protectedRootDirectories = @[@".Trashes", @".Spotlight-V100", @".fseventsd", @".TemporaryItems"];
        BOOL protectedRootDirectoriesAreExcludedFromPreviewTraversal =
            DSIsPreviewTraversalExcludedRootDirectory(@".Trashes") &&
            DSIsPreviewTraversalExcludedRootDirectory(@".Spotlight-V100") &&
            DSIsPreviewTraversalExcludedRootDirectory(@".fseventsd") &&
            DSIsPreviewTraversalExcludedRootDirectory(@".TemporaryItems") &&
            !DSIsPreviewTraversalExcludedRootDirectory(@"ordinary-folder");
        for (NSString *name in protectedRootDirectories) {
            NSString *directory = [root stringByAppendingPathComponent:name];
            if (![@"metadata" writeToFile:[directory stringByAppendingPathComponent:@"state"] atomically:YES encoding:NSUTF8StringEncoding error:nil]) return 1;
            if (!DenyFixtureDirectoryTraversal(directory)) return 1;
        }
        NSMutableDictionary<NSString *, id> *optionsWithDisabledRootMetadata = [options mutableCopy];
        for (NSString *key in @[DSTrashes, DSSpotlight, DSFileEvents, DSTemporaryItems]) optionsWithDisabledRootMetadata[key] = @NO;
        NSDictionary<NSString *, id> *unreadableRootMetadataPreview = [controller previewVolumeOnWorker:volume expectedMountIdentity:nil options:optionsWithDisabledRootMetadata];
        for (NSString *name in protectedRootDirectories) {
            NSString *directory = [root stringByAppendingPathComponent:name];
            if (!RestoreFixtureDirectoryTraversal(directory)) return 1;
        }
        BOOL unreadableRootMetadataDoesNotFailPreview =
            [unreadableRootMetadataPreview[@"success"] boolValue] &&
            [unreadableRootMetadataPreview[@"counts"][DSTrashes] unsignedIntegerValue] == 0 &&
            [unreadableRootMetadataPreview[@"counts"][DSSpotlight] unsignedIntegerValue] == 0 &&
            [unreadableRootMetadataPreview[@"counts"][DSFileEvents] unsignedIntegerValue] == 0 &&
            [unreadableRootMetadataPreview[@"counts"][DSTemporaryItems] unsignedIntegerValue] == 0 &&
            [unreadableRootMetadataPreview[@"errors"] count] == 0;

        DSOperationState *cancelledScanOperation = [[DSOperationState alloc] init];
        cancelledScanOperation.kind = DSOperationKindPreview;
        cancelledScanOperation.volumeURL = volume;
        cancelledScanOperation.volumeName = @"Fixture";
        cancelledScanOperation.totalCategories = [controller enabledCategoryCountForOptions:options];
        cancelledScanOperation.cancellationRequested = YES;
        NSDictionary<NSString *, id> *cancelledPreview = [controller previewVolumeOnWorker:volume expectedMountIdentity:nil options:options operation:cancelledScanOperation];
        BOOL cancelledScanTransition = ![cancelledPreview[@"success"] boolValue] &&
            [cancelledPreview[@"cancelled"] boolValue] &&
            [[controller operationStatusText:cancelledScanOperation] containsString:@"attendo che il filesystem"] &&
            [manager fileExistsAtPath:[root stringByAppendingPathComponent:@"._photo.jpg"]];

        for (NSString *key in DSCleanupPreferenceKeys()) [defaults setBool:NO forKey:key];
        [defaults setObject:@"" forKey:DSAppleDoubleExtensions];
        NSDictionary<NSString *, id> *result = [controller cleanVolumeOnWorker:volume expectedMountIdentity:nil options:options];
        BOOL cleanedWithSnapshot = [result[@"success"] boolValue] &&
            ![manager fileExistsAtPath:[nested stringByAppendingPathComponent:@".DS_Store"]] &&
            ![manager fileExistsAtPath:[root stringByAppendingPathComponent:@"._photo.jpg"]] &&
            [manager fileExistsAtPath:[root stringByAppendingPathComponent:@"._keep.eps"]] &&
            ![manager fileExistsAtPath:[root stringByAppendingPathComponent:@".Trashes"]] &&
            ![manager fileExistsAtPath:[root stringByAppendingPathComponent:@".Spotlight-V100"]] &&
            ![manager fileExistsAtPath:[root stringByAppendingPathComponent:@".fseventsd"]] &&
            ![manager fileExistsAtPath:[root stringByAppendingPathComponent:@".TemporaryItems"]] &&
            ![manager fileExistsAtPath:[root stringByAppendingPathComponent:@".AppleDouble"]] &&
            ![manager fileExistsAtPath:[root stringByAppendingPathComponent:@".apdisk"]] &&
            ![manager fileExistsAtPath:[root stringByAppendingPathComponent:@".VolumeIcon.icns"]] &&
            ![manager fileExistsAtPath:[root stringByAppendingPathComponent:@"Desktop.ini"]] &&
            ![manager fileExistsAtPath:[root stringByAppendingPathComponent:@"Thumbs.db"]] &&
            [manager fileExistsAtPath:[root stringByAppendingPathComponent:@"purge.cache"]] &&
        [manager fileExistsAtPath:[nested stringByAppendingPathComponent:@".apdisk/keep.txt"]] &&
            [manager fileExistsAtPath:[root stringByAppendingPathComponent:@"photo.jpg"]] &&
            [manager fileExistsAtPath:[root stringByAppendingPathComponent:@"keep.eps"]] &&
            [manager fileExistsAtPath:[root stringByAppendingPathComponent:@"keep.txt"]];

        [@"appledouble" writeToFile:[root stringByAppendingPathComponent:@"._identity.jpg"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [@"metadata" writeToFile:[root stringByAppendingPathComponent:@".DS_Store"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        controller.testMountIdentity = @"fixture-volume-uuid";
        controller.mountIdentityChecks = 0;
        controller.changeIdentityAfterChecks = 2;
        NSDictionary<NSString *, id> *identityChanged = [controller cleanVolumeOnWorker:volume expectedMountIdentity:controller.testMountIdentity options:options];
        BOOL identityChangeStopsCleanup = ![identityChanged[@"success"] boolValue] &&
            [[identityChanged[@"errors"] componentsJoinedByString:@"; "] containsString:@"identità è cambiata durante la pulizia"] &&
            ![manager fileExistsAtPath:[root stringByAppendingPathComponent:@"._identity.jpg"]] &&
            [manager fileExistsAtPath:[root stringByAppendingPathComponent:@".DS_Store"]];
        controller.changeIdentityAfterChecks = NSUIntegerMax;

        [defaults setBool:YES forKey:DSAppleDouble];
        [defaults setBool:YES forKey:DSDSStore];
        [defaults setObject:@"eps" forKey:DSAppleDoubleExtensions];
        [@"appledouble" writeToFile:[root stringByAppendingPathComponent:@"._cancel.jpg"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [@"metadata" writeToFile:[root stringByAppendingPathComponent:@".DS_Store"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSDictionary<NSString *, id> *cancellationOptions = [controller cleanupOptionsSnapshot];
        DSOperationState *cancellationOperation = [[DSOperationState alloc] init];
        cancellationOperation.volumeURL = volume;
        cancellationOperation.volumeName = @"Fixture";
        cancellationOperation.totalCategories = [controller enabledCategoryCountForOptions:cancellationOptions];
        cancellationOperation.progressHandler = ^(DSOperationState *operation) {
            if (operation.removedCount >= 1) operation.cancellationRequested = YES;
        };
        NSDictionary<NSString *, id> *cancelled = [controller cleanVolumeOnWorker:volume expectedMountIdentity:nil options:cancellationOptions operation:cancellationOperation];
        BOOL cancellationStopsCleanup = ![cancelled[@"success"] boolValue] &&
            [cancelled[@"cancelled"] boolValue] &&
            [cancelled[@"removed"] unsignedIntegerValue] == 1 &&
            ![manager fileExistsAtPath:[root stringByAppendingPathComponent:@"._cancel.jpg"]] &&
            [manager fileExistsAtPath:[root stringByAppendingPathComponent:@".DS_Store"]] &&
            [manager fileExistsAtPath:[root stringByAppendingPathComponent:@"keep.txt"]];
        BOOL cancelledEjectionCompletionIsFalse = ![cancelled[@"success"] boolValue] && [cancelled[@"cancelled"] boolValue];
        BOOL customExtensionCleanup = CustomExtensionCleanupRegression(controller, defaults);
        BOOL mountIdentitySafety = MountIdentitySafetyRegression(controller, defaults);
        [manager removeItemAtPath:root error:nil];
        return notificationAuthorizationLaunch && rejectsDiskImages && dockLifecycle && dashboardReopenAfterClose && profileSnapshots && migratesLegacyPeriodicSeconds && preservesModernMinuteInterval && clampsShortPeriodicInterval && acceptsOneMinutePeriodicInterval && clampsLongPeriodicInterval && configuredScheduleUsesChosenInterval && resourceGuardThresholds && resourceGuardSuspendsScheduler && resourceWarningSurvivesCancellation && resourceGuardCanResume && customExtensionsRemainEditable && customExtensionsCommitOnSave && orphanedResourceMonitorIsStopped && uuidRules && dashboardAnalyzeCapturesTarget && periodicTargetsRequireSeparateConsent && periodicTargetsRequirePerDiskSelection && periodicRunUsesAuthorizedTarget && periodicTimerEnabled && periodicTimerDisabled && countdownTimerStopsOnTermination && periodicEndToEndCleanup && periodicCleansAllSelectedVolumes && periodicNSTimerE2E && noTargetTickIsVisible && alertPresentationSeam && previewed && protectedRootDirectoriesAreExcludedFromPreviewTraversal && unreadableRootMetadataDoesNotFailPreview && cancelledScanTransition && cleanedWithSnapshot && identityChangeStopsCleanup && cancellationStopsCleanup && cancelledEjectionCompletionIsFalse && customExtensionCleanup && mountIdentitySafety ? 0 : 1;
    }
}
