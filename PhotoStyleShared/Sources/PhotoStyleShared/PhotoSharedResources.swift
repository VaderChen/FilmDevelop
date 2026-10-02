import Foundation

/// Xcode App 與獨立引擎均優先載入已封裝資源，再使用 SwiftPM 開發目錄。
enum PhotoSharedResources {
    static let bundle: Bundle = {
        for name in ["PhotoStyleShared_PhotoStyleShared", "PhotoStyleShared"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "bundle"),
               let bundle = Bundle(url: url) { return bundle }
        }
        #if FILMDEVELOP_BUNDLED_RESOURCES
        preconditionFailure("缺少已封裝的 PhotoStyleShared 資源")
        #else
        return .module
        #endif
    }()
}
