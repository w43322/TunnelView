import SwiftUI
import WebKit

struct BrowserPage: View {
    let url: URL?
    let sessionID: UUID
    @ObservedObject var browser: BrowserState

    var body: some View {
        NavigationStack {
            Group {
                if let url {
                    EmbeddedWebView(
                        url: url,
                        sessionID: sessionID,
                        browser: browser
                    )
                } else {
                    ContentUnavailableView(
                        "尚未连接",
                        systemImage: "network.slash",
                        description: Text("在配置页连接 SSH 后，远端服务会显示在这里。")
                    )
                }
            }
            .navigationTitle("浏览器")
#if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
#if os(iOS) || os(visionOS)
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 12) {
                        Button {
                            browser.zoomOut()
                        } label: {
                            Image(systemName: "minus")
                        }
                        .disabled(!browser.canZoomOut)
                        .accessibilityLabel("缩小")

                        Text("\(browser.zoomPercentage)%")
                            .monospacedDigit()
                            .frame(minWidth: 44)

                        Button {
                            browser.zoomIn()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .disabled(!browser.canZoomIn)
                        .accessibilityLabel("放大")
                    }
                }
#else
                ToolbarItem(placement: .principal) {
                    ControlGroup {
                        Button {
                            browser.zoomOut()
                        } label: {
                            Image(systemName: "minus")
                        }
                        .disabled(!browser.canZoomOut)
                        .accessibilityLabel("缩小")

                        Text("\(browser.zoomPercentage)%")
                            .monospacedDigit()
                            .frame(minWidth: 48)

                        Button {
                            browser.zoomIn()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .disabled(!browser.canZoomIn)
                        .accessibilityLabel("放大")
                    }
                }
#endif

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        browser.reload()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(url == nil)
                }
            }
        }
    }
}

#if os(macOS)
private struct EmbeddedWebView: NSViewRepresentable {
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
private struct EmbeddedWebView: UIViewRepresentable {
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

private final class ViewportScaledWebView: UIView {
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
