#import "InstalledAppIcon.h"
#import <dlfcn.h>
#include <stdbool.h>

// These declarations are used only to type-check calls on runtime-resolved classes.
@interface UIImage (SSInstalledAppIcon)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleID format:(int)format scale:(CGFloat)scale;
@end

@interface SSSystemIconImage : NSObject
@property (readonly) CGImageRef CGImage;
@property (readonly) bool placeholder;
@end

@interface SSSystemIconDescriptor : NSObject
- (instancetype)initWithSize:(CGSize)size scale:(CGFloat)scale;
@property (copy) NSString *preferedResourceName;
@property bool shouldApplyMask;
@end

@interface SSSystemApplicationIcon : NSObject
- (instancetype)initWithBundleIdentifier:(NSString *)bundleID;
- (SSSystemIconImage *)prepareImageForDescriptor:(SSSystemIconDescriptor *)descriptor;
@end

@interface SSSystemIconAppearance : NSObject
+ (instancetype)darkAppearance;
+ (instancetype)tintedAppearanceWithTintColor:(UIColor *)tint;
+ (instancetype)tintedDarkAppearanceWithTintColor:(UIColor *)tint;
+ (instancetype)tintedLightAppearanceWithTintColor:(UIColor *)tint;
@end

typedef void (*SSApplyIconAppearance)(id descriptor, id appearance, uint64_t options);

static SSSystemIconAppearance *SSMakeAppearance(Class appearanceClass, SSIconAppearance appearance, UIColor *tint) {
    switch (appearance) {
        case SSIconAppearanceDark:
            return [appearanceClass respondsToSelector:@selector(darkAppearance)] ? [appearanceClass darkAppearance] : nil;
        case SSIconAppearanceTinted:
            return tint && [appearanceClass respondsToSelector:@selector(tintedAppearanceWithTintColor:)]
                ? [appearanceClass tintedAppearanceWithTintColor:tint] : nil;
        case SSIconAppearanceTintedDark:
            return tint && [appearanceClass respondsToSelector:@selector(tintedDarkAppearanceWithTintColor:)]
                ? [appearanceClass tintedDarkAppearanceWithTintColor:tint] : nil;
        case SSIconAppearanceTintedLight:
            return tint && [appearanceClass respondsToSelector:@selector(tintedLightAppearanceWithTintColor:)]
                ? [appearanceClass tintedLightAppearanceWithTintColor:tint] : nil;
        case SSIconAppearanceStandard:
            return nil;
    }
    return nil;
}

static NSData *SSUIKitIconPNG(NSString *bundleID) {
    if (![UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) return nil;
    // Use the same format for both requests. UIKit may return a generic icon
    // instead of nil when the app cannot be resolved or its image is restricted.
    UIImage *icon = [UIImage _applicationIconImageForBundleIdentifier:bundleID format:2 scale:3];
    if (!icon.CGImage) return nil;
    UIImage *placeholder = [UIImage _applicationIconImageForBundleIdentifier:@"invalid.ssstore.icon-placeholder" format:2 scale:3];
    NSData *png = UIImagePNGRepresentation(icon);
    NSData *generic = placeholder.CGImage ? UIImagePNGRepresentation(placeholder) : nil;
    return [png isEqualToData:generic] ? nil : png;
}

@implementation InstalledAppIcon
+ (NSData *)PNGForBundleIdentifier:(NSString *)bundleID resourceName:(NSString *)resourceName
                        appearance:(SSIconAppearance)appearance tint:(UIColor *)tint error:(NSError **)error {
    NSString *failure = appearance == SSIconAppearanceStandard
        ? @"系统没有返回此已安装应用的图标。"
        : @"当前系统未提供这种图标外观的读取接口。";
    @try {
        static dispatch_once_t iconOnce;
        dispatch_once(&iconOnce, ^{
            dlopen("/System/Library/PrivateFrameworks/IconServices.framework/IconServices", RTLD_LAZY | RTLD_LOCAL);
        });
        Class iconClass = NSClassFromString(@"ISBundleIdentifierIcon");
        Class descriptorClass = NSClassFromString(@"ISImageDescriptor");
        if ([iconClass instancesRespondToSelector:@selector(initWithBundleIdentifier:)] &&
            [iconClass instancesRespondToSelector:@selector(prepareImageForDescriptor:)] &&
            [descriptorClass instancesRespondToSelector:@selector(initWithSize:scale:)]) {
            SSSystemApplicationIcon *icon = [[iconClass alloc] initWithBundleIdentifier:bundleID];
            SSSystemIconDescriptor *descriptor = [[descriptorClass alloc] initWithSize:CGSizeMake(60, 60) scale:3];
            BOOL ready = icon && descriptor;
            if (resourceName.length) {
                ready = ready && [descriptor respondsToSelector:@selector(setPreferedResourceName:)];
                if (ready) descriptor.preferedResourceName = resourceName;
            }
            if (appearance != SSIconAppearanceStandard) {
                static SSApplyIconAppearance applyAppearance;
                static dispatch_once_t appearanceOnce;
                dispatch_once(&appearanceOnce, ^{
                    void *framework = dlopen("/System/Library/PrivateFrameworks/SpringBoardHome.framework/SpringBoardHome",
                                             RTLD_LAZY | RTLD_LOCAL);
                    if (framework) applyAppearance = (SSApplyIconAppearance)dlsym(framework, "SBHModifyImageDescriptorWithImageAppearance");
                });
                SSSystemIconAppearance *style = SSMakeAppearance(NSClassFromString(@"SBHIconImageAppearance"), appearance, tint);
                if (ready && applyAppearance && style) {
                    applyAppearance(descriptor, style, 0);
                    failure = @"系统没有返回此应用的所选外观图标。";
                } else ready = NO;
            } else if ([descriptor respondsToSelector:@selector(setShouldApplyMask:)]) {
                descriptor.shouldApplyMask = YES;
            }
            if (ready) {
                SSSystemIconImage *image = [icon prepareImageForDescriptor:descriptor];
                if ([image respondsToSelector:@selector(CGImage)] &&
                    (![image respondsToSelector:@selector(placeholder)] || !image.placeholder) && image.CGImage) {
                    NSData *png = UIImagePNGRepresentation([UIImage imageWithCGImage:image.CGImage]);
                    if (png.length) return png;
                }
            }
        }
        if (appearance == SSIconAppearanceStandard && !resourceName.length) {
            NSData *png = SSUIKitIconPNG(bundleID);
            if (png.length) return png;
        }
    } @catch (NSException *exception) {
        failure = [NSString stringWithFormat:@"本机图标服务读取失败（%@）。", exception.name];
    }
    if (error) *error = [NSError errorWithDomain:@"ssstore.InstalledAppIcon" code:1
                                       userInfo:@{NSLocalizedDescriptionKey:failure}];
    return nil;
}
@end
