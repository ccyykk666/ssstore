# ssstore 0.4.0 device data interfaces

This reference describes implemented calls, not guaranteed availability on a particular iOS release. The user's iOS 27.2 device has confirmed InstallationProxy metadata and SpringBoard icons. Other services must be tested on that device. The app displays actual errors rather than simulating unavailable data.

Transport is the user's existing Loon loopback and Remote Pairing/RSD connection. Traditional paired TCP connections are supported where the corresponding published FFI offers them. CoreDevice and DVT entries require Remote Pairing in this app.

## Entry points

The main More menu opens **设备数据**. Each app's details opens **应用数据**. There are 41 main entries plus two file helpers. Requests run on a background queue with all FFI handles created, used, and released on that queue. App scanning, version checks, pairing, and inspection do not execute concurrently through the UI.

| Family | Implemented operations | Published interface |
| --- | --- | --- |
| Service discovery | All advertised services, ports, entitlement requirements, feature names and versions | `rsd_get_services` |
| Connection probes | 15 service families; each reports success/error separately | Corresponding `*_connect_rsd` calls |
| Application records | Full returned records, capability declarations and file-sharing flags | `installation_proxy_browse` |
| Storage | Single/all-app static and dynamic disk usage, sorted by combined reported bytes | Browse `ReturnAttributes`: `StaticDiskUsage`, `DynamicDiskUsage` |
| Provisioning | Raw exported profiles, embedded plist, profile expiry and certificate subject names | `misagent_copy_all`, public Security certificate parsing |
| Shared documents and containers | Read-only directory browsing, file attributes, preview and explicit file export | `house_arrest_vend_documents`, `house_arrest_vend_container`, AFC |
| Media/filesystem | AFC directory browsing and filesystem capacity | `afc_list_directory`, `afc_get_device_info` |
| Crash reports | Browse and read already exposed report files | `crash_report_client_connect_rsd`, conversion to read-only AFC operations |
| SpringBoard | App icon, home/lock wallpaper previews, icon metrics, interface orientation | `springboard_services_get_*` |
| Screenshots | Mobile screenshot service and DVT screenshot service | `screenshotr_take_screenshot`, `screenshot_client_take_screenshot` |
| Device information | General, battery and disk domains | `lockdownd_get_value` |
| Diagnostics | General, battery/gas-gauge, NAND, Wi-Fi, MobileGestalt and IORegistry | `diagnostics_relay_client_*` read methods |
| CoreDevice apps | App records and running processes | `app_service_list_apps`, `app_service_list_processes` |
| CoreDevice files | Directory listing in app, App Group, temporary or crash-log domain | `file_service_create_session`, `file_service_retrieve_directory_list` |
| Display configuration | Appearance, text size, color filter, Reduce Motion, Reduce Transparency, debug-border state | `configuration_service_get_*` |
| DVT | App list, processes, hardware, network, kernel name and available sampling attribute names | `application_listing_get_apps`, `device_info_*` |
| Developer state | Developer-mode status and mounted image records | `image_mounter_query_developer_mode_status`, `image_mounter_copy_devices` |
| Companion devices | Registry of paired companion device identifiers | `companion_proxy_get_device_registry` |

## Result semantics

1. **Advertised** means the name was in the RSD handshake. It does not prove that the caller has permission.
2. **Connection success** means the client constructor succeeded. It does not prove every method on that client works.
3. **Call success** means the specific read operation returned without a protocol error. Individual fields may still be absent or empty.
4. Errors preserve the stage, idevice error code, sub-code and message. A missing service never becomes a placeholder success.

Returned plist dictionaries/arrays are rendered as navigable fields. Dates are ISO strings. Embedded plist data is decoded; other binary values display their byte count. Explicitly retrieved images, profiles and files are stored inside the app and can be previewed or shared by the user. Nothing is automatically uploaded. JSON exports include the request operation, app/path context and capture time.

Dynamic disk usage is not synonymous with disposable cache. Reported capacities need not match the Settings app's accounting. Entitlements describe capabilities and are not a readout of the user's camera/location permission decisions. Description-file expiry is not certificate expiry or revocation status. CMS profile contents are extracted for display; no trust-validation result is claimed.

## File behavior

Shared-document access, whole-container access and media access remain restricted to what the device service authorizes. Knowing an install path does not grant access to that path. Files are opened with `AfcRdOnly`; no file creation, source writes, deletes, renames or links are sent to the device.

Export is limited to 32 MiB per file, read in 64 KiB chunks. The source is not modified. The CoreDevice file entry currently lists directories only; bounded export uses the AFC-based entries, which provide file-size information before downloading. Listing crash reports does not flush/move or erase logs.

## Interface research and exclusions

The in-app **完整依赖接口索引** contains 661 C declarations parsed from the pinned v0.1.68 distributed `idevice.h`, including supporting resource-management and bundled plist functions. It marks the 125 declarations used by the inspector. An indexed declaration is not an executable button and does not imply device authorization.

The published Rust SpringBoard client implements `get_icon_state`, but the pinned C interface does not export that method. The icon-metrics entry therefore does not claim to expose the full desktop/folder arrangement.

Continuous syslog, packet capture and performance streams are listed in the dependency index but not started. Some published calls wait for the next event without an exposed cancellation/timeout interface. This release uses explicit finite reads and does not start background recording.

Install/uninstall, configuration setters, file deletion/writes, location simulation, service forwarding, image mounting, reboot/recovery/restore and other state-changing interfaces have no execution entry in the inspector. Their declarations remain searchable for reference.

Reproduce the index after extracting the pinned XCFramework:

```sh
python3 scripts/generate-api-index.py /path/to/IDevice.xcframework/ios-arm64/IDevice.framework/Headers/idevice.h
```

## Snapshot history

After a successful complete scan, ssstore compares the previous and final app list. It records discovered additions/removals and changed non-missing external version IDs, up to 1000 events. It does not compare the intermediate Lookup and Browse callbacks as independent scans. The first scan establishes a baseline. Event timestamps are observation times, not true installation times, and ID changes do not imply upgrade direction.

## Upstream sources

- [Pinned idevice FFI source](https://github.com/jkcoxson/idevice/tree/v0.1.68/ffi/src)
- [InstallationProxy](https://github.com/jkcoxson/idevice/blob/v0.1.68/idevice/src/services/installation_proxy.rs)
- [SpringBoard methods](https://github.com/jkcoxson/idevice/blob/v0.1.68/idevice/src/services/springboardservices.rs)
- [Provisioning profiles](https://github.com/jkcoxson/idevice/blob/v0.1.68/idevice/src/services/misagent.rs)
- [AFC FFI and ownership](https://github.com/jkcoxson/idevice/blob/v0.1.68/ffi/src/afc.rs)
- [CoreDevice file domains](https://github.com/jkcoxson/idevice/blob/v0.1.68/ffi/src/core_device/file_service.rs)
