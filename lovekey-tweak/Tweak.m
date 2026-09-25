// LovekeyTweak —— 进程内注入版（TrollFools 兼容）
//
// 关键：不使用 Logos %hook / mobilesubstrate。
// TrollFools 只做 Mach-O 注入（insert_dylib + ChOma），不提供 hook 运行时，
// 因此全部改用纯 Objective-C runtime API，只依赖 libobjc。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "LKURLProtocol.h"
#import "LKLog.h"

static IMP gOrigProtocolClasses = NULL;
static BOOL gLoggedOnce = NO;

// hook NSURLSessionConfiguration.protocolClasses 的 getter
static NSArray *LKProtocolClasses(id self, SEL _cmd) {
    NSArray *orig = ((NSArray *(*)(id, SEL))gOrigProtocolClasses)(self, _cmd);

    Class protoCls = objc_getClass("LKURLProtocol");
    if (!protoCls) {
        if (!gLoggedOnce) { gLoggedOnce = YES; LKLog(@"[hook] LKURLProtocol 类不存在，跳过注入"); }
        return orig;
    }
    NSMutableArray *arr = orig ? [orig mutableCopy] : [NSMutableArray array];
    BOOL found = NO;
    for (Class c in arr) { if (c == protoCls) { found = YES; break; } }
    if (found) return arr;

    [arr insertObject:protoCls atIndex:0];
    if (!gLoggedOnce) {
        gLoggedOnce = YES;
        LKLog(@"[hook] protocolClasses 已注入 LKURLProtocol（原有 %lu 个）", (unsigned long)(orig.count));
    }
    return arr;
}

__attribute__((constructor))
static void LKInit(void) {
    @autoreleasepool {
        LKLogEnvironment();

        // 1) hook protocolClasses getter
        Class cls = objc_getClass("NSURLSessionConfiguration");
        if (!cls) {
            LKLog(@"[FATAL] 找不到 NSURLSessionConfiguration，方案不可用");
        } else {
            SEL sel = sel_registerName("protocolClasses");
            Method m = class_getInstanceMethod(cls, sel);
            if (!m) {
                LKLog(@"[FATAL] NSURLSessionConfiguration 没有 protocolClasses 方法");
            } else {
                gOrigProtocolClasses = method_getImplementation(m);
                method_setImplementation(m, (IMP)LKProtocolClasses);
                LKLog(@"[hook] protocolClasses 挂钩成功");
            }
        }

        // 2) 注册 URLProtocol
        Class protoCls = objc_getClass("LKURLProtocol");
        if (protoCls) {
            BOOL ok = [NSURLProtocol registerClass:protoCls];
            LKLog(@"[hook] registerClass(LKURLProtocol) = %@", ok ? @"成功" : @"失败");
        } else {
            LKLog(@"[FATAL] LKURLProtocol 类未编译进来");
        }

        // 3) 自检：确认注入是否真的生效（会立刻走一次 protocolClasses）
        if (gOrigProtocolClasses) {
            NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
            NSArray *pcs = cfg.protocolClasses;
            LKLog(@"[self-test] ephemeral.protocolClasses = %@", pcs);
        }

        LKLog(@"=== LovekeyTweak 初始化完成 ===");
    }
}
