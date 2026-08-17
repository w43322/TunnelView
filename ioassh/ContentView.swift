import SwiftUI
import WebKit

@MainActor
final class AppModel: ObservableObject {
    enum Tab: Hashable {
        case browser
        case configuration
    }

    @Published var selectedTab: Tab = .configuration
    @Published var host = ""
    @Published var sshPort = "22"
    @Published var username = ""
    @Published var password = ""
    @Published var servicePort = "8188"
    @Published var browserURL: URL?
    @Published var status = "尚未连接"
    @Published var isConnecting = false
    @Published var isConnected = false

    private let bridge = SSHBridge.shared()

    init() {
        let saved = bridge.savedConfiguration()
        host = saved["host"] as? String ?? ""
        username = saved["username"] as? String ?? ""
        sshPort = String((saved["sshPort"] as? NSNumber)?.intValue ?? 22)
        servicePort = String((saved["servicePort"] as? NSNumber)?.intValue ?? 8188)
        password = bridge.savedPassword()
    }

    var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.isEmpty && !password.isEmpty &&
        validPort(sshPort) != nil && validPort(servicePort) != nil &&
        !isConnecting
    }

    func connect() {
        guard let parsedSSHPort = validPort(sshPort),
              let parsedServicePort = validPort(servicePort) else {
            status = "端口必须是 1–65535 的数字"
            return
        }

        isConnecting = true
        status = "正在连接 SSH…"
        bridge.start(
            withHost: host.trimmingCharacters(in: .whitespacesAndNewlines),
            sshPort: parsedSSHPort,
            username: username,
            password: password,
            servicePort: parsedServicePort
        ) { [weak self] localPort, errorMessage in
            guard let self else { return }
            self.isConnecting = false
            if localPort > 0 {
                self.isConnected = true
                self.status = "已连接，本地端口 \(localPort)"
                self.browserURL = URL(string: "http://127.0.0.1:\(localPort)/")
                self.selectedTab = .browser
            } else {
                self.isConnected = false
                self.browserURL = nil
                self.status = errorMessage ?? "SSH 隧道启动失败"
            }
        }
    }

    func disconnect() {
        bridge.stop()
        isConnected = false
        browserURL = nil
        status = "已断开"
    }

    private func validPort(_ text: String) -> Int? {
        guard let value = Int(text), (1...65535).contains(value) else { return nil }
        return value
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        TabView(selection: $model.selectedTab) {
            BrowserPage(url: model.browserURL)
                .tabItem { Label("浏览器", systemImage: "globe") }
                .tag(AppModel.Tab.browser)

            ConfigurationPage(model: model)
                .tabItem { Label("配置", systemImage: "gearshape") }
                .tag(AppModel.Tab.configuration)
        }
#if os(macOS)
        .frame(minWidth: 680, minHeight: 520)
#endif
    }
}

private struct ConfigurationPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("SSH") {
                TextField("用户名", text: $model.username)
                    .textContentType(.username)
                SecureField("密码", text: $model.password)
                    .textContentType(.password)
                TextField("IP 或域名", text: $model.host)
                    .textContentType(.URL)
                TextField("端口", text: $model.sshPort)
#if os(iOS) || os(visionOS)
                    .keyboardType(.numberPad)
#endif
            }

            Section("服务") {
                TextField("远端端口", text: $model.servicePort)
#if os(iOS) || os(visionOS)
                    .keyboardType(.numberPad)
#endif
            }

            Section {
                HStack {
                    Circle()
                        .fill(model.isConnected ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(model.status)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.isConnecting {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if model.isConnected {
                    Button("断开连接", role: .destructive) {
                        model.disconnect()
                    }
                } else {
                    Button("连接并打开服务") {
                        model.connect()
                    }
                    .disabled(!model.canConnect)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct BrowserPage: View {
    let url: URL?

    var body: some View {
        Group {
            if let url {
                EmbeddedWebView(url: url)
                    .id(url)
            } else {
                ContentUnavailableView(
                    "尚未连接",
                    systemImage: "network.slash",
                    description: Text("在配置页连接 SSH 后，远端服务会显示在这里。")
                )
            }
        }
    }
}

#if os(macOS)
private struct EmbeddedWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        WKWebView()
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }
}
#else
private struct EmbeddedWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        WKWebView()
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }
}
#endif

#Preview {
    ContentView()
}
