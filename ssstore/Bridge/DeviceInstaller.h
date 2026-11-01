#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface DeviceInstaller : NSObject
+ (BOOL)installPairingPath:(NSString *)pairingPath host:(NSString *)host port:(uint16_t)port
              packagePath:(NSString *)packagePath bundleID:(NSString *)bundleID
                 progress:(void (^)(NSString *stage, double fraction))progress
                    error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(install(pairingPath:host:port:packagePath:bundleID:progress:));
@end
NS_ASSUME_NONNULL_END
