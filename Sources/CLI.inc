// Included after DriveSweepController: both frontends call the same engine.
static volatile sig_atomic_t DSCLIInterrupted = 0;
static void DSCLISignal(int signalNumber) { DSCLIInterrupted = signalNumber; }

static NSString *DSCLITerminalText(NSString *text) {
    NSMutableString *safe = [NSMutableString string];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        [safe appendFormat:@"%C", (unichar)(c < 32 || c == 127 ? ' ' : c)];
    }
    return safe;
}

static void DSCLIJSON(id value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    if (data) { fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout); }
}

static int DSCLIError(NSString *message, int code, BOOL json) {
    if (DSCLIInterrupted) code = 128 + DSCLIInterrupted;
    if (json) DSCLIJSON(@{ @"success": @NO, @"exitCode": @(code), @"error": message });
    else fprintf(stderr, "drivesweep: %s\n", DSCLITerminalText(message).UTF8String);
    return code;
}

@interface DSCLIController : DriveSweepController
@property BOOL terminalProgress;
@end
@implementation DSCLIController
- (void)rebuildMenu { }
- (void)showDashboard:(id)sender { }
- (void)refreshDashboard { }
- (void)refreshPreferenceControls { }
- (void)notify:(NSString *)message { fprintf(stderr, "%s\n", DSCLITerminalText(message).UTF8String); }
- (void)updateOperationUI:(DSOperationState *)operation {
    if (self.terminalProgress && operation == self.activeOperation) {
        fprintf(stderr, "\r\033[2K%s", DSCLITerminalText([self operationStatusText:operation]).UTF8String);
        fflush(stderr);
    }
}
@end

static const char *DSCLIHelp =
"DriveSweep 3.1 — app e CLI, stesso motore e stesse preferenze\n"
"Uso: drivesweep COMANDO [ARGOMENTI] [--json]\n\n"
"  list                          Dischi esterni fisici scrivibili e regole UUID\n"
"  analyze VOLUME | --all         Analisi di sola lettura, Ctrl-C per annullare\n"
"    [--export FILE]              Salva il report JSON senza sovrascrivere\n"
"  clean VOLUME [--eject] [--yes]  Conferma e pulisce; --eject solo dopo successo\n"
"  profiles [set PROFILO]         crossPlatform | macMetadata | custom\n"
"  config show                   Preferenze e categorie selezionate\n"
"  config set CHIAVE VALORE       Booleani, intervallo, whitelist, estensioni\n"
"  config reset [--yes]           Default iniziali; conserva regole per disco\n"
"  rules list                    Consensi persistenti per VolumeUUID\n"
"  rules set VOLUME               --exclude true|false --automatic true|false\n"
"                                --periodic true|false [--yes]\n"
"  rules confirm-custom VOLUME    Analizza e conferma estensioni [--yes]\n"
"  schedule status               Stato e intervallo condivisi con l'app\n"
"  schedule start MINUTI          Configura 1..10080 minuti; nessuna pulizia subito\n"
"  schedule stop                 Ferma timer e pulizie periodiche autorizzate\n"
"  schedule run                  Un passaggio sui dischi autorizzati, se attiva\n"
"  daemon                        Montaggi e pianificazione in primo piano\n"
"  resources [--watch]            CPU, RAM fisica/RSS, I/O, PID e thread live\n"
"    [--interval SECONDI]         Da 0.25 a 10 (default 1)\n"
"    [--samples NUMERO]           Limite campioni (1..3600), utile per script\n"
"  --version | --help\n\n"
"VOLUME deve essere la radice esatta del mount, es. /Volumes/USB.\n"
"App e daemon condividono un solo runner automatico; la pulizia ha un lock\n"
"tra processi. Senza l'app aperta, lascia daemon attivo per l'automazione.\n"
"Pulizia = rimozione definitiva, non svuotamento recuperabile. --yes è una\n"
"conferma esplicita; senza TTY è obbligatorio per le azioni che la richiedono.\n"
"Exit: 0 successo, 1 errore, 2 uso, 3 target non idoneo, 4 occupato, 130 Ctrl-C.\n";

static BOOL DSCLIConfirm(NSString *message, BOOL yes) {
    if (yes) return YES;
    if (!isatty(STDIN_FILENO)) return NO;
    fprintf(stderr, "%s\nScrivi PULISCI per confermare: ", DSCLITerminalText(message).UTF8String);
    char buffer[64] = {0};
    if (!fgets(buffer, sizeof(buffer), stdin)) return NO;
    return [[[[NSString stringWithUTF8String:buffer] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString] isEqual:@"PULISCI"];
}

static NSNumber *DSCLIBoolean(NSString *text) {
    if ([@[@"true", @"yes", @"1"] containsObject:text.lowercaseString]) return @YES;
    if ([@[@"false", @"no", @"0"] containsObject:text.lowercaseString]) return @NO;
    return nil;
}

static NSDictionary *DSCLIParse(NSArray<NSString *> *arguments, NSString **error) {
    NSMutableArray *positionals = [NSMutableArray array];
    NSMutableDictionary *flags = [NSMutableDictionary dictionary];
    NSSet *switches = [NSSet setWithArray:@[@"json", @"yes", @"all", @"eject", @"watch"]];
    NSSet *values = [NSSet setWithArray:@[@"export", @"interval", @"samples", @"exclude", @"automatic", @"periodic"]];
    for (NSUInteger i = 0; i < arguments.count; i++) {
        NSString *argument = arguments[i];
        if ([argument hasPrefix:@"--"]) {
            NSString *key = [argument substringFromIndex:2];
            if (flags[key] || (![switches containsObject:key] && ![values containsObject:key])) {
                if (error) *error = [NSString stringWithFormat:@"Opzione sconosciuta o duplicata: %@", argument]; return nil;
            }
            if ([switches containsObject:key]) flags[key] = @YES;
            else {
                if (++i >= arguments.count || [arguments[i] hasPrefix:@"--"]) { if (error) *error = [@"Valore mancante: " stringByAppendingString:argument]; return nil; }
                flags[key] = arguments[i];
            }
        } else [positionals addObject:argument];
    }
    NSString *command = positionals.firstObject ?: @"";
    NSDictionary *allowed = @{
        @"list": @[@"json"], @"analyze": @[@"json", @"all", @"export"],
        @"clean": @[@"json", @"yes", @"eject"], @"profiles": @[@"json"],
        @"config": @[@"json", @"yes"], @"rules": @[@"json", @"yes", @"exclude", @"automatic", @"periodic"],
        @"schedule": @[@"json"], @"daemon": @[@"json"],
        @"resources": @[@"json", @"watch", @"interval", @"samples"]
    };
    if (!allowed[command]) { if (error) *error = @"Comando sconosciuto. Usa drivesweep --help."; return nil; }
    for (NSString *key in flags) if (![allowed[command] containsObject:key]) { if (error) *error = [NSString stringWithFormat:@"--%@ non è valido per %@", key, command]; return nil; }
    return @{ @"arguments": positionals, @"flags": flags };
}

static void DSCLIChangedPreferences(void) {
    DSBroadcastPreferences();
}

static NSArray<NSDictionary *> *DSCLIVolumes(DSCLIController *controller) {
    NSMutableArray *items = [NSMutableArray array];
    NSMutableDictionary *identities = [NSMutableDictionary dictionary];
    NSArray *volumes = [controller externalVolumes];
    for (NSURL *url in volumes) {
        NSString *identity = [controller mountIdentityForVolume:url];
        if (identity.length) identities[url.path] = identity;
        NSDictionary *values = [url resourceValuesForKeys:@[NSURLVolumeTotalCapacityKey, NSURLVolumeAvailableCapacityKey, NSURLVolumeLocalizedFormatDescriptionKey] error:nil];
        [items addObject:@{ @"name": url.lastPathComponent, @"path": url.path, @"uuid": identity ?: NSNull.null,
            @"excluded": @([controller isVolumeExcludedForIdentity:identity]), @"automatic": @([controller allowsAutomaticCleaningForIdentity:identity]),
            @"periodic": @([controller allowsPeriodicCleaningForIdentity:identity]),
            @"totalBytes": values[NSURLVolumeTotalCapacityKey] ?: NSNull.null, @"availableBytes": values[NSURLVolumeAvailableCapacityKey] ?: NSNull.null,
            @"format": values[NSURLVolumeLocalizedFormatDescriptionKey] ?: NSNull.null }];
    }
    controller.eligibleVolumes = volumes;
    controller.eligibleVolumeIdentities = identities;
    return items;
}

static DSVolumeTarget *DSCLITarget(DSCLIController *controller, NSString *path) {
    if (![path hasPrefix:@"/"]) return nil;
    NSString *standard = path.stringByStandardizingPath;
    for (NSURL *url in controller.eligibleVolumes) {
        NSString *identity = controller.eligibleVolumeIdentities[url.path];
        if ([url.path isEqual:standard] && identity.length) return [[DSVolumeTarget alloc] initWithVolumeURL:url mountIdentity:identity];
    }
    return nil;
}

static NSDictionary *DSCLIRunOperation(DSCLIController *controller, DSVolumeTarget *target, BOOL clean, BOOL periodic) {
    NSDictionary *options = [controller cleanupOptionsSnapshot];
    DSOperationState *operation = [controller beginOperationKind:clean ? DSOperationKindCleanup : DSOperationKindPreview volume:target.volumeURL identity:target.mountIdentity options:options];
    if (!operation) return @{ @"success": @NO, @"errors": @[@"Un'operazione è già in corso."] };
    operation.automaticCleanup = periodic;
    operation.periodicCleanup = periodic;
    [controller startResourceMonitorForOperation:operation];
    __block NSDictionary *result = nil;
    __block BOOL done = NO;
    dispatch_async(controller.cleanupQueue, ^{
        NSDictionary *report = clean
            ? [controller cleanVolumeOnWorker:target.volumeURL expectedMountIdentity:target.mountIdentity options:options operation:operation]
            : [controller previewInSubprocess:target.volumeURL identity:target.mountIdentity options:options operation:operation];
        dispatch_async(dispatch_get_main_queue(), ^{ result = report; done = YES; });
    });
    while (!done) {
        if (DSCLIInterrupted) { @synchronized (operation) { operation.cancellationRequested = YES; } }
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    if (DSCLIInterrupted || [controller operationShouldStop:operation]) {
        NSMutableDictionary *cancelled = [result mutableCopy];
        cancelled[@"success"] = @NO; cancelled[@"cancelled"] = @YES; result = cancelled;
    }
    [controller stopResourceMonitorForOperation:operation];
    controller.activeOperation = nil;
    if (controller.terminalProgress) fputc('\n', stderr);
    return result;
}

static void DSCLIPrintResources(NSDictionary *snapshot, BOOL json, BOOL redraw) {
    if (json) { DSCLIJSON(snapshot); return; }
    if (redraw && isatty(STDOUT_FILENO)) fputs("\033[H\033[2J", stdout);
    id cpu = snapshot[@"cpuPercent"];
    double cpuValue = cpu == NSNull.null ? 0 : [cpu doubleValue];
    NSUInteger cores = MAX(1, [snapshot[@"logicalCPUs"] unsignedIntegerValue]);
    double memory = [snapshot[@"physicalBytes"] doubleValue] / (1024 * 1024);
    NSMutableString *cpuBar = [NSMutableString string], *memoryBar = [NSMutableString string];
    for (NSUInteger i = 0; i < 20; i++) {
        [cpuBar appendString:i < (NSUInteger)MIN(20, cpuValue / (100 * cores) * 20) ? @"|" : @"."];
        [memoryBar appendString:i < (NSUInteger)MIN(20, memory / 750 * 20) ? @"|" : @"."];
    }
    printf("DriveSweep · risorse live · %lu processi\nCPU [%s] %s (100%% = 1 core, scala %lu core)\nRAM [%s] %.1f MiB · picco %.1f MiB · scala 750 MiB\n", (unsigned long)[snapshot[@"processes"] count], cpuBar.UTF8String,
        (cpu == NSNull.null ? @"in campionamento" : [NSString stringWithFormat:@"%.1f%%", cpuValue]).UTF8String, (unsigned long)cores,
        memoryBar.UTF8String, memory, [snapshot[@"peakPhysicalBytes"] doubleValue] / (1024 * 1024));
    printf("%-8s %-20s %9s %12s %12s\n", "PID", "Processo", "CPU/core", "RAM MiB", "Thread");
    for (NSDictionary *process in snapshot[@"processes"]) {
        NSString *percent = ![process[@"available"] boolValue] || process[@"cpuPercent"] == NSNull.null ? @"—" : [NSString stringWithFormat:@"%.1f%%", [process[@"cpuPercent"] doubleValue]];
        NSString *ram = [process[@"available"] boolValue] ? [NSString stringWithFormat:@"%.1f", [process[@"physicalBytes"] doubleValue] / (1024 * 1024)] : @"non disp.";
        printf("%-8d %-20s %9s %12s %12s\n", [process[@"pid"] intValue], DSCLITerminalText(process[@"name"]).UTF8String, percent.UTF8String, ram.UTF8String, process[@"threads"] ? [process[@"threads"] description].UTF8String : "—");
    }
    printf("I/O: lettura %s B/s · scrittura %s B/s; dati non disponibili: %lu\n", (snapshot[@"readBytesPerSecond"] == NSNull.null ? @"—" : [snapshot[@"readBytesPerSecond"] description]).UTF8String, (snapshot[@"writeBytesPerSecond"] == NSNull.null ? @"—" : [snapshot[@"writeBytesPerSecond"] description]).UTF8String, (unsigned long)[snapshot[@"unavailable"] unsignedIntegerValue]);
    fflush(stdout);
}

static BOOL DSCLINumber(NSString *text, double minimum, double maximum, BOOL integer, double *value) {
    NSScanner *scanner = [NSScanner scannerWithString:text];
    double number = 0;
    if (![scanner scanDouble:&number] || !scanner.isAtEnd || !isfinite(number) || number < minimum || number > maximum || (integer && floor(number) != number)) return NO;
    if (value) *value = number;
    return YES;
}

static id DSCLIConfigValue(DSCLIController *controller, NSString *key, NSString *text) {
    if ([DSCleanupPreferenceKeys() containsObject:key] || [@[DSAutomaticCleaning, DSPeriodicCleaning] containsObject:key]) return DSCLIBoolean(text);
    if ([key isEqual:DSPeriodicCleaningInterval]) {
        double value;
        return DSCLINumber(text, 1, 10080, YES, &value) ? @((NSInteger)value) : nil;
    }
    if ([key isEqual:DSCleanupProfile]) return [@[DSProfileCrossPlatform, DSProfileMacMetadata, DSProfileCustom] containsObject:text] ? text : nil;
    if ([key isEqual:DSAppleDoubleExtensions]) return [[[[controller protectedAppleDoubleExtensionsFromValue:text] allObjects] sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","];
    if ([key isEqual:DSCustomFileExtensions]) {
        NSArray *normalized = [[[controller normalizedCustomFileExtensionsFromValue:text] allObjects] sortedArrayUsingSelector:@selector(compare:)];
        // Reject partially accepted lists: a typo must not silently change the deletion scope.
        NSMutableArray *requested = [NSMutableArray array];
        for (NSString *part in [text componentsSeparatedByString:@","]) {
            NSString *extension = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
            if ([extension hasPrefix:@"."]) extension = [extension substringFromIndex:1];
            if (extension.length && ![requested containsObject:extension]) [requested addObject:extension];
        }
        return [NSSet setWithArray:normalized].count == [NSSet setWithArray:requested].count ? normalized : nil;
    }
    if ([key isEqual:DSExcludedVolumes]) return text;
    return nil;
}

static NSDictionary *DSCLIConfiguration(DSCLIController *controller) {
    NSMutableDictionary *config = [NSMutableDictionary dictionary];
    for (NSString *key in DSDefaultPreferences()) {
        id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
        if (value) config[key] = value;
    }
    config[DSPeriodicCleaningInterval] = @([controller periodicCleanupIntervalMinutes]);
    return config;
}

static void DSCLIOutput(id result, BOOL json) {
    if (json) DSCLIJSON(result);
    else {
        NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
        if (data) { fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); }
    }
}

static DSCLIController *DSCLIMakeController(void) {
    DSCLIController *controller = [[DSCLIController alloc] init];
    controller.cleanupQueue = dispatch_queue_create("com.drivesweep.cli.cleanup", DISPATCH_QUEUE_SERIAL);
    controller.discoveryQueue = dispatch_queue_create("com.drivesweep.cli.discovery", DISPATCH_QUEUE_SERIAL);
    controller.eligibleVolumes = @[];
    controller.eligibleVolumeIdentities = @{};
    controller.handledMountIdentities = [NSMutableSet set];
    controller.scheduledCleanupPaths = [NSMutableSet set];
    controller.previewRecords = [NSMutableDictionary dictionary];
    controller.recentActivity = [NSMutableArray array];
    controller.lastCustomAnalysisFingerprints = [NSMutableDictionary dictionary];
    controller.liveSampler = [[DSResourceSampler alloc] init];
    controller.terminalProgress = isatty(STDERR_FILENO);
    return controller;
}

static int DSRunCLI(NSArray<NSString *> *arguments) {
    if (!arguments.count || [arguments isEqual:@[@"--help"]] || [arguments isEqual:@[@"help"]]) { fputs(DSCLIHelp, stdout); return 0; }
    if ([arguments isEqual:@[@"--version"]]) {
        printf("DriveSweep %s\n", [[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"3.1.0" UTF8String]); return 0;
    }
    NSString *error = nil;
    NSDictionary *parsed = DSCLIParse(arguments, &error);
    BOOL json = [arguments containsObject:@"--json"];
    if (!parsed) return DSCLIError(error, 2, json);
    NSArray *args = parsed[@"arguments"];
    NSDictionary *flags = parsed[@"flags"];
    NSString *command = args.firstObject;
    BOOL yes = [flags[@"yes"] boolValue];
    DSCLIController *controller = DSCLIMakeController();
    controller.terminalProgress = controller.terminalProgress && !json;
    DSCLIInterrupted = 0;
    struct sigaction action = {0}; action.sa_handler = DSCLISignal; sigemptyset(&action.sa_mask);
    sigaction(SIGINT, &action, NULL); sigaction(SIGTERM, &action, NULL);
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([command isEqual:@"resources"]) {
        double interval = 1, samples = flags[@"watch"] ? 0 : 2;
        if (args.count != 1 || (flags[@"interval"] && !DSCLINumber(flags[@"interval"], .25, 10, NO, &interval)) ||
            (flags[@"samples"] && !DSCLINumber(flags[@"samples"], 1, 3600, YES, &samples))) return DSCLIError(@"Intervallo 0.25..10; campioni interi 1..3600.", 2, json);
        NSUInteger count = 0;
        do {
            @autoreleasepool { DSCLIPrintResources([controller.liveSampler sample], json, flags[@"watch"] != nil); }
            if (++count >= samples && samples > 0) break;
            NSDate *until = [NSDate dateWithTimeIntervalSinceNow:interval];
            while (!DSCLIInterrupted && until.timeIntervalSinceNow > 0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:MIN(.05, MAX(0, until.timeIntervalSinceNow))]];
        } while (!DSCLIInterrupted);
        return DSCLIInterrupted ? 128 + DSCLIInterrupted : 0;
    }
    if ([command isEqual:@"profiles"]) {
        if (args.count == 1) { DSCLIOutput(@{ @"profiles": @[DSProfileCrossPlatform, DSProfileMacMetadata, DSProfileCustom], @"current": [defaults objectForKey:DSCleanupProfile] }, json); return 0; }
        if (args.count != 3 || ![args[1] isEqual:@"set"] || ![@[DSProfileCrossPlatform, DSProfileMacMetadata, DSProfileCustom] containsObject:args[2]]) return DSCLIError(@"Usa profiles set crossPlatform|macMetadata|custom.", 2, json);
        [controller applyCleanupProfile:args[2]]; DSCLIChangedPreferences(); DSCLIOutput(DSCLIConfiguration(controller), json); return 0;
    }
    if ([command isEqual:@"config"]) {
        if (args.count == 2 && [args[1] isEqual:@"show"] && !yes) { DSCLIOutput(DSCLIConfiguration(controller), json); return 0; }
        if (args.count == 2 && [args[1] isEqual:@"reset"]) {
            if (!DSCLIConfirm(@"Ripristinare i default? I consensi e le esclusioni per UUID restano salvati.", yes)) return DSCLIError(@"Conferma richiesta (TTY oppure --yes).", 2, json);
            [controller resetSafeDefaults:nil]; DSCLIChangedPreferences(); DSCLIOutput(DSCLIConfiguration(controller), json); return 0;
        }
        if (args.count != 4 || ![args[1] isEqual:@"set"]) return DSCLIError(@"Usa config show, set CHIAVE VALORE oppure reset.", 2, json);
        NSString *key = args[2]; id value = DSCLIConfigValue(controller, key, args[3]);
        if (!value) return DSCLIError(@"Chiave o valore non valido. Leggi config show e docs/CLI.md.", 2, json);
        if ([key isEqual:DSCleanupProfile]) [controller applyCleanupProfile:value];
        else {
            [defaults setObject:value forKey:key];
            if ([DSCleanupPreferenceKeys() containsObject:key] || [@[DSCustomFileExtensions, DSAppleDoubleExtensions] containsObject:key]) [defaults setObject:DSProfileCustom forKey:DSCleanupProfile];
            if ([key isEqual:DSPeriodicCleaningInterval]) [defaults setObject:DSPeriodicCleaningIntervalUnitMinutes forKey:DSPeriodicCleaningIntervalUnit];
        }
        DSCLIChangedPreferences(); DSCLIOutput(DSCLIConfiguration(controller), json); return 0;
    }
    if ([command isEqual:@"rules"] && args.count == 2 && [args[1] isEqual:@"list"] && flags.count == (json ? 1U : 0U)) {
        DSCLIOutput([controller volumeRules], json); return 0;
    }
    if ([command isEqual:@"schedule"]) {
        if (args.count < 2) return DSCLIError(@"Usa schedule status|start MINUTI|stop|run.", 2, json);
        NSString *action = args[1];
        if ([action isEqual:@"start"]) {
            double minutes;
            if (args.count != 3 || !DSCLINumber(args[2], 1, 10080, YES, &minutes)) return DSCLIError(@"Intervallo intero di 1..10080 minuti.", 2, json);
            [controller configurePeriodicCleanupWithMinutes:(NSInteger)minutes]; DSCLIChangedPreferences();
        } else if ([action isEqual:@"stop"] && args.count == 2) { [controller stopPeriodicCleanup:nil]; DSCLIChangedPreferences(); }
        else if (!([action isEqual:@"status"] && args.count == 2) && !([action isEqual:@"run"] && args.count == 2)) return DSCLIError(@"Comando schedule non valido.", 2, json);
        if (![action isEqual:@"run"]) {
            DSCLIOutput(@{ @"enabled": @([controller periodicCleanupIsEnabled]), @"intervalMinutes": @([controller periodicCleanupIntervalMinutes]), @"runner": @"L'app aperta o drivesweep daemon deve restare attivo; il comando non crea servizi." }, json); return 0;
        }
        if (![controller periodicCleanupIsEnabled]) return DSCLIError(@"La pianificazione è disattivata.", 1, json);
        __attribute__((objc_precise_lifetime)) DSLease *runner = [DSLease acquire:@"automation"];
        if (!runner) return DSCLIError(@"L'app o un daemon gestisce già la pianificazione.", 4, json);
        DSCLIVolumes(controller); NSMutableArray *reports = [NSMutableArray array]; BOOL success = YES;
        for (DSVolumeTarget *target in [controller configuredPeriodicCleanupTargets]) {
            if (DSCLIInterrupted) break;
            NSDictionary *report = DSCLIRunOperation(controller, target, YES, YES);
            [reports addObject:@{ @"volume": target.volumeURL.path, @"report": report }]; success &= [report[@"success"] boolValue];
        }
        DSCLIOutput(@{ @"success": @(success && !DSCLIInterrupted), @"reports": reports }, json);
        return DSCLIInterrupted ? 128 + DSCLIInterrupted : success ? 0 : 1;
    }
    if ([command isEqual:@"daemon"]) {
        if (args.count != 1) return DSCLIError(@"daemon non accetta argomenti.", 2, json);
        controller.requiresAutomationLease = YES;
        controller.automationLease = [DSLease acquire:@"automation"];
        if (!controller.automationLease) return DSCLIError(@"L'app o un altro daemon possiede già il runner automatico.", 4, json);
        NSNotificationCenter *center = NSWorkspace.sharedWorkspace.notificationCenter;
        [center addObserver:controller selector:@selector(volumeMounted:) name:NSWorkspaceDidMountNotification object:nil];
        [center addObserver:controller selector:@selector(volumeUnmounted:) name:NSWorkspaceDidUnmountNotification object:nil];
        [[NSDistributedNotificationCenter defaultCenter] addObserver:controller selector:@selector(sharedPreferencesChanged:) name:@"com.github.naicud.drivesweep.preferences" object:nil];
        controller.scanTimer = [NSTimer scheduledTimerWithTimeInterval:15 target:controller selector:@selector(checkMountedVolumes) userInfo:nil repeats:YES];
        [controller configurePeriodicCleanupTimer]; [controller checkMountedVolumes];
        NSDate *nextSample = NSDate.date;
        while (!DSCLIInterrupted) {
            @autoreleasepool {
                if (nextSample.timeIntervalSinceNow <= 0) {
                    if (json || isatty(STDOUT_FILENO)) DSCLIPrintResources([controller.liveSampler sample], json, YES);
                    nextSample = [NSDate dateWithTimeIntervalSinceNow:1];
                }
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
            }
        }
        @synchronized (controller.activeOperation) { controller.activeOperation.cancellationRequested = YES; }
        while (controller.activeOperation) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
        [controller.scanTimer invalidate]; [controller.periodicCleanupTimer invalidate]; [controller.scheduleCountdownTimer invalidate];
        [center removeObserver:controller]; [[NSDistributedNotificationCenter defaultCenter] removeObserver:controller];
        return 128 + DSCLIInterrupted;
    }
    // Validate arity before discovery; invalid commands cannot start disk access or deletion.
    BOOL valid = ([command isEqual:@"list"] && args.count == 1) ||
        ([command isEqual:@"analyze"] && ((flags[@"all"] && args.count == 1) || (!flags[@"all"] && args.count == 2))) ||
        ([command isEqual:@"clean"] && args.count == 2) ||
        ([command isEqual:@"rules"] && args.count == 3 && ([@"set" isEqual:args[1]] || [@"confirm-custom" isEqual:args[1]]));
    if (!valid) return DSCLIError(@"Argomenti non validi. Usa drivesweep --help.", 2, json);
    NSArray *volumes = DSCLIVolumes(controller);
    if ([command isEqual:@"list"]) { DSCLIOutput(@{ @"volumes": volumes }, json); return DSCLIInterrupted ? 128 + DSCLIInterrupted : 0; }
    NSString *path = [command isEqual:@"rules"] ? args[2] : args.count > 1 ? args[1] : nil;
    DSVolumeTarget *target = path ? DSCLITarget(controller, path) : nil;
    if (DSCLIInterrupted) return DSCLIError(@"Operazione annullata.", 128 + DSCLIInterrupted, json);
    if (path && !target) return DSCLIError(@"Target rifiutato: serve la radice esatta di un disco esterno fisico scrivibile con UUID verificato.", 3, json);
    if ([command isEqual:@"rules"]) {
        if ([args[1] isEqual:@"set"]) {
            NSMutableDictionary *values = [NSMutableDictionary dictionary];
            for (NSString *key in @[@"exclude", @"automatic", @"periodic"]) if (flags[key]) {
                NSNumber *boolean = DSCLIBoolean(flags[key]);
                if (!boolean) return DSCLIError(@"Le regole richiedono true o false.", 2, json); values[key] = boolean;
            }
            if (!values.count || ([values[@"exclude"] boolValue] && ([values[@"automatic"] boolValue] || [values[@"periodic"] boolValue]))) return DSCLIError(@"Specificare almeno una regola coerente.", 2, json);
            if (([values[@"automatic"] boolValue] || [values[@"periodic"] boolValue]) && !DSCLIConfirm(@"Consentire rimozioni automatiche definitive su questo VolumeUUID?", yes)) return DSCLIError(@"Conferma richiesta (TTY oppure --yes).", 2, json);
            BOOL excluded = values[@"exclude"] ? [values[@"exclude"] boolValue] : [controller isVolumeExcludedForIdentity:target.mountIdentity];
            BOOL automatic = values[@"automatic"] ? [values[@"automatic"] boolValue] : [controller allowsAutomaticCleaningForIdentity:target.mountIdentity];
            BOOL periodic = values[@"periodic"] ? [values[@"periodic"] boolValue] : [controller allowsPeriodicCleaningForIdentity:target.mountIdentity];
            if (excluded && ([values[@"automatic"] boolValue] || [values[@"periodic"] boolValue])) return DSCLIError(@"Rimuovere prima l'esclusione del disco.", 2, json);
            [controller setVolumeRuleForIdentity:target.mountIdentity name:target.volumeURL.lastPathComponent excluded:excluded allowAutomatic:automatic];
            [controller setPeriodicCleaning:periodic forIdentity:target.mountIdentity name:target.volumeURL.lastPathComponent];
        } else {
            if (flags[@"exclude"] || flags[@"automatic"] || flags[@"periodic"]) return DSCLIError(@"confirm-custom accetta soltanto --yes e --json.", 2, json);
            NSDictionary *options = [controller cleanupOptionsSnapshot];
            if (![options[DSCustomFiles] boolValue] || ![options[DSCustomFileExtensions] count]) return DSCLIError(@"Abilitare customFiles e una lista customFileExtensions valida.", 2, json);
            if ([controller isVolumeExcludedForIdentity:target.mountIdentity]) return DSCLIError(@"Disco escluso.", 3, json);
            NSDictionary *report = DSCLIRunOperation(controller, target, NO, NO);
            if (DSCLIInterrupted) return DSCLIError(@"Analisi annullata: nessun consenso salvato.", 128 + DSCLIInterrupted, json);
            if (![report[@"success"] boolValue] || ![controller volume:target.volumeURL matchesExpectedMountIdentity:target.mountIdentity]) return DSCLIError(@"Analisi non completa o UUID cambiato: consenso negato.", 1, json);
            DSCLIOutput(report, json);
            if (!DSCLIConfirm([NSString stringWithFormat:@"Confermare le estensioni %@ per le pulizie automatiche di %@?", [options[DSCustomFileExtensions] allObjects], target.volumeURL.lastPathComponent], yes)) return DSCLIError(@"Conferma richiesta (TTY oppure --yes).", 2, json);
            [controller recordCustomExtensionAnalysisForIdentity:target.mountIdentity options:options];
            if (![controller confirmCurrentCustomExtensionsForIdentity:target.mountIdentity name:target.volumeURL.lastPathComponent]) return DSCLIError(@"Le opzioni sono cambiate: ripetere l'analisi.", 1, json);
        }
        DSCLIChangedPreferences(); DSCLIOutput([controller volumeRuleForIdentity:target.mountIdentity], json); return 0;
    }
    if ([command isEqual:@"clean"]) {
        if ([controller isVolumeExcludedForIdentity:target.mountIdentity]) return DSCLIError(@"Disco escluso.", 3, json);
        if (DSCLIInterrupted) return DSCLIError(@"Operazione annullata.", 128 + DSCLIInterrupted, json);
        NSDictionary *options = [controller cleanupOptionsSnapshot];
        NSMutableArray *labels = [NSMutableArray array];
        for (NSString *key in DSCleanupPreferenceKeys()) if ([controller cleanupOption:key isEnabledInOptions:options]) [labels addObject:DSCleanupReportLabel(key)];
        if (!labels.count) return DSCLIError(@"Nessuna categoria selezionata.", 2, json);
        NSString *categories = [labels componentsJoinedByString:@", "];
        if (!DSCLIConfirm([NSString stringWithFormat:@"Pulire definitivamente %@? Categorie: %@", target.volumeURL.path, categories], yes)) return DSCLIError(@"Conferma richiesta (TTY oppure --yes).", 2, json);
        NSDictionary *report = DSCLIRunOperation(controller, target, YES, NO);
        if ([report[@"success"] boolValue] && flags[@"eject"] && !DSCLIInterrupted) {
            NSError *ejectError = nil;
            if (![controller ejectVerifiedVolumeTarget:target error:&ejectError]) {
                NSMutableDictionary *failed = [report mutableCopy]; failed[@"success"] = @NO;
                failed[@"ejectionError"] = ejectError.localizedDescription; report = failed;
            }
        }
        DSCLIOutput(report, json); return DSCLIInterrupted ? 128 + DSCLIInterrupted : [report[@"busy"] boolValue] ? 4 : [report[@"success"] boolValue] ? 0 : 1;
    }
    NSMutableArray *reports = [NSMutableArray array]; BOOL success = YES;
    NSArray *targets;
    if (target) targets = @[target];
    else {
        NSMutableArray *all = [NSMutableArray array];
        for (NSURL *url in controller.eligibleVolumes) {
            DSVolumeTarget *item = DSCLITarget(controller, url.path);
            if (item && ![controller isVolumeExcludedForIdentity:item.mountIdentity]) [all addObject:item];
        }
        targets = all;
    }
    for (DSVolumeTarget *item in targets) {
        if (DSCLIInterrupted) break;
        if ([controller isVolumeExcludedForIdentity:item.mountIdentity]) return DSCLIError(@"Disco escluso.", 3, json);
        NSDictionary *report = DSCLIRunOperation(controller, item, NO, NO);
        [reports addObject:@{ @"volume": item.volumeURL.path, @"uuid": item.mountIdentity, @"report": report }];
        success &= [report[@"success"] boolValue];
    }
    NSDictionary *output = @{ @"success": @(success && !DSCLIInterrupted), @"reports": reports, @"byteMeaning": @"Somma logica dei soli file candidati; non spazio recuperabile garantito." };
    if (flags[@"export"]) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:output options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
        NSError *writeError = nil;
        if (!data || ![data writeToFile:[flags[@"export"] stringByExpandingTildeInPath] options:NSDataWritingWithoutOverwriting error:&writeError]) return DSCLIError(writeError.localizedDescription ?: @"Report non serializzabile.", 1, json);
    }
    DSCLIOutput(output, json); return DSCLIInterrupted ? 128 + DSCLIInterrupted : success ? 0 : 1;
}
