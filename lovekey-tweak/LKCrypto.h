#import <Foundation/Foundation.h>

@interface LKCrypto : NSObject
// AES-128-ECB / PKCS7，返回 Base64
+ (NSString *)aesEncrypt:(NSString *)plain key:(NSString *)key;
// 输入 Base64 密文，返回明文
+ (NSString *)aesDecrypt:(NSString *)b64 key:(NSString *)key;
// 小写 hex MD5
+ (NSString *)md5:(NSString *)input;
@end
