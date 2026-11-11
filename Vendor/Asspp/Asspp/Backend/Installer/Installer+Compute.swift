//
//  Installer+Compute.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
import Foundation
import UpdateCore

extension Installer {
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
    var payloadEndpoint: URL {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = Self.host
        comps.path = "/\(id).ipa"
        comps.port = port
        return comps.url!
    }

    var iTunesLink: URL? {
        guard let remoteManifestEndpoint else { return nil }
        return try? InstallationManifest.installationLink(manifestURL: remoteManifestEndpoint)
    }

    var indexHtml: String? {
        guard let iTunesLink else { return nil }
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

}

