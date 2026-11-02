# Third-party references and dependencies

The public Apple catalog query design (`mdm-lockup` lookup and external version ID) was researched from [AssppWeb](https://github.com/ccyykk666/AssppWeb). AssppWeb is also used for the local WebKit kbsync runtime described below; the earlier statement that it was only a research reference is no longer accurate.

The device transport links the published **idevice v0.1.68** Apple XCFramework from [jkcoxson/idevice](https://github.com/jkcoxson/idevice). The Rust `idevice` crate declares MIT licensing in its [package metadata](https://github.com/jkcoxson/idevice/blob/v0.1.68/idevice/Cargo.toml). Its distributed static binary also contains transitive dependencies; consult the upstream repository and release for their applicable license terms before distributing a finished build.

Pinned release asset: `idevice-xcframework-v0.1.68.zip`.

SHA-256: `c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7`.

[Antrag](https://github.com/claration/antrag), [IDeviceKit](https://github.com/claration/idevicekit), [SideStore](https://github.com/SideStore/SideStore), and [SideInstaller](https://github.com/FrizzleM/SideInstaller) were research references. Their application source code is not vendored into this repository. The local app and C bridge call the published idevice interface directly rather than linking IDeviceKit or copying Antrag's interface.

The user's [Loon loopback plugin](https://github.com/ios151/Rewrite/blob/main/dev-loopback/modules/dev-loopback.lpx) is referenced for use in Loon, not downloaded or enabled automatically. Loon is a separate application.

The optional export script invokes an existing [ideviceinstaller](https://github.com/libimobiledevice/ideviceinstaller) installation. Its executable and source are not bundled.


## Asspp

The App Store account, search, historical version, download, IPA management and local installation features integrate Asspp 4.2.2, upstream commit `6682eb8f831a7b5c62dc14ea97088769c6adba48`, from <https://github.com/Lakr233/Asspp>. The user's fork `ccyykk666/Asspp` was fast-forwarded to that upstream commit on 2026-11-01. Asspp is MIT licensed; its full notice is preserved in `Vendor/Asspp/LICENSE` and bundled as `AssppLicense.txt`. Dependencies are pinned to the versions in the upstream resolved package file, including ApplePackage 2.0.3.

Local adaptations: shared ssstore launch and storage bootstrap, integration tabs and links from installed-app details, embedded store settings, a download navigation callback, and dismissible preview/share sheets. Upstream standalone launch, welcome UI, branding assets and macOS-only device management are excluded from the iOS target.

## AssppWeb and local kbsync runtime

The build uses AssppWeb commit `dda77c915e9b61469ca7b4995c7515a6eb0e3115` from <https://github.com/ccyykk666/AssppWeb>, pinned by file hashes in `scripts/kbsync-manifest.json`. The TypeScript engine and adapters are modified for ssstore's bundled WebKit page and worker. AssppWeb's MIT license, copyright (c) 2025 Lakr233 with his friends, is preserved in `Vendor/AssppWeb/LICENSE` and bundled as `AssppWebLicense.txt`.

AssppWeb's MIT license does **not** replace the licenses of the following bundled dependencies or Apple binaries.

### Unicorn / QEMU

The runtime uses a patched Unicorn 2.1.4 WebAssembly interpreter. Upstream: <https://github.com/unicorn-engine/unicorn/tree/2.1.4>. Unicorn declares GPLv2 licensing and contains components with additional notices, including LGPL and GLib notices. The build copies `COPYING`, `COPYING.LGPL2`, `COPYING_GLIB`, the AssppWeb patch and build script into `KBSyncRuntime/sources`.

The current script does **not** include the complete Unicorn source tree: copying the AssppWeb adapter, patch and build script alone is not a complete corresponding-source distribution. This must be resolved, together with the license terms of the combined distribution, before treating a released IPA as license-compliant. Adding an attribution or an MIT license to ssstore alone does not resolve this.

### Apple runtime resources

`scripts/prepare-kbsync.py` extracts CommerceKit, CommerceCore, CoreFP, CoreFP.icxs and storeagent from an Apple OS X 10.9 update and bundles selected architecture slices in the IPA. These files are not committed to the Git source tree. They remain Apple software; publicly downloadable files are not automatically licensed for redistribution.

No permission to redistribute those Apple components is granted by Asspp, AssppWeb, this repository or this notice. Review the applicable [Apple software license](https://www.apple.com/legal/sla/docs/OSX109.pdf) before distributing a build containing them.

## Public localhost TLS fixture

`Vendor/Asspp/Certificates/localhost.qaq.wiki/localhost.qaq.wiki-key.pem` is the public localhost TLS fixture supplied by the pinned Asspp upstream. It is not a user's device pairing key, Apple ID credential or code-signing key. It must not be reused to protect a public server or other confidential service.

## License scope

Each third-party component retains its own license and copyright notices. Making the repository public does not assign an MIT license to all files, nor authorize redistribution of proprietary dependencies. No project-wide license for ssstore's original code has been selected by this notice.
