#import "LKCrypto.h"
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonDigest.h>

@implementation LKCrypto

+ (NSData *)aesECB:(NSData *)data keyData:(NSData *)key encrypt:(BOOL)encrypt {
    if (data.length == 0 || key.length != kCCKeySizeAES128) return nil;
    size_t bufSize = data.length + kCCBlockSizeAES128;
    void *buf = malloc(bufSize);
    if (!buf) return nil;
    size_t moved = 0;
    CCCryptorStatus st = CCCrypt(encrypt ? kCCEncrypt : kCCDecrypt,
                                 kCCAlgorithmAES,
                                 kCCOptionPKCS7Padding | kCCOptionECBMode,
                                 key.bytes, kCCKeySizeAES128, NULL,
                                 data.bytes, data.length,
                                 buf, bufSize, &moved);
    if (st != kCCSuccess) { free(buf); return nil; }
    NSData *out = [NSData dataWithBytes:buf length:moved];
    free(buf);
    return out;
}

+ (NSString *)aesEncrypt:(NSString *)plain key:(NSString *)key {
    if (!plain) return nil;
    NSData *kd = [key dataUsingEncoding:NSUTF8StringEncoding];
    NSData *pd = [plain dataUsingEncoding:NSUTF8StringEncoding];
    NSData *ct = [self aesECB:pd keyData:kd encrypt:YES];
    return ct ? [ct base64EncodedStringWithOptions:0] : nil;
}

+ (NSString *)aesDecrypt:(NSString *)b64 key:(NSString *)key {
    if (!b64) return nil;
    NSData *kd = [key dataUsingEncoding:NSUTF8StringEncoding];
    NSData *cd = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
    if (!cd) return nil;
    NSData *pt = [self aesECB:cd keyData:kd encrypt:NO];
    if (!pt) return nil;
    return [[NSString alloc] initWithData:pt encoding:NSUTF8StringEncoding];
}

+ (NSString *)md5:(NSString *)input {
    if (!input) return nil;
    const char *c = [input UTF8String];
    unsigned char d[CC_MD5_DIGEST_LENGTH];
    CC_MD5(c, (CC_LONG)strlen(c), d);
    NSMutableString *s = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", d[i]];
    return s;
}

@end
