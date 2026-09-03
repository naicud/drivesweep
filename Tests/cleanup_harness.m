#define main DriveSweepApplicationMain
#import "../Sources/main.m"
#undef main

@interface TestDriveSweepController : DriveSweepController
@property(nonatomic) NSUInteger presentedAlertCount;
@property(nonatomic) NSUInteger dashboardPresentationCount;
@end

@implementation TestDriveSweepController

- (BOOL)isEligibleExternalVolume:(NSURL *)url error:(NSError **)error {
    return YES;
}

- (void)presentAlertModally:(NSAlert *)alert {
    self.presentedAlertCount += 1;
}

- (void)showDashboard:(id)sender {
    self.dashboardPresentationCount += 1;
}

@end

static BOOL CreateDirectory(NSFileManager *manager, NSString *path) {
    return [manager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
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
            [registeredDefaults[DSAutomaticCleaning] boolValue]) return 1;
        TestDriveSweepController *controller = [[TestDriveSweepController alloc] init];
        BOOL dockLifecycle = ![controller applicationShouldTerminateAfterLastWindowClosed:NSApp] &&
            [controller applicationShouldHandleReopen:NSApp hasVisibleWindows:NO] &&
            controller.dashboardPresentationCount == 1;
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
        [manager removeItemAtPath:root error:nil];
        return dockLifecycle && profileSnapshots && uuidRules && alertPresentationSeam && previewed && cancelledScanTransition && cleanedWithSnapshot && cancellationStopsCleanup && cancelledEjectionCompletionIsFalse ? 0 : 1;
    }
}
