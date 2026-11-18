# Third-party references and dependencies

The 2026-11-09 store compatibility updates reference MIT-licensed [ipatool](https://github.com/majd/ipatool), Copyright (c) 2021 Majd Alfhaily. Applied behavior changes and upstream commits are documented in `docs/UPSTREAM_REVIEW_2026-11-09.md`; the desktop emulator and its Apple framework assets are not bundled.

The public Apple catalog query design (`mdm-lockup` lookup and external version ID) was researched from [AssppWeb](https://github.com/ccyykk666/AssppWeb).

The device transport links the published **idevice v0.1.68** Apple XCFramework from [jkcoxson/idevice](https://github.com/jkcoxson/idevice). The Rust `idevice` crate declares MIT licensing in its [package metadata](https://github.com/jkcoxson/idevice/blob/v0.1.68/idevice/Cargo.toml). Its distributed static binary also contains transitive dependencies; consult the upstream repository and release for their applicable license terms before distributing a finished build.

Pinned release asset: `idevice-xcframework-v0.1.68.zip`.

The iOS arm64 slice is rebuilt from upstream commit `d32c8189c51c2789496b0768039419c3705498c3` with `scripts/patches/rsd-discovery.patch`, which preserves valid advertised endpoints whose optional entitlement metadata is absent and accepts numeric ports. The `dvt-screenshot.patch` adds a bounded single-shot Instruments capture using idevice’s DTX client. Discovery and DTX fixtures run before compilation; the source archive/module hashes, Cargo lockfile and Rust 1.94.0 toolchain are pinned. Earlier sysmontap and cancellation-relay patches were removed with the remote performance recorder. The live panel, hardware sensors and their private OS readers were removed in build 80. Other XCFramework slices retain the pinned published binary. The upstream MIT notice is bundled as `ssstore/Resources/IDeviceLicense.txt`.

SHA-256: `c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7`.

[Antrag](https://github.com/claration/antrag), [IDeviceKit](https://github.com/claration/idevicekit), [SideStore](https://github.com/SideStore/SideStore), and [SideInstaller](https://github.com/FrizzleM/SideInstaller) were research references. Their application source code is not vendored into this repository. The local app and C bridge call the published idevice interface directly rather than linking IDeviceKit or copying Antrag's interface.

The user's [Loon loopback plugin](https://github.com/ios151/Rewrite/blob/main/dev-loopback/modules/dev-loopback.lpx) is referenced for use in Loon, not downloaded or enabled automatically. Loon is a separate application.

The optional export script invokes an existing [ideviceinstaller](https://github.com/libimobiledevice/ideviceinstaller) installation. Its executable and source are not bundled.


## Asspp

The App Store account, search, historical version, download, IPA management and local installation features integrate Asspp 4.2.2, upstream commit `6682eb8f831a7b5c62dc14ea97088769c6adba48`, from <https://github.com/Lakr233/Asspp>. The user's fork `ccyykk666/Asspp` was fast-forwarded to that upstream commit on 2026-11-01. Asspp is MIT licensed; its full notice is preserved in `Vendor/Asspp/LICENSE` and bundled as `AssppLicense.txt`. Dependencies are pinned to the versions in the upstream resolved package file, including ApplePackage 2.0.3.

Local adaptations: shared ssstore launch and storage bootstrap, integration tabs and links from installed-app details, embedded store settings, a download navigation callback, and dismissible preview/share sheets. Upstream standalone launch, welcome UI, branding assets and macOS-only device management are excluded from the iOS target.

## AssppWeb

The AssppWeb MIT license, copyright (c) 2025 Lakr233 with his friends, is preserved in `Vendor/AssppWeb/LICENSE` and bundled as `AssppWebLicense.txt`. Versions through build 92 included a local WebKit kbsync runtime with its own notices. Build 93 uses the compatibility download endpoints and omits the local interpreter and OS X runtime assets.

## Public localhost TLS fixture

`Vendor/Asspp/Certificates/localhost.qaq.wiki/localhost.qaq.wiki-key.pem` is the public localhost TLS fixture supplied by the pinned Asspp upstream. From build 56 it remains only in the vendored source and is not bundled or used by ssstore. Local installation generates a device-specific CA and loopback IP server identity using Apple's Apache-2.0-licensed Swift Certificates, Swift Crypto and Swift ASN.1 (the existing pinned versions). Private keys are stored in the device-only Keychain; only the public root certificate is included in the configuration profile.

## License scope

Each third-party component retains its own license and copyright notices. Making the repository public does not assign an MIT license to all files, nor authorize redistribution of proprietary dependencies. No project-wide license for ssstore's original code has been selected by this notice.
