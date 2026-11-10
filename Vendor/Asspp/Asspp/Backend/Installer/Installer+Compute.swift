//
//  Installer+Compute.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
import Foundation
import LocalInstallTLS

extension Installer {
    private var localScheme: String { isCompatible ? "http" : "https" }
    private var localHost: String { isCompatible ? Self.host : Self.installationHost }
    var certificateProfileEndpoint: URL {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = Self.host
        comps.port = port
        comps.path = "/ssstore-loopback.mobileconfig"
        return comps.url!
    }
    var pingEndpoint: URL {
        var comps = URLComponents(url: payloadEndpoint, resolvingAgainstBaseURL: false)!
        comps.path = "/ping"
        return comps.url!
    }
    var installPage: URL {
        var comps = URLComponents(url: payloadEndpoint, resolvingAgainstBaseURL: false)!
        comps.path = "/index.html"
        return comps.url!
    }
    var plistEndpoint: URL {
        if let remoteManifestEndpoint { return remoteManifestEndpoint }
        var comps = URLComponents()
        comps.scheme = localScheme
        comps.host = localHost
        comps.path = "/\(id).plist"
        comps.port = port
        return comps.url!
    }

    var payloadEndpoint: URL {
        var comps = URLComponents()
        comps.scheme = localScheme
        comps.host = localHost
        comps.path = "/\(id).ipa"
        comps.port = port
        return comps.url!
    }

    var iTunesLink: URL {
        LocalInstallURL.installationLink(manifestURL: plistEndpoint)
    }

    var displayImageSmallEndpoint: URL {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = Self.installationHost
        comps.path = "/app57x57.png"
        comps.port = port
        return comps.url!
    }

    var displayImageSmallData: Data {
        createWhite(57)
    }

    var displayImageLargeEndpoint: URL {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = Self.installationHost
        comps.path = "/app512x512.png"
        comps.port = port
        return comps.url!
    }

    var displayImageLargeData: Data {
        createWhite(512)
    }

    var indexHtml: String {
        let link = iTunesLink.absoluteString.replacingOccurrences(of: "&", with: "&amp;")
        return """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>安装应用</title><style>html{color-scheme:light dark;font-family:-apple-system,system-ui}main{max-width:32rem;margin:15vh auto;padding:1.5rem}a{display:inline-block;padding:.8rem 1.5rem;background:#007aff;color:white;text-decoration:none;border-radius:.75rem;font-weight:600}</style></head>
        <body><main><h2>安装应用</h2><p>请点击下方按钮，并在系统提示中确认安装。</p><a id="install" href="\(link)">安装</a></main>
        <script>
        function report(event) { fetch('/ping?event=' + event, {cache:'no-store',keepalive:true}).catch(function(){}); }
        report('page-ready');
        document.getElementById('install').addEventListener('click', function(){ report('install-click'); });
        setInterval(function(){ if(document.visibilityState === 'visible') report('heartbeat'); }, 3000);
        </script></body></html>
        """
    }

    var installManifest: [String: Any] {
        [
            "items": [
                [
                    "assets": [
                        [
                            "kind": "software-package",
                            "url": payloadEndpoint.absoluteString,
                        ],
                        [
                            "kind": "display-image",
                            "url": displayImageSmallEndpoint.absoluteString,
                        ],
                        [
                            "kind": "full-size-image",
                            "url": displayImageLargeEndpoint.absoluteString,
                        ],
                    ],
                    "metadata": [
                        "bundle-identifier": packageMetadata?.bundleID ?? archive.software.bundleID,
                        "bundle-version": packageMetadata?.version ?? archive.software.version,
                        "kind": "software",
                        "title": packageMetadata?.name ?? archive.software.name,
                    ],
                ],
            ],
        ]
    }

    var installManifestData: Data {
        (try? PropertyListSerialization.data(
            fromPropertyList: installManifest,
            format: .xml,
            options: .zero,
        )) ?? .init()
    }
}

