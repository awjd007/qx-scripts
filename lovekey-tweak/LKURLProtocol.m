#import "LKURLProtocol.h"
#import "LKCrypto.h"
#import "LKAccount.h"
#import "LKLog.h"

static NSString *const kHandledKey = @"LKHandled";
static NSMutableSet *gSeenHosts = nil;

@interface LKURLProtocol ()
@property (nonatomic, strong) NSURLSession *streamSession;
@property (nonatomic, assign) BOOL finished;
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

    if ([path hasPrefix:@"/v2/account/vip"] || [path hasPrefix:@"/v1/account/vip"]) {
        id d = wrapped[@"data"];
        if ([d isKindOfClass:[NSDictionary class]]) [self patchVipPage:d];
        return [self encode:wrapped];
    }
    if ([path hasPrefix:@"/v2/account"] || [path hasPrefix:@"/v1/account"]) {
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
    if ([path hasPrefix:@"/v2/app/config"] || [path hasPrefix:@"/v1/app/config"]) {
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
