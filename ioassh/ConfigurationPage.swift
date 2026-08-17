import SwiftUI

struct ConfigurationPage: View {
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
                    Button("连接服务") {
                        model.connect()
                    }
                    .disabled(!model.canConnect)
                }
            }
        }
        .formStyle(.grouped)
    }
}
