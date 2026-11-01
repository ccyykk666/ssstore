#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface DeviceScanner : NSObject
+ (nullable NSData *)scanPairingPath:(NSString *)path
                               host:(NSString *)host
                               port:(uint16_t)port
                     iconsDirectory:(NSString *)iconsDirectory
                   ignoredBundleIDs:(NSArray<NSString *> *)ignoredBundleIDs
                          inventory:(void (^)(NSData *data))inventory
                           progress:(void (^)(NSString *message))progress
                            warning:(void (^)(NSString *message))warning
                              error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(scan(pairingPath:host:port:iconsDirectory:ignoredBundleIDs:inventory:progress:warning:));
@end
NS_ASSUME_NONNULL_END

