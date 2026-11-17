#import <Foundation/Foundation.h>
#import "LocalPerformance.h"
#import "LocalMetricParsing.h"
#include <unistd.h>

static void Check(BOOL value, NSString *message) {
    if (!value) { fprintf(stderr, "%s\n", message.UTF8String); exit(1); }
}
int main(void) {
    @autoreleasepool {
        NSDictionary *gpu = SSGPUMetrics(@{@"Device Utilization %":@0, @"Renderer Utilization %":@101, @"Tiler Utilization %":@YES, @"SerialNumber":@"not-exported"});
        Check([gpu[@"gpuPercent"] doubleValue] == 0 && gpu.count == 1, @"GPU invalid/boolean fields became metrics");
        NSDictionary *battery = SSBatteryMetrics(@{@"Voltage":@4000, @"InstantAmperage":@(-500), @"CycleCount":@0}, @{@"BatteryData":@{@"Temperature":@3210}});
        Check(fabs([battery[@"batteryTemperature"] doubleValue] - 32.1) < 0.001, @"New battery temperature node/unit failed");
        Check([battery[@"batteryVoltage"] doubleValue] == 4 && [battery[@"batteryPower"] doubleValue] == -2, @"Battery electrical units/sign lost");
        Check(SSBatteryMetrics(@{@"Temperature":@(-999999), @"Voltage":@"4000", @"CycleCount":@YES}, @{}).count == 0, @"Invalid battery data accepted");
        Check([SSBatteryMetrics(@{@"Temperature":@(-999999)}, @{@"BatteryData":@{@"Temperature":@3000}})[@"batteryTemperature"] intValue] == 30, @"Invalid legacy temperature suppressed valid new node");
        NSDictionary *sensor = SSHIDMetric(@"PMU tdie1", 0x54503162, 0xff00, 5, 40.5, 1);
        Check([sensor[@"id"] isEqual:@"temperature:TP1b"] && [sensor[@"unit"] isEqual:@"°C"], @"Sensor identity/type decoding failed");
        Check(SSHIDMetric(@"sentinel", 0, 0xff00, 5, -9199, 0) == nil && SSHIDMetric(@"invalid", 0, 0xff08, 2, NAN, 0) == nil, @"Sensor sentinel/NaN became a current value");
        Check(SSHIDMetric(@"input", 0, 1, 5, 20, 0) == nil, @"Non-sensor HID page accepted");
        Check([SSHIDMetric(@"rail", 0, 0xff08, 2, -0.5, 0)[@"unit"] isEqual:@"A"], @"Signed sensor current unavailable");
        NSDictionary *first = [LocalPerformance snapshotForBundleID:@""];
        Check([NSJSONSerialization isValidJSONObject:first], @"Invalid device snapshot");
        Check([first[@"memoryTotal"] unsignedLongLongValue] > 0, @"Missing physical memory");
        Check([first[@"issues"] isKindOfClass:NSDictionary.class], @"Missing availability results");
        Check([first[@"metrics"][@"processorCount"] intValue] > 0, @"Missing processor metadata");
        NSString *own = NSBundle.mainBundle.bundleIdentifier;
        Check(own.length > 0, @"Fixture bundle identity missing");
        NSDictionary *selfValue = [LocalPerformance snapshotForBundleID:own];
        Check([selfValue[@"pid"] intValue] == getpid(), @"Wrong own-process PID");
        Check([selfValue[@"processMemory"] unsignedLongLongValue] > 0, @"Own-process memory unavailable");
        Check([selfValue[@"metrics"][@"processThreads"] intValue] > 0, @"Own task-info ABI or thread count failed");
        Check(selfValue[@"metrics"][@"gpuPercent"] == nil, @"Device metrics leaked into selected process");
        NSDictionary *unknown = [LocalPerformance snapshotForBundleID:@"dev.personal.nonexistent.performance.test"];
        Check(unknown[@"processMemory"] == nil && unknown[@"processCPUTime"] == nil, @"Unknown app used own-process metrics");
        Check(unknown[@"issues"][@"application"] != nil, @"Missing denied/unavailable app explanation");
        for (int i = 0; i < 50; i++) {
            NSDictionary *value = [LocalPerformance snapshotForBundleID:own];
            Check([NSJSONSerialization isValidJSONObject:value], @"Invalid repeated snapshot");
        }
        NSDictionary *sensors = [LocalPerformance sensorsSnapshot];
        Check([NSJSONSerialization isValidJSONObject:sensors], @"Invalid sensor snapshot");
        NSMutableSet *ids = [NSMutableSet set];
        for (NSDictionary *item in sensors[@"sensors"]) {
            Check(![ids containsObject:item[@"id"]], @"Duplicate hardware sensor identity");
            [ids addObject:item[@"id"]];
        }
        Check([sensors[@"sensors"] count] <= 256, @"Sensor reads exceeded bounded inventory");
        puts("Local performance: native host/process ABI, metric units, invalid values, sensor snapshots, denied-app isolation and finite reads passed");
    }
    return 0;
}
