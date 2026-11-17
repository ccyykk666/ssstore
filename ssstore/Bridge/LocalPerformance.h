#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface LocalPerformance : NSObject
+ (NSDictionary<NSString *, id> *)snapshotForBundleID:(NSString *)bundleID NS_SWIFT_NAME(snapshot(bundleID:));
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)applications;
+ (NSDictionary<NSString *, id> *)sensorsSnapshot;
@end
NS_ASSUME_NONNULL_END
