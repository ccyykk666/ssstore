# Third-party references and dependencies

The public Apple catalog query design (`mdm-lockup` lookup and external version ID) was researched from the user's MIT-licensed [AssppWeb](https://github.com/ccyykk666/AssppWeb/blob/main/backend/src/routes/search.ts). The Swift client is implemented here and calls Apple directly; AssppWeb's account, purchase, and download flows are not included.

The device transport links the published **idevice v0.1.68** Apple XCFramework from [jkcoxson/idevice](https://github.com/jkcoxson/idevice). The Rust `idevice` crate declares MIT licensing in its [package metadata](https://github.com/jkcoxson/idevice/blob/v0.1.68/idevice/Cargo.toml). Its distributed static binary also contains transitive dependencies; consult the upstream repository and release for their applicable license terms before distributing a finished build.

Pinned release asset: `idevice-xcframework-v0.1.68.zip`.

SHA-256: `c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7`.

[Antrag](https://github.com/claration/antrag), [IDeviceKit](https://github.com/claration/idevicekit), [SideStore](https://github.com/SideStore/SideStore), and [SideInstaller](https://github.com/FrizzleM/SideInstaller) were research references. Their application source code is not vendored into this repository. The local app and C bridge call the published idevice interface directly rather than linking IDeviceKit or copying Antrag's interface.

The user's [Loon loopback plugin](https://github.com/ios151/Rewrite/blob/main/dev-loopback/modules/dev-loopback.lpx) is referenced for use in Loon, not downloaded or enabled automatically. Loon is a separate application.

The optional export script invokes an existing [ideviceinstaller](https://github.com/libimobiledevice/ideviceinstaller) installation. Its executable and source are not bundled.


## Asspp

The App Store account, search, historical version, download, IPA management and local installation features integrate Asspp 4.2.2, upstream commit `6682eb8f831a7b5c62dc14ea97088769c6adba48`, from <https://github.com/Lakr233/Asspp>. The user's fork `ccyykk666/Asspp` was fast-forwarded to that upstream commit on 2026-11-01. Asspp is MIT licensed; its full notice is preserved in `Vendor/Asspp/LICENSE` and bundled as `AssppLicense.txt`. Dependencies are pinned to the versions in the upstream resolved package file, including ApplePackage 2.0.3.

Local adaptations: shared ssstore launch and storage bootstrap, integration tabs and links from installed-app details, embedded store settings, a download navigation callback, and dismissible preview/share sheets. Upstream standalone launch, welcome UI, branding assets and macOS-only device management are excluded from the iOS target.
