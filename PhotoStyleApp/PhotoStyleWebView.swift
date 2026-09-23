import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct PhotoStyleWebView: NSViewRepresentable {
    let coordinator: PhotoStyleWebCoordinator

    func makeNSView(context: Context) -> PhotoStyleDesktopWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .default()
        configuration.userContentController.add(context.coordinator, name: "nativeBridge")
        let webView = PhotoStyleDesktopWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = false
        webView.registerForDraggedTypes([.fileURL])
        webView.photoCoordinator = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.startObservingModelStore()
        loadWebApp(in: webView)
        return webView
    }

    func updateNSView(_ nsView: PhotoStyleDesktopWebView, context: Context) { }
    func makeCoordinator() -> PhotoStyleWebCoordinator { coordinator }

    static func dismantleNSView(_ nsView: PhotoStyleDesktopWebView, coordinator: PhotoStyleWebCoordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "nativeBridge")
        nsView.navigationDelegate = nil
        coordinator.webView = nil
        coordinator.isWebReady = false
        coordinator.cancelStyleComputation()
    }
}

final class PhotoStyleDesktopWebView: WKWebView {
    weak var photoCoordinator: PhotoStyleWebCoordinator?

    private func photoURL(from sender: NSDraggingInfo) -> URL? {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], urls.count == 1, let url = urls.first,
              let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .image) else { return nil }
        return url
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard photoCoordinator?.canImport == true, photoURL(from: sender) != nil else { return [] }
        evaluateJavaScript("document.body.classList.add('file-drag-over')", completionHandler: nil)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        photoCoordinator?.canImport == true && photoURL(from: sender) != nil ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        evaluateJavaScript("document.body.classList.remove('file-drag-over')", completionHandler: nil)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        photoCoordinator?.canImport == true && photoURL(from: sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        draggingExited(sender)
        guard photoCoordinator?.canImport == true, let url = photoURL(from: sender) else { return false }
        photoCoordinator?.openImage(at: url)
        return true
    }
}
