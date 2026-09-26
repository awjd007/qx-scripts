#import "LKLog.h"
#import <os/log.h>
#import <os/lock.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <sys/stat.h>
#import <sys/time.h>      // gettimeofday
#import <time.h>          // localtime_r / time_t

static NSString *gLogPath = nil;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static const unsigned long long kMaxBytes = 512 * 1024;   // 超限即轮转，防爆盘

// 候选路径：按顺序尝试，取第一个可写
static NSArray<NSString *> *LKCandidatePaths(void) {
    NSMutableArray *a = [NSMutableArray array];
    NSString *home = NSHomeDirectory();
    if (home.length) {
        [a addObject:[home stringByAppendingPathComponent:@"Documents/lk_tweak.log"]];
        [a addObject:[home stringByAppendingPathComponent:@"Library/Caches/lk_tweak.log"]];
        [a addObject:[home stringByAppendingPathComponent:@"lk_tweak.log"]];
    }
    [a addObject:@"/var/mobile/Documents/lk_tweak.log"];
    [a addObject:@"/var/tmp/lk_tweak.log"];
    [a addObject:[NSTemporaryDirectory() stringByAppendingPathComponent:@"lk_tweak.log"]];
    return a;
}

static BOOL LKEnsureLogPath(void) {
    if (gLogPath) return YES;
    for (NSString *p in LKCandidatePaths()) {
        NSString *dir = [p stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil error:nil];
        if (![[NSFileManager defaultManager] fileExistsAtPath:p]) {
            [[NSFileManager defaultManager] createFileAtPath:p contents:nil attributes:nil];
        }
        if ([[NSFileManager defaultManager] isWritableFileAtPath:p]) {
            gLogPath = p;
            return YES;
        }
    }
    return NO;
}

NSString *LKLogPath(void) {
    os_unfair_lock_lock(&gLock);
    LKEnsureLogPath();
    NSString *p = gLogPath;
    os_unfair_lock_unlock(&gLock);
    return p;
}

static void LKWriteFile(NSString *line) {
    if (!LKEnsureLogPath()) return;
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
    if (!fh) return;
    @try {
        // 简单轮转
        unsigned long long sz = [fh seekToEndOfFile];
        if (sz > kMaxBytes) {
            [fh closeFile];
            [[NSFileManager defaultManager] removeItemAtPath:gLogPath error:nil];
            [[NSFileManager defaultManager] createFileAtPath:gLogPath contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
            if (!fh) return;
            [fh seekToEndOfFile];
        }
        NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
        [fh writeData:d];
        [fh synchronizeFile];        // 键盘扩展进程可能随时被杀，必须立刻落盘
        [fh closeFile];
    } @catch (NSException *e) { }
}

void LKLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    // 时间戳必须用纯 C 构造，不能用 [NSDate date] / NSDateFormatter。
    // 原因：LKLog 会被 NSUserDefaults 的 hook 调用（fakeUserManager → memberID …），
    // 而 NSDate 的 description 会走 ICU 日期格式化，ICU 内部又访问 locale/UserDefaults，
    // 形成重入并直接崩溃（实测崩溃栈：
    //   LKLog → NSString stringWithFormat → NSDate descriptionWithLocale
    //        → CFDateFormatterCreateStringWithAbsoluteTime → libicucore）。
    struct timeval tv;
    gettimeofday(&tv, NULL);
    time_t sec = tv.tv_sec;
    struct tm tmv;
    localtime_r(&sec, &tmv);
    char tsbuf[32];
    snprintf(tsbuf, sizeof(tsbuf), "%02d:%02d:%02d.%03d",
             tmv.tm_hour, tmv.tm_min, tmv.tm_sec, (int)(tv.tv_usec / 1000));

    // 进程名同样可能触发 Foundation 内部逻辑，失败时退化为 pid
    const char *proc = "?";
    @try {
        NSString *pn = [[NSProcessInfo processInfo] processName];
        if (pn.length) proc = pn.UTF8String ?: "?";
    } @catch (NSException *e) { proc = "?"; }

    NSString *line = [NSString stringWithFormat:@"[LK %s][%s pid=%d] %@\n",
                      tsbuf, proc, getpid(), msg];

    // 通道 1：syslog（public 格式，避免被隐私脱敏成 <private>）
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "%{public}s", line.UTF8String);

    // 通道 2：文件
    os_unfair_lock_lock(&gLock);
    LKWriteFile(line);
    os_unfair_lock_unlock(&gLock);
}

void LKLogEnvironment(void) {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    // 版本标识：用于确认设备上实际运行的是哪一份 dylib。
    // 每次交付新版本必须同步修改，否则无法从日志判断产物是否更新。
    LKLog(@"=== LovekeyTweak 启动 (build=%s) ===", LK_TWEAK_BUILD);
    LKLog(@"tweakBuild = %s", LK_TWEAK_BUILD);
    LKLog(@"bundleID   = %@", [[NSBundle mainBundle] bundleIdentifier]);
    LKLog(@"appVer     = %@ (%@)", info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"]);
    LKLog(@"process    = %@", [[NSProcessInfo processInfo] processName]);
    LKLog(@"pid        = %d", getpid());
    LKLog(@"homeDir    = %@", NSHomeDirectory());
    LKLog(@"OS version = %@", [[NSProcessInfo processInfo] operatingSystemVersionString]);
    LKLog(@"logFile    = %@", LKLogPath() ?: @"(无可用路径)");

    // 探测关键类是否存在，确认 NSURLProtocol 方案可行
    Class cfg = objc_getClass("NSURLSessionConfiguration");
    Class alp = objc_getClass("Alamofire");
    Class st  = objc_getClass("URLSessionTask");
    LKLog(@"class NSURLSessionConfiguration = %@", cfg ? @"存在" : @"缺失");
    LKLog(@"class Alamofire                = %@", alp ? @"存在" : @"未找到(可能被混淆)");
    LKLog(@"class URLSessionTask           = %@", st ? @"存在" : @"缺失");

    // 沙盒探测
    NSString *probe = [NSTemporaryDirectory() stringByAppendingPathComponent:@"lk_probe"];
    BOOL ok = [[NSData data] writeToFile:probe atomically:YES];
    LKLog(@"tmp 可写 = %@", ok ? @"是" : @"否");
}
