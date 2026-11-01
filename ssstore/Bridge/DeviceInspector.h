#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface DeviceInspector : NSObject
+ (nullable NSData *)runPairingPath:(NSString *)path host:(NSString *)host port:(uint16_t)port
                    remotePairing:(BOOL)remote operation:(NSString *)operation options:(NSDictionary *)options
                  outputDirectory:(NSString *)outputDirectory error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(run(pairingPath:host:port:remotePairing:operation:options:outputDirectory:));
@end
NS_ASSUME_NONNULL_END
