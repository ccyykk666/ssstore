#import "PairingHost.h"
@import IDevice;

static BOOL PairingCheck(IdeviceFfiError *failure, NSError **error) {
    if (!failure) return YES;
    NSString *message = failure->message ? [NSString stringWithUTF8String:failure->message] : @"配对失败";
    if (error) *error = [NSError errorWithDomain:@"ssstore.Pairing" code:failure->code
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
    idevice_error_free(failure);
    return NO;
}

static void DisplayPairingPIN(const char *pin, void *context) {
    void (^handler)(NSString *) = (__bridge void (^)(NSString *))context;
    if (pin && handler) handler([NSString stringWithUTF8String:pin]);
}

@implementation PairingHost {
    struct PairableHostHandle *_handle;
    NSData *_hostAltIRK;
}

- (instancetype)initWithName:(NSString *)name error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    char *serviceID = NULL;
    uint8_t *txt = NULL;
    uintptr_t txtLength = 0;
    uint8_t hostAltIRK[16] = {0};
    @try {
        // A normal PIN-confirmed host; the protocol's default model is a Mac.
        if (!PairingCheck(pairable_host_prepare(name.UTF8String, NULL, false, &_handle,
                                               &serviceID, &txt, &txtLength, hostAltIRK), error)) return nil;
        _serviceName = [NSString stringWithUTF8String:serviceID];
        _hostAltIRK = [NSData dataWithBytes:hostAltIRK length:sizeof(hostAltIRK)];
        NSData *data = [NSData dataWithBytes:txt length:txtLength];
        NSDictionary *values = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:error];
        if (![values isKindOfClass:NSDictionary.class]) return nil;
        NSMutableDictionary *records = [NSMutableDictionary dictionary];
        for (NSString *key in values) {
            if ([values[key] isKindOfClass:NSString.class]) {
                records[key] = [values[key] dataUsingEncoding:NSUTF8StringEncoding];
            }
        }
        _txtRecords = records;
        return self;
    } @finally {
        idevice_string_free(serviceID);
        idevice_data_free(txt, txtLength);
    }
}

- (NSData *)acceptSocket:(int32_t)socket pinHandler:(void (^)(NSString *))pinHandler error:(NSError **)error {
    struct RpPairingFileHandle *record = NULL;
    uint8_t *bytes = NULL;
    uintptr_t length = 0;
    CFTypeRef context = CFBridgingRetain([pinHandler copy]);
    @try {
        // The library duplicates socket; the caller retains the original for cancellation.
        if (!PairingCheck(pairable_host_accept_fd(_handle, socket, DisplayPairingPIN,
                                                  (void *)context, NULL, &record), error)) return nil;
        if (!PairingCheck(rp_pairing_file_to_bytes(record, &bytes, &length), error)) return nil;
        NSData *data = [NSData dataWithBytes:bytes length:length];
        NSMutableDictionary *plist = [[NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:error] mutableCopy];
        if (![plist isKindOfClass:NSMutableDictionary.class]) return nil;
        plist[@"ssstoreHostAltIRK"] = _hostAltIRK;
        return [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
    } @finally {
        CFRelease(context);
        idevice_data_free(bytes, length);
        rp_pairing_file_free(record);
    }
}

- (void)dealloc {
    pairable_host_free(_handle);
}
@end
