import Foundation

extension PhotoStyleWebCoordinator {
    func showLoadError(_ error: Error) {
        let message = error.localizedDescription
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        webView?.loadHTMLString("""
        <html><body style="font-family:-apple-system;padding:24px;background:#ffe5e5;color:#8a1c1c">
        <h2>無法載入工作台</h2><p>\(message)</p>
        </body></html>
        """, baseURL: nil)
    }
}
