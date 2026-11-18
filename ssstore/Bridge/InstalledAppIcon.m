#import "InstalledAppIcon.h"
#import "InstalledIconPixels.h"
#import <dlfcn.h>

// These declarations are used only to type-check calls on runtime-resolved classes.
@interface UIImage (SSInstalledAppIcon)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleID format:(int)format scale:(CGFloat)scale;
@end

@interface SSSystemIconImage : NSObject
- (CGImageRef)CGImage NS_RETURNS_INNER_POINTER;
@property (readonly) bool placeholder;
@end

@interface SSSystemIconDescriptor : NSObject
- (instancetype)initWithSize:(CGSize)size scale:(CGFloat)scale;
@property (copy) NSString *preferedResourceName;
@property bool shouldApplyMask;
@end

@interface SSSystemIconResource : NSObject
@property (readonly) NSString *imageName;
- (bool)hasDarkResource;
- (bool)hasTintableResource;
- (SSSystemIconImage *)imageForSize:(CGSize)size scale:(CGFloat)scale;
@end

@interface SSSystemIconProvider : NSObject
- (SSSystemIconResource *)iconResource;
- (SSSystemIconResource *)resourceNamed:(NSString *)name;
@end

@interface SSSystemApplicationIcon : NSObject
+ (instancetype)genericApplicationIcon;
+ (instancetype)placeholderIcon;
- (instancetype)initWithBundleIdentifier:(NSString *)bundleID;
- (SSSystemIconProvider *)makeResourceProvider;
- (SSSystemIconImage *)prepareImageForDescriptor:(SSSystemIconDescriptor *)descriptor;
@end

@interface SSSystemIconAppearance : NSObject
+ (instancetype)darkAppearance;
+ (instancetype)tintedAppearanceWithTintColor:(UIColor *)tint;
+ (instancetype)tintedDarkAppearanceWithTintColor:(UIColor *)tint;
+ (instancetype)tintedLightAppearanceWithTintColor:(UIColor *)tint;
@end

typedef void (*SSApplyIconAppearance)(id descriptor, id appearance, uint64_t options);

static NSString *const SSMissingIconBundleID = @"invalid.ssstore.icon-placeholder";

static void SSLoadIconServices(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/IconServices.framework/IconServices", RTLD_LAZY | RTLD_LOCAL);
    });
}

static SSApplyIconAppearance SSLoadAppearanceModifier(void) {
    static SSApplyIconAppearance modifier;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *framework = dlopen("/System/Library/PrivateFrameworks/SpringBoardHome.framework/SpringBoardHome",
                                 RTLD_LAZY | RTLD_LOCAL);
        if (framework) modifier = (SSApplyIconAppearance)dlsym(framework, "SBHModifyImageDescriptorWithImageAppearance");
    });
    return modifier;
}

static SSSystemApplicationIcon *SSBundleIcon(NSString *bundleID) {
    SSLoadIconServices();
    Class iconClass = NSClassFromString(@"ISBundleIdentifierIcon");
    if (![iconClass instancesRespondToSelector:@selector(initWithBundleIdentifier:)]) return nil;
    return [[iconClass alloc] initWithBundleIdentifier:bundleID];
}

static SSSystemIconDescriptor *SSDescriptor(NSString *resourceName) {
    Class descriptorClass = NSClassFromString(@"ISImageDescriptor");
    if (![descriptorClass instancesRespondToSelector:@selector(initWithSize:scale:)]) return nil;
    SSSystemIconDescriptor *descriptor = [[descriptorClass alloc] initWithSize:CGSizeMake(60, 60) scale:3];
    if (resourceName.length) {
        if (![descriptor respondsToSelector:@selector(setPreferedResourceName:)]) return nil;
        descriptor.preferedResourceName = resourceName;
    }
    if ([descriptor respondsToSelector:@selector(setShouldApplyMask:)]) descriptor.shouldApplyMask = YES;
    return descriptor;
}

static SSSystemIconResource *SSIconResource(SSSystemApplicationIcon *icon, NSString *resourceName) {
    if (![icon respondsToSelector:@selector(makeResourceProvider)]) return nil;
    SSSystemIconProvider *provider = [icon makeResourceProvider];
    if (resourceName.length && [provider respondsToSelector:@selector(resourceNamed:)]) {
        SSSystemIconResource *named = [provider resourceNamed:resourceName];
        if (named) return named;
    }
    if (![provider respondsToSelector:@selector(iconResource)]) return nil;
    SSSystemIconResource *primary = [provider iconResource];
    if (!resourceName.length) return primary;
    return [primary respondsToSelector:@selector(imageName)] && [primary.imageName isEqualToString:resourceName] ? primary : nil;
}

static SSIconCapabilities SSResourceCapabilities(SSSystemIconResource *resource) {
    if (!SSLoadAppearanceModifier()) return 0;
    Class style = NSClassFromString(@"SBHIconImageAppearance");
    SSIconCapabilities result = 0;
    if ([resource respondsToSelector:@selector(hasDarkResource)] && [resource hasDarkResource] &&
        [style respondsToSelector:@selector(darkAppearance)]) {
        result |= SSIconCapabilitiesDark;
    }
    // A tintable rendition is the supplied artwork shared by the two tint modes.
    // IconServices can also synthesize tinting for ordinary icons. Do not count that.
    if ([resource respondsToSelector:@selector(hasTintableResource)] && [resource hasTintableResource]) {
        if ([style respondsToSelector:@selector(tintedAppearanceWithTintColor:)]) result |= SSIconCapabilitiesTinted;
        if ([style respondsToSelector:@selector(tintedDarkAppearanceWithTintColor:)]) result |= SSIconCapabilitiesTintedDark;
        if ([style respondsToSelector:@selector(tintedLightAppearanceWithTintColor:)]) result |= SSIconCapabilitiesTintedLight;
    }
    return result;
}

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

static SSSystemIconImage *SSPrepareIcon(SSSystemApplicationIcon *icon, SSSystemIconDescriptor *descriptor) {
    if (!descriptor || ![icon respondsToSelector:@selector(prepareImageForDescriptor:)]) return nil;
    return [icon prepareImageForDescriptor:descriptor];
}

static CGImageRef SSSystemIconCGImage(SSSystemIconImage *image) {
    return [image respondsToSelector:@selector(CGImage)] ? image.CGImage : NULL;
}

static UIImage *SSUIKitIcon(NSString *bundleID) {
    if (![UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) return nil;
    return [UIImage _applicationIconImageForBundleIdentifier:bundleID format:2 scale:3];
}

static BOOL SSIsIconArtwork(CGImageRef image, SSSystemIconDescriptor *descriptor) {
    SSIconPixels pixels;
    if (!SSGetIconPixels(image, &pixels)) return NO;
    if (SSIconMatchesPixels(pixels, SSUIKitIcon(SSMissingIconBundleID).CGImage)) return NO;
    SSSystemIconImage *missing = SSPrepareIcon(SSBundleIcon(SSMissingIconBundleID), descriptor);
    if (SSIconMatchesPixels(pixels, SSSystemIconCGImage(missing))) return NO;
    Class iconClass = NSClassFromString(@"ISIcon");
    if ([iconClass respondsToSelector:@selector(genericApplicationIcon)]) {
        SSSystemIconImage *generic = SSPrepareIcon([iconClass genericApplicationIcon], descriptor);
        if (SSIconMatchesPixels(pixels, SSSystemIconCGImage(generic))) return NO;
    }
    if ([iconClass respondsToSelector:@selector(placeholderIcon)]) {
        SSSystemIconImage *placeholder = SSPrepareIcon([iconClass placeholderIcon], descriptor);
        if (SSIconMatchesPixels(pixels, SSSystemIconCGImage(placeholder))) return NO;
    }
    return YES;
}

static NSData *SSSystemIconPNG(SSSystemIconImage *image, SSSystemIconDescriptor *descriptor) {
    if ([image respondsToSelector:@selector(placeholder)] && image.placeholder) return nil;
    CGImageRef cgImage = SSSystemIconCGImage(image);
    return SSIsIconArtwork(cgImage, descriptor) ? UIImagePNGRepresentation([UIImage imageWithCGImage:cgImage]) : nil;
}

@implementation InstalledAppIcon
+ (SSIconCapabilities)capabilitiesForBundleIdentifier:(NSString *)bundleID resourceName:(NSString *)resourceName {
    @try {
        return SSResourceCapabilities(SSIconResource(SSBundleIcon(bundleID), resourceName));
    } @catch (__unused NSException *exception) {
        return 0;
    }
}

+ (BOOL)isUsablePNG:(NSData *)data {
    @try {
        SSLoadIconServices();
        UIImage *image = [UIImage imageWithData:data];
        return SSIsIconArtwork(image.CGImage, SSDescriptor(nil));
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

+ (NSData *)PNGForBundleIdentifier:(NSString *)bundleID resourceName:(NSString *)resourceName
                        appearance:(SSIconAppearance)appearance tint:(UIColor *)tint error:(NSError **)error {
    NSString *failure = @"本机系统没有返回可用的图标内容。";
    @try {
        SSSystemApplicationIcon *icon = SSBundleIcon(bundleID);
        SSSystemIconDescriptor *descriptor = SSDescriptor(resourceName);
        if (appearance == SSIconAppearanceStandard) {
            NSData *png = SSSystemIconPNG(SSPrepareIcon(icon, descriptor), descriptor);
            if (png) return png;
            SSSystemIconResource *resource = SSIconResource(icon, resourceName);
            if ([resource respondsToSelector:@selector(imageForSize:scale:)]) {
                png = SSSystemIconPNG([resource imageForSize:CGSizeMake(60, 60) scale:3], descriptor);
                if (png) return png;
            }
        } else if (appearance >= SSIconAppearanceDark && appearance <= SSIconAppearanceTintedLight) {
            // The order of capabilities matches the non-default appearance enum values.
            SSIconCapabilities capabilities = SSResourceCapabilities(SSIconResource(icon, resourceName));
            SSIconCapabilities requested = (SSIconCapabilities)(1UL << (appearance - 1));
            SSApplyIconAppearance modifier = SSLoadAppearanceModifier();
            SSSystemIconAppearance *style = SSMakeAppearance(NSClassFromString(@"SBHIconImageAppearance"), appearance, tint);
            if ((capabilities & requested) && modifier && style && descriptor) {
                modifier(descriptor, style, 0);
                NSData *png = SSSystemIconPNG(SSPrepareIcon(icon, descriptor), descriptor);
                if (png) return png;
            } else failure = @"未能确认此应用提供了所选外观的图标资源。";
        }
    } @catch (NSException *exception) {
        failure = [NSString stringWithFormat:@"本机图标服务读取失败（%@）。", exception.name];
    }
    if (appearance == SSIconAppearanceStandard) {
        // UIKit resolves the registered app icon by bundle ID independently of
        // the named asset. The other path may return a placeholder or throw.
        @try {
            UIImage *image = SSUIKitIcon(bundleID);
            if (SSIsIconArtwork(image.CGImage, SSDescriptor(nil))) {
                NSData *png = UIImagePNGRepresentation(image);
                if (png) return png;
            }
        } @catch (NSException *exception) {
            failure = [NSString stringWithFormat:@"本机图标服务读取失败（%@）。", exception.name];
        }
    }
    if (error) *error = [NSError errorWithDomain:@"ssstore.InstalledAppIcon" code:1
                                       userInfo:@{NSLocalizedDescriptionKey:failure}];
    return nil;
}
@end
