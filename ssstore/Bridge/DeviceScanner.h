#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface DeviceScanner : NSObject
+ (nullable NSData *)scanPairingPath:(NSString *)path
                               host:(NSString *)host
                               port:(uint16_t)port
                      remotePairing:(BOOL)remotePairing
                     iconsDirectory:(NSString *)iconsDirectory
                          inventory:(void (^)(NSData *data))inventory
                           progress:(void (^)(NSString *message))progress
                              error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(scan(pairingPath:host:port:remotePairing:iconsDirectory:inventory:progress:));
@end
NS_ASSUME_NONNULL_END
