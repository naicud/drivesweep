#define main DriveSweepApplicationMain
#import "../Sources/main.m"
#undef main

static void Check(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

@interface DSV3CleanupCompletionFixture : DriveSweepController
@end
@implementation DSV3CleanupCompletionFixture
- (NSDictionary *)cleanVolumeOnWorker:(NSURL *)volume expectedMountIdentity:(NSString *)identity options:(NSDictionary *)options operation:(DSOperationState *)operation {
    @synchronized (operation) { operation.cancellationRequested = YES; }
    return @{ @"success": @YES, @"removed": @0, @"cancelled": @NO, @"errors": @[] };
}
- (void)notify:(NSString *)message { }
@end

// When launched by previewInSubprocess, this executable is a controlled IPC
// fixture. It never accesses a disk; the production worker is tested separately.
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 4 && strcmp(argv[1], "--preview-worker") == 0) {
            NSData *input = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
            NSDictionary *options = [NSJSONSerialization JSONObjectWithData:input options:0 error:nil];
            if (![options[DSAppleDoubleExtensions] isKindOfClass:NSArray.class]) return 2;
            if (strstr(argv[2], "slow")) {
                // Parent must regain its queue without waiting for this delay.
                sleep(10);
                return 0;
            }
            if (strstr(argv[2], "invalid")) { puts("invalid-json"); return 0; }
            puts("{\"progress\":true,\"category\":\"dsStore\",\"location\":\"Radice del disco\",\"completed\":1}");
            puts("{\"success\":true,\"cancelled\":false,\"counts\":{\"dsStore\":2},\"protectedAppleDouble\":1,\"candidateFileBytes\":64,\"errors\":[]}");
            return 0;
        }

        [NSApplication sharedApplication];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSDictionary *savedArguments = [defaults volatileDomainForName:NSArgumentDomain];
        [defaults setVolatileDomain:DSDefaultPreferences() forName:NSArgumentDomain];
        DriveSweepController *controller = [[DriveSweepController alloc] init];
        controller.previewRecords = [NSMutableDictionary dictionary];
        controller.recentActivity = [NSMutableArray array];
        NSURL *volume = [NSURL fileURLWithPath:@"/private/tmp/ipc-success"];
        controller.eligibleVolumes = @[volume];
        controller.eligibleVolumeIdentities = @{volume.path: @"fixture-uuid"};
        NSDictionary *options = [controller cleanupOptionsSnapshot];
        char fixtureTemplate[] = "/private/tmp/drivesweep-v3.XXXXXX";
        char *fixturePath = mkdtemp(fixtureTemplate);
        Check(fixturePath != NULL, @"Create disposable scanner fixture");
        NSURL *fixture = [NSURL fileURLWithPath:[NSString stringWithUTF8String:fixturePath]];
        NSFileManager *manager = NSFileManager.defaultManager;
        [manager createDirectoryAtURL:[fixture URLByAppendingPathComponent:@".Trashes"] withIntermediateDirectories:YES attributes:nil error:nil];
        [manager createDirectoryAtURL:[fixture URLByAppendingPathComponent:@".AppleDouble"] withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSMutableData dataWithLength:64] writeToURL:[fixture URLByAppendingPathComponent:@".DS_Store"] atomically:NO];
        [[NSMutableData dataWithLength:20] writeToURL:[fixture URLByAppendingPathComponent:@"._movie.mp4"] atomically:NO];
        [[NSMutableData dataWithLength:32] writeToURL:[fixture URLByAppendingPathComponent:@"._keep.eps"] atomically:NO];
        [[NSMutableData dataWithLength:128] writeToURL:[fixture URLByAppendingPathComponent:@".Trashes/.DS_Store"] atomically:NO];
        [manager createSymbolicLinkAtPath:[fixture.path stringByAppendingPathComponent:@"._symlink"] withDestinationPath:@"/private/tmp" error:nil];
        NSMutableDictionary *scanOptions = [options mutableCopy];
        scanOptions[DSAppleDoubleExtensions] = [NSSet setWithObject:@"eps"];
        scanOptions[DSAppleDoubleDirectories] = @YES;
        NSMutableArray *errors = [NSMutableArray array];
        NSUInteger traversals = DSPreviewFileTraversalCount;
        NSDictionary *scan = [controller previewFileCountsOnePassFromVolume:fixture options:scanOptions errors:errors operation:nil];
        Check(errors.count == 0 && [scan[@"candidateFileBytes"] unsignedIntegerValue] == 84 &&
            [scan[@"counts"][DSAppleDouble] intValue] == 1 && [scan[@"counts"][DSDSStore] intValue] == 1 &&
            [scan[@"counts"][DSAppleDoubleDirectories] intValue] == 1 && [scan[@"protected"] intValue] == 1 &&
            DSPreviewFileTraversalCount == traversals + 1, @"One traversal measures candidate files without protected metadata, symlinks or root directory contents");
        Check([manager fileExistsAtPath:[fixture.path stringByAppendingPathComponent:@".DS_Store"]], @"Analysis never removes fixture data");
        [manager removeItemAtURL:fixture error:nil];
        DSOperationState *operation = [[DSOperationState alloc] init];
        operation.volumeURL = volume;
        NSDictionary *report = [controller previewInSubprocess:volume identity:@"fixture-uuid" options:options operation:operation];
        Check([report[@"success"] boolValue] && [report[@"counts"][DSDSStore] intValue] == 2, @"IPC report and options serialization");
        Check(operation.completedCategories == 1 && [operation.category isEqual:DSDSStore], @"IPC progress forwarding");
        [controller recordPreview:report volume:volume identity:@"fixture-uuid" options:options elapsed:0.1];
        Check([controller currentPreviewForIdentity:@"fixture-uuid"] != nil, @"Fresh report available");
        NSDictionary *export = [NSJSONSerialization JSONObjectWithData:[controller dashboardReportData] options:0 error:nil];
        Check([export[@"volumes"] count] == 1 && [export[@"volumes"][0][@"candidateFileBytes"] intValue] == 64, @"JSON export preserves measured counts and size");
        NSMutableDictionary *changed = [DSDefaultPreferences() mutableCopy];
        changed[DSDSStore] = @NO;
        [defaults setVolatileDomain:changed forName:NSArgumentDomain];
        Check([controller currentPreviewForIdentity:@"fixture-uuid"] == nil, @"Options changes invalidate reports");
        export = [NSJSONSerialization JSONObjectWithData:[controller dashboardReportData] options:0 error:nil];
        Check([export[@"volumes"] count] == 0, @"Export excludes stale reports");
        [defaults setVolatileDomain:DSDefaultPreferences() forName:NSArgumentDomain];
        [controller recordPreview:report volume:volume identity:@"replacement-uuid" options:options elapsed:0.1];
        Check(controller.previewRecords[@"replacement-uuid"] == nil, @"Remounted identity cannot receive stale report");
        [controller handleUnmountedVolumeURL:volume];
        Check(controller.previewRecords.count == 0, @"Unmount clears reports");
        for (NSUInteger i = 0; i < 20; i++) [controller addRecentActivity:@"Fixture"];
        Check(controller.recentActivity.count == 8, @"History stays bounded");

        operation = [[DSOperationState alloc] init];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            @synchronized (operation) { operation.cancellationRequested = YES; }
        });
        NSTimeInterval start = NSDate.timeIntervalSinceReferenceDate;
        report = [controller previewInSubprocess:[NSURL fileURLWithPath:@"/private/tmp/ipc-slow"] identity:@"fixture-uuid" options:options operation:operation];
        NSTimeInterval elapsed = NSDate.timeIntervalSinceReferenceDate - start;
        Check([report[@"cancelled"] boolValue] && elapsed < 2, @"Cancellation releases worker queue without waiting for child filesystem");
        NSTimeInterval deadline = NSDate.timeIntervalSinceReferenceDate + 2;
        while (controller.previewTask.running && NSDate.timeIntervalSinceReferenceDate < deadline) [NSThread sleepForTimeInterval:0.01];
        Check(!controller.previewTask.running, @"Cancelled child is reaped");
        report = [controller previewInSubprocess:[NSURL fileURLWithPath:@"/private/tmp/ipc-invalid"] identity:@"fixture-uuid" options:options operation:[[DSOperationState alloc] init]];
        Check(![report[@"success"] boolValue] && [report[@"errors"] count] > 0, @"Invalid child output cannot become success");

        DriveSweepController *bulk = [[DriveSweepController alloc] init];
        NSURL *slow = [NSURL fileURLWithPath:@"/private/tmp/ipc-slow"];
        bulk.cleanupQueue = dispatch_queue_create("drivesweep.test.bulk", DISPATCH_QUEUE_SERIAL);
        bulk.eligibleVolumes = @[slow, volume];
        bulk.eligibleVolumeIdentities = @{slow.path: @"slow-uuid", volume.path: @"fixture-uuid"};
        bulk.previewRecords = [NSMutableDictionary dictionary];
        [bulk previewAll:nil];
        Check(bulk.activeOperation != nil, @"Analyze all exposes an active operation immediately");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5), dispatch_get_main_queue(), ^{ [bulk cancelActiveOperation:nil]; });
        NSDate *bulkDeadline = [NSDate dateWithTimeIntervalSinceNow:3];
        while (bulk.activeOperation && bulkDeadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        Check(!bulk.activeOperation && bulk.previewRecords[@"fixture-uuid"] == nil &&
            [bulk.previewRecords[@"slow-uuid"][@"report"][@"cancelled"] boolValue], @"Bulk cancellation stops before the next disk and frees active operation");
        DSV3CleanupCompletionFixture *lateCancel = [[DSV3CleanupCompletionFixture alloc] init];
        lateCancel.cleanupQueue = dispatch_queue_create("drivesweep.test.late-cancel", DISPATCH_QUEUE_SERIAL);
        lateCancel.scheduledCleanupPaths = [NSMutableSet set];
        __block BOOL completionCalled = NO, completionSuccess = YES;
        [lateCancel cleanVolume:volume source:@"manuale" expectedMountIdentity:@"fixture-uuid" completion:^(BOOL success) {
            completionCalled = YES;
            completionSuccess = success;
        }];
        NSDate *completionDeadline = [NSDate dateWithTimeIntervalSinceNow:3];
        while (!completionCalled && completionDeadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        Check(completionCalled && !completionSuccess, @"Cancellation before UI completion prevents successful eject continuation");
        [defaults setVolatileDomain:savedArguments ?: @{} forName:NSArgumentDomain];
        fprintf(stderr, "PASS: V3 IPC, report lifetime, export, bounded history; cancellation %.3fs\n", elapsed);
    }
    return 0;
}
