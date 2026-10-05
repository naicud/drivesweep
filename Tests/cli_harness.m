#define main DriveSweepApplicationMain
#import "../Sources/main.m"
#undef main
#import <sys/wait.h>

static void Check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}

int main(void) {
    @autoreleasepool {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSDictionary *saved = [defaults volatileDomainForName:NSArgumentDomain];
        [defaults setVolatileDomain:DSDefaultPreferences() forName:NSArgumentDomain];
        DSCLIController *controller = DSCLIMakeController();
        NSString *error = nil;
        Check(DSCLIParse(@[@"clean", @"/Volumes/USB", @"--all", @"--yes"], &error) == nil, @"No destructive --all");
        Check(DSCLIParse(@[@"list", @"--json", @"--json"], &error) == nil, @"Duplicate flags rejected");
        Check(DSCLIParse(@[@"analyze", @"--export"], &error) == nil, @"Missing flag value rejected");
        Check(DSCLIParse(@[@"resources", @"--samples", @"2", @"--json"], &error) != nil, @"Valid resource flags");
        Check(DSCLIBoolean(@"TRUE").boolValue && DSCLIBoolean(@"false") != nil && DSCLIBoolean(@"garbage") == nil, @"Strict booleans");
        double value;
        Check(!DSCLINumber(@"NaN", .25, 10, NO, &value) && !DSCLINumber(@"2junk", 1, 100, YES, &value) &&
            !DSCLINumber(@"1.5", 1, 10080, YES, &value) && DSCLINumber(@"0.25", .25, 10, NO, &value), @"Finite bounded numeric input");
        Check(DSCLIConfigValue(controller, DSVolumeRules, @"{}") == nil && DSCLIConfigValue(controller, DSPeriodicCleaningInterval, @"10081") == nil, @"No raw UUID consent injection or invalid interval");
        Check(DSCLIConfigValue(controller, DSCustomFileExtensions, @"tmp,../txt") == nil, @"Invalid deletion extension never partially accepted");
        Check([DSCLIConfigValue(controller, DSCustomFileExtensions, @".tmp,TMP,log") isEqual:@[@"log", @"tmp"]], @"Normalized extension list");
        Check([DSCLITerminalText(@"name\033[31m\n") isEqual:@"name [31m "], @"Terminal controls neutralized");
        NSURL *volume = [NSURL fileURLWithPath:@"/Volumes/CLI-fixture"];
        controller.eligibleVolumes = @[volume]; controller.eligibleVolumeIdentities = @{volume.path: @"uuid-fixture"};
        Check(DSCLITarget(controller, volume.path) != nil && DSCLITarget(controller, [volume.path stringByAppendingPathComponent:@"subdir"]) == nil &&
            DSCLITarget(controller, @"/") == nil && DSCLITarget(controller, @"relative") == nil, @"Exact verified mount root only");
        NSString *lockName = [NSString stringWithFormat:@"test-%d", getpid()];
        DSLease *lease = [DSLease acquire:lockName];
        Check(lease != nil && [DSLease acquire:lockName] == nil, @"Exclusive lock across descriptors");
        pid_t contender = fork();
        if (contender == 0) { close(lease.descriptor); _exit([DSLease acquire:lockName] == nil ? 0 : 1); }
        int status = 0; waitpid(contender, &status, 0);
        Check(WIFEXITED(status) && WEXITSTATUS(status) == 0, @"Exclusive lock across processes");
        [lease invalidate]; lease = nil; lease = [DSLease acquire:lockName]; Check(lease != nil, @"Lock released after owner closes"); [lease invalidate]; lease = nil;
        DSLease *cleanupLease = [DSLease acquire:@"cleanup"];
        if (cleanupLease) {
            NSDictionary *busy = [controller cleanVolumeOnWorker:[NSURL fileURLWithPath:@"/"] expectedMountIdentity:@"invalid" options:[controller cleanupOptionsSnapshot] operation:nil];
            Check([busy[@"busy"] boolValue], @"Engine rejects concurrent app/CLI cleanup before target access");
            [cleanupLease invalidate];
            NSDictionary *rejected = [controller cleanVolumeOnWorker:[NSURL fileURLWithPath:@"/"] expectedMountIdentity:@"invalid" options:[controller cleanupOptionsSnapshot] operation:nil];
            Check(![rejected[@"success"] boolValue], @"Internal target rejected by shared engine");
            cleanupLease = [DSLease acquire:@"cleanup"];
            Check(cleanupLease != nil, @"Early rejection releases cleanup lock before autorelease pool drains");
            [cleanupLease invalidate];
        } else puts("SKIP: existing user cleanup owns engine lock");
        Check(fabs(DSCPUPercent(2000000000, 1000000000, 2) - 50) < .001 && DSCPUPercent(1, 2, 1) == 0 && DSCPUPercent(2, 1, 0) == 0, @"Monotonic CPU delta and reset handling");
        pid_t child = fork();
        if (child == 0) { execl("/bin/sleep", "sleep", "30", NULL); _exit(127); }
        usleep(50000);
        DSResourceSampler *sampler = [[DSResourceSampler alloc] init];
        NSDictionary *snapshot = [sampler sample]; BOOL found = NO;
        for (NSDictionary *process in snapshot[@"processes"]) if ([process[@"pid"] intValue] == child) found = [process[@"available"] boolValue];
        Check(found && snapshot[@"cpuPercent"] == NSNull.null, @"Live descendants and honest first sample");
        usleep(50000); snapshot = [sampler sample];
        Check(snapshot[@"cpuPercent"] != NSNull.null && [snapshot[@"physicalBytes"] unsignedLongLongValue] > 0, @"CPU and physical memory sampled");
        kill(child, SIGTERM); waitpid(child, &status, 0);
        for (NSUInteger i = 0; i < 65; i++) [sampler sample];
        Check(sampler.history.count == 60 && sampler.previous.count <= 128, @"Bounded history and process identity state");
        found = NO; for (NSDictionary *process in sampler.history.lastObject[@"processes"]) if ([process[@"pid"] intValue] == child) found = YES;
        Check(!found, @"Exited child removed without stale CPU or RAM");
        [defaults setVolatileDomain:saved forName:NSArgumentDomain];
        puts("PASS: CLI parsing, targets, consent boundaries, process locks, live descendants and bounded metrics");
    }
    return 0;
}
