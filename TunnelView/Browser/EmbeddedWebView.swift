//
//  EmbeddedWebView.swift
//  TunnelView
//
//  Created by wyl on 2026/8/17.
//

import SwiftUI
import WebKit

#if os(macOS)
struct EmbeddedWebView: NSViewRepresentable {
    let url: URL
    let sessionID: UUID
    @ObservedObject var browser: BrowserState

    func makeNSView(context: Context) -> WKWebView {
        browser.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        browser.load(url, for: sessionID)
    }
}
#else
struct EmbeddedWebView: UIViewRepresentable {
    let url: URL
    let sessionID: UUID
    @ObservedObject var browser: BrowserState

    func makeUIView(context: Context) -> ViewportScaledWebView {
        ViewportScaledWebView(webView: browser.webView)
    }

    func updateUIView(_ container: ViewportScaledWebView, context: Context) {
        container.zoomScale = CGFloat(browser.zoomPercentage) / 100
        browser.load(url, for: sessionID)
    }
}

final class ViewportScaledWebView: UIView {
    let webView: WKWebView

    var zoomScale: CGFloat = 1 {
        didSet {
            guard zoomScale != oldValue else { return }
            setNeedsLayout()
        }
    }

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(webView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }

        let scale = max(zoomScale, 0.01)
        webView.transform = .identity
        webView.layer.anchorPoint = .zero
        webView.layer.position = .zero
        webView.bounds = CGRect(
            origin: .zero,
            size: CGSize(width: bounds.width / scale, height: bounds.height / scale)
        )
        webView.transform = CGAffineTransform(scaleX: scale, y: scale)
    }
}
#endif
