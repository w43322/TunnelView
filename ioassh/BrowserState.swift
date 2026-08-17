import Foundation
import WebKit

#if os(macOS)
import AppKit
#else
import UIKit
import UniformTypeIdentifiers
#endif

@MainActor
final class BrowserState: NSObject, ObservableObject, WKUIDelegate, WKNavigationDelegate, WKDownloadDelegate {
    let webView: WKWebView
    @Published private(set) var zoomPercentage = 100
    private var loadedSessionID: UUID?
#if !os(macOS)
    private var openPanelCompletion: (([URL]?) -> Void)?
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]
#endif

    override init() {
        webView = WKWebView()
        super.init()
        webView.uiDelegate = self
        webView.navigationDelegate = self
    }

    func load(_ url: URL, for sessionID: UUID) {
        guard loadedSessionID != sessionID else { return }
        loadedSessionID = sessionID
        webView.load(URLRequest(url: url))
    }

    func reload() {
        webView.reload()
    }

    var canZoomOut: Bool {
        zoomPercentage > 50
    }

    var canZoomIn: Bool {
        zoomPercentage < 200
    }

    func zoomOut() {
        setZoom(zoomPercentage - 10)
    }

    func zoomIn() {
        setZoom(zoomPercentage + 10)
    }

    private func setZoom(_ percentage: Int) {
        zoomPercentage = min(max(percentage, 50), 200)
        webView.pageZoom = CGFloat(zoomPercentage) / 100
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.begin { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
#else
        guard openPanelCompletion == nil,
              let presenter = topViewController() else {
            completionHandler(nil)
            return
        }
        openPanelCompletion = completionHandler
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.data],
            asCopy: true
        )
        picker.allowsMultipleSelection = parameters.allowsMultipleSelection
        picker.delegate = self
        presenter.present(picker, animated: true)
#endif
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
#if os(macOS)
        completionHandler(nil)
#else
        let filename = UUID().uuidString + "-" + safeFilename(suggestedFilename)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        downloadDestinations[ObjectIdentifier(download)] = destination
        completionHandler(destination)
#endif
    }

#if !os(macOS)
    func downloadDidFinish(_ download: WKDownload) {
        guard let fileURL = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)),
              let presenter = topViewController() else { return }
        let activity = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        activity.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: fileURL)
        }
        if let popover = activity.popoverPresentationController {
            popover.sourceView = webView
            popover.sourceRect = CGRect(x: webView.bounds.midX, y: webView.bounds.midY, width: 1, height: 1)
        }
        presenter.present(activity, animated: true)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let fileURL = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) else {
            return
        }
        try? FileManager.default.removeItem(at: fileURL)
    }
#endif

    private func safeFilename(_ filename: String) -> String {
        let value = (filename as NSString).lastPathComponent
        return value.isEmpty ? "download" : value
    }

#if !os(macOS)
    private func topViewController() -> UIViewController? {
        var controller = webView.window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
#endif
}

#if !os(macOS)
extension BrowserState: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let completion = openPanelCompletion
        openPanelCompletion = nil
        completion?(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        let completion = openPanelCompletion
        openPanelCompletion = nil
        completion?(nil)
    }
}
#endif
