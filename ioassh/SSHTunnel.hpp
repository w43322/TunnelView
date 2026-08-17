#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>

class SSHTunnel final {
public:
    struct Configuration {
        std::string host;
        std::string username;
        std::string password;
        uint16_t sshPort = 22;
        std::string serviceHost = "127.0.0.1";
        uint16_t servicePort = 0;
    };

    SSHTunnel() = default;
    ~SSHTunnel();

    SSHTunnel(const SSHTunnel &) = delete;
    SSHTunnel &operator=(const SSHTunnel &) = delete;

    bool start(Configuration configuration,
               uint16_t &localPort,
               std::string &error);
    void stop();
    bool isRunning() const noexcept;

private:
    void run(Configuration configuration);
    void completeStartup(uint16_t localPort, std::string error);

    std::atomic<bool> stopRequested_{false};
    std::atomic<bool> running_{false};
    std::atomic<int> listenerFileDescriptor_{-1};
    std::thread worker_;

    std::mutex startupMutex_;
    std::condition_variable startupCondition_;
    bool startupComplete_ = false;
    uint16_t startupLocalPort_ = 0;
    std::string startupError_;
};
