#pragma once
// Transparent, bounded 64-byte clipboard reports. The companion owns sessions,
// acknowledgement/retry and pasteboard semantics; this owns no clipboard data.
#ifndef _WIN32
#include <array>
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <deque>
#include <fcntl.h>
#include <iostream>
#include <poll.h>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <vector>

namespace wk {
class ClipboardChannel {
public:
    using Report = std::array<uint8_t, 64>;
    static constexpr std::size_t queue_limit = 64;
private:
    std::string path_;
    bool input_only_ = false;
    bool permitted(const Report &report) const {
        return !input_only_ || std::memcmp(report.data(), "WKSC", 4) == 0 ||
            std::memcmp(report.data(), "WKG1", 4) == 0 || std::memcmp(report.data(), "WKG2", 4) == 0;
    }
    int listener_ = -1, client_ = -1;
    dev_t socket_device_ = 0;
    ino_t socket_inode_ = 0;
    Report partial_{};
    std::size_t partial_size_ = 0, write_offset_ = 0;
    std::deque<Report> to_uart_, to_client_;
    uint64_t rejected_ = 0, dropped_ = 0, disconnections_ = 0;
    uint64_t unix_rx_ = 0, uart_rx_ = 0, unix_tx_ = 0, uart_tx_ = 0;
    uint64_t crc_rejected_ = 0, no_client_dropped_ = 0, uart_dropped_ = 0;
    uint64_t disconnect_drop_uart_ = 0, disconnect_drop_unix_ = 0, connections_ = 0;
    std::size_t uart_high_water_ = 0, unix_high_water_ = 0;
    bool stats_dirty_ = false;
    unsigned realtime_burst_ = 0;
    using StatsClock = std::chrono::steady_clock;
    StatsClock::time_point last_stats_ = StatsClock::now();

    void emit_stats() {
        const auto now = StatsClock::now();
        if (!stats_dirty_ || now - last_stats_ < std::chrono::seconds(1)) return;
        last_stats_ = now; stats_dirty_ = false;
        std::cerr << "CPP_CLIPBOARD_STATS unix_rx=" << unix_rx_ << " uart_rx=" << uart_rx_
                  << " unix_tx=" << unix_tx_ << " uart_tx=" << uart_tx_
                  << " crc_reject=" << crc_rejected_ << " format_reject=" << (rejected_ - crc_rejected_)
                  << " queue_drop=" << dropped_ << " no_client_drop=" << no_client_dropped_
                  << " uart_drop=" << uart_dropped_
                  << " disconnect_drop_uart=" << disconnect_drop_uart_
                  << " disconnect_drop_unix=" << disconnect_drop_unix_
                  << " q_uart=" << to_uart_.size() << " q_unix=" << to_client_.size()
                  << " q_uart_max=" << uart_high_water_ << " q_unix_max=" << unix_high_water_
                  << " connections=" << connections_ << " connected=" << (client_ >= 0 ? 1 : 0) << '\n';
    }

    static int nonblocking(int fd) {
        if (fd < 0) return -1;
        const auto flags = ::fcntl(fd, F_GETFL, 0);
        if (flags < 0 || ::fcntl(fd, F_SETFL, flags | O_NONBLOCK) ||
            ::fcntl(fd, F_SETFD, FD_CLOEXEC)) { ::close(fd); return -1; }
#ifdef __APPLE__
        int enabled = 1;
        if (::setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled))) {
            ::close(fd); return -1;
        }
#endif
        return fd;
    }
    static bool same_user(int fd) {
#ifdef __APPLE__
        uid_t uid = 0; gid_t gid = 0;
        return ::getpeereid(fd, &uid, &gid) == 0 && uid == ::geteuid();
#else
        struct ucred credentials{}; socklen_t size = sizeof(credentials);
        return ::getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &size) == 0 &&
               credentials.uid == ::geteuid();
#endif
    }
    void cleanup_socket() noexcept {
        struct stat st{};
        if (socket_inode_ && ::lstat(path_.c_str(), &st) == 0 &&
            st.st_dev == socket_device_ && st.st_ino == socket_inode_ && S_ISSOCK(st.st_mode))
            ::unlink(path_.c_str());
    }
    void close_client(const char *reason, int error = 0) noexcept {
        const bool was_connected = client_ >= 0;
        if (was_connected) ::close(client_);
        disconnect_drop_uart_ += to_uart_.size(); disconnect_drop_unix_ += to_client_.size();
        client_ = -1; partial_size_ = 0; write_offset_ = 0;
        to_uart_.clear(); to_client_.clear(); realtime_burst_ = 0;
        if (was_connected) {
            ++disconnections_; stats_dirty_ = true;
            std::cerr << "CPP_CLIPBOARD_DISCONNECTED reason=" << reason << " errno=" << error << '\n';
        }
    }
    // Detect EOF even when the UART queue is full and POLLIN is backpressured.
    bool disconnected() {
        if (client_ < 0) return true;
        pollfd descriptor{client_, POLLIN | POLLHUP | POLLERR, 0};
        if (::poll(&descriptor, 1, 0) > 0 &&
            (descriptor.revents & (POLLHUP | POLLERR | POLLNVAL))) {
            close_client((descriptor.revents & POLLHUP) ? "POLL_HUP" : "POLL_ERROR"); return true;
        }
        uint8_t byte = 0;
        const auto count = ::recv(client_, &byte, 1, MSG_PEEK);
        if (count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
            close_client(count == 0 ? "EOF" : "RECV_ERROR", count == 0 ? 0 : errno); return true;
        }
        return false;
    }
    void accept_clients() {
        // Bound work even if another same-user process repeatedly connects.
        for (unsigned attempt = 0; attempt < 4; ++attempt) {
            const int accepted = ::accept(listener_, nullptr, nullptr);
            if (accepted < 0) break;
            const int incoming = nonblocking(accepted);
            if (incoming < 0) continue;
            if (client_ >= 0 || !same_user(incoming)) { ::close(incoming); continue; }
            client_ = incoming;
            ++connections_; stats_dirty_ = true;
            std::cerr << "CPP_CLIPBOARD_CONNECTED\n";
        }
    }
    static int unhex(char c) {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        return -1;
    }
    static bool realtime(const Report &report) {
        if (std::memcmp(report.data(), "WKI1", 4) == 0) return true;
        if (std::memcmp(report.data(), "WKB5", 4) == 0) return true;
        return std::memcmp(report.data(), "WKSC", 4) == 0 ||
               std::memcmp(report.data(), "WKG1", 4) == 0 ||
               std::memcmp(report.data(), "WKG2", 4) == 0;
    }
public:
    explicit ClipboardChannel(std::string path, bool input_only = false):
        path_(std::move(path)), input_only_(input_only) {
        sockaddr_un address{}; address.sun_family = AF_UNIX;
        struct stat st{};
        const auto slash = path_.find_last_of('/');
        if (path_.empty() || path_[0] != '/' || path_.find('\0') != std::string::npos ||
            path_.size() >= sizeof(address.sun_path) || slash == std::string::npos ||
            ::lstat(path_.substr(0, slash).c_str(), &st) || !S_ISDIR(st.st_mode) ||
            st.st_uid != ::geteuid() || (st.st_mode & 0077))
            throw std::runtime_error("CLIPBOARD_SOCKET_DIRECTORY_UNSAFE: use an absolute path in a private 0700 directory");
        std::memcpy(address.sun_path, path_.c_str(), path_.size() + 1);
        if (::lstat(path_.c_str(), &st) == 0) {
            if (!S_ISSOCK(st.st_mode) || st.st_uid != ::geteuid())
                throw std::runtime_error("CLIPBOARD_SOCKET_EXISTS");
            const auto old_dev = st.st_dev; const auto old_ino = st.st_ino;
            const int probe = nonblocking(::socket(AF_UNIX, SOCK_STREAM, 0));
            if (probe < 0) throw std::runtime_error("CLIPBOARD_SOCKET_PROBE_FAILED");
            const int connected = ::connect(probe, reinterpret_cast<sockaddr *>(&address), sizeof(address));
            const int error = errno; ::close(probe);
            if (connected == 0 || error != ECONNREFUSED)
                throw std::runtime_error("CLIPBOARD_SOCKET_IN_USE");
            if (::lstat(path_.c_str(), &st) || st.st_dev != old_dev || st.st_ino != old_ino ||
                ::unlink(path_.c_str())) throw std::runtime_error("CLIPBOARD_SOCKET_CHANGED");
        } else if (errno != ENOENT) throw std::runtime_error("CLIPBOARD_SOCKET_STAT_FAILED");
        listener_ = nonblocking(::socket(AF_UNIX, SOCK_STREAM, 0));
        const auto old_mask = ::umask(0077);
        const int bound = listener_ < 0 ? -1 : ::bind(listener_, reinterpret_cast<sockaddr *>(&address), sizeof(address));
        ::umask(old_mask);
        if (bound == 0 && ::lstat(path_.c_str(), &st) == 0) {
            socket_device_ = st.st_dev; socket_inode_ = st.st_ino;
        }
        if (bound || !socket_inode_ || ::chmod(path_.c_str(), 0600) || ::listen(listener_, 4)) {
            if (listener_ >= 0) ::close(listener_);
            listener_ = -1; cleanup_socket(); throw std::runtime_error("CLIPBOARD_SOCKET_FAILED");
        }
        std::cerr << "CPP_CLIPBOARD_LISTENING\n";
    }
    ~ClipboardChannel() { close_client("SHUTDOWN"); emit_stats(); if (listener_ >= 0) ::close(listener_); cleanup_socket(); }
    ClipboardChannel(const ClipboardChannel &) = delete;
    ClipboardChannel &operator=(const ClipboardChannel &) = delete;

    static uint32_t crc32(const Report &report) {
        uint32_t crc = 0xffffffffU;
        for (const auto byte : report) {
            crc ^= byte;
            for (unsigned bit = 0; bit < 8; ++bit)
                crc = (crc >> 1) ^ ((crc & 1U) ? 0xedb88320U : 0U);
        }
        return ~crc;
    }
    static std::string encode(const Report &report) {
        static constexpr char hex[] = "0123456789abcdef";
        std::string result = "C1,";
        result.reserve(141);
        for (const auto byte : report) {
            result += hex[byte >> 4]; result += hex[byte & 15];
        }
        result += ',';
        const auto crc = crc32(report);
        for (int shift = 28; shift >= 0; shift -= 4) result += hex[(crc >> shift) & 15];
        result += '\n'; return result;
    }
    static bool decode(const std::string &line, Report &report, bool *crc_mismatch = nullptr) {
        if (crc_mismatch) *crc_mismatch = false;
        if (line.size() != 140 || line.compare(0, 3, "C1,") || line[131] != ',') return false;
        for (std::size_t i = 0; i < report.size(); ++i) {
            const int high = unhex(line[3 + i * 2]), low = unhex(line[4 + i * 2]);
            if (high < 0 || low < 0) return false;
            report[i] = static_cast<uint8_t>((high << 4) | low);
        }
        uint32_t expected = 0;
        for (std::size_t i = 132; i < line.size(); ++i) {
            const int digit = unhex(line[i]);
            if (digit < 0) return false;
            expected = (expected << 4) | static_cast<uint32_t>(digit);
        }
        const bool matches = expected == crc32(report);
        if (crc_mismatch) *crc_mismatch = !matches;
        return matches;
    }
    // Malformed C1 lines are consumed too: they are never WK1 acknowledgements.
    bool on_line(const std::string &line) {
        if (line != "C1" && line.rfind("C1,", 0) != 0) return false;
        Report report{};
        bool crc_mismatch = false;
        stats_dirty_ = true;
        if (!decode(line, report, &crc_mismatch)) {
            if (crc_mismatch) ++crc_rejected_;
            if (++rejected_ == 1) std::cerr << "CPP_CLIPBOARD_INVALID_FRAME\n";
            return true;
        }
        ++uart_rx_;
        if (!permitted(report)) { ++dropped_; return true; }
        if (client_ < 0) { ++no_client_dropped_; return true; }
        if (to_client_.size() == queue_limit) {
            if (++dropped_ == 1) std::cerr << "CPP_CLIPBOARD_BACKPRESSURE\n";
            return true; // Companion acknowledgement/retry recovers dropped reports.
        }
        to_client_.push_back(report);
        if (to_client_.size() > unix_high_water_) unix_high_water_ = to_client_.size();
        return true;
    }
    void tick() {
        if (client_ >= 0) disconnected();
        accept_clients();
        if (client_ < 0) { emit_stats(); return; }
        for (std::size_t reads = 0; reads < queue_limit && to_uart_.size() < queue_limit; ++reads) {
            const auto n = ::recv(client_, partial_.data() + partial_size_, partial_.size() - partial_size_, 0);
            if (n > 0) {
                partial_size_ += static_cast<std::size_t>(n);
                if (partial_size_ == partial_.size()) {
                    if (!permitted(partial_)) {
                        partial_size_ = 0; ++dropped_; stats_dirty_ = true; continue;
                    }
                    if (realtime(partial_)) {
                        const auto bulk = std::find_if(to_uart_.begin(), to_uart_.end(),
                            [](const Report &item) { return !realtime(item); });
                        to_uart_.insert(bulk, partial_);
                    } else to_uart_.push_back(partial_);
                    partial_size_ = 0;
                    ++unix_rx_; stats_dirty_ = true;
                    if (to_uart_.size() > uart_high_water_) uart_high_water_ = to_uart_.size();
                }
            } else {
                if (n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR))
                    close_client(n == 0 ? "EOF" : "RECV_ERROR", n == 0 ? 0 : errno);
                break;
            }
        }
        for (std::size_t writes = 0; client_ >= 0 && writes < queue_limit && !to_client_.empty(); ++writes) {
            const auto &report = to_client_.front();
#ifdef MSG_NOSIGNAL
            constexpr int send_flags = MSG_NOSIGNAL;
#else
            constexpr int send_flags = 0;
#endif
            const auto n = ::send(client_, report.data() + write_offset_, report.size() - write_offset_, send_flags);
            if (n > 0) {
                write_offset_ += static_cast<std::size_t>(n);
                if (write_offset_ == report.size()) {
                    to_client_.pop_front(); write_offset_ = 0;
                    ++unix_tx_; stats_dirty_ = true;
                }
            } else {
                if (n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR))
                    close_client("SEND_ERROR", n == 0 ? 0 : errno);
                break;
            }
        }
        emit_stats();
    }
    std::string next_frame() {
        if (disconnected() || to_uart_.empty()) return {};
        auto next = to_uart_.begin();
        if (realtime_burst_ >= 16) {
            const auto bulk = std::find_if(to_uart_.begin(), to_uart_.end(),
                [](const Report &item) { return !realtime(item); });
            if (bulk != to_uart_.end()) next = bulk;
        }
        realtime_burst_ = realtime(*next) ? std::min(16U, realtime_burst_ + 1) : 0;
        const auto result = encode(*next); to_uart_.erase(next); stats_dirty_ = true; return result;
    }
    void record_uart_write(bool written) {
        if (written) ++uart_tx_; else ++uart_dropped_;
        stats_dirty_ = true;
    }
    int poll_delay_ms() const { return to_uart_.empty() ? 100 : 0; }
    uint64_t disconnections() const { return disconnections_; }
    void add_poll(std::vector<pollfd> &descriptors) const {
        descriptors.push_back({listener_, POLLIN | POLLHUP | POLLERR, 0});
        if (client_ >= 0) {
            short events = POLLHUP | POLLERR;
            if (to_uart_.size() < queue_limit) events |= POLLIN;
            if (!to_client_.empty()) events |= POLLOUT;
            descriptors.push_back({client_, events, 0});
        }
    }
};
} // namespace wk
#endif
