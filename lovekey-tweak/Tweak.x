// LovekeyTweak —— 进程内注入版
// 思路：把 MITM 脚本的逻辑搬进 App 进程，绕开 Shadowrocket 模块链路
// 注入点：hook NSURLSessionConfiguration.protocolClasses，塞入 LKURLProtocol

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "LKURLProtocol.h"

%hook NSURLSessionConfiguration

- (NSArray *)protocolClasses {
    NSArray *orig = %orig;
    Class cls = objc_getClass("LKURLProtocol");
    if (!cls) return orig;
    NSMutableArray *arr = orig ? [orig mutableCopy] : [NSMutableArray array];
    for (Class c in arr) {
        if (c == cls) return arr;   // 已在列表中
    }
    [arr insertObject:cls atIndex:0];
    return arr;
}

%end

%ctor {
    NSLog(@"[LovekeyTweak] loaded into %@", [[NSBundle mainBundle] bundleIdentifier]);
}
