#import <Foundation/Foundation.h>

@interface LKAccount : NSObject
// 异步注册一个全新访客账号，回调返回 access_token（失败为 nil）
+ (void)fetchGuestToken:(void (^)(NSString *token))completion;

// 常量
+ (NSString *)aesKey;
+ (NSString *)signSecret;
+ (NSString *)appVersion;
+ (NSString *)apiHost;
@end
