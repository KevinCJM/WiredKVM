#pragma once
// Private, leased input commands. This never opens UART or proves Finder success.
#ifndef _WIN32
#include <cerrno>
#include <charconv>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <optional>
#include <poll.h>
#include <sstream>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <vector>

namespace wk {
class FileTransferRuntime {
public:
    enum class Operation { Begin, Key, End };
    struct Action { Operation operation; uint64_t intent; int modifiers = 0, key = 0; };
private:
    using Time = std::chrono::steady_clock;
    std::string path_, state_ = "IDLE", reason_ = "-", buffer_;
    int listener_ = -1, client_ = -1;
    pid_t client_pid_ = -1, owner_pid_ = -1;
    dev_t socket_device_ = 0;
    ino_t socket_inode_ = 0;
    uint64_t intent_ = 0;
    Time::time_point lease_ = Time::time_point::max(), client_deadline_{};
    std::optional<Action> action_;
    bool waiting_ = false, release_ = false;

    static int nonblocking(int fd) {
        if (fd >= 0) {
            fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
            fcntl(fd, F_SETFD, FD_CLOEXEC);
        }
        return fd;
    }
    static bool number(const std::string &s, uint64_t &v) {
        if (s.empty()) return false;
        const auto r = std::from_chars(s.data(), s.data() + s.size(), v);
        return r.ec == std::errc{} && r.ptr == s.data() + s.size();
    }
    static bool peer(int fd, pid_t &pid) {
#ifdef __APPLE__
        uid_t uid = 0; gid_t gid = 0;
        socklen_t size = sizeof(pid);
        return getpeereid(fd, &uid, &gid) == 0 && uid == geteuid() &&
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 && pid > 0;
#else
        struct ucred credentials{}; socklen_t size = sizeof(credentials);
        if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &size) != 0 ||
            credentials.uid != geteuid()) return false;
        pid = credentials.pid; return pid > 0;
#endif
    }
    void close_client() {
        if (client_ >= 0) ::close(client_);
        client_ = -1; client_pid_ = -1; buffer_.clear();
    }
    void reply(const std::string &s) {
        if (client_ >= 0) {
            const auto line = s + "\n";
            // One short response, on an empty local stream; never block input.
            (void)::send(client_, line.data(), line.size(), 0);
        }
        close_client();
    }
    void renew() { lease_ = Time::now() + std::chrono::seconds(10); }
    void command(const std::string &line) {
        std::istringstream input(line);
        std::vector<std::string> fields;
        for (std::string s; input >> s;) fields.push_back(s);
        if (fields.size() == 1 && fields[0] == "STATUS") {
            reply("OK " + state_ + " " + std::to_string(intent_) + " " +
                  (waiting_ ? "1 " : "0 ") + reason_); return;
        }
        uint64_t requested = 0;
        if (fields.size() < 2 || !number(fields[1], requested)) { reply("ERR BAD_COMMAND"); return; }
        if (requested != intent_ || !busy()) { reply("ERR STALE_INTENT"); return; }
        if (owner_pid_ > 0 && client_pid_ != owner_pid_) { reply("ERR WRONG_OWNER"); return; }
        if (fields[0] == "CANCEL" && fields.size() == 2) {
            reply("OK CANCEL " + std::to_string(intent_)); cancel("CANCELLED"); return;
        }
        if (fields[0] == "BEGIN" && fields.size() == 2 && state_ == "PENDING") {
            owner_pid_ = client_pid_; state_ = "ACTIVE"; renew();
            action_ = Action{Operation::Begin, intent_}; waiting_ = true; return;
        }
        if (state_ != "ACTIVE") { reply("ERR NEED_BEGIN"); return; }
        if (fields[0] == "KEEP" && fields.size() == 2) {
            renew(); reply("OK ACTIVE " + std::to_string(intent_)); return;
        }
        if (fields[0] == "END" && fields.size() == 2) {
            renew(); action_ = Action{Operation::End, intent_}; waiting_ = true; return;
        }
        uint64_t modifiers = 0, key = 0;
        if (fields[0] == "KEY" && fields.size() == 4 && number(fields[2], modifiers) &&
            number(fields[3], key) && modifiers <= 15 &&
            (key == 0 || (key >= 4 && key <= 223))) {
            renew(); action_ = Action{Operation::Key, intent_, int(modifiers), int(key)};
            waiting_ = true; return;
        }
        reply("ERR BAD_COMMAND");
    }
    void cleanup_socket() noexcept {
        struct stat st{};
        if (socket_inode_ && lstat(path_.c_str(), &st) == 0 &&
            st.st_dev == socket_device_ && st.st_ino == socket_inode_ && S_ISSOCK(st.st_mode))
            ::unlink(path_.c_str());
    }
public:
    explicit FileTransferRuntime(std::string path): path_(std::move(path)) {
        sockaddr_un address{}; address.sun_family = AF_UNIX;
        struct stat st{};
        const auto slash = path_.find_last_of('/');
        if (path_.empty() || path_.size() >= sizeof(address.sun_path) || slash == std::string::npos ||
            lstat(path_.substr(0, slash).c_str(), &st) || !S_ISDIR(st.st_mode) ||
            st.st_uid != geteuid() || (st.st_mode & 0022))
            throw std::runtime_error("FILE_SOCKET_DIRECTORY_UNSAFE");
        std::memcpy(address.sun_path, path_.c_str(), path_.size() + 1);
        if (lstat(path_.c_str(), &st) == 0) {
            if (!S_ISSOCK(st.st_mode) || st.st_uid != geteuid())
                throw std::runtime_error("FILE_SOCKET_EXISTS");
            const auto old_dev = st.st_dev; const auto old_ino = st.st_ino;
            const int probe = nonblocking(::socket(AF_UNIX, SOCK_STREAM, 0));
            const int connected = ::connect(probe, reinterpret_cast<sockaddr *>(&address), sizeof(address));
            const int error = errno; if (probe >= 0) ::close(probe);
            if (connected == 0 || error != ECONNREFUSED) throw std::runtime_error("FILE_SOCKET_IN_USE");
            if (lstat(path_.c_str(), &st) || st.st_dev != old_dev || st.st_ino != old_ino ||
                ::unlink(path_.c_str())) throw std::runtime_error("FILE_SOCKET_CHANGED");
        } else if (errno != ENOENT) throw std::runtime_error("FILE_SOCKET_STAT_FAILED");
        listener_ = nonblocking(::socket(AF_UNIX, SOCK_STREAM, 0));
        const auto old_mask = ::umask(0077);
        const int bound = listener_ < 0 ? -1 : ::bind(listener_, reinterpret_cast<sockaddr *>(&address), sizeof(address));
        ::umask(old_mask);
        if (bound == 0 && lstat(path_.c_str(), &st) == 0) {
            socket_device_ = st.st_dev; socket_inode_ = st.st_ino;
        }
        if (bound || ::chmod(path_.c_str(), 0600) || ::listen(listener_, 4)) {
            if (listener_ >= 0) ::close(listener_);
            listener_ = -1; cleanup_socket(); throw std::runtime_error("FILE_SOCKET_FAILED");
        }
        // Intent ids are monotonic within a process and unlikely to repeat across restarts.
        intent_ = uint64_t(Time::now().time_since_epoch().count()) & ((uint64_t(1) << 52) - 1);
    }
    ~FileTransferRuntime() { close_client(); if (listener_ >= 0) ::close(listener_); cleanup_socket(); }
    FileTransferRuntime(const FileTransferRuntime &) = delete;
    FileTransferRuntime &operator=(const FileTransferRuntime &) = delete;
    bool busy() const { return state_ != "IDLE"; }
    uint64_t intent() const { return intent_; }
    uint64_t offer() {
        cancel("REPLACED"); ++intent_; state_ = "PENDING"; reason_ = "-"; owner_pid_ = -1; renew();
        return intent_;
    }
    void cancel(const std::string &reason) {
        if (!busy() && !waiting_) return;
        if (waiting_) reply("ERR CANCELLED " + reason);
        state_ = "IDLE"; reason_ = reason; owner_pid_ = -1; lease_ = Time::time_point::max();
        action_.reset(); waiting_ = false; release_ = true;
    }
    bool take_release() { const bool result = release_; release_ = false; return result; }
    std::optional<Action> take_action() { auto result = action_; action_.reset(); return result; }
    void acknowledged(Operation operation, uint64_t id) {
        if (!waiting_ || state_ != "ACTIVE" || id != intent_) return;
        waiting_ = false;
        const auto name = operation == Operation::Begin ? "ACTIVE" : operation == Operation::Key ? "KEY" : "END";
        reply(std::string("OK ") + name + " " + std::to_string(intent_));
        if (operation == Operation::End) {
            state_ = "IDLE"; reason_ = "-"; owner_pid_ = -1; lease_ = Time::time_point::max();
        }
    }
    void add_poll(std::vector<pollfd> &fds) const {
        if (listener_ >= 0 && client_ < 0) fds.push_back({listener_, POLLIN, 0});
        if (client_ >= 0) fds.push_back({client_, POLLIN | POLLHUP, 0});
    }
    int poll_delay_ms() const { return busy() || client_ >= 0 ? 10 : 100; }
    void tick() {
        const auto now = Time::now();
        if (busy() && now >= lease_) cancel("LEASE_EXPIRED");
        if (owner_pid_ > 0 && ::kill(owner_pid_, 0) != 0 && errno == ESRCH) cancel("OWNER_EXITED");
        if (client_ < 0) {
            client_ = nonblocking(::accept(listener_, nullptr, nullptr));
            if (client_ >= 0) {
                if (!peer(client_, client_pid_)) { reply("ERR PEER_DENIED"); return; }
                client_deadline_ = now + std::chrono::seconds(2);
            }
        }
        if (client_ >= 0) {
            char bytes[128];
            const auto count = ::recv(client_, bytes, sizeof(bytes), waiting_ ? MSG_PEEK : 0);
            if (count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
                close_client(); if (waiting_) cancel("CLIENT_DISCONNECTED");
            } else if (count > 0 && !waiting_) {
                buffer_.append(bytes, size_t(count));
                const auto newline = buffer_.find('\n');
                if (buffer_.size() > 128 || (newline != std::string::npos && newline + 1 != buffer_.size()))
                    reply("ERR BAD_COMMAND");
                else if (newline != std::string::npos) command(buffer_.substr(0, newline));
            } else if (count > 0 && waiting_) {
                cancel("CLIENT_PIPELINED");
            }
        }
        if (client_ >= 0 && now >= client_deadline_) {
            if (waiting_) cancel("IPC_TIMEOUT"); else reply("ERR IPC_TIMEOUT");
        }
    }
};
} // namespace wk
#endif
