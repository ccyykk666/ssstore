#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Owns one host identity. Accept one connected socket on a worker thread.
@interface PairingHost : NSObject
@property(nonatomic, readonly) NSString *serviceName;
@property(nonatomic, readonly) NSDictionary<NSString *, NSData *> *txtRecords;
- (nullable instancetype)initWithName:(NSString *)name error:(NSError **)error;
- (nullable NSData *)acceptSocket:(int32_t)socket
                      pinHandler:(void (^)(NSString *pin))pinHandler
                           error:(NSError **)error
    NS_SWIFT_NAME(accept(socket:pinHandler:));
@end
NS_ASSUME_NONNULL_END
