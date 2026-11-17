#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface DevicePerformance : NSObject
+ (BOOL)streamPairingPath:(NSString *)path host:(NSString *)host port:(uint16_t)port
           mapTunnelPort:(uint16_t (^)(uint16_t))mapTunnelPort
             isCancelled:(BOOL (^)(void))isCancelled
                  sample:(void (^)(NSData *))sample error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(stream(pairingPath:host:port:mapTunnelPort:isCancelled:sample:));
@end
NS_ASSUME_NONNULL_END
