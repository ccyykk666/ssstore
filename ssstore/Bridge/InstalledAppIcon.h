#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, SSIconAppearance) {
    SSIconAppearanceStandard,
    SSIconAppearanceDark,
    SSIconAppearanceTinted,
    SSIconAppearanceTintedDark,
    SSIconAppearanceTintedLight,
};

@interface InstalledAppIcon : NSObject
+ (nullable NSData *)PNGForBundleIdentifier:(NSString *)bundleID
                               resourceName:(nullable NSString *)resourceName
                                 appearance:(SSIconAppearance)appearance tint:(nullable UIColor *)tint
                                      error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(readPNG(bundleID:resourceName:appearance:tint:));
@end
NS_ASSUME_NONNULL_END
