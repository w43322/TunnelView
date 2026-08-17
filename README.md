# TunnelView

TunnelView 是一个面向 iOS 与 macOS 的轻量 SSH 端口转发客户端。它通过 SSH 连接远端主机，把远端主机回环地址上的 Web 服务转发到 App 内部的本地端口，并直接使用内置浏览器显示页面。

典型用途是访问 ComfyUI、开发面板或其他不适合直接暴露在公网的 Web 服务：公网只需要开放 SSH，业务服务可以继续监听远端的 `127.0.0.1`。

## 功能

- 使用 SSH 用户名和密码连接服务器
- 将远端 `127.0.0.1:<服务端口>` 转发到随机分配的本地回环端口
- 在 App 内通过 `WKWebView` 打开转发后的页面
- 配置页与浏览器页相互独立，切换 Tab 不会重新加载页面
- 只有重新建立隧道时才创建新的浏览器会话
- 浏览器支持刷新以及 50%–200% 页面缩放
- 支持网页文件选择；iOS 下载完成后通过系统分享面板导出
- SSH 密码保存在 Keychain，其他连接配置保存在 `UserDefaults`
- libssh 与 Mbed TLS 以源码形式参与 Xcode 构建，不依赖预编译二进制库

## 工作原理

```text
SwiftUI 配置页
      │
      ▼
Objective-C++ 桥接层
      │
      ▼
C++ 本地监听与数据转发 ── libssh / Mbed TLS ── SSH 服务器
      ▲                                      │
      │                                      ▼
WKWebView → 127.0.0.1:随机端口        127.0.0.1:服务端口
```

libssh 提供 SSH 会话、密码认证和 `direct-tcpip` Channel。OpenSSH `ssh -L` 所包含的本地监听与双向数据泵由项目中的 C++ 层实现。

## 技术栈

- UI 与状态管理：SwiftUI / Swift
- 内置浏览器：WebKit / `WKWebView`
- Swift 与 C++ 桥接：Objective-C++
- 隧道实现：C++20、BSD Socket、`poll`
- SSH：libssh 0.12.0
- 密码学后端：Mbed TLS 3.6.7

上游源码位于 Git submodule：

- `Vendor/libssh`
- `Vendor/mbedtls`

Apple 平台所需的生成配置位于 `Vendor/apple-config`。依赖版本与构建裁剪说明见 [`Vendor/README.md`](Vendor/README.md)。

## 构建

当前 Deployment Target：

- iOS 18.5+
- macOS 15.5+

克隆仓库并拉取源码依赖：

```sh
git clone --recurse-submodules https://github.com/w43322/TunnelView.git
cd TunnelView
open TunnelView.xcodeproj
```

如果已经克隆但缺少 `Vendor` 中的依赖：

```sh
git submodule update --init --recursive
```

在 Xcode 中选择 `TunnelView` Scheme 和目标设备后直接运行即可。首次部署真机时，需要配置自己的 Development Team 与签名。

正常构建不需要 CMake、Homebrew 或单独生成静态库；Xcode 工程已经包含 `LibSSH` 和 `MbedCrypto` 源码 Target。`scripts/integrate_ssh_sources.rb` 仅用于从头重建这些 Xcode Target，日常构建无需执行。

## 使用

1. 打开“配置”Tab。
2. 填写 SSH 用户名、密码、IP 或域名以及 SSH 端口。
3. 填写需要访问的远端服务端口。例如，ComfyUI 默认常用 `8188`。
4. 点击“连接服务”。
5. 连接成功后手动切换到“浏览器”Tab。

远端服务必须能够从 SSH 服务器本机通过 `127.0.0.1:<服务端口>` 访问。TunnelView 不要求该服务端口暴露到公网。

## 安全说明

- 隧道的本地监听仅绑定 `127.0.0.1`，不会监听设备的局域网地址。
- SSH 密码写入系统 Keychain，不会存入仓库或普通偏好设置。
- 业务流量通过 SSH 加密传输，但当前版本**尚未校验 SSH 主机密钥**。这意味着它目前不能抵御能够劫持 SSH 连接的中间人攻击。用于正式或不可信网络前，应实现主机指纹首次确认与后续固定校验。
- 当前只支持密码认证，尚未支持私钥、证书、Agent 或交互式认证。
- 不要把真实服务器密码、私钥或生产配置提交到 Git。

## 当前限制

- 每次只维护一个 SSH 会话和一个远端服务端口。
- 转发目标主机固定为 SSH 服务器自身的 `127.0.0.1`。
- 内置浏览器按 HTTP 地址打开本地转发端口。
- iOS 进入后台后，系统可能暂停 App 并中断长期隧道；项目没有申请后台常驻能力。
- 受管设备、按 App VPN、防火墙或 iOA 策略可能在 SSH 握手前拦截连接。放行策略需要匹配 App、目标主机、SSH 端口以及原始 TCP/SSH 流量。

## 排查连接问题

Debug 构建会在 Xcode 控制台输出分阶段日志：

```text
[TunnelView][SSH][DNS]
[TunnelView][SSH][TCP]
[TunnelView][SSH][HANDSHAKE]
[TunnelView][SSH][AUTH]
[TunnelView][SSH][LISTENER]
[TunnelView][SSH][FORWARD]
```

常见判断方式：

- `TCP` 前失败：检查 DNS、目标地址、端口、防火墙和网络策略。
- `TCP` 成功但 `HANDSHAKE` 立即断开：检查 SSH 服务是否真正收到连接，以及 VPN/iOA 是否在本地代理或拦截 Socket。
- `AUTH` 失败：检查用户名、密码和服务器认证策略。
- `FORWARD` 失败：检查 sshd 是否允许 TCP Forwarding，以及远端服务是否正在目标端口监听。
- 隧道成功但页面打不开：先在服务器执行 `curl http://127.0.0.1:<服务端口>/` 验证服务本身。

## 项目结构

```text
TunnelView/
├── TunnelView/Browser/       # 浏览器页面、持久 WKWebView、缩放及文件交互
├── TunnelView/AppModel.swift # 配置、连接状态和浏览器会话状态
├── TunnelView/SSHBridge.mm   # Swift/Objective-C++ 与 C++ 的桥接
├── TunnelView/SSHTunnel.cpp  # SSH 连接、本地监听和双向端口转发
├── Vendor/                   # libssh、Mbed TLS 及 Apple 构建配置
└── scripts/                  # 源码 Target 集成脚本
```

## 第三方许可

libssh 与 Mbed TLS 保留各自的上游许可文件：

- `Vendor/libssh/COPYING`
- `Vendor/mbedtls/LICENSE`

分发应用前，请根据实际发布方式核对并履行所有第三方许可与 App Store 要求。
