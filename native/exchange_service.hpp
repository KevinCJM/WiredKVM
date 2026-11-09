#pragma once
// One UART owner multiplexes X1 storage packets with WK1 HID. Disk I/O runs
// off the input loop; the GUI must unmount the image before PUBLISH.
#ifndef _WIN32
#include <algorithm>
#include <array>
#include <charconv>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <future>
#include <random>
#include <string>
#include <string_view>
#include <vector>
#include <fcntl.h>
#include <poll.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

namespace wk {
inline uint32_t exchange_crc(std::string_view text) {
    uint32_t crc = 0xffffffffu;
    for (unsigned char c : text) {
        crc ^= c;
        for (int i = 0; i != 8; ++i) crc = (crc >> 1) ^ ((crc & 1) ? 0xedb88320u : 0);
    }
    return ~crc;
}
inline std::string exchange_frame(const std::string &body) {
    char tail[11];
    std::snprintf(tail, sizeof(tail), ",%08x\n", exchange_crc(body));
    return body + tail;
}
inline bool exchange_number(std::string_view s, uint32_t &out) {
    if (s.empty()) return false;
    auto result = std::from_chars(s.data(), s.data() + s.size(), out);
    return result.ec == std::errc{} && result.ptr == s.data() + s.size();
}
inline bool exchange_parse(const std::string &line, std::vector<std::string_view> &parts) {
    if (line.size() > 1152 || line.rfind("X1,", 0) != 0) return false;
    const auto comma = line.rfind(',');
    if (comma == std::string::npos || line.size() - comma != 9) return false;
    uint32_t crc = 0;
    auto result = std::from_chars(line.data() + comma + 1, line.data() + line.size(), crc, 16);
    if (result.ec != std::errc{} || result.ptr != line.data() + line.size() ||
        crc != exchange_crc(std::string_view(line.data(), comma))) return false;
    parts.clear();
    for (std::size_t start = 0; start < comma;) {
        const auto next = line.find(',', start);
        parts.emplace_back(line.data() + start, next - start);
        start = next + 1;
    }
    return !parts.empty();
}

class ExchangeService {
    using Time = std::chrono::steady_clock;
    struct IOResult {
        uint32_t generation, request; bool ok; std::string data;
        bool write = false; uint32_t length = 0;
    };
    std::string image_, socket_, marker_, state_ = "OFFLINE", error_;
    int listener_ = -1, client_ = -1, image_fd_ = -1;
    uint64_t bytes_ = 0;
    uint32_t generation_ = 0;
    uint64_t write_sequence_ = 0, read_bytes_ = 0, write_bytes_ = 0;
    bool capable_ = false, dirty_ = false, local_pending_ = false;
    bool read_only_ = false, local_absent_ = false;
    bool board_setup_ = false;
    uint32_t image_crc_ = 0;
    bool publish_withdraw_ = false, ejected_ = false, remote_seen_ = false;
    std::string client_buffer_;
    std::future<IOResult> job_;
    std::deque<std::string> outgoing_;
    Time::time_point heartbeat_ = Time::now(), command_deadline_ = Time::time_point::max();
    Time::time_point client_deadline_ = Time::time_point::max();
    Time::time_point publish_retry_ = Time::time_point::max();

    static int nonblocking(int fd) {
        if (fd >= 0) { fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK); fcntl(fd, F_SETFD, FD_CLOEXEC); }
        return fd;
    }
    void fail(const std::string &reason) { state_ = "ERROR"; error_ = reason; }
    void enqueue(const std::string &body) {
        if (outgoing_.size() >= 8) { fail("QUEUE_FULL"); return; }
        outgoing_.push_back(exchange_frame(body));
    }
    void close_image() { if (image_fd_ >= 0) { ::close(image_fd_); image_fd_ = -1; } }
    std::string publish_command() const {
        if (board_setup_) return "X1,J," + std::to_string(generation_) + "," +
            std::to_string(bytes_ / 512) + "," + std::to_string(image_crc_);
        return std::string(read_only_ ? "X1,I," : "X1,P,") + std::to_string(generation_) + "," +
               std::to_string(bytes_ / 512);
    }
    void finish_read_only_local() {
        if (!read_only_ || !local_pending_ || !local_absent_ || job_.valid()) return;
        close_image(); outgoing_.clear(); local_pending_ = false; local_absent_ = false;
        remote_seen_ = false; state_ = "LOCAL"; error_.clear();
        command_deadline_ = Time::time_point::max(); reply_client(status());
    }
    bool sync_parent() {
        const auto slash = image_.find_last_of('/');
        const std::string parent = slash == std::string::npos ? "." : image_.substr(0, slash);
        const int fd = ::open(parent.c_str(), O_RDONLY | O_CLOEXEC | O_DIRECTORY);
        if (fd < 0) return false;
        const bool ok = ::fsync(fd) == 0;
        ::close(fd);
        return ok;
    }
    std::string identity(const struct stat &st) const {
        return "WKX1 " + std::to_string(static_cast<uint64_t>(st.st_dev)) + " " +
               std::to_string(static_cast<uint64_t>(st.st_ino)) + " " + std::to_string(bytes_) + "\n";
    }
    bool mark_dirty(const struct stat &st) {
        const std::string expected = identity(st);
        if (dirty_) {
            const int fd = ::open(marker_.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
            if (fd < 0) { fail("DIRTY_MARKER_INVALID"); return false; }
            struct stat marker_stat{}; char buf[256];
            const auto size = ::read(fd, buf, sizeof(buf));
            const bool ok = fstat(fd, &marker_stat) == 0 && S_ISREG(marker_stat.st_mode) &&
                            marker_stat.st_uid == geteuid() && size >= 0 &&
                            std::string(buf, static_cast<std::size_t>(size)) == expected;
            ::close(fd);
            if (!ok) fail("IMAGE_CHANGED");
            return ok;
        }
        const int fd = ::open(marker_.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd < 0) { dirty_ = true; fail("DIRTY_MARKER_FAILED"); return false; }
        dirty_ = true; // Preserve on every partial write/failure; never assume clean.
        const bool ok = ::write(fd, expected.data(), expected.size()) == static_cast<ssize_t>(expected.size()) &&
                        ::fsync(fd) == 0;
        ::close(fd);
        if (!ok || !sync_parent()) { fail("DIRTY_MARKER_FAILED"); return false; }
        return true;
    }
    bool open_image() {
        close_image();
        const int fd = ::open(image_.c_str(), (read_only_ ? O_RDONLY : O_RDWR) | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
        if (fd < 0) { fail("IMAGE_OPEN_FAILED"); return false; }
        struct stat st{};
        if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != geteuid() ||
            st.st_size < 512 || st.st_size % 512 || uint64_t(st.st_size) / 512 > UINT32_MAX) {
            ::close(fd); fail("IMAGE_INVALID"); return false;
        }
        if (flock(fd, LOCK_EX | LOCK_NB)) { ::close(fd); fail("IMAGE_BUSY"); return false; }
        image_fd_ = fd; bytes_ = static_cast<uint64_t>(st.st_size);
        if (board_setup_) {
            // Match the complete, immutable image against the validated board
            // partition. Never silently publish a stale installer of equal size.
            if (bytes_ > 12U * 1024U * 1024U - 4096U) { close_image(); fail("SETUP_TOO_LARGE"); return false; }
            std::string contents(static_cast<std::size_t>(bytes_), '\0');
            std::size_t at = 0;
            while (at < contents.size()) {
                auto n = ::pread(fd, contents.data() + at, contents.size() - at, static_cast<off_t>(at));
                if (n < 0 && errno == EINTR) continue;
                if (n <= 0) { close_image(); fail("SETUP_READ_FAILED"); return false; }
                at += static_cast<std::size_t>(n);
            }
            image_crc_ = exchange_crc(contents);
        }
        if (!read_only_ && !mark_dirty(st)) { close_image(); return false; }
        return true;
    }
    void finish_eject() {
        if (!ejected_ || job_.valid()) return;
        close_image();
        if (!read_only_ && (::unlink(marker_.c_str()) != 0 || !sync_parent())) { fail("DIRTY_CLEAR_FAILED"); return; }
        dirty_ = false; ejected_ = false; remote_seen_ = false;
        outgoing_.clear(); state_ = "EJECTED"; error_.clear();
    }
    void reply_client(const std::string &answer) {
        const auto line = answer + "\n";
        if (client_ >= 0) {
            // Replies are under 128 bytes and the socket is local/nonblocking.
            (void)::send(client_, line.data(), line.size(), 0);
            ::close(client_); client_ = -1;
        }
        client_buffer_.clear();
    }
    std::string status() const {
        return "OK " + state_ + " " + std::to_string(bytes_) +
               (error_.empty() ? "" : " " + error_);
    }
    void command(std::string line) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line == "STATUS") { reply_client(status()); return; }
        if (line == "STATUS2") {
            // Observations only: byte counts and storage quiescence never
            // prove an entire Finder copy completed or grant ownership.
            reply_client("OK " + state_ + " " + std::to_string(bytes_) + " " +
                std::to_string(generation_) + " " + std::to_string(write_sequence_) + " " +
                std::to_string(read_bytes_) + " " + std::to_string(write_bytes_) + " " +
                (job_.valid() ? "1 " : "0 ") + (dirty_ ? "1 " : "0 ") +
                (error_.empty() ? "-" : error_)); return;
        }
        if (!capable_) { reply_client("ERR CAP_UNSUPPORTED"); return; }
        if (line == "LOCAL") {
            if (read_only_) {
                if (!generation_) {
                    if (remote_seen_) { reply_client("ERR MEDIA_NOT_OWNED"); return; }
                    state_ = "LOCAL"; error_.clear(); reply_client(status()); return;
                }
                if (state_ == "LOCAL") { reply_client(status()); return; }
                if (!local_pending_) {
                    local_pending_ = true; local_absent_ = false; publish_withdraw_ = false;
                    publish_retry_ = Time::time_point::max();
                    state_ = "WITHDRAWING"; outgoing_.clear();
                    command_deadline_ = Time::now() + std::chrono::seconds(2);
                    enqueue("X1,O," + std::to_string(generation_));
                }
                return; // Close the read-only image only after ABSENT and the last read finish.
            }
            if (dirty_ || remote_seen_) { reply_client("ERR NEED_EJECT"); return; }
            if (state_ == "LOCAL") { reply_client(status()); return; }
            if (!local_pending_) {
                local_pending_ = true;
                command_deadline_ = Time::now() + std::chrono::seconds(2);
                enqueue("X1,O,0");
            }
            // Keep this client until withdrawal is acknowledged. STATUS never
            // grants local ownership merely because a timer or cable expired.
            return;
        }
        if (line == "PUBLISH") {
            if (state_ == "REMOTE" || state_ == "PUBLISHING") { reply_client(status()); return; }
            if (read_only_ && remote_seen_ && generation_ == 0) { reply_client("ERR MEDIA_NOT_OWNED"); return; }
            if (job_.valid()) { reply_client("ERR BUSY"); return; }
            if (!open_image()) { reply_client("ERR " + error_); return; }
            generation_ = std::random_device{}();
            if (generation_ == 0) generation_ = 1;
            write_sequence_ = read_bytes_ = write_bytes_ = 0;
            outgoing_.clear(); ejected_ = false; local_pending_ = false; local_absent_ = false;
            state_ = "PUBLISHING"; error_.clear(); publish_withdraw_ = !read_only_;
            publish_retry_ = Time::time_point::max();
            command_deadline_ = Time::now() + std::chrono::seconds(2);
            // Setup must not retire an unknown (possibly writable) mounted disk.
            enqueue(read_only_ ? publish_command() : "X1,O,0");
            reply_client(status()); return;
        }
        reply_client("ERR BAD_COMMAND");
    }
    void request(const std::vector<std::string_view> &p) {
        uint32_t generation, id, lba, offset, length = 0;
        if (p.size() != 7 || !exchange_number(p[2], generation) || !exchange_number(p[3], id) ||
            !exchange_number(p[4], lba) || !exchange_number(p[5], offset)) return;
        const bool write = p[1] == "W";
        std::string payload;
        if (write) {
            if (p[6].empty() || p[6].size() > 1024 || p[6].size() % 2) return;
            length = static_cast<uint32_t>(p[6].size() / 2);
            for (std::size_t i = 0; i < p[6].size(); i += 2) {
                unsigned value = 0;
                auto result = std::from_chars(p[6].data() + i, p[6].data() + i + 2, value, 16);
                if (result.ec != std::errc{} || result.ptr != p[6].data() + i + 2) return;
                payload.push_back(static_cast<char>(value));
            }
        } else if (!exchange_number(p[6], length)) return;
        if (generation != generation_) return; // A delayed old request must not touch this image.
        auto reject = [&] { enqueue("X1,F," + std::to_string(generation) + "," + std::to_string(id)); };
        if (board_setup_ || (read_only_ && write)) { reject(); return; }
        if (state_ != "REMOTE" || image_fd_ < 0 || job_.valid() || offset >= 512 ||
            length == 0 || length > 512 - offset || uint64_t(lba) >= bytes_ / 512) { reject(); return; }
        const int fd = image_fd_;
        const off_t position = static_cast<off_t>(uint64_t(lba) * 512 + offset);
        job_ = std::async(std::launch::async, [fd, position, length, write, payload, generation, id]() {
            IOResult result{generation, id, false, {}};
            result.write = write; result.length = length;
            std::string data = write ? payload : std::string(length, '\0');
            std::size_t done = 0;
            while (done < length) {
                const auto n = write ? ::pwrite(fd, data.data() + done, length - done, position + done)
                                     : ::pread(fd, data.data() + done, length - done, position + done);
                if (n < 0 && errno == EINTR) continue;
                if (n <= 0) return result;
                done += static_cast<std::size_t>(n);
            }
            if (write && ::fsync(fd) != 0) return result;
            result.ok = true;
            if (!write) {
                static constexpr char hex[] = "0123456789abcdef";
                for (unsigned char c : data) { result.data += hex[c >> 4]; result.data += hex[c & 15]; }
            }
            return result;
        });
    }
public:
    ExchangeService(std::string image, std::string socket, bool read_only = false, bool board_setup = false):
        image_(std::move(image)), socket_(std::move(socket)), marker_(read_only ? "" : image_ + ".remote_dirty"),
        read_only_(read_only), board_setup_(board_setup) {
        if (board_setup_ && !read_only_) throw std::runtime_error("board setup must be read-only");
        struct stat st{};
        dirty_ = !read_only_ && lstat(marker_.c_str(), &st) == 0;
        if (dirty_) error_ = "NEED_EJECT";
        if (lstat(image_.c_str(), &st) == 0 && S_ISREG(st.st_mode)) bytes_ = st.st_size;
        sockaddr_un address{}; address.sun_family = AF_UNIX;
        if (socket_.empty() || socket_.size() >= sizeof(address.sun_path)) { fail("SOCKET_PATH_INVALID"); return; }
        const auto slash = socket_.find_last_of('/');
        if (slash == std::string::npos || lstat(socket_.substr(0, slash).c_str(), &st) ||
            !S_ISDIR(st.st_mode) || st.st_uid != geteuid() || (st.st_mode & 0022)) { fail("SOCKET_DIRECTORY_UNSAFE"); return; }
        std::memcpy(address.sun_path, socket_.c_str(), socket_.size() + 1);
        if (lstat(socket_.c_str(), &st) == 0) {
            if (!S_ISSOCK(st.st_mode) || st.st_uid != geteuid()) { fail("SOCKET_EXISTS"); return; }
            const int probe = ::socket(AF_UNIX, SOCK_STREAM, 0);
            const int connected = ::connect(probe, reinterpret_cast<sockaddr *>(&address), sizeof(address));
            const int failure = errno; ::close(probe);
            if (connected == 0 || failure != ECONNREFUSED) { fail("SOCKET_IN_USE"); return; }
            if (::unlink(socket_.c_str())) { fail("SOCKET_EXISTS"); return; }
        }
        listener_ = nonblocking(::socket(AF_UNIX, SOCK_STREAM, 0));
        if (listener_ < 0 || ::bind(listener_, reinterpret_cast<sockaddr *>(&address), sizeof(address)) ||
            ::chmod(socket_.c_str(), 0600) || ::listen(listener_, 4)) { fail("SOCKET_FAILED"); }
    }
    ~ExchangeService() {
        if (job_.valid()) job_.wait();
        close_image();
        if (client_ >= 0) ::close(client_);
        if (listener_ >= 0) { ::close(listener_); ::unlink(socket_.c_str()); }
    }
    ExchangeService(const ExchangeService &) = delete;
    ExchangeService &operator=(const ExchangeService &) = delete;
    static std::string query() { return exchange_frame("X1,Q,0"); }
    void unsupported() { capable_ = false; error_ = "CAP_UNSUPPORTED"; }
    bool on_line(const std::string &line) {
        if (line.rfind("X1,", 0) != 0) return false;
        std::vector<std::string_view> p;
        if (!exchange_parse(line, p)) return true;
        if (p.size() == 4 && p[1] == "S") {
            uint32_t generation;
            if (!exchange_number(p[2], generation)) return true;
            capable_ = true;
            if (error_ == "CAP_UNSUPPORTED") error_.clear();
            if (p[3] == "ABSENT" && publish_withdraw_) {
                publish_withdraw_ = false;
                enqueue(publish_command());
                command_deadline_ = Time::now() + std::chrono::seconds(2);
            } else if (p[3] == "ABSENT" && read_only_ && local_pending_ && generation == generation_) {
                local_absent_ = true; finish_read_only_local();
            } else if (p[3] == "ABSENT" && !read_only_ && local_pending_ && !dirty_) {
                local_pending_ = false; remote_seen_ = false; state_ = "LOCAL"; error_.clear();
                command_deadline_ = Time::time_point::max(); reply_client(status());
            } else if ((p[3] == "ABSENT" || p[3] == "EJECTED") && generation_ == 0 &&
                       !dirty_ && !remote_seen_ && !local_pending_ && state_ == "OFFLINE") {
                // A supported, idle device is available. This is deliberately
                // not a LOCAL lease: LOCAL must still get its own O/ABSENT ACK.
                state_ = "AVAILABLE"; error_.clear();
            } else if (p[3] == "PRESENT") {
                remote_seen_ = true;
                if (generation == generation_ && state_ == "PUBLISHING") {
                    state_ = "REMOTE"; heartbeat_ = Time::now(); command_deadline_ = Time::time_point::max();
                    publish_retry_ = Time::time_point::max();
                }
            } else if (p[3] == "EJECTED" && generation == generation_ && state_ == "REMOTE") {
                ejected_ = true; finish_eject();
            } else if (p[3] == "BUSY" && state_ == "PUBLISHING" && !publish_withdraw_) {
                // TinyUSB may still be completing an old request after O ACK.
                // Retry this not-yet-published generation, within the same deadline.
                publish_retry_ = Time::now() + std::chrono::milliseconds(20);
            } else if ((p[3] == "OFFLINE" || p[3] == "ERROR" || p[3] == "BUSY") &&
                       (generation == generation_ || state_ == "PUBLISHING")) {
                state_ = p[3] == "OFFLINE" ? "OFFLINE" : "ERROR";
                error_ = p[3] == "BUSY" ? "DEVICE_BUSY" :
                    (read_only_ ? (p[3] == "OFFLINE" ? "DEVICE_OFFLINE" : "DEVICE_ERROR") : "NEED_EJECT");
                outgoing_.clear(); publish_withdraw_ = false;
                publish_retry_ = Time::time_point::max();
            }
        } else if (board_setup_ && p.size() == 4 && p[1] == "T") {
            uint32_t generation, bytes;
            if (exchange_number(p[2], generation) && exchange_number(p[3], bytes) &&
                generation == generation_ && state_ == "REMOTE") read_bytes_ = bytes;
        } else if (p.size() >= 2 && (p[1] == "R" || p[1] == "W")) request(p);
        return true;
    }
    bool capable() const { return capable_; }
    int poll_delay_ms() const { return job_.valid() ? 2 : 100; }
    void add_poll(std::vector<pollfd> &fds) const {
        if (listener_ >= 0) fds.push_back({listener_, POLLIN, 0});
        if (client_ >= 0) fds.push_back({client_, POLLIN | POLLHUP, 0});
    }
    void tick() {
        const auto now = Time::now();
        if (listener_ >= 0 && client_ < 0) {
            client_ = nonblocking(::accept(listener_, nullptr, nullptr));
            if (client_ >= 0) client_deadline_ = now + std::chrono::seconds(3);
        }
        if (client_ >= 0 && !local_pending_) {
            char buf[128]; const auto count = ::read(client_, buf, sizeof(buf));
            if (count > 0) {
                client_buffer_.append(buf, static_cast<std::size_t>(count));
                const auto newline = client_buffer_.find('\n');
                if (newline != std::string::npos) command(client_buffer_.substr(0, newline));
                else if (client_buffer_.size() > 64) reply_client("ERR BAD_COMMAND");
            } else if (count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
                ::close(client_); client_ = -1; client_buffer_.clear();
            }
        }
        if (client_ >= 0 && now >= client_deadline_) reply_client("ERR IPC_TIMEOUT");
        if (now >= command_deadline_) {
            command_deadline_ = Time::time_point::max(); local_pending_ = false; publish_withdraw_ = false;
            publish_retry_ = Time::time_point::max();
            fail("DEVICE_TIMEOUT"); outgoing_.clear(); reply_client("ERR DEVICE_TIMEOUT");
        }
        if (state_ == "PUBLISHING" && now >= publish_retry_) {
            publish_retry_ = Time::time_point::max();
            enqueue(publish_command());
        }
        if (job_.valid() && job_.wait_for(std::chrono::seconds(0)) == std::future_status::ready) {
            auto result = job_.get();
            if (result.ok && result.generation == generation_) {
                if (result.write) { ++write_sequence_; write_bytes_ += result.length; }
                else read_bytes_ += result.length;
            }
            if (result.generation == generation_ && state_ == "REMOTE" && !ejected_) {
                const std::string prefix = "X1," + std::string(result.ok ? (result.data.empty() ? "A," : "D,") : "F,") +
                    std::to_string(result.generation) + "," + std::to_string(result.request);
                enqueue(prefix + (result.ok && !result.data.empty() ? "," + result.data : ""));
            }
            if (!result.ok) { ejected_ = false; fail("IMAGE_IO_FAILED"); }
            finish_eject();
            finish_read_only_local();
        }
        if (state_ == "REMOTE" && now - heartbeat_ >= std::chrono::milliseconds(500)) {
            enqueue("X1,H," + std::to_string(generation_)); heartbeat_ = now;
        }
    }
    std::string next_frame() {
        if (outgoing_.empty()) return {};
        auto result = std::move(outgoing_.front()); outgoing_.pop_front(); return result;
    }
};
} // namespace wk
#endif
