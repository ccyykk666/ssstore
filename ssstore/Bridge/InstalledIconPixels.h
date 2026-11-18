#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

enum { SSIconSampleSide = 24 };
typedef struct {
    uint8_t rgba[SSIconSampleSide * SSIconSampleSide * 4];
} SSIconPixels;

static inline bool SSGetIconPixels(CGImageRef image, SSIconPixels *sample) {
    if (!image || CGImageGetWidth(image) < 16 || CGImageGetHeight(image) < 16) return false;
    *sample = (SSIconPixels){0};
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(sample->rgba, SSIconSampleSide, SSIconSampleSide, 8,
        SSIconSampleSide * 4, color, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(color);
    if (!context) return false;
    CGContextDrawImage(context, CGRectMake(0, 0, SSIconSampleSide, SSIconSampleSide), image);
    CGContextRelease(context);
    for (size_t i = 3; i < sizeof(sample->rgba); i += 4) {
        if (sample->rgba[i] >= 32) return true;
    }
    return false;
}

static inline bool SSIconMatchesPixels(SSIconPixels candidate, CGImageRef reference) {
    SSIconPixels other;
    if (!SSGetIconPixels(reference, &other)) return false;
    for (size_t i = 0; i < sizeof(candidate.rgba); i++) {
        int difference = (int)candidate.rgba[i] - (int)other.rgba[i];
        if (difference < -3 || difference > 3) return false;
    }
    return true;
}
