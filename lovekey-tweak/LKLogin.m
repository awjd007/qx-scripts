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

// 防重入标志：login 相关的写入（syncToGroupForKey / seedLoginState）内部
// 会再次触发 setObject:forKey:，没有保护会无限递归导致栈溢出、进程崩溃。
static __thread BOOL gInLoginWrite = NO;

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
    // 保留接口供 seedLoginState 使用；注意调用方必须先置 gInLoginWrite，
    // 否则 setObject: 会再次进入 hook 形成递归。
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
    NSDictionary *um = [self fakeUserManager];
    NSString *umJSON = [self fakeUserManagerJSON];
    NSString *token = [self fakeToken];

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSUserDefaults *gs = [self groupStore];

    BOOL prev = gInLoginWrite;
    gInLoginWrite = YES;      // 防止写入过程被自己的 hook 再次拦截
    for (NSUserDefaults *store in @[ud, gs]) {
        if (!store) continue;
        @try {
            [store setObject:um      forKey:kKeyShareAccount];
            [store setObject:token   forKey:kKeyUserToken];
            [store setObject:@NO     forKey:kKeyIsGuest];
            [store setObject:umJSON  forKey:kKeyLocalUser];
            [store setObject:@"iPhone" forKey:kKeyDevName];
            [store synchronize];
        } @catch (NSException *e) {}
    }
    gInLoginWrite = prev;
    LKLog(@"[login] 已向 standard + %@ 写入伪造登录态(token=%@...)",
          kAppGroup, [token substringToIndex:MIN(12, token.length)]);
}

#pragma mark - 伪造的登录态数据

// 永久会员时间戳：2100-01-01，避免某些实现用 32 位 int 溢出
static NSString *const kForeverExpire = @"4102416000";

// 本地伪造的 token。格式必须与服务端一致：<数字ID>|<32位随机串>
// （客户端会把它直接当 Authorization 使用，格式不符会被服务端拒绝）
+ (NSString *)fakeToken {
    static NSString *t = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableString *s = [NSMutableString stringWithFormat:@"%lld|", [self memberID]];
        static const char *cs = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
        for (int i = 0; i < 32; i++) [s appendFormat:@"%c", cs[arc4random_uniform(62)]];
        t = s;
    });
    return t;
}

// com.kb.shareaccount 存的是 UserManager 的结构（不是服务端 /v1/account 的响应）。
// 字段名从 appex 二进制提取：account / logInToken / intimacy / idfa / uudIdStr /
// deviceName / config / relationModels / nowRelationModel / dataLoad
// 若结构不符，客户端解析失败会退化成拿裸 token 当 Authorization，导致校验不过。
+ (NSDictionary *)fakeUserManager {
    return @{
        @"account":         [self fakeAccount],
        @"logInToken":      [self fakeToken],
        @"intimacy":        @30,
        @"idfa":            @"00000000-0000-0000-0000-000000000000",
        @"uudIdStr":        [self deviceIdentifier],
        @"deviceName":      @"iPhone",
        @"config":          @{},
        @"relationModels":  @[],
        @"nowRelationModel": @{},
        @"dataLoad":        @YES,
        @"isGuestLogin":    @NO,
    };
}

+ (NSString *)fakeUserManagerJSON {
    NSData *d = [NSJSONSerialization dataWithJSONObject:[self fakeUserManager] options:0 error:nil];
    return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"{}";
}

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
        // shareaccount 存的是 UserManager 结构（含 logInToken），不是账号对象
        return [self fakeUserManager];
    }
    if ([key isEqualToString:kKeyUserToken]) {
        return [self fakeToken];
    }
    if ([key isEqualToString:kKeyIsGuest]) {
        return @NO;
    }
    if ([key isEqualToString:kKeyLocalUser]) {
        return [self fakeUserManagerJSON];
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
            return [[LKLogin class] fakeToken];
        }
        // shareaccount / localUserModel 以 JSON 字符串形式返回 UserManager 结构
        return [[LKLogin class] fakeUserManagerJSON];
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
        NSString *json = [[LKLogin class] fakeUserManagerJSON];
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

// 防重入：syncToGroupForKey / seedLoginState 内部会再次调用 setObject:forKey:，
// 若不做保护会形成无限递归（hk_setObject → syncToGroupForKey → hk_setObject …）
// 导致栈溢出、键盘进程崩溃（表现为切换键盘闪退）。
static void hk_setObject(id self, SEL _cmd, id value, NSString *key) {
    if (gInLoginWrite) {
        ((void (*)(id, SEL, id, id))gOrigSetObject)(self, _cmd, value, key);
        return;
    }
    if ([[LKLogin class] isLoginKey:key]) {
        // 不能丢弃写入：客户端 UserManager 是单例，把自己写入的值当登录态来源，
        // 丢弃后它读到 nil/旧值 → 判定游客 → 弹「请先绑定账号」。
        // 做法：把写入值就地替换为同类型的伪造会员态。
        // 不再额外写 group 域 —— 客户端写共享域时走的也是本方法，已被覆盖；
        // 额外写入会形成递归（本方法 → syncToGroupForKey → 本方法）导致崩溃。
        id fake = nil;
        if ([value isKindOfClass:[NSString class]]) {
            fake = [[LKLogin class] fakeUserManagerJSON];
        } else if ([value isKindOfClass:[NSDictionary class]]) {
            fake = [[LKLogin class] fakeUserManager];
        } else {
            fake = [[LKLogin class] fakeValueForKey:key];
        }
        if (fake) {
            gInLoginWrite = YES;
            ((void (*)(id, SEL, id, id))gOrigSetObject)(self, _cmd, fake, key);
            gInLoginWrite = NO;
            return;
        }
    }
    ((void (*)(id, SEL, id, id))gOrigSetObject)(self, _cmd, value, key);
}

#pragma mark - KeyboardManager 属性 hook
//
// 登录门禁的真正开关不在 NSUserDefaults，而在 KeyboardManager 的实例属性：
//   isGuest       是否游客
//   isNeedBind    是否需要绑定  ← 「请先绑定账号」的直接依据
//   showMemberVC  是否弹会员页
// 这三个是 Swift 只读计算属性（二进制里只有 getter，无 setter），
// 在类方法表层面替换 getter 即可让所有实例返回伪造值。

static IMP gOrigIsNeedBind    = NULL;
static IMP gOrigIsGuest       = NULL;
static IMP gOrigShowMemberVC  = NULL;

static BOOL hk_isNeedBind(id self, SEL _cmd) {
    if (gOrigIsNeedBind) {
        BOOL orig = ((BOOL (*)(id, SEL))gOrigIsNeedBind)(self, _cmd);
        if (orig) LKLog(@"[login] isNeedBind 原值=YES → 强制 NO");
    }
    return NO;
}

static BOOL hk_isGuest(id self, SEL _cmd) {
    return NO;
}

static BOOL hk_showMemberVC(id self, SEL _cmd) {
    return NO;
}

+ (void)installManagerHooks {
    // Swift 类名带模块前缀，两种写法都试
    const char *names[] = {
        "_TtC16SeekLoveKeyboard15KeyboardManager",
        "SeekLoveKeyboard.KeyboardManager",
        "KeyboardManager",
    };
    Class cls = NULL;
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        cls = objc_getClass(names[i]);
        if (cls) { LKLog(@"[login] 找到 KeyboardManager: %s", names[i]); break; }
    }
    if (!cls) {
        LKLog(@"[login] !! 找不到 KeyboardManager 类，门禁 hook 跳过");
        return;
    }

    struct { const char *sel; IMP imp; IMP *orig; const char *desc; } items[] = {
        { "isNeedBind",   (IMP)hk_isNeedBind,   &gOrigIsNeedBind,   "isNeedBind" },
        { "isGuest",      (IMP)hk_isGuest,      &gOrigIsGuest,      "isGuest" },
        { "showMemberVC", (IMP)hk_showMemberVC, &gOrigShowMemberVC, "showMemberVC" },
    };

    for (size_t i = 0; i < sizeof(items) / sizeof(items[0]); i++) {
        SEL sel = sel_registerName(items[i].sel);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) {
            LKLog(@"[login] KeyboardManager 无 %s（可能是存储属性，跳过）", items[i].desc);
            continue;
        }
        *items[i].orig = method_getImplementation(m);
        method_setImplementation(m, items[i].imp);
        LKLog(@"[login] hook KeyboardManager.%s 成功", items[i].desc);
    }
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

        // 关键：登录门禁的真正开关是 KeyboardManager 的实例属性
        // （isNeedBind / isGuest / showMemberVC），只改 NSUserDefaults 影响不到它，
        // 「开场白」「优化」在发请求前就被这几个属性拦下。
        [self installManagerHooks];
    });
}

@end
