#import "LKLogin.h"
#import "LKLog.h"
#import <objc/runtime.h>

// 需要伪造/拦截的登录态键
static NSString *const kKeyShareAccount = @"com.kb.shareaccount";
static NSString *const kKeyUserToken    = @"com.kb.usertoken";
static NSString *const kKeyIsGuest      = @"com.kb.isguestaccount";
static NSString *const kKeyLocalUser    = @"com.kblove.localUserModel";
static NSString *const kKeyDevName      = @"com.kb.devicename";

static NSString *const kMemberIDKey     = @"lktweak.member_id";
static NSString *const kDeviceIDKey     = @"lktweak.device_id";

static IMP gOrigObjectForKey    = NULL;
static IMP gOrigStringForKey    = NULL;
static IMP gOrigSetObject       = NULL;
static IMP gOrigArrayForKey     = NULL;
static IMP gOrigDictionaryForKey = NULL;
static IMP gOrigDataForKey      = NULL;
static IMP gOrigBoolForKey      = NULL;
static IMP gOrigValueForKey     = NULL;
@implementation LKLogin

#pragma mark - 持久化取值

+ (NSUserDefaults *)store {
    // 优先写入 App 自身的 standard defaults（沙盒内，appex 可写），
    // 保证跨进程重启后仍然固定。
    return [NSUserDefaults standardUserDefaults];
}

+ (long long)memberID {
    NSUserDefaults *ud = [self store];
    long long v = [ud integerForKey:kMemberIDKey];
    if (v <= 0) {
        // 随机生成一个 7 位数的会员 ID 并持久化，避免所有设备取同值
        v = 1000000 + arc4random_uniform(8000000);
        [ud setInteger:v forKey:kMemberIDKey];
        [ud synchronize];
    }
    return v;
}

+ (NSString *)deviceIdentifier {
    NSUserDefaults *ud = [self store];
    NSString *v = [ud stringForKey:kDeviceIDKey];
    if (v.length < 8) {
        // 首次生成后固定：服务端的 launchV2 等接口按设备标识统计，
        // 若每次注册都换新 UUID 会被当成全新设备。
        v = [[NSUUID UUID] UUIDString];
        [ud setObject:v forKey:kDeviceIDKey];
        [ud synchronize];
    }
    return v;
}

+ (BOOL)isLoginKey:(NSString *)key {
    if (key.length == 0) return NO;
    return [key isEqualToString:kKeyShareAccount]
        || [key isEqualToString:kKeyUserToken]
        || [key isEqualToString:kKeyIsGuest]
        || [key isEqualToString:kKeyLocalUser];
}

#pragma mark - App Group 共享域

// 客户端（键盘扩展与主 App）通过 App Group group.com.cck.lovekey 共享登录态。
// 这里把伪造值同时写进共享域，保证两边读到一致，且重启后仍然有效。
static NSString *const kAppGroup = @"group.com.cck.lovekey";

+ (NSUserDefaults *)groupStore {
    static NSUserDefaults *g = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g = [[NSUserDefaults alloc] initWithSuiteName:kAppGroup];
    });
    return g;
}

+ (void)syncToGroupForKey:(NSString *)key value:(id)value {
    if (!value) return;
    NSUserDefaults *gs = [self groupStore];
    if (!gs) return;
    @try {
        [gs setObject:value forKey:key];
        [gs synchronize];
    } @catch (NSException *e) {
        LKLog(@"[login] !! 写共享域失败 %@: %@", key, e.reason);
    }
}

// 启动时主动把全套伪造登录态写进共享域与 standard 域，
// 避免客户端首次读取时拿到 nil。
+ (void)seedLoginState {
    NSDictionary *acc = [self fakeAccount];
    NSString *accJSON = [self fakeAccountJSON];
    NSString *token = @"30699999|lktweakLocalToken000000000000000000";

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSUserDefaults *gs = [self groupStore];

    void (^put)(NSUserDefaults *, NSString *, id) = ^(NSUserDefaults *store, NSString *k, id v) {
        if (!store || !v) return;
        @try {
            [store setObject:v forKey:k];
            [store synchronize];
        } @catch (NSException *e) {}
    };

    for (NSUserDefaults *store in @[ud, gs]) {
        put(store, kKeyShareAccount, acc);
        put(store, kKeyUserToken, token);
        put(store, kKeyIsGuest, @NO);
        put(store, kKeyLocalUser, accJSON);
        put(store, kKeyDevName, @"iPhone");
    }
    LKLog(@"[login] 已向 standard + %@ 写入伪造登录态", kAppGroup);
}

#pragma mark - 伪造的登录态数据

// 永久会员时间戳：2100-01-01，避免某些实现用 32 位 int 溢出
static NSString *const kForeverExpire = @"4102416000";

+ (NSDictionary *)fakeAccount {
    long long mid = [self memberID];
    return @{
        @"id":             @(mid),
        @"member_id":      @(mid),
        @"nickname":       @"baby",
        @"name":           @"baby",
        @"source":         @"App store",
        @"perpetual_vip":  @1,
        @"member_vip":     @2,
        @"vip_level":      @"永久会员",
        @"vip_expired_at": kForeverExpire,
        @"hy_expired_day": @"9999",
        @"hy_expired_at":  kForeverExpire,
        @"perpetual_hy":   @1,
        @"member_hy":      @1,
        @"guest":          @NO,
        @"is_formal":      @YES,
        @"is_must_vip_keyboard": @NO,
        @"restrict_times": @999999,
        @"free_search_time": @999999,
        @"img_analysis_remain_times": @999,
        @"phone":          @"13800000000",
        @"has_password":   @YES,
        @"third_party_bound": @YES,
        @"guest_positive_at": @"2026-01-01 00:00:00",
        @"wechat_mini_program_open_id": @"oLovekeyTweakBind",
        @"google_open_id": @"lovetweak.bind",
        @"status":         @1,
        @"option":         @1,
        @"login_times":    @1,
        @"device_uuid":    [self deviceIdentifier],
        @"device_name":    @"iPhone",
        @"used_chs_times": @0,
        @"used_bnh_times": @0,
        @"used_kcb_times": @0,
        @"used_img_analysis_times": @0,
        @"total_used_times": @0,
    };
}

+ (NSString *)fakeAccountJSON {
    NSDictionary *acc = [self fakeAccount];
    NSData *d = [NSJSONSerialization dataWithJSONObject:acc options:0 error:nil];
    return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"{}";
}

+ (id)fakeValueForKey:(NSString *)key {
    if ([key isEqualToString:kKeyShareAccount]) {
        // 客户端可能以 JSON 字符串或字典形式读取，这里统一给字典更通用；
        // 若实际读字符串也能被 NSString 分支兜住。
        return [self fakeAccount];
    }
    if ([key isEqualToString:kKeyUserToken]) {
        // 给一个非空 token 即可，实际请求仍由 LKURLProtocol 替换为真实访客 token
        return @"30699999|lktweakLocalToken000000000000000000";
    }
    if ([key isEqualToString:kKeyIsGuest]) {
        return @NO;
    }
    if ([key isEqualToString:kKeyLocalUser]) {
        return [self fakeAccountJSON];
    }
    return nil;
}

#pragma mark - Hook（必须是 C 函数，用 method_setImplementation 安装）

static id hk_objectForKey(id self, SEL _cmd, NSString *key) {
    if ([[LKLogin class] isLoginKey:key]) {
        id v = [[LKLogin class] fakeValueForKey:key];
        if (v) {
            LKLog(@"[login] 拦截读 %@ → 返回伪造登录态", key);
            return v;
        }
    }
    return ((id (*)(id, SEL, id))gOrigObjectForKey)(self, _cmd, key);
}

static NSString *hk_stringForKey(id self, SEL _cmd, NSString *key) {
    if ([[LKLogin class] isLoginKey:key]) {
        if ([key isEqualToString:kKeyUserToken]) {
            return @"30699999|lktweakLocalToken000000000000000000";
        }
        return [[LKLogin class] fakeAccountJSON];
    }
    return ((id (*)(id, SEL, id))gOrigStringForKey)(self, _cmd, key);
}

static NSArray *hk_arrayForKey(id self, SEL _cmd, NSString *key) {
    if ([[LKLogin class] isLoginKey:key]) {
        return @[ [[LKLogin class] fakeAccount] ];
    }
    return ((id (*)(id, SEL, id))gOrigArrayForKey)(self, _cmd, key);
}

static NSDictionary *hk_dictionaryForKey(id self, SEL _cmd, NSString *key) {
    if ([[LKLogin class] isLoginKey:key]) {
        return [[LKLogin class] fakeAccount];
    }
    return ((id (*)(id, SEL, id))gOrigDictionaryForKey)(self, _cmd, key);
}

// 客户端可能以 NSData(JSON) 形式存取账号，需要一并覆盖
static NSData *hk_dataForKey(id self, SEL _cmd, NSString *key) {
    if ([[LKLogin class] isLoginKey:key]) {
        NSString *json = [[LKLogin class] fakeAccountJSON];
        return [json dataUsingEncoding:NSUTF8StringEncoding];
    }
    return ((id (*)(id, SEL, id))gOrigDataForKey)(self, _cmd, key);
}

// isguestaccount 之类会用 boolForKey: 读取
static BOOL hk_boolForKey(id self, SEL _cmd, NSString *key) {
    if ([[LKLogin class] isLoginKey:key]) {
        if ([key isEqualToString:kKeyIsGuest]) return NO;   // 不是游客
        return YES;                                          // 其它登录键视为真
    }
    return ((BOOL (*)(id, SEL, id))gOrigBoolForKey)(self, _cmd, key);
}

// KVC 路径
static id hk_valueForKey(id self, SEL _cmd, NSString *key) {
    if ([[LKLogin class] isLoginKey:key]) {
        id v = [[LKLogin class] fakeValueForKey:key];
        if (v) return v;
    }
    return ((id (*)(id, SEL, id))gOrigValueForKey)(self, _cmd, key);
}

static void hk_setObject(id self, SEL _cmd, id value, NSString *key) {
    if ([[LKLogin class] isLoginKey:key]) {
        // 关键：不能丢弃写入。
        // 客户端 UserManager 是单例，它把「自己写入的值」当作登录态来源，
        // 丢弃后它读到 nil/旧值 → 判定游客 → 弹「请先绑定账号」。
        // 正确做法：把写入值替换成伪造会员态，并保持类型一致。
        id fake = nil;
        if ([value isKindOfClass:[NSString class]]) {
            fake = [[LKLogin class] fakeAccountJSON];
        } else if ([value isKindOfClass:[NSDictionary class]]) {
            fake = [[LKLogin class] fakeAccount];
        } else {
            fake = [[LKLogin class] fakeValueForKey:key];
        }
        if (fake) {
            LKLog(@"[login] 替换写 %@ → 伪造会员态", key);
            ((void (*)(id, SEL, id, id))gOrigSetObject)(self, _cmd, fake, key);
            // 同步写一份到 App Group 共享域，保证主 App 与 appex 读到一致
            [[LKLogin class] syncToGroupForKey:key value:fake];
            return;
        }
    }
    ((void (*)(id, SEL, id, id))gOrigSetObject)(self, _cmd, value, key);
}

+ (void)install {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = objc_getClass("NSUserDefaults");
        if (!cls) { LKLog(@"[login] !! 找不到 NSUserDefaults"); return; }

        struct { const char *sel; IMP imp; IMP *orig; } items[] = {
            { "objectForKey:",       (IMP)hk_objectForKey,      &gOrigObjectForKey },
            { "stringForKey:",       (IMP)hk_stringForKey,      &gOrigStringForKey },
            { "arrayForKey:",        (IMP)hk_arrayForKey,       &gOrigArrayForKey },
            { "dictionaryForKey:",   (IMP)hk_dictionaryForKey,  &gOrigDictionaryForKey },
            { "dataForKey:",         (IMP)hk_dataForKey,        &gOrigDataForKey },
            { "boolForKey:",         (IMP)hk_boolForKey,        &gOrigBoolForKey },
            { "valueForKey:",        (IMP)hk_valueForKey,       &gOrigValueForKey },
            { "setObject:forKey:",   (IMP)hk_setObject,         &gOrigSetObject },
        };

        for (size_t i = 0; i < sizeof(items) / sizeof(items[0]); i++) {
            SEL sel = sel_registerName(items[i].sel);
            Method m = class_getInstanceMethod(cls, sel);
            if (!m) { LKLog(@"[login] !! 找不到方法 %s", items[i].sel); continue; }
            *items[i].orig = method_getImplementation(m);
            method_setImplementation(m, items[i].imp);
            LKLog(@"[login] hook %s 成功", items[i].sel);
        }

        NSString *dev = [self deviceIdentifier];
        LKLog(@"[login] 登录态伪造就绪 member_id=%lld device=%@@...",
              [self memberID], [dev substringToIndex:MIN(8, dev.length)]);

        // 主动写入伪造登录态：客户端 UserManager 会先尝试读取已有值，
        // 若为空才走登录流程；预置数据可让它直接认为「已绑定」。
        [self seedLoginState];
    });
}

@end
