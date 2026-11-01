# Third-party references and dependencies

The public Apple catalog query design (`mdm-lockup` lookup and external version ID) was researched from the user's MIT-licensed [AssppWeb](https://github.com/ccyykk666/AssppWeb/blob/main/backend/src/routes/search.ts). The Swift client is implemented here and calls Apple directly; AssppWeb's account, purchase, and download flows are not included.

The device transport links the published **idevice v0.1.68** Apple XCFramework from [jkcoxson/idevice](https://github.com/jkcoxson/idevice). The Rust `idevice` crate declares MIT licensing in its [package metadata](https://github.com/jkcoxson/idevice/blob/v0.1.68/idevice/Cargo.toml). Its distributed static binary also contains transitive dependencies; consult the upstream repository and release for their applicable license terms before distributing a finished build.

Pinned release asset: `idevice-xcframework-v0.1.68.zip`.

SHA-256: `c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7`.

[Antrag](https://github.com/claration/antrag), [IDeviceKit](https://github.com/claration/idevicekit), [SideStore](https://github.com/SideStore/SideStore), and [SideInstaller](https://github.com/FrizzleM/SideInstaller) were research references. Their application source code is not vendored into this repository. The local app and C bridge call the published idevice interface directly rather than linking IDeviceKit or copying Antrag's interface.

The user's [Loon loopback plugin](https://github.com/ios151/Rewrite/blob/main/dev-loopback/modules/dev-loopback.lpx) is referenced for use in Loon, not downloaded or enabled automatically. Loon is a separate application.

The optional export script invokes an existing [ideviceinstaller](https://github.com/libimobiledevice/ideviceinstaller) installation. Its executable and source are not bundled.
