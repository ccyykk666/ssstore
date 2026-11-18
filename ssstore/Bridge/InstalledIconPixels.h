#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <stdbool.h>
#include <stdlib.h>

enum { SSIconSampleSide = 64 };
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

// Other system placeholder probes can return an empty rounded tile,
// so matching those bitmaps misses the unmasked white icon template.
static inline bool SSIconHasPlaceholderGrid(const SSIconPixels *sample) {
    // Normalized positions of the square and the straight guides.
    const double guides[] = {0.0625, 0.3125, 0.5, 0.6875, 0.9375};
    unsigned opaque = 0, paper = 0, lines = 0, offGrid = 0, colored = 0, darkInk = 0;
    unsigned axes = 0, forward = 0, backward = 0, middle = 0, outer = 0;
    for (unsigned y = 0; y < SSIconSampleSide; y++) {
        for (unsigned x = 0; x < SSIconSampleSide; x++) {
            const uint8_t *pixel = &sample->rgba[(y * SSIconSampleSide + x) * 4];
            if (pixel[3] < 250) continue;
            opaque++;
            if (abs(pixel[0] - pixel[1]) > 8 || abs(pixel[1] - pixel[2]) > 8) colored++;
            if (pixel[1] < 120) darkInk++;
            if (pixel[1] >= 240) { paper++; continue; }
            lines++;
            double u = (x + 0.5) / SSIconSampleSide, v = (y + 0.5) / SSIconSampleSide;
            bool axis = false;
            for (unsigned i = 0; i < sizeof(guides) / sizeof(guides[0]); i++) {
                axis |= fabs(u - guides[i]) < 0.026 || fabs(v - guides[i]) < 0.026;
            }
            bool diagonalA = fabs(u - v) < 0.036;
            bool diagonalB = fabs(u + v - 1) < 0.036;
            double radius = hypot(u - 0.5, v - 0.5);
            bool ringA = fabs(radius - 0.265625) < 0.026;
            bool ringB = fabs(radius - 0.4375) < 0.026;
            bool inner = fabs(radius - 0.1875) < 0.026;
            // Count independent evidence so a line crossing a ring does not establish the ring.
            offGrid += !(axis || diagonalA || diagonalB || ringA || ringB || inner);
            axes += axis && !diagonalA && !diagonalB && !ringA && !ringB && !inner;
            forward += diagonalA && !axis && !diagonalB && !ringA && !ringB && !inner;
            backward += diagonalB && !axis && !diagonalA && !ringA && !ringB && !inner;
            middle += ringA && !axis && !diagonalA && !diagonalB;
            outer += ringB && !axis && !diagonalA && !diagonalB;
        }
    }
    return opaque * 10 >= 9 * SSIconSampleSide * SSIconSampleSide && paper * 2 > opaque &&
        colored * 100 < opaque && darkInk * 100 < opaque && offGrid * 20 <= lines &&
        axes >= 24 && forward >= 12 && backward >= 12 && middle >= 12 && outer >= 12;
}
