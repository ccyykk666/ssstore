#import <Foundation/Foundation.h>
#include <math.h>

// Normalise only documented/researched numeric keys. Never retain complete
// registry dictionaries (which may contain device serials and other identity).
static inline NSNumber *SSMetricNumber(id raw, double minimum, double maximum) {
    if (![raw isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)raw) == CFBooleanGetTypeID()) return nil;
    double value = [raw doubleValue];
    return isfinite(value) && value >= minimum && value <= maximum ? @(value) : nil;
}
static inline NSDictionary *SSBatteryMetrics(NSDictionary *source, NSDictionary *pack) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSDictionary *data = [pack[@"BatteryData"] isKindOfClass:NSDictionary.class] ? pack[@"BatteryData"] : @{};
    NSNumber *temperature = SSMetricNumber(source[@"Temperature"], -4000, 10000) ?: SSMetricNumber(data[@"Temperature"], -4000, 10000);
    if (temperature) result[@"batteryTemperature"] = @(temperature.doubleValue / 100);
    NSNumber *voltage = SSMetricNumber(source[@"Voltage"], 1, 30000);
    NSNumber *current = SSMetricNumber(source[@"InstantAmperage"], -30000, 30000);
    if (voltage) result[@"batteryVoltage"] = @(voltage.doubleValue / 1000);
    if (current) result[@"batteryCurrent"] = @(current.doubleValue / 1000);
    // Battery-side electrical power; never label this as charger input or CPU power.
    if (voltage && current) result[@"batteryPower"] = @(voltage.doubleValue * current.doubleValue / 1000000);
    NSNumber *cycles = SSMetricNumber(source[@"CycleCount"], 0, 100000);
    if (cycles) result[@"batteryCycles"] = cycles;
    for (NSString *key in @[@"IsCharging", @"ExternalConnected", @"FullyCharged"]) {
        id raw = source[key];
        if ([raw isKindOfClass:NSNumber.class] && ([raw doubleValue] == 0 || [raw doubleValue] == 1)) {
            NSString *output = [@{@"IsCharging":@"batteryCharging", @"ExternalConnected":@"batteryExternal", @"FullyCharged":@"batteryFull"} objectForKey:key];
            result[output] = @([raw boolValue]);
        }
    }
    return result;
}
static inline NSDictionary *SSGPUMetrics(NSDictionary *values) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSDictionary *keys = @{@"Device Utilization %":@"gpuPercent", @"Renderer Utilization %":@"gpuRenderer", @"Tiler Utilization %":@"gpuTiler"};
    for (NSString *key in keys) {
        NSNumber *number = SSMetricNumber(values[key], 0, 100);
        if (number) result[keys[key]] = number;
    }
    NSNumber *memory = SSMetricNumber(values[@"In use system memory"], 0, 1e15);
    if (memory) result[@"gpuMemory"] = memory;
    return result;
}
static inline NSDictionary *SSHIDMetric(NSString *name, uint32_t location, int page, int usage, double value, NSUInteger index) {
    BOOL temperature = page == 0xff00 && usage == 5;
    BOOL current = page == 0xff08 && usage == 2;
    BOOL voltage = page == 0xff08 && usage == 3;
    if ((!temperature && !current && !voltage) || !isfinite(value)) return nil;
    if ((temperature && (value < -40 || value > 150)) || (current && fabs(value) > 100) || (voltage && (value < 0 || value > 100))) return nil;
    char bytes[5] = {(char)(location >> 24), (char)(location >> 16), (char)(location >> 8), (char)location, 0};
    BOOL printable = location != 0;
    for (int i = 0; i < 4; i++) if ((unsigned char)bytes[i] < 0x20 || (unsigned char)bytes[i] > 0x7e) printable = NO;
    NSString *key = printable ? [NSString stringWithUTF8String:bytes] : @"";
    NSString *kind = temperature ? @"temperature" : current ? @"current" : @"voltage";
    NSString *identity = key.length ? [NSString stringWithFormat:@"%@:%@", kind, key]
        : [NSString stringWithFormat:@"%@:%lu:%@", kind, (unsigned long)index, name];
    return @{@"id":identity, @"name":name.length ? [name substringToIndex:MIN(name.length, 100)] : @"未命名传感器", @"key":key,
        @"kind":kind, @"value":@(value), @"unit":temperature ? @"°C" : current ? @"A" : @"V"};
}
