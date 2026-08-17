import Foundation
import SwiftUI

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
    @Published var browserSessionID = UUID()
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
                self.browserSessionID = UUID()
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
