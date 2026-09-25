#import "LKAccount.h"
#import "LKCrypto.h"
#import "LKLog.h"

static NSString *const kAESKey      = @"d4XvusEYeafO9SBK";
static NSString *const kSignSecret  = @"BeJsdgiq1azlQItxc93W";
static NSString *const kAppVersion  = @"v1.8.5";
static NSString *const kAppNum      = @"1.8.5";
static NSString *const kApiHost     = @"sea.api.lovekeyboard.com";
static NSString *const kGuestURL    = @"https://sea.api.lovekeyboard.com/v2/auth/guest";

@implementation LKAccount

+ (NSString *)aesKey { return kAESKey; }
+ (NSString *)signSecret { return kSignSecret; }
+ (NSString *)appVersion { return kAppVersion; }
+ (NSString *)apiHost { return kApiHost; }

+ (NSString *)uuid {
    // 复刻脚本的 uuid()：xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx，y 取 (r&3|8)
    NSMutableString *s = [NSMutableString stringWithCapacity:36];
    for (int i = 0; i < 36; i++) {
        if (i == 8 || i == 13 || i == 18 || i == 23) { [s appendString:@"-"]; continue; }
        if (i == 14) { [s appendString:@"4"]; continue; }
        uint32_t r = arc4random_uniform(16);
        if (i == 19) r = ((r & 3) | 8);
        [s appendFormat:@"%X", r];
    }
    return s;
}

+ (NSString *)encodeURIComponent:(NSString *)v {
    NSCharacterSet *allow = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"];
    return [v stringByAddingPercentEncodingWithAllowedCharacters:allow] ?: @"";
}

+ (void)fetchGuestToken:(void (^)(NSString *))completion {
    long long ms = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
    long long ts = ms / 1000;
    NSArray *models = @[@"iPhone 16 Pro Max", @"iPhone 16 Pro", @"iPhone 16",
                        @"iPhone 15 Pro Max", @"iPhone 15 Pro", @"iPhone 15"];
    NSString *model = models[arc4random_uniform((uint32_t)models.count)];
    NSString *uid = [self uuid];
    NSString *flat = [uid stringByReplacingOccurrencesOfString:@"-" withString:@""];
    NSString *prefix = [flat substringToIndex:MIN(16, flat.length)];
    while (prefix.length < 16) prefix = [prefix stringByAppendingString:@"0"];
    NSString *installId = [LKCrypto md5:[prefix stringByAppendingFormat:@"%lld", ms]];

    // query 顺序必须与 App 端一致，否则 sign 校验失败
    NSArray *pairs = @[
        @[@"device[identifier]", uid],
        @[@"device[name]", model],
        @[@"device[platform]", @"0"],
        @[@"install_id", installId],
        @[@"source", @"App store"],
        @[@"version", kAppVersion],
    ];
    NSMutableArray *qparts = [NSMutableArray array];
    for (NSArray *p in pairs) {
        NSString *k = [[p[0] stringByReplacingOccurrencesOfString:@"[" withString:@"%5B"]
                                stringByReplacingOccurrencesOfString:@"]" withString:@"%5D"];
        [qparts addObject:[NSString stringWithFormat:@"%@=%@", k, [self encodeURIComponent:p[1]]]];
    }
    NSString *query = [qparts componentsJoinedByString:@"&"];
    NSString *sign = [LKCrypto md5:[NSString stringWithFormat:@"%@%lld%@", query, ts, kSignSecret]];

    NSDictionary *body = @{
        @"version": kAppVersion,
        @"install_id": installId,
        @"device": @{ @"name": model, @"platform": @"0", @"identifier": uid },
        @"source": @"App store",
    };
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kGuestURL]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 15;
    [NSURLProtocol setProperty:@YES forKey:@"LKHandled" inRequest:req];
    NSDictionary *hdrs = @{
        @"User-Agent": [NSString stringWithFormat:@"LoveKeyboard/%@ (com.fd.lovekeyboard; build:55; iOS 18.5.0) Alamofire/5.10.2", kAppNum],
        @"device-name": @"iPhone",
        @"device-band": model,
        @"device-version": @"18.5",
        @"device-type": @"1",
        @"channel": @"1",
        @"app-version": kAppVersion,
        @"app-locale": @"zh-Hans",
        @"app-lan": @"zh",
        @"timestamp": [NSString stringWithFormat:@"%lld", ts],
        @"sign": sign,
        @"authorization": @"",
        @"accept": @"*/*",
        @"content-type": @"application/json;charset=utf-8",
        @"accept-encoding": @"identity",
    };
    for (NSString *k in hdrs) [req setValue:hdrs[k] forHTTPHeaderField:k];
    req.HTTPBody = bodyData;

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.protocolClasses = @[];   // 避免再次进入 LKURLProtocol
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    LKLog(@"[注册] 发起 guest 注册 model=%@ installId=%@", model, installId);
    LKLog(@"[注册] sign=%@", sign);
    NSURLSessionDataTask *task = [session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]]
                             ? ((NSHTTPURLResponse *)resp).statusCode : -1;
            NSString *token = nil;
            if (err) {
                LKLog(@"[注册] !! 网络错误 status=%ld err=%@", (long)code, err.localizedDescription);
            } else {
                NSString *bodyStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                LKLog(@"[注册] status=%ld bytes=%lu", (long)code, (unsigned long)data.length);
                LKLog(@"[注册] 响应体前 300 字 = %@",
                      bodyStr.length > 300 ? [bodyStr substringToIndex:300] : (bodyStr ?: @"(空)"));
                id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([obj isKindOfClass:[NSDictionary class]]) {
                    LKLog(@"[注册] 外层 code=%@ msg=%@", obj[@"code"] ?: @"-", obj[@"message"] ?: @"-");
                    id wrapped = obj[@"data"];
                    if ([wrapped isKindOfClass:[NSString class]]) {
                        // 脚本逻辑：先 AES 解密外层 data，再取 access_token
                        NSString *plain = [LKCrypto aesDecrypt:wrapped key:kAESKey];
                        LKLog(@"[注册] AES 解密 %@ (长度=%lu)", plain ? @"成功" : @"失败", (unsigned long)plain.length);
                        if (plain) {
                            LKLog(@"[注册] 解密后 = %@",
                                  plain.length > 300 ? [plain substringToIndex:300] : plain);
                            id inner = [NSJSONSerialization JSONObjectWithData:
                                [plain dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
                            if ([inner isKindOfClass:[NSDictionary class]]) token = inner[@"access_token"];
                        }
                    } else if ([wrapped isKindOfClass:[NSDictionary class]]) {
                        token = wrapped[@"access_token"];
                    }
                }
            }
            LKLog(@"[注册] token = %@", token.length ? [NSString stringWithFormat:@"%@...(len=%lu)",
                  [token substringToIndex:MIN(12, token.length)], (unsigned long)token.length] : @"(nil)");
            if (completion) completion(token);
        }];
    [task resume];
}

@end
