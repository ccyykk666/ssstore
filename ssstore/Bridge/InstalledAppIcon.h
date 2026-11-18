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

typedef NS_OPTIONS(NSUInteger, SSIconCapabilities) {
    SSIconCapabilitiesDark = 1 << 0,
    SSIconCapabilitiesTinted = 1 << 1,
    SSIconCapabilitiesTintedDark = 1 << 2,
    SSIconCapabilitiesTintedLight = 1 << 3,
};

@interface InstalledAppIcon : NSObject
+ (SSIconCapabilities)capabilitiesForBundleIdentifier:(NSString *)bundleID resourceName:(nullable NSString *)resourceName
    NS_SWIFT_NAME(capabilities(bundleID:resourceName:));
+ (BOOL)isUsablePNG:(NSData *)data NS_SWIFT_NAME(isUsablePNG(_:));
+ (nullable NSData *)PNGForBundleIdentifier:(NSString *)bundleID
                               resourceName:(nullable NSString *)resourceName
                                 appearance:(SSIconAppearance)appearance tint:(nullable UIColor *)tint
                                      error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(readPNG(bundleID:resourceName:appearance:tint:));
@end
NS_ASSUME_NONNULL_END
