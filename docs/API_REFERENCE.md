# ssstore 0.5.2 device data interfaces

This reference describes implemented calls, not guaranteed availability on a particular iOS release. The user's iOS 27.2 device has confirmed InstallationProxy metadata and SpringBoard icons. Other services must be tested on that device. The app displays actual errors rather than simulating unavailable data.

Transport is the user's existing Loon loopback and Remote Pairing/RSD connection. Classic paired TCP connections and Lockdown pairing-file imports are no longer supported. Lockdown information services remain available through the authenticated RSD connection.

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

The in-app **完整依赖接口索引** contains 661 C declarations parsed from the pinned v0.1.68 distributed `idevice.h`, including supporting resource-management and bundled plist functions. It marks the 110 declarations used by the inspector. An indexed declaration is not an executable button and does not imply device authorization.

The published Rust SpringBoard client implements `get_icon_state`, but the pinned C interface does not export that method. The icon-metrics entry therefore does not claim to expose the full desktop/folder arrangement.

Continuous syslog, packet capture and performance streams are listed in the dependency index but not started. Some published calls wait for the next event without an exposed cancellation/timeout interface. This release uses explicit finite reads and does not start background recording.

Install/uninstall, configuration setters, file deletion/writes, location simulation, service forwarding, image mounting, reboot/recovery/restore and other state-changing interfaces have no execution entry in the inspector. Their declarations remain searchable for reference.

Reproduce the index after extracting the pinned XCFramework:

```sh
python3 scripts/generate-api-index.py /path/to/IDevice.xcframework/ios-arm64/IDevice.framework/Headers/idevice.h
```

## App visibility and main actions

The app list supports a trailing swipe to ignore an app by its exact Bundle ID. The ignored list persists across restarts. Subsequent scans omit these apps before icon caching, saved-list loading and merge also filter them, and version checks only target visible records. Settings provides a restore action; restored apps return on the next scan.

The bottom toolbar provides **读取应用** and **查询版本**. The More menu contains **刷新全部版本** and **设备数据**. Inventory import, history recording/UI and raw-inventory export have been removed. Existing inventory files remain readable. Normal scan/query completion summaries are hidden; progress appears during work and failures retain their actual messages. The app detail query button is beside the app name; the mapping editor, source field and redundant equality explanations have been removed.

## Upstream sources

- [Pinned idevice FFI source](https://github.com/jkcoxson/idevice/tree/v0.1.68/ffi/src)
- [InstallationProxy](https://github.com/jkcoxson/idevice/blob/v0.1.68/idevice/src/services/installation_proxy.rs)
- [SpringBoard methods](https://github.com/jkcoxson/idevice/blob/v0.1.68/idevice/src/services/springboardservices.rs)
- [Provisioning profiles](https://github.com/jkcoxson/idevice/blob/v0.1.68/idevice/src/services/misagent.rs)
- [AFC FFI and ownership](https://github.com/jkcoxson/idevice/blob/v0.1.68/ffi/src/afc.rs)
- [CoreDevice file domains](https://github.com/jkcoxson/idevice/blob/v0.1.68/ffi/src/core_device/file_service.rs)


## Store module integration (0.5.0)

Asspp 4.2.2 at `6682eb8f831a7b5c62dc14ea97088769c6adba48` is vendored with its MIT license and current dependency pins. The matching user fork has been fast-forwarded to the same upstream revision. ApplePackage is pinned to 2.0.3. The store module provides account authentication, region/platform search, explicit license acquisition, current/historical downloads, pause/resume, IPA inspection/sharing and local OTA installation. Authentication and downloads require the user's own account; existing installed-app version comparisons still use the original login-free Catalog path. No account action executes merely because the app scans installed applications.

The native device inspector remains read-only. Store installation is a separate explicit user action. Certificate installation retains upstream TLS trust requirements; the new pairing installation route uses authenticated Remote Pairing, AFC and InstallationProxy instead of the HTTPS server. Store files/configuration are isolated below Documents/Asspp and the store Keychain services; scan/pairing state stays in ssstore Application Support. Original standalone startup and welcome branding are excluded from the target; integration uses the ssstore scene and tabs.

Inspection app selection uses a searchable sheet instead of a long system menu. File preview and export/share sheets include a Done action and visible drag indicator. Difference filtering includes unknown and failed records; a conditional failure counter toggles the failure filter. Ignored application behavior is unchanged.


## Interface refinements (0.5.1)

Device data now has a bottom tab; Downloads is in the home More menu. Search uses a regular store tab with a visible navigation search field. A persisted includeSystemApps preference controls both the home list and inspection app selection. Store settings are embedded in the main Settings form and demo mode is removed. Store regions use the supported ApplePackage region list with localized search.

Preview/share payloads live on AppModel and are presented from RootView, rather than from transient result rows. The share UI retains Done and drag dismissal; incomplete callbacks do not force dismissal. Inspector completion timestamps and redundant success labels are hidden, while actual failure messages remain visible. Byte values use ordinary size units without duplicated raw byte counts. The read limit remains 32 MiB, with a concise oversized-file error. Ignored app records retain icon metadata and decode legacy names-only lists.

## Pairing installation (0.5.2)

The completed-download page offers pairing installation alongside certificate installation. Pairing installation only starts after the user selects that action. It requires a saved Remote Pairing record and the configured reachable IPv4/port, uploads the finalized signed IPA in 256 KiB chunks via RSD AFC to a unique `PublicStaging/ssstore-<UUID>/package.ipa`, closes the upload, and invokes `installation_proxy_install_with_callback` with `CFBundleIdentifier`, following the pinned idevice v0.1.68 implementation. Upload size is checked for consistency. Only this operation's UUID staging directory is removed on completion or failure; the downloaded source IPA is retained. Native errors are shown unchanged with their stage and codes. The system remains responsible for validating the original app signature and FairPlay authorization; no signing or entitlement checks are bypassed. No local web CA is used by this route. Real-device installation acceptance still needs the user's device; a successful build alone does not establish it.

Bottom tabs are Apps, Device, Account and Search. Both app-list filters use ordinary menu action icons to avoid the additional native Toggle checkmark column. The difference count and filter both include everything not confirmed current. Query progress is typed completed/total state, and counts use SwiftUI's native numeric content transition. Pairing management is a secondary Settings page; region rows use plain button styling. Logs open immediately without the prior warning interstitial; existing log redaction is unchanged.
