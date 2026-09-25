#import <Foundation/Foundation.h>

// 进程内 MITM：拦截 sea.api.lovekeyboard.com 流量
// - 请求：/v1/chat/* 每条换一个全新访客 token（流式转发，不改响应）
// - 响应：account / app.config 注入会员字段（缓冲后改写）
@interface LKURLProtocol : NSURLProtocol <NSURLSessionDataDelegate>
@end
