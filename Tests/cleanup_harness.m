#define main DriveSweepApplicationMain
#import "../Sources/main.m"
#undef main

@interface TestDriveSweepController : DriveSweepController
@end

@implementation TestDriveSweepController

- (BOOL)isEligibleExternalVolume:(NSURL *)url error:(NSError **)error {
    return YES;
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

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSDictionary<NSString *, id> *registeredDefaults = DSDefaultPreferences();
        if (![registeredDefaults[DSAppleDouble] boolValue] ||
            [registeredDefaults[DSAutomaticCleaning] boolValue]) return 1;
        [defaults setBool:YES forKey:DSAppleDouble];
        [defaults setBool:YES forKey:DSDSStore];
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

        TestDriveSweepController *controller = [[TestDriveSweepController alloc] init];
        NSDictionary<NSString *, id> *result = [controller cleanVolumeOnWorker:[NSURL fileURLWithPath:root]];
        BOOL cleaned = [result[@"success"] boolValue] &&
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
        [manager removeItemAtPath:root error:nil];
        return cleaned ? 0 : 1;
    }
}
