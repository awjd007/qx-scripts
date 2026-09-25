#import "LKURLProtocol.h"
#import "LKCrypto.h"
#import "LKAccount.h"

static NSString *const kHandledKey = @"LKHandled";

@implementation LKURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *host = request.URL.host;
    if (host.length == 0 || ![host containsString:@"lovekeyboard"]) return NO;
    // 自己发起的注册请求已打标，避免递归
    if ([NSURLProtocol propertyForKey:kHandledKey inRequest:request]) return NO;
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSMutableURLRequest *req = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:kHandledKey inRequest:req];
    NSString *path = req.URL.path ?: @"";

    if ([path hasPrefix:@"/v1/chat/"]) {
        // 关键：每次超会说请求都用全新访客账号（每号仅 3 次额度）
        __weak typeof(self) weakSelf = self;
        [LKAccount fetchGuestToken:^(NSString *token) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (token.length > 0) {
                [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
            }
            [self forward:req];
        }];
    } else {
        [self forward:req];
    }
}

- (void)stopLoading { }

- (void)forward:(NSURLRequest *)req {
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.protocolClasses = @[];   // 不再走本类
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (error) { [self.client URLProtocol:self didFailWithError:error]; return; }
            NSData *patched = [self transformForURL:req.URL data:data];
            NSData *out = patched ?: data;
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
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    NSMutableDictionary *wrapped = obj;
    BOOL isV1 = [path hasPrefix:@"/v1/"];

    if ([path hasPrefix:@"/v2/account/vip"] || [path hasPrefix:@"/v1/account/vip"]) {
        id d = wrapped[@"data"];
        if ([d isKindOfClass:[NSDictionary class]]) [self patchVipPage:d];
        return [self encode:wrapped];
    }
    if ([path hasPrefix:@"/v2/account"] || [path hasPrefix:@"/v1/account"]) {
        id d = wrapped[@"data"];
        if (isV1) {
            if ([d isKindOfClass:[NSDictionary class]]) wrapped[@"data"] = [self patchVip:d];
        } else if ([d isKindOfClass:[NSString class]]) {
            NSString *plain = [LKCrypto aesDecrypt:d key:[LKAccount aesKey]];
            id acc = plain ? [NSJSONSerialization JSONObjectWithData:[plain dataUsingEncoding:NSUTF8StringEncoding]
                                                            options:NSJSONReadingMutableContainers error:nil] : nil;
            if ([acc isKindOfClass:[NSDictionary class]]) {
                NSString *re = [LKCrypto aesEncrypt:[self jsonString:[self patchVip:acc]] key:[LKAccount aesKey]];
                if (re) wrapped[@"data"] = re;
            }
        }
        return [self encode:wrapped];
    }
    if ([path hasPrefix:@"/v2/app/config"] || [path hasPrefix:@"/v1/app/config"]) {
        id d = wrapped[@"data"];
        if (isV1) {
            [self patchConfig:wrapped];
            if ([d isKindOfClass:[NSDictionary class]]) [self patchConfig:d];
        } else if ([d isKindOfClass:[NSString class]]) {
            NSString *plain = [LKCrypto aesDecrypt:d key:[LKAccount aesKey]];
            id conf = plain ? [NSJSONSerialization JSONObjectWithData:[plain dataUsingEncoding:NSUTF8StringEncoding]
                                                             options:NSJSONReadingMutableContainers error:nil] : nil;
            if ([conf isKindOfClass:[NSDictionary class]]) {
                [self patchConfig:conf];
                NSString *re = [LKCrypto aesEncrypt:[self jsonString:conf] key:[LKAccount aesKey]];
                if (re) wrapped[@"data"] = re;
            }
        }
        return [self encode:wrapped];
    }
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
