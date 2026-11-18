#import <Foundation/Foundation.h>
#import "DevicePlist.h"
#import "InstalledIconPixels.h"
#include <math.h>
#include <string.h>

static void Check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "%s\n", message.UTF8String); exit(1); }
}
static CGImageRef IconFixture(BOOL visible, BOOL artwork, size_t size) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, size, size, 8, size * 4, space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    Check(context != NULL, @"Could not create an icon fixture");
    CGContextClearRect(context, CGRectMake(0, 0, size, size));
    if (visible) {
        CGContextSetRGBFillColor(context, .52, .52, .52, 1);
        CGContextFillRect(context, CGRectMake(0, 0, size, size));
        if (artwork) {
            CGContextSetRGBFillColor(context, 0, 0.4, 1, 1);
            CGContextFillRect(context, CGRectMake(size / 4, size / 4, size / 2, size / 2));
        }
    }
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return image;
}

static CGImageRef IconGridFixture(size_t size, BOOL artwork) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, size, size, 8, size * 4, space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    Check(context != NULL, @"Could not create an icon grid fixture");
    CGContextScaleCTM(context, size, size);
    CGContextSetRGBFillColor(context, 1, 1, 1, 1);
    CGContextFillRect(context, CGRectMake(0, 0, 1, 1));
    CGContextSetRGBStrokeColor(context, .65, .65, .65, 1);
    CGContextSetLineWidth(context, .007);
    CGContextAddRect(context, CGRectMake(.0625, .0625, .875, .875));
    for (unsigned i = 0; i < 3; i++) {
        double guide = .3125 + .1875 * i;
        CGContextMoveToPoint(context, guide, 0);
        CGContextAddLineToPoint(context, guide, 1);
        CGContextMoveToPoint(context, 0, guide);
        CGContextAddLineToPoint(context, 1, guide);
    }
    CGContextMoveToPoint(context, .0625, .0625);
    CGContextAddLineToPoint(context, .9375, .9375);
    CGContextMoveToPoint(context, .0625, .9375);
    CGContextAddLineToPoint(context, .9375, .0625);
    const double radii[] = {.1875, .265625, .4375};
    for (unsigned i = 0; i < sizeof(radii) / sizeof(radii[0]); i++) {
        double radius = radii[i];
        CGContextAddEllipseInRect(context, CGRectMake(.5 - radius, .5 - radius, 2 * radius, 2 * radius));
    }
    CGContextStrokePath(context);
    if (artwork) {
        CGContextSetRGBFillColor(context, .13, .13, .13, 1);
        CGContextFillEllipseInRect(context, CGRectMake(.18, .33, .64, .36));
    }
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return image;
}

static void CheckIconPixels(void) {
    CGImageRef invisible = IconFixture(NO, NO, 60);
    CGImageRef placeholder = IconFixture(YES, NO, 60);
    CGImageRef scaled = IconFixture(YES, NO, 180);
    CGImageRef artwork = IconFixture(YES, YES, 60);
    SSIconPixels pixels;
    Check(!SSGetIconPixels(invisible, &pixels), @"A transparent PNG is not artwork");
    Check(SSGetIconPixels(placeholder, &pixels), @"The placeholder fixture must have visible pixels");
    Check(SSIconMatchesPixels(pixels, scaled), @"The same placeholder at a different size must match");
    Check(!SSIconMatchesPixels(pixels, artwork), @"An icon with artwork must differ from the placeholder");
    for (size_t size = 180; size <= 540; size *= 3) {
        CGImageRef grid = IconGridFixture(size, NO);
        CGImageRef drawn = IconGridFixture(size, YES);
        Check(SSGetIconPixels(grid, &pixels) && SSIconHasPlaceholderGrid(&pixels),
              @"Reject a white app-icon guide grid even when the system placeholder probe has a different image");
        Check(SSGetIconPixels(drawn, &pixels) && !SSIconHasPlaceholderGrid(&pixels),
              @"Keep a grayscale icon with distinct artwork");
        CGImageRelease(drawn);
        CGImageRelease(grid);
    }
    CGImageRelease(invisible);
    CGImageRelease(placeholder);
    CGImageRelease(scaled);
    CGImageRelease(artwork);
    puts("Installed icons: transparent, blank tile, white grid, and valid artwork fixtures passed");
}

static plist_t Fixture(void) {
    plist_t node = plist_new_dict();
    plist_dict_set_item(node, "UID", plist_new_uid(42));
    plist_dict_set_item(node, "counter", plist_new_uint(UINT64_MAX));
    plist_dict_set_item(node, "cpu", plist_new_real(NAN));
    plist_dict_set_item(node, "name", plist_new_string("before\001after"));
    const char bytes[] = {1, 0, 2, 0, 3};
    plist_dict_set_item(node, "data", plist_new_data(bytes, sizeof(bytes)));
    plist_t values = plist_new_array();
    plist_array_append_item(values, plist_new_uid(99));
    plist_array_append_item(values, plist_new_real(12.5));
    plist_dict_set_item(node, "Processes", values);
    return node;
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        plist_t node = Fixture();
        if (argc > 1 && strcmp(argv[1], "--legacy-empty-array") == 0) {
            volatile uintptr_t sentinel = _Alignof(plist_t);
            plist_t *empty = (plist_t *)sentinel;
            // Reproduce the previous C cleanup for Rust's empty Box<[plist_t]>.
            idevice_plist_array_free(empty, 0);
            free(empty);
            return 0;
        }
        if (argc > 1 && strcmp(argv[1], "--legacy-xml") == 0) {
            char *xml = NULL; uint32_t size = 0;
            // Deliberately isolate the old abort in a child process. This is the
            // exact FFI boundary identified by the build-76 crash's call sites.
            plist_to_xml(node, &xml, &size);
            return 0;
        }
        for (NSUInteger i = 0; i < 200; i++) {
            NSDictionary *value = SSDevicePlistValue(node);
            Check([value isKindOfClass:NSDictionary.class], @"Expected dictionary");
            Check(value[@"UID"] != nil, @"Binary UID must survive decoding");
            Check([value[@"counter"] unsignedLongLongValue] == UINT64_MAX, @"Unsigned counter changed");
            Check(isnan([value[@"cpu"] doubleValue]), @"NaN must reach the existing JSON normalization");
            Check([value[@"name"] isEqualToString:@"before\001after"], @"Non-XML character changed");
            Check([value[@"data"] isEqualToData:[NSData dataWithBytes:"\001\0\002\0\003" length:5]], @"Embedded NUL data changed");
            Check([value[@"Processes"] count] == 2, @"Nested array changed");
        }
        Check(SSDevicePlistValue(NULL) == NSNull.null, @"Missing node must remain null");
        for (NSUInteger i = 0; i < 200; i++) {
            SSDevicePlistArrayFree(NULL, 0);
            SSDevicePlistArrayFree((plist_t *)(uintptr_t)_Alignof(plist_t), 0);
            SSDeviceArrayStorageFree((void *)(uintptr_t)_Alignof(char *), 0);
            plist_t *single = malloc(sizeof(plist_t));
            single[0] = plist_new_dict();
            SSDevicePlistArrayFree(single, 1);
        }
        plist_free(node);
        puts("Device plist: binary conversion and repeated null/empty-sentinel/nonempty-array cleanup passed");
        CheckIconPixels();
    }
    return 0;
}
