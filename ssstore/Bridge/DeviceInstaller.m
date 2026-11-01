#import "DeviceInstaller.h"
@import IDevice;
#include <arpa/inet.h>

static BOOL InstallError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"ssstore.Installation" code:1
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}

static BOOL InstallCheck(IdeviceFfiError *failure, NSString *stage, NSError **error) {
    if (!failure) return YES;
    NSString *detail = failure->message ? [NSString stringWithUTF8String:failure->message] : @"未知错误";
    if (error) *error = [NSError errorWithDomain:@"ssstore.Installation" code:failure->code
        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@失败（%d/%d）：%@",
                                             stage, failure->code, failure->sub_code, detail]}];
    idevice_error_free(failure);
    return NO;
}

typedef void (^InstallationProgressBlock)(NSString *, double);

static void InstallProgress(uint64_t percent, void *context) {
    InstallationProgressBlock progress = (__bridge InstallationProgressBlock)context;
    progress(@"正在安装…", 0.85 + 0.15 * MIN(percent, 100) / 100.0);
}

@implementation DeviceInstaller
+ (BOOL)installPairingPath:(NSString *)pairingPath host:(NSString *)host port:(uint16_t)port
              packagePath:(NSString *)packagePath bundleID:(NSString *)bundleID
                 progress:(void (^)(NSString *, double))progress error:(NSError **)error {
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address); address.sin_family = AF_INET; address.sin_port = htons(port);
    if (inet_pton(AF_INET, host.UTF8String, &address.sin_addr) != 1)
        return InstallError(error, @"请输入有效的 IPv4 地址。");
    if (!bundleID.length || ![packagePath.pathExtension.lowercaseString isEqualToString:@"ipa"])
        return InstallError(error, @"应用安装包无效。");
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:packagePath error:error];
    if (!attributes) return NO;
    unsigned long long size = [attributes fileSize];
    if (![attributes[NSFileType] isEqual:NSFileTypeRegular] || !size)
        return InstallError(error, @"应用安装包为空或不可读取。");
    NSFileHandle *source = [NSFileHandle fileHandleForReadingFromURL:[NSURL fileURLWithPath:packagePath] error:error];
    if (!source) return NO;

    struct RpPairingFileHandle *pairing = NULL;
    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;
    struct AfcClientHandle *afc = NULL;
    struct AfcFileHandle *remote = NULL;
    struct InstallationProxyClientHandle *installation = NULL;
    plist_t options = NULL;
    NSString *staging = [@"PublicStaging" stringByAppendingPathComponent:
                         [@"ssstore-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *remotePath = [staging stringByAppendingPathComponent:@"package.ipa"];
    BOOL createdStaging = NO;
    @try {
        progress(@"正在连接设备…", 0);
        if (!InstallCheck(rp_pairing_file_read(pairingPath.UTF8String, &pairing), @"读取配对文件", error)) return NO;
        if (!InstallCheck(tunnel_create_rppairing((const idevice_sockaddr *)&address, sizeof(address),
            "ssstore-install", pairing, NULL, NULL, &adapter, &handshake), @"连接配对通道", error)) return NO;
        if (!InstallCheck(afc_client_connect_rsd(adapter, handshake, &afc), @"连接安装包传输服务", error)) return NO;
        // PublicStaging is shared. Only the UUID subdirectory created below is ever removed.
        struct AfcFileInfo info = {0};
        IdeviceFfiError *statError = afc_get_file_info(afc, "PublicStaging", &info);
        if (statError) {
            idevice_error_free(statError);
            if (!InstallCheck(afc_make_directory(afc, "PublicStaging"), @"创建暂存目录", error)) return NO;
        } else { afc_file_info_free(&info); }
        if (!InstallCheck(afc_make_directory(afc, staging.UTF8String), @"创建安装暂存目录", error)) return NO;
        createdStaging = YES;
        if (!InstallCheck(afc_file_open(afc, remotePath.UTF8String, AfcWrOnly, &remote), @"打开安装暂存文件", error)) return NO;
        unsigned long long sent = 0;
        double lastReported = -1;
        while (YES) {
            @autoreleasepool {
                NSError *readError = nil;
                NSData *chunk = [source readDataUpToLength:256 * 1024 error:&readError];
                if (!chunk) { if (error) *error = readError; return NO; }
                if (!chunk.length) break;
                if (!InstallCheck(afc_file_write(remote, chunk.bytes, chunk.length), @"传输安装包", error)) return NO;
                sent += chunk.length;
                double fraction = MIN(0.85, 0.85 * (double)sent / size);
                if (fraction - lastReported >= 0.005 || sent == size) {
                    progress(@"正在传输安装包…", fraction);
                    lastReported = fraction;
                }
            }
        }
        if (sent != size) return InstallError(error, @"安装包在传输过程中发生变化，请重新下载后重试。");
        // Closing consumes the FFI handle, including when the close itself reports an error.
        IdeviceFfiError *closeError = afc_file_close(remote); remote = NULL;
        if (!InstallCheck(closeError, @"完成安装包传输", error)) return NO;
        if (!InstallCheck(installation_proxy_connect_rsd(adapter, handshake, &installation), @"连接系统安装服务", error)) return NO;
        options = plist_new_dict();
        plist_dict_set_item(options, "CFBundleIdentifier", plist_new_string(bundleID.UTF8String));
        progress(@"正在安装…", 0.85);
        // System installation still validates the app's original signature and FairPlay authorization.
        if (!InstallCheck(installation_proxy_install_with_callback(installation, remotePath.UTF8String,
            options, InstallProgress, (__bridge void *)progress), @"系统安装", error)) return NO;
        progress(@"安装完成", 1);
        return YES;
    } @finally {
        [source closeAndReturnError:NULL];
        if (remote) { IdeviceFfiError *e = afc_file_close(remote); if (e) idevice_error_free(e); }
        if (createdStaging) {
            IdeviceFfiError *e = afc_remove_path_and_contents(afc, staging.UTF8String);
            if (e) idevice_error_free(e);
        }
        plist_free(options);
        installation_proxy_client_free(installation);
        afc_client_free(afc);
        rsd_handshake_free(handshake);
        adapter_free(adapter);
        rp_pairing_file_free(pairing);
    }
}
@end
