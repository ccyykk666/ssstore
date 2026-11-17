#import <Foundation/Foundation.h>
#import "LocalPerformance.h"
#include <unistd.h>

static void Check(BOOL value, NSString *message) {
    if (!value) { fprintf(stderr, "%s\n", message.UTF8String); exit(1); }
}
int main(void) {
    @autoreleasepool {
        NSDictionary *first = [LocalPerformance snapshotForBundleID:@""];
        Check([NSJSONSerialization isValidJSONObject:first], @"Invalid device snapshot");
        Check([first[@"memoryTotal"] unsignedLongLongValue] > 0, @"Missing physical memory");
        Check([first[@"issues"] isKindOfClass:NSDictionary.class], @"Missing availability results");
        NSString *own = NSBundle.mainBundle.bundleIdentifier;
        Check(own.length > 0, @"Fixture bundle identity missing");
        NSDictionary *selfValue = [LocalPerformance snapshotForBundleID:own];
        Check([selfValue[@"pid"] intValue] == getpid(), @"Wrong own-process PID");
        Check([selfValue[@"processMemory"] unsignedLongLongValue] > 0, @"Own-process memory unavailable");
        NSDictionary *unknown = [LocalPerformance snapshotForBundleID:@"dev.personal.nonexistent.performance.test"];
        Check(unknown[@"processMemory"] == nil && unknown[@"processCPUTime"] == nil, @"Unknown app used own-process metrics");
        Check(unknown[@"issues"][@"application"] != nil, @"Missing denied/unavailable app explanation");
        for (int i = 0; i < 50; i++) {
            NSDictionary *value = [LocalPerformance snapshotForBundleID:own];
            Check([NSJSONSerialization isValidJSONObject:value], @"Invalid repeated snapshot");
        }
        puts("Local performance: real host snapshot, own process, unavailable-app isolation and repeated finite reads passed");
    }
    return 0;
}
