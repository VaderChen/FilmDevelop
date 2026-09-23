import Foundation
import WebKit

extension PhotoStyleWebView {
    func loadWebApp(in webView: WKWebView) {
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") else {
            webView.loadHTMLString("""
            <html><body style="font-family:-apple-system;padding:24px;background:#fff3cd;color:#7a5200">
            <h2>\(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "照片沖洗")</h2><p>\(PhotoL10n.text("找不到 Web 資源："))<code>Bundle.main/Web/index.html</code></p>
            </body></html>
            """, baseURL: nil)
            return
        }

        let baseURL = url.deletingLastPathComponent()
        let cacheBust = String(Int(Date().timeIntervalSince1970))
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let buildNumber = Bundle.main.infoDictionary?["PhotoStyleBuildTime"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0000"
        #if DEBUG
        let buildConfiguration = "DEBUG"
        #else
        let buildConfiguration = "RELEASE"
        #endif

        guard var html = try? String(contentsOf: url, encoding: .utf8) else {
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
            return
        }

        html = html.replacingOccurrences(of: "styles.css", with: "styles.css?v=\(cacheBust)")
        html = html.replacingOccurrences(of: "desktop.css", with: "desktop.css?v=\(cacheBust)")
        html = html.replacingOccurrences(of: "export-development.js", with: "export-development.js?v=\(cacheBust)")
        html = html.replacingOccurrences(of: "film-hover-preview.js", with: "film-hover-preview.js?v=\(cacheBust)")
        html = html.replacingOccurrences(of: "localization-data.js", with: "localization-data.js?v=\(cacheBust)")
        html = html.replacingOccurrences(of: "localization.js", with: "localization.js?v=\(cacheBust)")
        html = html.replacingOccurrences(of: "app.js", with: "app.js?v=\(cacheBust)")
        html = html.replacingOccurrences(
            of: "</head>",
            with: """
            <script>
            window.__appInfo = {
              languagePreference: \(PhotoStyleWebCoordinator.jsonString(UserDefaults.standard.string(forKey: PhotoL10n.preferenceKey) ?? "")),
              systemLanguage: \(PhotoStyleWebCoordinator.jsonString(Locale.preferredLanguages.first ?? "zh-Hant")),
              version: \(PhotoStyleWebCoordinator.jsonString(appVersion)),
              build: \(PhotoStyleWebCoordinator.jsonString(buildNumber)),
              configuration: \(PhotoStyleWebCoordinator.jsonString(buildConfiguration)),
              isDebug: \(buildConfiguration == "DEBUG" ? "true" : "false")
            };
            </script>
            </head>
            """
        )
        webView.loadHTMLString(html, baseURL: baseURL)
    }
}
