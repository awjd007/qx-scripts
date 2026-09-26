#import <Foundation/Foundation.h>

@interface LKAccount : NSObject
// 异步注册一个全新访客账号，回调返回 access_token（失败为 nil）
+ (void)fetchGuestToken:(void (^)(NSString *token))completion;

// 获取一个可用于鉴权的 token。
// 策略：缓存最近一次有效的 token 并复用；仅当没有缓存或已被服务端判为失效
// （清缓存）时才注册新账号。避免每个接口都新建账号造成请求风暴。
// 超会说这类需要"每次换新账号"的场景仍用 fetchGuestToken:。
+ (void)ensureToken:(void (^)(NSString *token))completion;

// 标记当前缓存的 token 已失效，下次 ensureToken: 会重新注册
+ (void)invalidateToken;

// 常量
+ (NSString *)aesKey;
+ (NSString *)signSecret;
+ (NSString *)appVersion;
+ (NSString *)apiHost;
@end
