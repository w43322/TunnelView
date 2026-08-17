#include "SSHTunnel.hpp"

#include <libssh/libssh.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <memory>
#include <poll.h>
#include <string_view>
#include <sys/socket.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <unistd.h>
#include <utility>
#include <vector>

namespace {

constexpr std::size_t kBufferLimit = 1024 * 1024;

void tunnelLog(const char *stage, const std::string &message) {
    std::fprintf(stderr, "[TunnelView][SSH][%s] %s\n", stage, message.c_str());
    std::fflush(stderr);
}

class FileDescriptor final {
public:
    explicit FileDescriptor(int value = -1) noexcept : value_(value) {}

    ~FileDescriptor() {
        if (value_ >= 0) {
            close(value_);
        }
    }

    FileDescriptor(const FileDescriptor &) = delete;
    FileDescriptor &operator=(const FileDescriptor &) = delete;

    int get() const noexcept { return value_; }

private:
    int value_;
};

struct SessionDeleter {
    void operator()(ssh_session session) const {
        if (session != nullptr) {
            ssh_disconnect(session);
            ssh_free(session);
        }
    }
};

struct ChannelDeleter {
    void operator()(ssh_channel channel) const {
        if (channel != nullptr) {
            ssh_channel_free(channel);
        }
    }
};

using SessionPointer = std::unique_ptr<ssh_session_struct, SessionDeleter>;
using ChannelPointer = std::unique_ptr<ssh_channel_struct, ChannelDeleter>;

struct ForwardedConnection {
    int localFileDescriptor = -1;
    ChannelPointer channel;
    bool opening = true;
    bool localReadClosed = false;
    bool channelEOFWasSent = false;
    std::vector<uint8_t> pendingForSSH;
    std::vector<uint8_t> pendingForLocal;

    ForwardedConnection(int fd, ssh_channel rawChannel)
        : localFileDescriptor(fd), channel(rawChannel) {}

    ForwardedConnection(ForwardedConnection &&other) noexcept
        : localFileDescriptor(std::exchange(other.localFileDescriptor, -1)),
          channel(std::move(other.channel)),
          opening(other.opening),
          localReadClosed(other.localReadClosed),
          channelEOFWasSent(other.channelEOFWasSent),
          pendingForSSH(std::move(other.pendingForSSH)),
          pendingForLocal(std::move(other.pendingForLocal)) {}

    ForwardedConnection &operator=(ForwardedConnection &&other) noexcept {
        if (this == &other) {
            return *this;
        }
        if (localFileDescriptor >= 0) {
            close(localFileDescriptor);
        }
        localFileDescriptor = std::exchange(other.localFileDescriptor, -1);
        channel = std::move(other.channel);
        opening = other.opening;
        localReadClosed = other.localReadClosed;
        channelEOFWasSent = other.channelEOFWasSent;
        pendingForSSH = std::move(other.pendingForSSH);
        pendingForLocal = std::move(other.pendingForLocal);
        return *this;
    }

    ~ForwardedConnection() {
        if (localFileDescriptor >= 0) {
            close(localFileDescriptor);
        }
    }
};

bool setNonBlocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
}

int connectTCP(const std::string &host,
               uint16_t port,
               std::chrono::seconds timeout,
               std::string &error) {
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;

    addrinfo *addresses = nullptr;
    std::string portString = std::to_string(port);
    int resolveResult = getaddrinfo(host.c_str(), portString.c_str(), &hints, &addresses);
    if (resolveResult != 0) {
        error = "解析 SSH 地址失败: " + std::string(gai_strerror(resolveResult));
        tunnelLog("DNS", error);
        return -1;
    }

    int connectedFD = -1;
    std::string lastFailure = "没有可用地址";
    for (addrinfo *address = addresses; address != nullptr; address = address->ai_next) {
        char numericHost[NI_MAXHOST] = {};
        if (getnameinfo(address->ai_addr,
                        address->ai_addrlen,
                        numericHost,
                        sizeof(numericHost),
                        nullptr,
                        0,
                        NI_NUMERICHOST) != 0) {
            std::snprintf(numericHost, sizeof(numericHost), "%s", "未知地址");
        }
        const std::string endpoint = std::string(numericHost) + ":" + portString;
        tunnelLog("TCP", "正在连接 " + endpoint);

        int fd = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (fd < 0) {
            lastFailure = endpoint + " 创建 socket 失败: " + std::string(strerror(errno));
            tunnelLog("TCP", lastFailure);
            continue;
        }

        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        if (address->ai_family == AF_INET) {
            int tos = 0x48;
            setsockopt(fd, IPPROTO_IP, IP_TOS, &tos, sizeof(tos));
        }

        if (!setNonBlocking(fd)) {
            lastFailure = endpoint + " 设置非阻塞失败: " + std::string(strerror(errno));
            tunnelLog("TCP", lastFailure);
            close(fd);
            continue;
        }

        int result = connect(fd, address->ai_addr, address->ai_addrlen);
        if (result != 0 && errno != EINPROGRESS) {
            lastFailure = endpoint + " 连接失败: " + std::string(strerror(errno));
            tunnelLog("TCP", lastFailure);
            close(fd);
            continue;
        }

        if (result != 0) {
            pollfd descriptor{fd, POLLOUT, 0};
            result = poll(&descriptor, 1, static_cast<int>(timeout.count() * 1000));
            if (result <= 0) {
                lastFailure = result == 0
                    ? endpoint + " 连接超时"
                    : endpoint + " 等待连接失败: " + std::string(strerror(errno));
                tunnelLog("TCP", lastFailure);
                close(fd);
                continue;
            }

            int socketError = 0;
            socklen_t errorLength = sizeof(socketError);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) != 0 ||
                socketError != 0) {
                int failure = socketError != 0 ? socketError : errno;
                lastFailure = endpoint + " 连接失败: " + std::string(strerror(failure));
                tunnelLog("TCP", lastFailure);
                close(fd);
                continue;
            }
        }

        int flags = fcntl(fd, F_GETFL, 0);
        if (flags >= 0) {
            fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
        }
        connectedFD = fd;
        tunnelLog("TCP", "已连接 " + endpoint + "，fd=" + std::to_string(fd));
        break;
    }

    freeaddrinfo(addresses);
    if (connectedFD < 0) {
        error = "无法连接 SSH 服务器: " + lastFailure;
    }
    return connectedFD;
}

int makeLoopbackListener(uint16_t &port, std::string &error) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        error = "无法创建本地监听 socket";
        return -1;
    }

    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    if (bind(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0 ||
        listen(fd, 128) != 0 ||
        !setNonBlocking(fd)) {
        error = "无法监听本地回环端口: " + std::string(strerror(errno));
        close(fd);
        return -1;
    }

    socklen_t addressLength = sizeof(address);
    if (getsockname(fd, reinterpret_cast<sockaddr *>(&address), &addressLength) != 0) {
        error = "无法读取本地监听端口";
        close(fd);
        return -1;
    }

    port = ntohs(address.sin_port);
    return fd;
}

void erasePrefix(std::vector<uint8_t> &buffer, std::size_t count) {
    if (count >= buffer.size()) {
        buffer.clear();
    } else {
        buffer.erase(buffer.begin(), buffer.begin() + static_cast<std::ptrdiff_t>(count));
    }
}

bool flushToLocal(ForwardedConnection &connection) {
    while (!connection.pendingForLocal.empty()) {
        ssize_t written = send(connection.localFileDescriptor,
                               connection.pendingForLocal.data(),
                               connection.pendingForLocal.size(),
                               0);
        if (written > 0) {
            erasePrefix(connection.pendingForLocal, static_cast<std::size_t>(written));
        } else if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            return true;
        } else {
            return false;
        }
    }
    return true;
}

bool flushToSSH(ForwardedConnection &connection) {
    while (!connection.pendingForSSH.empty()) {
        int written = ssh_channel_write(connection.channel.get(),
                                        connection.pendingForSSH.data(),
                                        static_cast<uint32_t>(connection.pendingForSSH.size()));
        if (written > 0) {
            erasePrefix(connection.pendingForSSH, static_cast<std::size_t>(written));
        } else if (written == SSH_AGAIN) {
            return true;
        } else {
            return false;
        }
    }
    return true;
}

} // namespace

SSHTunnel::~SSHTunnel() {
    stop();
}

bool SSHTunnel::start(Configuration configuration,
                      uint16_t &localPort,
                      std::string &error) {
    stop();

    {
        std::lock_guard lock(startupMutex_);
        startupComplete_ = false;
        startupLocalPort_ = 0;
        startupError_.clear();
    }
    stopRequested_ = false;
    worker_ = std::thread(&SSHTunnel::run, this, std::move(configuration));

    std::unique_lock lock(startupMutex_);
    startupCondition_.wait(lock, [this] { return startupComplete_; });
    localPort = startupLocalPort_;
    error = startupError_;
    bool succeeded = error.empty() && localPort != 0;
    lock.unlock();

    if (!succeeded && worker_.joinable()) {
        worker_.join();
    }
    return succeeded;
}

void SSHTunnel::stop() {
    stopRequested_ = true;
    int listener = listenerFileDescriptor_.exchange(-1);
    if (listener >= 0) {
        shutdown(listener, SHUT_RDWR);
        close(listener);
    }
    if (worker_.joinable() && worker_.get_id() != std::this_thread::get_id()) {
        worker_.join();
    }
    running_ = false;
}

bool SSHTunnel::isRunning() const noexcept {
    return running_;
}

void SSHTunnel::completeStartup(uint16_t localPort, std::string error) {
    {
        std::lock_guard lock(startupMutex_);
        startupLocalPort_ = localPort;
        startupError_ = std::move(error);
        startupComplete_ = true;
    }
    startupCondition_.notify_all();
}

void SSHTunnel::run(Configuration configuration) {
    tunnelLog("START", "开始连接 " + configuration.host + ":" +
                           std::to_string(configuration.sshPort));
    std::string error;
    FileDescriptor socket(connectTCP(configuration.host,
                                     configuration.sshPort,
                                     std::chrono::seconds(10),
                                     error));
    if (socket.get() < 0) {
        completeStartup(0, std::move(error));
        return;
    }

    SessionPointer session(ssh_new());
    if (!session) {
        tunnelLog("SESSION", "无法创建 SSH 会话");
        completeStartup(0, "无法创建 SSH 会话");
        return;
    }

    unsigned int sshPort = configuration.sshPort;
    long timeoutSeconds = 10;
    int processConfig = 0;
    int socketFD = socket.get();
#if DEBUG
    int logVerbosity = SSH_LOG_PROTOCOL;
#else
    int logVerbosity = SSH_LOG_WARNING;
#endif
    bool optionsSucceeded =
        ssh_options_set(session.get(), SSH_OPTIONS_HOST, configuration.host.c_str()) == SSH_OK &&
        ssh_options_set(session.get(), SSH_OPTIONS_PORT, &sshPort) == SSH_OK &&
        ssh_options_set(session.get(), SSH_OPTIONS_USER, configuration.username.c_str()) == SSH_OK &&
        ssh_options_set(session.get(), SSH_OPTIONS_TIMEOUT, &timeoutSeconds) == SSH_OK &&
        ssh_options_set(session.get(), SSH_OPTIONS_PROCESS_CONFIG, &processConfig) == SSH_OK &&
        ssh_options_set(session.get(), SSH_OPTIONS_LOG_VERBOSITY, &logVerbosity) == SSH_OK &&
        ssh_options_set(session.get(), SSH_OPTIONS_FD, &socketFD) == SSH_OK;
    if (!optionsSucceeded) {
        std::string message = "设置 SSH 参数失败: " +
                              std::string(ssh_get_error(session.get()));
        tunnelLog("SESSION", message);
        completeStartup(0, std::move(message));
        return;
    }

    tunnelLog("HANDSHAKE", "开始 SSH 握手");
    if (ssh_connect(session.get()) != SSH_OK) {
        std::string message = "SSH 连接失败: " +
                              std::string(ssh_get_error(session.get())) +
                              " (code=" + std::to_string(ssh_get_error_code(session.get())) + ")";
        tunnelLog("HANDSHAKE", message);
        completeStartup(0, std::move(message));
        return;
    }

    tunnelLog("AUTH", "SSH 握手完成，开始密码认证");
    int authenticationResult = ssh_userauth_password(session.get(),
                                                     nullptr,
                                                     configuration.password.c_str());
    std::fill(configuration.password.begin(), configuration.password.end(), '\0');
    configuration.password.clear();
    if (authenticationResult != SSH_AUTH_SUCCESS) {
        std::string message = "SSH 认证失败: " +
                              std::string(ssh_get_error(session.get())) +
                              " (result=" + std::to_string(authenticationResult) + ")";
        tunnelLog("AUTH", message);
        completeStartup(0, std::move(message));
        return;
    }
    tunnelLog("AUTH", "SSH 认证成功");

    uint16_t localPort = 0;
    int listener = makeLoopbackListener(localPort, error);
    if (listener < 0) {
        tunnelLog("LISTENER", error);
        completeStartup(0, std::move(error));
        return;
    }

    listenerFileDescriptor_ = listener;
    ssh_set_blocking(session.get(), 0);
    running_ = true;
    tunnelLog("READY", "本地端口 " + std::to_string(localPort) +
                           " 已映射到远端 " + configuration.serviceHost + ":" +
                           std::to_string(configuration.servicePort));
    completeStartup(localPort, {});

    std::vector<ForwardedConnection> connections;
    std::array<uint8_t, 32 * 1024> transferBuffer{};

    while (!stopRequested_) {
        const std::size_t polledConnectionCount = connections.size();
        std::vector<pollfd> descriptors;
        descriptors.reserve(polledConnectionCount + 1);
        descriptors.push_back({listener, POLLIN, 0});
        for (const auto &connection : connections) {
            short events = 0;
            if (!connection.localReadClosed &&
                connection.pendingForSSH.size() < kBufferLimit) {
                events |= POLLIN;
            }
            if (!connection.pendingForLocal.empty()) {
                events |= POLLOUT;
            }
            descriptors.push_back({connection.localFileDescriptor, events, 0});
        }

        poll(descriptors.data(), static_cast<nfds_t>(descriptors.size()), 10);

        if ((descriptors[0].revents & POLLIN) != 0) {
            while (true) {
                int clientFD = accept(listener, nullptr, nullptr);
                if (clientFD < 0) {
                    break;
                }
                setNonBlocking(clientFD);
                int one = 1;
                setsockopt(clientFD, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
#ifdef SO_NOSIGPIPE
                setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
                ssh_channel channel = ssh_channel_new(session.get());
                if (channel == nullptr) {
                    close(clientFD);
                } else {
                    connections.emplace_back(clientFD, channel);
                }
            }
        }

        // accept() above can append to connections. Those new sockets were not
        // present when descriptors was built, so process them on the next poll.
        for (std::size_t index = 0; index < polledConnectionCount; ++index) {
            auto &connection = connections[index];
            pollfd descriptor = descriptors[index + 1];

            if (connection.opening) {
                int result = ssh_channel_open_forward(connection.channel.get(),
                                                      configuration.serviceHost.c_str(),
                                                      configuration.servicePort,
                                                      "127.0.0.1",
                                                      localPort);
                if (result == SSH_OK) {
                    connection.opening = false;
                    tunnelLog("FORWARD", "远端转发通道已打开");
                } else if (result != SSH_AGAIN) {
                    tunnelLog("FORWARD", "打开远端转发失败: " +
                                             std::string(ssh_get_error(session.get())));
                    connection.localReadClosed = true;
                    connection.channelEOFWasSent = true;
                    shutdown(connection.localFileDescriptor, SHUT_RDWR);
                }
                continue;
            }

            if ((descriptor.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
                connection.localReadClosed = true;
            }

            if ((descriptor.revents & POLLIN) != 0 && !connection.localReadClosed) {
                ssize_t count = recv(connection.localFileDescriptor,
                                     transferBuffer.data(),
                                     transferBuffer.size(),
                                     0);
                if (count > 0) {
                    connection.pendingForSSH.insert(connection.pendingForSSH.end(),
                                                    transferBuffer.begin(),
                                                    transferBuffer.begin() + count);
                } else if (count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK)) {
                    connection.localReadClosed = true;
                }
            }

            if (!flushToSSH(connection) || !flushToLocal(connection)) {
                connection.localReadClosed = true;
                connection.channelEOFWasSent = true;
                shutdown(connection.localFileDescriptor, SHUT_RDWR);
                continue;
            }

            while (connection.pendingForLocal.size() < kBufferLimit) {
                int count = ssh_channel_read_nonblocking(connection.channel.get(),
                                                         transferBuffer.data(),
                                                         static_cast<uint32_t>(transferBuffer.size()),
                                                         0);
                if (count > 0) {
                    connection.pendingForLocal.insert(connection.pendingForLocal.end(),
                                                      transferBuffer.begin(),
                                                      transferBuffer.begin() + count);
                } else {
                    break;
                }
            }
            flushToLocal(connection);

            if (connection.localReadClosed &&
                connection.pendingForSSH.empty() &&
                !connection.channelEOFWasSent) {
                int result = ssh_channel_send_eof(connection.channel.get());
                if (result == SSH_OK) {
                    connection.channelEOFWasSent = true;
                }
            }
        }

        std::erase_if(connections, [](ForwardedConnection &connection) {
            bool channelFinished = !connection.opening &&
                                   ssh_channel_is_eof(connection.channel.get()) &&
                                   connection.pendingForLocal.empty();
            bool failedOpening = connection.opening && connection.channelEOFWasSent;
            if (channelFinished || failedOpening) {
                ssh_channel_close(connection.channel.get());
                return true;
            }
            return false;
        });
    }

    connections.clear();
    int ownedListener = listenerFileDescriptor_.exchange(-1);
    if (ownedListener >= 0) {
        close(ownedListener);
    }
    running_ = false;
    tunnelLog("STOP", "SSH 隧道已停止");
}
