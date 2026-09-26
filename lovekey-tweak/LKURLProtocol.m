#import "LKURLProtocol.h"
#import "LKCrypto.h"
#import "LKAccount.h"
#import "LKLog.h"

static NSString *const kHandledKey = @"LKHandled";
static NSMutableSet *gSeenHosts = nil;

@interface LKURLProtocol ()
@property (nonatomic, strong) NSURLSession *streamSession;
@property (nonatomic, assign) BOOL finished;
- (NSString *)preview:(NSString *)s max:(NSUInteger)max;
- (BOOL)pathMatches:(NSString *)path pattern:(NSString *)pattern;
@end

@implementation LKURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *host = request.URL.host;
    if (host.length == 0 || ![host containsString:@"lovekeyboard"]) return NO;
    // 自己发起的注册请求已打标，避免递归
    if ([NSURLProtocol propertyForKey:kHandledKey inRequest:request]) return NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gSeenHosts = [NSMutableSet set]; });
    @synchronized (gSeenHosts) {
        if (![gSeenHosts containsObject:host]) {
            [gSeenHosts addObject:host];
            LKLog(@"[拦截] 命中 host=%@ 首次出现", host);
        }
    }
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSMutableURLRequest *req = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:kHandledKey inRequest:req];
    NSString *path = req.URL.path ?: @"";
    LKLog(@"[请求] %@ %@", req.HTTPMethod, req.URL.absoluteString);
    LKLog(@"[请求] 原始 Authorization = %@", [req valueForHTTPHeaderField:@"Authorization"] ?: @"(无)");

    if ([path hasPrefix:@"/v1/chat/"]) {
        // 关键：每次超会说请求都用全新访客账号（每号仅 3 次额度）
        LKLog(@"[chat] 进入换账号流程 path=%@", path);
        __weak typeof(self) weakSelf = self;
        [LKAccount fetchGuestToken:^(NSString *token) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (token.length > 0) {
                [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
                LKLog(@"[chat] Authorization 已替换 token=%@@...", [token substringToIndex:MIN(12, token.length)]);
            } else {
                LKLog(@"[chat] !! token 获取失败，保留原 Authorization");
            }
            [self forwardStreaming:req];   // SSE 流式，不能缓冲
        }];
    } else {
        [self forward:req];
    }
}

- (void)stopLoading {
    LKLog(@"[请求] stopLoading %@", self.request.URL.path);
    self.finished = YES;
    [self.streamSession invalidateAndCancel];
    self.streamSession = nil;
}

#pragma mark - 流式转发（SSE：逐块转发，不改响应）

- (void)forwardStreaming:(NSURLRequest *)req {
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.protocolClasses = @[];   // 不再走本类
    self.streamSession = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    LKLog(@"[chat] 开始流式转发 path=%@", req.URL.path);
    [[self.streamSession dataTaskWithRequest:req] resume];
}

- (void)URLSession:(NSURLSession *)session
              dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    NSInteger code = [response isKindOfClass:[NSHTTPURLResponse class]]
                     ? ((NSHTTPURLResponse *)response).statusCode : -1;
    LKLog(@"[chat] 响应头 status=%ld", (long)code);
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    LKLog(@"[chat] 数据块 %lu 字节", (unsigned long)data.length);
    // 诊断：打印流式响应内容，定位服务端是否返回额度/绑定类错误
    NSString *chunk = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    LKLog(@"[LKDBG] 流式 %@ (%luB): %@", dataTask.originalRequest.URL.path,
          (unsigned long)data.length, [self preview:chunk max:600]);
    [self.client URLProtocol:self didLoadData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (self.finished) return;
    self.finished = YES;
    NSInteger code = [task.response isKindOfClass:[NSHTTPURLResponse class]]
                     ? ((NSHTTPURLResponse *)task.response).statusCode : -1;
    if (error) {
        LKLog(@"[chat] !! 结束(错误) status=%ld err=%@", (long)code, error.localizedDescription);
        [self.client URLProtocol:self didFailWithError:error];
    } else {
        LKLog(@"[chat] 流式结束 status=%ld", (long)code);
        [self.client URLProtocolDidFinishLoading:self];
    }
    [self.streamSession finishTasksAndInvalidate];
    self.streamSession = nil;
}

- (void)forward:(NSURLRequest *)req {
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.protocolClasses = @[];   // 不再走本类
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (self.finished) return;
            self.finished = YES;
            NSInteger code = [response isKindOfClass:[NSHTTPURLResponse class]]
                             ? ((NSHTTPURLResponse *)response).statusCode : -1;
            if (error) {
                LKLog(@"[响应] !! 网络错误 status=%ld err=%@ path=%@", (long)code, error.localizedDescription, req.URL.path);
                [self.client URLProtocol:self didFailWithError:error];
                return;
            }
            LKLog(@"[响应] status=%ld bytes=%lu path=%@", (long)code, (unsigned long)data.length, req.URL.path);
            NSData *patched = [self transformForURL:req.URL data:data];
            NSData *out = patched ?: data;
            LKLog(@"[响应] 改写=%@ (%lu -> %lu bytes)", patched ? @"已改写" : @"未改动",
                  (unsigned long)data.length, (unsigned long)out.length);
            NSURLResponse *fixed = patched ? [self stripLengthHeaders:response] : response;
            [self.client URLProtocol:self didReceiveResponse:fixed cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            if (out.length > 0) [self.client URLProtocol:self didLoadData:out];
            [self.client URLProtocolDidFinishLoading:self];
        }];
    [task resume];
}

#pragma mark - 响应改写

- (NSData *)transformForURL:(NSURL *)url data:(NSData *)data {
    if (data.length == 0) return nil;
    NSString *path = url.path ?: @"";
    // 诊断：原样打印服务端响应，用于定位客户端"请先绑定账号"的判定依据
    NSString *rawStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    LKLog(@"[LKDBG] 原始 %@ (%luB): %@", path, (unsigned long)data.length, [self preview:rawStr max:900]);
    id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        LKLog(@"[改写] path=%@ 非 JSON 对象，跳过", path);
        return nil;
    }
    NSMutableDictionary *wrapped = obj;
    BOOL isV1 = [path hasPrefix:@"/v1/"];
    id d0 = wrapped[@"data"];
    LKLog(@"[改写] path=%@ isV1=%@ dataType=%@", path, isV1 ? @"Y" : @"N",
          [d0 isKindOfClass:[NSString class]] ? @"string(加密)" :
          ([d0 isKindOfClass:[NSDictionary class]] ? @"dict(明文)" : @"其它"));

    // 路径匹配严格化：/v1/account 后面必须是结尾或 '?'，避免吞掉 /v1/account/vip 等子路径
    BOOL isAccountVip = [self pathMatches:path pattern:@"/v1/account/vip"] || [self pathMatches:path pattern:@"/v2/account/vip"];
    BOOL isAccount    = [self pathMatches:path pattern:@"/v1/account"]     || [self pathMatches:path pattern:@"/v2/account"];
    BOOL isConfig     = [self pathMatches:path pattern:@"/v1/app/config"]  || [self pathMatches:path pattern:@"/v2/app/config"];

    if (isAccountVip) {
        id d = wrapped[@"data"];
        if ([d isKindOfClass:[NSDictionary class]]) [self patchVipPage:d];
        return [self encode:wrapped];
    }
    if (isAccount) {
        id d = wrapped[@"data"];
        if (isV1) {
            if ([d isKindOfClass:[NSDictionary class]]) {
                wrapped[@"data"] = [self patchVip:d];
                LKLog(@"[改写] account v1 明文，已注入会员字段");
            } else {
                LKLog(@"[改写] account v1 但 data 非 dict，未处理");
            }
        } else if ([d isKindOfClass:[NSString class]]) {
            NSString *plain = [LKCrypto aesDecrypt:d key:[LKAccount aesKey]];
            LKLog(@"[改写] account v2 AES 解密 %@ (明文长度=%lu)",
                  plain ? @"成功" : @"失败", (unsigned long)plain.length);
            id acc = plain ? [NSJSONSerialization JSONObjectWithData:[plain dataUsingEncoding:NSUTF8StringEncoding]
                                                            options:NSJSONReadingMutableContainers error:nil] : nil;
            if ([acc isKindOfClass:[NSDictionary class]]) {
                NSString *re = [LKCrypto aesEncrypt:[self jsonString:[self patchVip:acc]] key:[LKAccount aesKey]];
                if (re) wrapped[@"data"] = re;
                LKLog(@"[改写] account v2 回写 %@", re ? @"成功" : @"失败");
            } else {
                LKLog(@"[改写] account v2 解密后非 JSON，跳过");
            }
        }
        return [self encode:wrapped];
    }
    if (isConfig) {
        id d = wrapped[@"data"];
        if (isV1) {
            [self patchConfig:wrapped];
            if ([d isKindOfClass:[NSDictionary class]]) [self patchConfig:d];
            LKLog(@"[改写] config v1 明文，已清空 AINeedLogin");
        } else if ([d isKindOfClass:[NSString class]]) {
            NSString *plain = [LKCrypto aesDecrypt:d key:[LKAccount aesKey]];
            LKLog(@"[改写] config v2 AES 解密 %@", plain ? @"成功" : @"失败");
            id conf = plain ? [NSJSONSerialization JSONObjectWithData:[plain dataUsingEncoding:NSUTF8StringEncoding]
                                                             options:NSJSONReadingMutableContainers error:nil] : nil;
            if ([conf isKindOfClass:[NSDictionary class]]) {
                [self patchConfig:conf];
                NSString *re = [LKCrypto aesEncrypt:[self jsonString:conf] key:[LKAccount aesKey]];
                if (re) wrapped[@"data"] = re;
                LKLog(@"[改写] config v2 回写 %@", re ? @"成功" : @"失败");
            }
        }
        return [self encode:wrapped];
    }
    LKLog(@"[改写] path=%@ 无匹配规则，原样放行", path);
    return nil;
}

- (NSMutableDictionary *)patchVip:(NSDictionary *)a {
    if (![a isKindOfClass:[NSDictionary class]]) return nil;
    NSMutableDictionary *m = [a mutableCopy];
    id nick = m[@"nickname"];
    if (![nick isKindOfClass:[NSString class]] || [(NSString *)nick hasPrefix:@"游客"]) m[@"nickname"] = @"baby";
    m[@"guest"] = @NO;
    id mid = m[@"member_id"];
    if (![mid respondsToSelector:@selector(integerValue)] || [mid integerValue] <= 0) m[@"member_id"] = @99999999;
    m[@"perpetual_vip"] = @1;
    m[@"vip_expired_at"] = @"3742732800";
    m[@"member_vip"] = @2;
    m[@"vip_level"] = @"永久会员";
    m[@"is_must_vip_keyboard"] = @NO;
    m[@"is_formal"] = @YES;
    m[@"restrict_times"] = @999999;
    m[@"free_search_time"] = @999999;
    m[@"img_analysis_remain_times"] = @999;
    m[@"hy_expired_day"] = @"9999";
    if (!m[@"phone"]) m[@"phone"] = @"13800000000";
    m[@"has_password"] = @YES;
    m[@"third_party_bound"] = @YES;
    // 服务端 /v1/account 实测返回这些 guest 相关字段，客户端据此判定"请先绑定账号"，
    // 必须一并改写，否则仅改 guest 仍会被本地缓存判定为游客。
    if (!m[@"guest_positive_at"]) m[@"guest_positive_at"] = @"2026-09-26 00:00:00";
    if (!m[@"wechat_mini_program_open_id"]) m[@"wechat_mini_program_open_id"] = @"oLovekeyTweakBind";
    if (!m[@"google_open_id"]) m[@"google_open_id"] = @"lovetweak.bind";
    m[@"login_times"] = @1;
    m[@"option"] = @1;
    m[@"status"] = @1;
    m[@"used_chs_times"] = @0;
    m[@"used_bnh_times"] = @0;
    m[@"used_kcb_times"] = @0;
    m[@"used_img_analysis_times"] = @0;
    m[@"total_used_times"] = @0;
    return m;
}

- (void)patchVipPage:(NSMutableDictionary *)d {
    id u = d[@"user"];
    if ([u isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *um = u;
        um[@"perpetual_hy"] = @1;
        um[@"member_hy"] = @1;
        if (!um[@"hy_expired_at"]) um[@"hy_expired_at"] = @"3742732800";
    }
}

- (void)patchConfig:(NSMutableDictionary *)o {
    id a = o[@"AINeedLogin"];
    if ([a isKindOfClass:[NSArray class]]) o[@"AINeedLogin"] = @[];
    id conf = o[@"conf"];
    if ([conf isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *cm = conf;
        id ca = cm[@"AINeedLogin"];
        if ([ca isKindOfClass:[NSArray class]]) cm[@"AINeedLogin"] = @[];
    }
    if (o[@"isGuestLogin"] != nil) o[@"isGuestLogin"] = @YES;
}

#pragma mark - 工具

// 路径精确匹配。url.path 已剥离查询串，故只做全等比较：
//   /v1/account       → 命中
//   /v1/account/vip   → 不命中（由 vip 分支单独处理）
//   /v1/account/vip/theme → 不命中（与原脚本 (?:\?|$) 语义一致）
- (BOOL)pathMatches:(NSString *)path pattern:(NSString *)pattern {
    return [path isEqualToString:pattern];
}

// 日志截断，避免超长响应刷爆 syslog
- (NSString *)preview:(NSString *)s max:(NSUInteger)max {
    if (s.length == 0) return @"(空)";
    if (s.length <= max) return s;
    return [[s substringToIndex:max] stringByAppendingFormat:@"...(共 %lu 字)", (unsigned long)s.length];
}

- (NSString *)jsonString:(id)obj {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
}

- (NSData *)encode:(id)obj {
    return [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
}

- (NSURLResponse *)stripLengthHeaders:(NSURLResponse *)resp {
    if (![resp isKindOfClass:[NSHTTPURLResponse class]]) return resp;
    NSHTTPURLResponse *h = (NSHTTPURLResponse *)resp;
    NSMutableDictionary *hdrs = [NSMutableDictionary dictionary];
    for (NSString *k in h.allHeaderFields) {
        NSString *low = k.lowercaseString;
        if ([low isEqualToString:@"content-length"] || [low isEqualToString:@"content-encoding"]) continue;
        hdrs[k] = h.allHeaderFields[k];
    }
    return [[NSHTTPURLResponse alloc] initWithURL:h.URL statusCode:h.statusCode
                                      HTTPVersion:@"HTTP/1.1" headerFields:hdrs];
}

@end
