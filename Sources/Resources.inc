// Shared by the native dashboard and CLI; libproc does not spawn monitoring tools.
#import <libproc.h>
#import <sys/proc_info.h>
#import <sys/file.h>
#import <fcntl.h>

@interface DSLease : NSObject
@property int descriptor;
+ (instancetype)acquire:(NSString *)name;
@end
@implementation DSLease
- (instancetype)init { if ((self = [super init])) _descriptor = -1; return self; }
+ (instancetype)acquire:(NSString *)name {
    NSString *path = [NSString stringWithFormat:@"/private/tmp/drivesweep-%u-%@.lock", getuid(), name];
    int fd = open(path.fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return nil;
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_uid != getuid() || info.st_nlink != 1 || flock(fd, LOCK_EX | LOCK_NB) != 0) {
        close(fd); return nil;
    }
    DSLease *lease = [[self alloc] init];
    lease.descriptor = fd;
    return lease;
}
- (void)dealloc { if (_descriptor >= 0) close(_descriptor); }
@end

static double DSCPUPercent(uint64_t current, uint64_t previous, double elapsed) {
    return elapsed > 0 && current >= previous ? (current - previous) / 1e9 / elapsed * 100.0 : 0;
}

@interface DSResourceSampler : NSObject
@property (strong) NSDictionary<NSString *, NSDictionary *> *previous;
@property (strong) NSMutableArray<NSDictionary *> *history;
@property uint64_t peakMemory;
@property BOOL includePeers;
- (NSDictionary *)sample;
@end
@implementation DSResourceSampler
- (instancetype)init {
    if ((self = [super init])) { _previous = @{}; _history = [NSMutableArray array]; _includePeers = YES; }
    return self;
}
- (NSDictionary *)sample {
    double now = NSProcessInfo.processInfo.systemUptime;
    BOOL truncated = NO;
    NSMutableOrderedSet<NSNumber *> *pids = [NSMutableOrderedSet orderedSetWithObject:@(getpid())];
    // Include other app/CLI instances from this user's DriveSweep bundles.
    int capacity = proc_listallpids(NULL, 0) + 64;
    if (self.includePeers && capacity > 0 && capacity < 65536) {
        pid_t *all = calloc((size_t)capacity, sizeof(pid_t));
        if (all) {
            int count = MIN(proc_listallpids(all, capacity * (int)sizeof(pid_t)), capacity);
            for (int i = 0; i < count; i++) {
                char name[64] = {0}, path[PROC_PIDPATHINFO_MAXSIZE] = {0};
                if (proc_name(all[i], name, sizeof(name)) <= 0 || strcmp(name, "DriveSweep") != 0) continue;
                struct proc_bsdinfo info;
                if (proc_pidinfo(all[i], PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) || info.pbi_uid != getuid()) continue;
                if (proc_pidpath(all[i], path, sizeof(path)) > 0 && [[NSString stringWithUTF8String:path] hasSuffix:@"/DriveSweep.app/Contents/MacOS/DriveSweep"]) {
                    if (pids.count < 128) [pids addObject:@(all[i])]; else truncated = YES;
                }
            }
            free(all);
        }
    }
    // At most 128 processes, with no duplicated children in the aggregate.
    for (NSUInteger i = 0; i < pids.count && pids.count < 128; i++) {
        pid_t children[128] = {0};
        int count = MIN(proc_listchildpids([pids[i] intValue], children, sizeof(children)), 128);
        for (int j = 0; j < count && pids.count < 128; j++) if (children[j] > 0) [pids addObject:@(children[j])];
        if (pids.count >= 128) truncated = YES;
    }
    NSMutableDictionary *next = [NSMutableDictionary dictionary];
    NSMutableArray *processes = [NSMutableArray array];
    uint64_t memory = 0, resident = 0, readRate = 0, writeRate = 0;
    double cpu = 0;
    NSUInteger unavailable = 0, cpuSamples = 0;
    for (NSNumber *number in pids) {
      @autoreleasepool {
        pid_t pid = number.intValue;
        struct rusage_info_v4 usage = {0};
        char name[128] = {0};
        proc_name(pid, name, sizeof(name));
        NSString *label = name[0] ? [NSString stringWithUTF8String:name] : @"Processo";
        if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0) {
            unavailable++;
            [processes addObject:@{ @"pid": number, @"name": label, @"available": @NO }];
            continue;
        }
        NSString *key = [NSString stringWithFormat:@"%d:%llu", pid, usage.ri_proc_start_abstime];
        NSDictionary *prior = self.previous[key];
        uint64_t cpuTime = usage.ri_user_time + usage.ri_system_time;
        double elapsed = prior ? now - [prior[@"time"] doubleValue] : 0;
        double percent = DSCPUPercent(cpuTime, [prior[@"cpu"] unsignedLongLongValue], elapsed);
        BOOL measuredCPU = prior != nil && elapsed > 0;
        if (measuredCPU) cpuSamples++;
        uint64_t reads = measuredCPU && usage.ri_diskio_bytesread >= [prior[@"read"] unsignedLongLongValue]
            ? (uint64_t)((usage.ri_diskio_bytesread - [prior[@"read"] unsignedLongLongValue]) / elapsed) : 0;
        uint64_t writes = measuredCPU && usage.ri_diskio_byteswritten >= [prior[@"write"] unsignedLongLongValue]
            ? (uint64_t)((usage.ri_diskio_byteswritten - [prior[@"write"] unsignedLongLongValue]) / elapsed) : 0;
        next[key] = @{ @"time": @(now), @"cpu": @(cpuTime), @"read": @(usage.ri_diskio_bytesread), @"write": @(usage.ri_diskio_byteswritten) };
        struct proc_taskinfo task = {0};
        BOOL hasTask = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, sizeof(task)) == sizeof(task);
        [processes addObject:@{ @"pid": number, @"name": label, @"available": @YES,
            @"cpuPercent": measuredCPU ? @(percent) : NSNull.null,
            @"physicalBytes": @(usage.ri_phys_footprint), @"residentBytes": @(usage.ri_resident_size),
            @"readBytesPerSecond": measuredCPU ? @(reads) : NSNull.null,
            @"writeBytesPerSecond": measuredCPU ? @(writes) : NSNull.null,
            @"threads": hasTask ? @(task.pti_threadnum) : NSNull.null }];
        cpu += percent; memory += usage.ri_phys_footprint; resident += usage.ri_resident_size;
        readRate += reads; writeRate += writes;
      }
    }
    self.previous = next.copy;
    self.peakMemory = MAX(self.peakMemory, memory);
    NSDictionary *snapshot = @{ @"timestamp": @(NSDate.date.timeIntervalSince1970), @"processes": processes,
        @"cpuPercent": cpuSamples ? @(cpu) : NSNull.null, @"physicalBytes": @(memory), @"residentBytes": @(resident),
        @"peakPhysicalBytes": @(self.peakMemory), @"readBytesPerSecond": cpuSamples ? @(readRate) : NSNull.null,
        @"writeBytesPerSecond": cpuSamples ? @(writeRate) : NSNull.null, @"unavailable": @(unavailable),
        @"warmingProcesses": @(processes.count - unavailable - cpuSamples), @"truncated": @(truncated),
        @"logicalCPUs": @(NSProcessInfo.processInfo.activeProcessorCount) };
    [self.history addObject:snapshot];
    while (self.history.count > 60) [self.history removeObjectAtIndex:0];
    return snapshot;
}
@end

@interface DSSpeedometer : NSView
@property double fraction;
@property (copy) NSString *value;
@property (copy) NSString *caption;
@end
@implementation DSSpeedometer
- (void)drawRect:(NSRect)dirtyRect {
    CGFloat width = self.bounds.size.width, height = self.bounds.size.height;
    NSPoint center = NSMakePoint(width / 2, height * 0.38);
    CGFloat radius = MIN(width * 0.35, height * 0.52);
    NSBezierPath *track = [NSBezierPath bezierPath];
    [track appendBezierPathWithArcWithCenter:center radius:radius startAngle:210 endAngle:-30 clockwise:YES];
    track.lineWidth = 9;
    track.lineCapStyle = NSLineCapStyleRound;
    [NSColor.quaternaryLabelColor setStroke]; [track stroke];
    double fraction = MAX(0, MIN(1, self.fraction));
    NSBezierPath *arc = [NSBezierPath bezierPath];
    [arc appendBezierPathWithArcWithCenter:center radius:radius startAngle:210 endAngle:210 - fraction * 240 clockwise:YES];
    arc.lineWidth = 9; arc.lineCapStyle = NSLineCapStyleRound;
    NSColor *accent = fraction >= 0.9 ? NSColor.systemOrangeColor : NSColor.controlAccentColor;
    [accent setStroke]; if (fraction > 0) [arc stroke];
    double pointerAngle = (210 - fraction * 240) * M_PI / 180;
    NSBezierPath *pointer = [NSBezierPath bezierPath];
    [pointer moveToPoint:NSMakePoint(center.x + cos(pointerAngle) * (radius - 23), center.y + sin(pointerAngle) * (radius - 23))];
    [pointer lineToPoint:NSMakePoint(center.x + cos(pointerAngle) * (radius - 3), center.y + sin(pointerAngle) * (radius - 3))];
    pointer.lineWidth = 3; pointer.lineCapStyle = NSLineCapStyleRound; [accent setStroke]; [pointer stroke];
    for (NSUInteger i = 0; i <= 8; i++) {
        double angle = (210 - i * 30) * M_PI / 180;
        NSBezierPath *tick = [NSBezierPath bezierPath];
        [tick moveToPoint:NSMakePoint(center.x + cos(angle) * (radius - 12), center.y + sin(angle) * (radius - 12))];
        [tick lineToPoint:NSMakePoint(center.x + cos(angle) * (radius - 18), center.y + sin(angle) * (radius - 18))];
        tick.lineWidth = 1; [NSColor.tertiaryLabelColor setStroke]; [tick stroke];
    }
    NSString *value = self.value ?: @"—";
    NSDictionary *attributes = @{ NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:22 weight:NSFontWeightSemibold], NSForegroundColorAttributeName: NSColor.labelColor };
    NSSize size = [value sizeWithAttributes:attributes];
    [value drawAtPoint:NSMakePoint(center.x - size.width / 2, center.y + 1) withAttributes:attributes];
    NSDictionary *small = @{ NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightMedium], NSForegroundColorAttributeName: NSColor.secondaryLabelColor };
    NSString *caption = self.caption ?: @"";
    NSSize captionSize = [caption sizeWithAttributes:small];
    [caption drawAtPoint:NSMakePoint(center.x - captionSize.width / 2, 3) withAttributes:small];
}
@end
