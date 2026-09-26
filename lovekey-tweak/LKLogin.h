#import <Foundation/Foundation.h>

// 本地登录态伪造。
//
// 背景：客户端（键盘扩展）在点「超会说 / 帮你回 / 开场白」前，会先读本地
// 缓存的登录态（App Group group.com.cck.lovekey 下的 com.kb.shareaccount 等键）
// 判断是否已绑定账号。判定为游客时直接弹「请先绑定账号」，请求根本不发出。
//
// 因此不再依赖服务端任何接口，改为在进程内 hook NSUserDefaults 的读写，
// 让客户端读到「已绑定 + 永久会员」的状态。
@interface LKLogin : NSObject

// 安装 hook（幂等，可重复调用）
+ (void)install;

// 取持久化的伪会员 ID（首次调用时随机生成并落盘）
+ (long long)memberID;

// 取持久化的设备标识（首次生成后固定，避免每次注册都被服务端当作新设备）
+ (NSString *)deviceIdentifier;

// 是否为需要伪造的登录态键
+ (BOOL)isLoginKey:(NSString *)key;

@end
