// WiredKVM native C++17 host: protocol, UART transport and macOS capture.
// No Python, no emulator needed for real ESP32-S3. Simulator remains a
// transport-independent integration test via tcp:127.0.0.1:PORT.
#include "wk_protocol.hpp"
#include "iphone_edge.hpp"
#include "desktop_pointer.hpp"
#include "raw_touch_wire.hpp"
#include "exchange_service.hpp"
#include "file_transfer_runtime.hpp"
#include "clipboard_channel.hpp"

#include <array>
#include <charconv>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <deque>
#include <exception>
#include <functional>
#include <iostream>
#include <memory>
#include <numeric>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#ifndef _WIN32
#include <cerrno>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <netinet/tcp.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#ifdef __APPLE__
#include <IOKit/serial/ioss.h>
#endif
#else
#define WIN32_LEAN_AND_MEAN
#include <Windows.h>
#endif

using Clock = std::chrono::steady_clock;
static std::atomic<bool> stopping{false};
static void on_stop(int) { stopping.store(true); }

class Transport {
public:
    virtual ~Transport() = default;
    virtual void write_all(const std::string &payload) = 0;
    // Optional low-priority data is allowed to drop (the companion retries).
    // It must never wait for POLLOUT ahead of keyboard or heartbeat traffic.
    virtual bool try_write_data(const std::string &payload) { write_all(payload); return true; }
    // -1 for EOF/error, 0 for no line; positive when line available.
    virtual int read_line(std::string &line, int timeout_ms) = 0;
    virtual int poll_handle() const { return -1; }
};

#ifndef _WIN32
class FDTransport final : public Transport {
    int fd_ = -1;
    bool tcp_ = false;
    std::string buffer_;
public:
    FDTransport(std::string address, int baud) {
        const bool cdc = address.rfind("cdc:", 0) == 0;
        if (cdc) address.erase(0, 4); // Dedicated USB control interface; files use a separate FD/process.
        if (address.rfind("tcp:", 0) == 0) {
            tcp_ = true;
            const auto colon = address.find_last_of(':');
            if (colon == std::string::npos || colon == 4)
                throw std::runtime_error("expected tcp:127.0.0.1:PORT");
            const auto host = address.substr(4, colon - 4);
            const auto port = std::stoi(address.substr(colon + 1));
            if (port < 1 || port > 65535) throw std::runtime_error("invalid TCP port");
            fd_ = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
            if (fd_ < 0) throw std::runtime_error("cannot create emulator socket");
            sockaddr_in dst{};
            dst.sin_family = AF_INET;
            dst.sin_port = htons(static_cast<uint16_t>(port));
            if (inet_pton(AF_INET, host.c_str(), &dst.sin_addr) != 1)
                throw std::runtime_error("simulator address must be numeric IPv4");
            if (::connect(fd_, reinterpret_cast<sockaddr*>(&dst), sizeof(dst)) != 0)
                throw std::runtime_error("cannot connect to virtual ESP32 UART1");
            int yes = 1;
            setsockopt(fd_, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
            fcntl(fd_, F_SETFL, fcntl(fd_, F_GETFL, 0) | O_NONBLOCK);
        } else {
            // O_NONBLOCK prevents a removed USB serial device from hanging
            // pointer release; the application consumes only WK1 frames.
            fd_ = ::open(address.c_str(), O_RDWR | O_NOCTTY | O_NONBLOCK);
            if (fd_ < 0) throw std::runtime_error("Cannot open USB COM: " + address);
            termios cfg{};
            if (tcgetattr(fd_, &cfg) != 0) throw std::runtime_error("serial tcgetattr failed");
            cfmakeraw(&cfg);
            cfg.c_cflag |= (CLOCAL | CREAD);
            cfg.c_cflag &= ~CRTSCTS;
            cfg.c_cc[VMIN] = 0;
            cfg.c_cc[VTIME] = 0;
            if (cfsetispeed(&cfg, B9600) || cfsetospeed(&cfg, B9600) ||
                tcsetattr(fd_, TCSANOW, &cfg))
                throw std::runtime_error("serial termios setup failed");
#ifdef __APPLE__
            speed_t target = static_cast<speed_t>(baud);
            if (!cdc && ioctl(fd_, IOSSIOSPEED, &target) != 0)
                throw std::runtime_error("CH343 refused serial baud rate");
#else
            if (!cdc && (baud != 921600 || cfsetispeed(&cfg, B921600) || cfsetospeed(&cfg, B921600) ||
                tcsetattr(fd_, TCSANOW, &cfg)))
                throw std::runtime_error("unsupported native serial baud rate");
#endif
            if (cdc) { int bits = TIOCM_DTR; (void)::ioctl(fd_, TIOCMBIS, &bits); }
            // Never toggle DTR/RTS once streaming; flashing uses a separate
            // bootloader tool. This process must not reset ESP32 on launch.
        }
    }
    ~FDTransport() override { if (fd_ >= 0) ::close(fd_); }
    int poll_handle() const override { return fd_; }
    bool try_write_data(const std::string &payload) override {
        int queued = 0;
        if (!tcp_ && ::ioctl(fd_, TIOCOUTQ, &queued) == 0 && queued > 256) return false;
        std::size_t sent = 0;
        // No poll/sleep here. If the driver accepts a partial line then stalls,
        // fail closed rather than injecting a HID frame into its middle.
        while (sent < payload.size()) {
            const auto n = ::write(fd_, payload.data() + sent, payload.size() - sent);
            if (n > 0) { sent += static_cast<std::size_t>(n); continue; }
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) && sent == 0)
                return false;
            throw std::runtime_error("USB COM stalled during clipboard frame; local pointer restored");
        }
        return true;
    }
    void write_all(const std::string &payload) override {
        std::size_t sent = 0;
        const auto deadline = Clock::now() + std::chrono::milliseconds(100);
        while (sent < payload.size()) { // Allow final HID release even after Ctrl+C.
            if (Clock::now() >= deadline)
                throw std::runtime_error("USB COM write timed out; local pointer restored");
            const auto n = ::write(fd_, payload.data() + sent, payload.size() - sent);
            if (n > 0) { sent += static_cast<std::size_t>(n); continue; }
            if (n < 0 && errno == EINTR) continue;
            if (n < 0 && (errno == EWOULDBLOCK || errno == EAGAIN)) {
                pollfd p{fd_, POLLOUT, 0};
                const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
                    deadline - Clock::now()).count();
                if (remaining > 0 && ::poll(&p, 1, static_cast<int>(remaining)) > 0 &&
                    !(p.revents & (POLLHUP | POLLERR | POLLNVAL))) continue;
            }
            throw std::runtime_error("USB COM or emulator disconnected during write");
        }
    }
    int read_line(std::string &line, int timeout_ms) override {
        auto end = Clock::now() + std::chrono::milliseconds(timeout_ms);
        bool polled = false;
        while (!stopping.load()) {
            auto pos = buffer_.find('\n');
            if (pos != std::string::npos) {
                line = buffer_.substr(0, pos);
                if (!line.empty() && line.back() == '\r') line.pop_back();
                buffer_.erase(0, pos + 1);
                return 1;
            }
            if (buffer_.size() > 2048) buffer_.clear(); // Includes bounded X1 512-byte hex payloads.
            auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
                                 end - Clock::now()).count();
            // A zero timeout must still consume already-readable bytes. This
            // lets the live loop drain serial ACKs without serial/capture sleeps.
            if (remaining <= 0 && polled) return 0;
            pollfd p{fd_, static_cast<short>(POLLIN | POLLHUP | POLLERR), 0};
            const int ready = ::poll(&p, 1, remaining > 0 ? static_cast<int>(remaining) : 0);
            if (ready == 0) return 0;
            if (ready < 0) {
                if (errno == EINTR) continue;
                return -1;
            }
            if (p.revents & (POLLHUP | POLLERR | POLLNVAL)) return -1;
            polled = true;
            char buf[256];
            auto n = ::read(fd_, buf, sizeof(buf));
            if (n > 0) { buffer_.append(buf, static_cast<std::size_t>(n)); continue; }
            if (n == 0 && tcp_) return -1;
            if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) return -1;
        }
        return -1;
    }
};
#else
// Windows COM-port implementation. Event hooks will be a separate Win32
// adapter; this native protocol and serial transport are platform-neutral.
class WindowsSerial final : public Transport {
    HANDLE h_ = INVALID_HANDLE_VALUE;
    std::string buffer_;
public:
    WindowsSerial(std::string device, int baud) {
        if (device.rfind("COM", 0) == 0) device = "\\\\.\\" + device;
        h_ = CreateFileA(device.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                         OPEN_EXISTING, 0, nullptr);
        if (h_ == INVALID_HANDLE_VALUE) throw std::runtime_error("Cannot open Windows COM");
        DCB dcb{}; dcb.DCBlength = sizeof(dcb);
        if (!GetCommState(h_, &dcb)) throw std::runtime_error("GetCommState failed");
        dcb.BaudRate = static_cast<DWORD>(baud);
        dcb.ByteSize = 8; dcb.Parity = NOPARITY; dcb.StopBits = ONESTOPBIT;
        // RP2040 TinyUSB CDC opens the UART bridge when DTR is asserted.
        // CH343 VCP also accepts this standard serial-port handshake.
        dcb.fDtrControl = DTR_CONTROL_ENABLE;
        dcb.fRtsControl = RTS_CONTROL_DISABLE;
        if (!SetCommState(h_, &dcb)) throw std::runtime_error("SetCommState failed");
        COMMTIMEOUTS t{};
        t.ReadIntervalTimeout = MAXDWORD;
        t.ReadTotalTimeoutConstant = 30;
        t.WriteTotalTimeoutConstant = 300;
        SetCommTimeouts(h_, &t);
    }
    ~WindowsSerial() override { if (h_ != INVALID_HANDLE_VALUE) CloseHandle(h_); }
    void write_all(const std::string &s) override {
        DWORD done = 0;
        if (!WriteFile(h_, s.data(), static_cast<DWORD>(s.size()), &done, nullptr) ||
            done != s.size()) throw std::runtime_error("Windows COM disconnected");
    }
    int read_line(std::string &line, int timeout_ms) override {
        auto deadline = Clock::now() + std::chrono::milliseconds(timeout_ms);
        while (Clock::now() < deadline && !stopping.load()) {
            auto pos = buffer_.find('\n');
            if (pos != std::string::npos) {
                line = buffer_.substr(0, pos);
                buffer_.erase(0, pos + 1);
                return 1;
            }
            char ch; DWORD received = 0;
            if (!ReadFile(h_, &ch, 1, &received, nullptr)) return -1;
            if (received) buffer_ += ch;
            if (buffer_.size() > 512) buffer_.clear();
        }
        return 0;
    }
};
#endif

struct Sender {
    Transport &port;
    uint16_t seq = 0;
    std::function<bool(const std::string &)> unsolicited;
    int read_line(std::string &line, int timeout_ms) {
        // Route data reports through every read path, including synchronous
        // startup ACK waits. Bound work so a data flood cannot starve HID.
        for (unsigned count = 0; count < 64; ++count) {
            const int received = port.read_line(line, timeout_ms);
            if (received <= 0 || !unsolicited || !unsolicited(line)) return received;
            timeout_ms = 0;
        }
        return 0;
    }
    uint16_t send(const wk::Event &event) {
        const uint16_t number = seq++;
        port.write_all(wk::frame(number, event));
        return number;
    }
    bool reply(uint16_t seq, int timeout_ms = 1000, bool allow_wait = false) {
        const auto until = Clock::now() + std::chrono::milliseconds(timeout_ms);
        while (Clock::now() < until && !stopping.load()) {
            std::string line;
            const int n = read_line(line, 80);
            if (n < 0) throw std::runtime_error("ESP32 serial port disappeared");
            if (n == 0) continue;
            if (line == "ACK," + std::to_string(seq)) return true;
            if (line == "WAIT," + std::to_string(seq) && allow_wait) return false;
            if (line == "WAIT," + std::to_string(seq))
                throw std::runtime_error("ESP32 USB HID host not ready (WAIT)");
            if (line.rfind("ERR,", 0) == 0)
                throw std::runtime_error("ESP32 rejected frame: " + line);
            // WK_READY and ESP ROM startup lines are not WK1 acknowledgments.
        }
        throw std::runtime_error("No ESP32 WK1 ACK received within timeout");
    }
    void wait_ready(int timeout_ms = 5500) {
        // CH343 can reset the ESP32 when opening COM. Wait for the firmware
        // boot rather than failing the first launch; P has no HID side effect.
        const auto deadline = Clock::now() + std::chrono::milliseconds(timeout_ms);
        while (Clock::now() < deadline && !stopping.load()) {
            auto seq = send({'P', 0, 0});
            try {
                reply(seq, 550);
                return;
            } catch (const std::runtime_error &e) {
                if (std::string(e.what()).find("No ESP32 WK1 ACK") == std::string::npos)
                    throw;
            }
        }
        throw std::runtime_error("ESP32 firmware did not answer COM after reset");
    }
    void require_absolute() {
        try {
            if (reply(send({'Q', 0, 0}), 700, true)) return;
        } catch (const std::exception &e) {
            throw std::runtime_error(std::string("ABSOLUTE_MOUSE_UNSUPPORTED: update ESP32 firmware for absolute mouse (Q): ") + e.what());
        }
        throw std::runtime_error("ABSOLUTE_MOUSE_UNSUPPORTED: update ESP32 firmware for absolute mouse (Q)");
    }
};

#ifndef _WIN32
struct MacCapture {
    pid_t pid = -1;
    int read_fd = -1;
    int write_fd = -1;
    explicit MacCapture(const std::string &binary, bool iphone_target,
                        const std::string &position, double mouse_speed, bool absolute_mouse,
                        bool invert_scroll, bool file_transfer = false, bool wired_clipboard = false,
                        bool wired_input = false, const std::string &raw_touch = {}) {
        int outgoing[2]{}, incoming[2]{};
        if (pipe(outgoing) || pipe(incoming))
            throw std::runtime_error("Unable to create capture pipes");
        pid = fork();
        if (pid < 0) throw std::runtime_error("fork macOS capture failed");
        if (pid == 0) {
            dup2(outgoing[1], STDOUT_FILENO);
            dup2(incoming[0], STDIN_FILENO);
            close(outgoing[0]); close(outgoing[1]);
            close(incoming[0]); close(incoming[1]);
            // iPhone has no Mac mini Agent: forward native Cmd+V as USB HID.
            if (iphone_target) setenv("WK_TARGET_IPHONE", "1", 1);
            else unsetenv("WK_TARGET_IPHONE");
            if (absolute_mouse) setenv("WK_TARGET_ABSOLUTE", "1", 1);
            else unsetenv("WK_TARGET_ABSOLUTE");
            if (invert_scroll) setenv("WK_INVERT_SCROLL", "1", 1);
            else unsetenv("WK_INVERT_SCROLL");
            if (file_transfer) setenv("WK_FILE_TRANSFER", "1", 1);
            else unsetenv("WK_FILE_TRANSFER");
            if (wired_clipboard) setenv("WK_WIRED_CLIPBOARD", "1", 1);
            else unsetenv("WK_WIRED_CLIPBOARD");
            if (wired_input) setenv("WK_WIRED_INPUT", "1", 1);
            else unsetenv("WK_WIRED_INPUT");
            if(raw_touch.empty())unsetenv("WK_RAW_TOUCH_HELPER");
            else setenv("WK_RAW_TOUCH_HELPER",raw_touch.c_str(),1);
            setenv("WK_TARGET_POSITION", position.c_str(), 1);
            const auto speed = std::to_string(mouse_speed);
            setenv("WK_MOUSE_SPEED", speed.c_str(), 1);
            execl(binary.c_str(), binary.c_str(), static_cast<char*>(nullptr));
            _exit(127);
        }
        close(outgoing[1]); close(incoming[0]);
        read_fd = outgoing[0]; write_fd = incoming[1];
        fcntl(read_fd, F_SETFL, fcntl(read_fd, F_GETFL, 0) | O_NONBLOCK);
        // Never let a stalled input relay/capture block LINK or local RETURN.
        if (wired_clipboard || wired_input) {
            const auto flags = fcntl(write_fd, F_GETFL, 0);
            if (flags < 0 || fcntl(write_fd, F_SETFL, flags | O_NONBLOCK) < 0) {
                close(read_fd); close(write_fd); read_fd = write_fd = -1;
                kill(pid, SIGTERM); (void)waitpid(pid, nullptr, 0); pid = -1;
                throw std::runtime_error("Unable to make capture control nonblocking");
            }
        }
    }
    bool control(const std::string &line) {
        auto s = line + '\n';
        return ::write(write_fd, s.data(), s.size()) == static_cast<ssize_t>(s.size());
    }
    ~MacCapture() {
        if (pid > 0) {
            control("RETURN"); // release mouse before terminating the helper
            std::this_thread::sleep_for(std::chrono::milliseconds(90));
            kill(pid, SIGTERM);
            int status = 0;
            if (waitpid(pid, &status, WNOHANG) == 0) {
                for (int i = 0; i < 20; ++i) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(50));
                    if (waitpid(pid, &status, WNOHANG) != 0) break;
                }
            }
        }
        if (read_fd >= 0) close(read_fd);
        if (write_fd >= 0) close(write_fd);
    }
};

// GUI decisions travel on stdin, never on the binary clipboard socket. Tokens
// identify one capture intent; validation bounds accidental/malicious input.
static bool clipboard_token(const std::string &token) {
    const auto dot = token.find('.');
    const auto digits = [](const std::string &part) {
        return !part.empty() && part.size() <= 20 &&
            part.find_first_not_of("0123456789") == std::string::npos;
    };
    return dot == std::string::npos ? digits(token) :
        digits(token.substr(0, dot)) && digits(token.substr(dot + 1));
}
class ClipboardControlInput {
    MacCapture &capture_;
    int original_flags_ = -1;
    bool active_ = true, overlong_ = false;
    std::string buffer_;
    void cancel() { (void)capture_.control("CLIPBOARD CANCEL 0"); }
public:
    explicit ClipboardControlInput(MacCapture &capture): capture_(capture) {
        original_flags_ = ::fcntl(STDIN_FILENO, F_GETFL, 0);
        if (original_flags_ < 0 || ::fcntl(STDIN_FILENO, F_SETFL, original_flags_ | O_NONBLOCK)) {
            active_ = false; cancel();
        }
    }
    ~ClipboardControlInput() {
        cancel();
        if (original_flags_ >= 0) ::fcntl(STDIN_FILENO, F_SETFL, original_flags_);
    }
    void add_poll(std::vector<pollfd> &inputs) const {
        if (active_) inputs.push_back({STDIN_FILENO, POLLIN | POLLHUP | POLLERR, 0});
    }
    void tick() {
        if (!active_) return;
        char bytes[2048];
        const auto count = ::read(STDIN_FILENO, bytes, sizeof(bytes));
        if (count <= 0) {
            if (count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
                active_ = false; buffer_.clear(); cancel();
            }
            return;
        }
        for (ssize_t i = 0; i < count; ++i) {
            if (bytes[i] == '\n') {
                if (!overlong_) {
                    std::istringstream command(buffer_);
                    std::string prefix, verb, token, extra;
                    command >> prefix >> verb >> token;
                    if (prefix == "CLIPBOARD" && (verb == "COPY" || verb == "PASTE" || verb == "CANCEL" ||
                        verb == "STATE" || verb == "ORIGIN_IN" || verb == "ORIGIN_OUT") &&
                        clipboard_token(token) && !(command >> extra))
                        if (!capture_.control("CLIPBOARD " + verb + " " + token)) cancel();
                }
                buffer_.clear(); overlong_ = false;
            } else if (!overlong_) {
                if (buffer_.size() == 256) { buffer_.clear(); overlong_ = true; cancel(); }
                else buffer_ += bytes[i];
            }
        }
    }
};
#endif

static void run_edge_self_test() {
    using namespace std::chrono;
    const auto start = wk::EdgeClock::now();
    const wk::IPhoneEdgeConfig c;
    for (const bool phone_left : {true, false}) {
        wk::IPhoneEdgeTracker t(c, phone_left);
        const int outward = phone_left ? 1 : -1;
        t.begin_homing();
        if (t.is_tracking()) throw std::runtime_error("Tracking before homing ACK");
        t.homed(start);
        if (t.ack_motion(20 * outward, false, start + milliseconds(70)))
            throw std::runtime_error("Bounce before entering phone");
        if (t.ack_motion(-120 * outward, false, start + milliseconds(330)))
            throw std::runtime_error("Inward movement returned");
        if (!t.is_armed()) throw std::runtime_error("Inward tracking did not arm");
        if (t.ack_motion(120 * outward, false, start + milliseconds(360)))
            throw std::runtime_error("Only reached edge, must push past it");
        if (t.ack_motion(30 * outward, false, start + milliseconds(400)))
            throw std::runtime_error("Return triggered before push threshold");
        if (!t.ack_motion(40 * outward, false, start + milliseconds(430)))
            throw std::runtime_error("Outward edge push did not return");
        t.leave();
        if (t.ack_motion(120 * outward, false, start + milliseconds(500)))
            throw std::runtime_error("Return while not tracking");
        t.begin_homing();
        t.homed(start);
        t.ack_motion(-120 * outward, false, start + milliseconds(340));
        t.ack_motion(120 * outward, true, start + milliseconds(370));
        if (t.ack_motion(127 * outward, true, start + milliseconds(400)))
            throw std::runtime_error("Dragging must not auto return");
        if (t.ack_motion(30 * outward, false, start + milliseconds(500)))
            throw std::runtime_error("Small edge push returned");
        if (t.ack_motion(35 * outward, false, start + milliseconds(1250)))
            throw std::runtime_error("Stale edge push returned");
        if (!t.ack_motion(40 * outward, false, start + milliseconds(1290)))
            throw std::runtime_error("Fresh edge push did not return");
    }
    std::cout << "CPP_IPHONE_EDGE_SELF_TEST_PASS left_right=YES push=YES drag_guard=YES cooldown=YES\n";
}

static void run_self_test() {
    if (wk::crc8("123456789") != 0xF4)
        throw std::runtime_error("CRC-8/ATM self-test failed");
    for (auto e : {wk::Event{'M', 15, -7}, {'W', 4, -1}, {'B', 3, 0},
                    {'K', 9, 4}, {'C', 16, 0}, {'T', 4, 1}, {'T', 4, 0},
                    {'T', 4, 2}, {'P', 0, 0}, {'S', 0, 0}, {'R', 0, 0},
                    {'A', 0, 32767}, {'A', 32767, 0}, {'Q', 0, 0}}) {
        auto f = wk::frame(99, e);
        if (f.substr(0, 7) != "WK1,99," || f.back() != '\n')
            throw std::runtime_error("WK1 framing failure");
        auto pos = f.rfind(',');
        if (pos == std::string::npos || f.size() - pos != 4)
            throw std::runtime_error("WK1 CRC formatting failure");
    }
    wk::Event e{};
    if (!wk::parse_capture_line("T 4 1", e) || e.kind != 'T' ||
        !wk::parse_capture_line("M -11 8", e) || e.a != -11 ||
        wk::parse_capture_line("E 5000 0", e) ||
        wk::valid({'A', -1, 0}) || wk::valid({'A', 0, 32768}) ||
        wk::valid({'Q', 1, 0}) ||
        wk::parse_capture_line("T 224 1", e) ||
        wk::parse_capture_line("K 2 4 extra", e))
        throw std::runtime_error("WK1 capture parsing failure");
    std::cout << "CPP_PROTOCOL_SELF_TEST_PASS CRC=F4 6KRO=YES E_IGNORED=YES\n";
}

static void demo(Sender &sender) {
    for (const auto &e : {wk::Event{'M', 24, -12}, {'B', 1, 0}, {'B', 0, 0},
                          {'C', 9, 0}, {'T', 4, 1}, {'T', 4, 0},
                          {'C', 0, 0}, {'R', 0, 0}, {'P', 0, 0}}) {
        auto n = sender.send(e);
        sender.reply(n);
        std::cout << "CPP_ESP_ACK seq=" << n << " kind=" << e.kind << '\n';
    }
    std::cout << "CPP_ESP_DEMO_PASS\n";
}

#ifndef _WIN32
static void live_macos(Sender &sender, const std::string &binary, bool iphone_target,
                       const std::string &position, const wk::IPhoneEdgeConfig &edge_config,
                       double mouse_speed, bool absolute_mouse,
                       const wk::DesktopPointerConfig &desktop_config, bool invert_scroll,
                       const std::string &exchange_image, const std::string &exchange_socket,
                       const std::string &file_socket, wk::ClipboardChannel *clipboard, int baud,
                       const std::string &setup_image, const std::string &setup_socket, bool setup_flash,
                       bool input_only = false, const std::string &raw_touch = {}) {
    if (absolute_mouse) sender.require_absolute(); // Must succeed before any EventTap exists.
    sender.reply(sender.send({'R', 0, 0}));
    sender.reply(sender.send({'S', 0, 0}));
    std::unique_ptr<wk::ExchangeService> exchange;
    if (!exchange_image.empty() || !setup_image.empty()) {
        exchange = std::make_unique<wk::ExchangeService>(
            setup_image.empty() ? exchange_image : setup_image,
            setup_image.empty() ? exchange_socket : setup_socket, !setup_image.empty(), setup_flash);
        // Probe while no EventTap exists and no WK1 replies are outstanding.
        // Old firmware rejects X1; that only disables storage, never keyboard/mouse.
        sender.port.write_all(wk::ExchangeService::query());
        const auto deadline = Clock::now() + std::chrono::milliseconds(400);
        while (Clock::now() < deadline && !stopping.load()) {
            std::string line;
            const int count = sender.read_line(line, 50);
            if (count < 0) throw std::runtime_error("ESP32 disconnected during exchange probe");
            if (count > 0 && exchange->on_line(line) && exchange->capable()) break;
            if (line.rfind("ERR,", 0) == 0) break;
        }
        if (!exchange->capable()) exchange->unsupported();
    }
    std::unique_ptr<wk::FileTransferRuntime> files;
    if (!file_socket.empty()) files = std::make_unique<wk::FileTransferRuntime>(file_socket);
    const char *touch_protocol_env=std::getenv("WK_RAW_TOUCH_PROTOCOL");
    const std::string touch_protocol=touch_protocol_env?touch_protocol_env:"1";
    if(touch_protocol!="1"&&touch_protocol!="2")throw std::runtime_error("Invalid local raw-touch protocol");
    const std::string touch_prefix="MT2,version="+touch_protocol+",enabled=";
    const std::string touch_enabled_prefix=touch_prefix+"1,";
    bool touch_ready=false,touch_capable=false;
    if(!raw_touch.empty()){
        sender.port.write_all("MT2?\n");
        const auto until=Clock::now()+std::chrono::milliseconds(500);
        while(Clock::now()<until){std::string line;if(sender.read_line(line,20)>0){
            if(line.rfind(touch_prefix,0)==0){touch_capable=true;touch_ready=line.rfind(touch_enabled_prefix,0)==0;break;}
            if(line.rfind("ERR,",0)==0)break;
        }}
        if(!touch_ready)std::cerr<<"CPP_RAW_TOUCH_WAIT capable="<<touch_capable<<" legacy_keyboard_mouse_preserved=true\n";
    }
    MacCapture capture(binary, iphone_target, position, mouse_speed, absolute_mouse, invert_scroll,
                       bool(files), clipboard != nullptr && !input_only, clipboard != nullptr, touch_capable?raw_touch:std::string{});
    std::unique_ptr<ClipboardControlInput> clipboard_control;
    if (clipboard && !input_only) clipboard_control = std::make_unique<ClipboardControlInput>(capture);
    wk::RawTouchWire touch_wire;
    wk::RawTouchFrames touch_packets;
    auto touch_query_at=Clock::now();
    std::string touch_faults;
    auto touch_status_at=Clock::now()-std::chrono::seconds(3);
    if(touch_ready)capture.control("TOUCH_READY 1");
    uint64_t clipboard_disconnections = 0;
    struct ReleaseRemote {
        Sender &sender;
        MacCapture &capture;
        wk::RawTouchWire &touch_wire;
        ~ReleaseRemote() noexcept {
            // Local recovery precedes any serial write, which may block on unplug.
            capture.control("RETURN");
            try { const auto end=touch_wire.leave();if(!end.empty())sender.port.write_all(end);sender.send({'R',0,0}); } catch (...) {}
        }
    } release_remote{sender, capture, touch_wire};
    const bool trace_hid = std::getenv("WK_HID_TRACE") != nullptr;
    std::cout << "CPP_CAPTURE_STARTED target=" << (iphone_target ? "iphone" : "desktop")
              << " position=" << position << " absolute=" << absolute_mouse
              << ". Ctrl+Option+F12 to toggle; Ctrl+C quits.\n";
    std::string buf;
    auto last_link = Clock::now() - std::chrono::milliseconds(140);
    auto last_link_ack = Clock::time_point{};
    auto last_ping = Clock::now();
    auto last_ack = Clock::now(); // Startup S has just been ACKed.
    auto last_mouse_wait_log = Clock::now() - std::chrono::seconds(2);
    std::array<char, 65536> pending{};
    struct QueuedHID {
        wk::Event event; bool homing = false; int return_fraction = -1;
        std::optional<wk::FileTransferRuntime::Action> automation = std::nullopt;
    };
    std::deque<QueuedHID> queued_hid;
    std::optional<wk::IPhoneEdgeTracker> edge_tracker;
    if (iphone_target && edge_config.enabled)
        edge_tracker.emplace(edge_config, position == "left");
    std::optional<wk::DesktopPointer> desktop_pointer;
    if (absolute_mouse) desktop_pointer.emplace(desktop_config, position == "left");
    int home_remaining = 0;
    bool remote_buttons_held = false;
    bool local_buttons_held = false;
    bool desktop_return_pending = false;
    bool awaiting_hid = false;
    uint16_t hid_seq = 0;
    int hid_retries = 0;
    auto last_hid_sent = Clock::now();
    auto next_hid_attempt = Clock::now();
    auto send_live = [&](const wk::Event &event) {
        const auto seq = sender.send(event);
        pending[seq] = event.kind;
        return seq;
    };
    auto clear_hid_queue = [&]() {
        if (awaiting_hid) pending[hid_seq] = 0;
        awaiting_hid = false;
        queued_hid.clear();
        hid_retries = 0;
        home_remaining = 0;
        remote_buttons_held = false;
        local_buttons_held = false;
        desktop_return_pending = false;
        next_hid_attempt = Clock::now();
    };
    auto cancel_hid = [&]() {
        touch_packets.clear();const auto touch_end=touch_wire.leave();
        if(!touch_end.empty())sender.port.write_all(touch_end);
        clear_hid_queue();
        if (edge_tracker) edge_tracker->leave();
        if (desktop_pointer) desktop_pointer->leave();
    };
    // Automatic keys may run while Book owns the pointer. Never enter/leave
    // the user's pointer session merely to inject a transaction step.
    auto release_automation = [&](std::optional<wk::FileTransferRuntime::Action> completion = std::nullopt) {
        clear_hid_queue();
        queued_hid.push_back({{'R', 0, 0}, false});
        // R resets firmware pointer mode. Restore absolute mode if the user
        // was still on mini, without changing the pointer's logical position.
        if (desktop_pointer && desktop_pointer->active())
            queued_hid.push_back({desktop_pointer->report(), false});
        queued_hid.back().automation = completion;
    };
    bool capture_file_busy = false;
    auto sync_file_control = [&]() {
        if (!files) return;
        if (files->take_release()) release_automation();
        if (auto action = files->take_action()) {
            if (action->operation == wk::FileTransferRuntime::Operation::Key) {
                QueuedHID input{{'K', action->modifiers, action->key}, false};
                input.automation = action; queued_hid.push_back(input);
            } else release_automation(action);
        }
        if (files->busy() != capture_file_busy) {
            capture_file_busy = files->busy();
            if (!capture.control(capture_file_busy ? "FILE BUSY 1" : "FILE BUSY 0"))
                throw std::runtime_error("Lost file transfer capture control");
        }
    };
    auto enqueue = [&](wk::Event event) {
        const bool mutable_tail = !queued_hid.empty() && !queued_hid.back().homing &&
                                  (!awaiting_hid || queued_hid.size() > 1);
        if (mutable_tail && event.kind == 'A' && queued_hid.back().event.kind == 'A') {
            queued_hid.back().event = event; // Absolute positions replace; never add them.
        } else if (mutable_tail && (event.kind == 'M' || event.kind == 'W') &&
                   queued_hid.back().event.kind == event.kind &&
                   wk::valid({event.kind, queued_hid.back().event.a + event.a,
                                         queued_hid.back().event.b + event.b})) {
            queued_hid.back().event.a += event.a;
            queued_hid.back().event.b += event.b;
        } else {
            if (queued_hid.size() >= 512)
                throw std::runtime_error("HID input queue full; local pointer restored");
            queued_hid.push_back({event, false});
        }
    };
    bool clipboard_turn = true;
    bool clipboard_uart_busy = false;
    auto next_bulk = Clock::now();
    while (!stopping.load()) {
        // Drain all complete ACKs before waiting on either input source.
        std::string status;
        for (unsigned received_lines = 0; received_lines < 128; ++received_lines) {
            const auto received = sender.read_line(status, 0);
            if (received < 0) {
                if (stopping.load()) break;
                throw std::runtime_error("ESP32 disconnected, returning MacBook input");
            }
            if (received == 0) break;
            const auto now = Clock::now();
            if(!raw_touch.empty()&&status.rfind(touch_prefix,0)==0){
                if(now-touch_status_at>=std::chrono::seconds(2)){
                    std::cerr<<"CPP_RAW_TOUCH_STATUS "<<status<<'\n';touch_status_at=now;
                }
                const bool next=status.rfind(touch_enabled_prefix,0)==0;
                const auto start=status.find(",faults=");
                const auto faults=start==std::string::npos?std::string{}:status.substr(start+8,status.find(',',start+8)-(start+8));
                if(!touch_faults.empty()&&touch_faults!=faults){
                    touch_packets.clear();const auto end=touch_wire.leave();if(!end.empty())sender.port.write_all(end);
                    capture.control("TOUCH_READY 0");touch_ready=false;
                }
                touch_faults=faults;
                if(next!=touch_ready){touch_ready=next;capture.control(next?"TOUCH_READY 1":"TOUCH_READY 0");
                    if(!next){touch_packets.clear();const auto end=touch_wire.leave();if(!end.empty())sender.port.write_all(end);}}
                continue;
            }
            if (exchange && exchange->on_line(status)) continue;
            if (status.rfind("ERR,", 0) == 0)
                throw std::runtime_error("ESP32 rejected WK1 packet: " + status);
            const bool ack = status.rfind("ACK,", 0) == 0;
            const bool wait = status.rfind("WAIT,", 0) == 0;
            if (!ack && !wait) continue;
            const char *first = status.data() + (ack ? 4 : 5);
            unsigned sequence = 0;
            auto [end, error] = std::from_chars(first, status.data() + status.size(), sequence);
            if (error != std::errc{} || end != status.data() + status.size() || sequence > 65535)
                throw std::runtime_error("Malformed ESP32 WK1 response");
            const char kind = pending[sequence];
            pending[sequence] = 0;
            if (kind == 0) continue; // ACK of an input cancelled by local return.
            if (trace_hid)
                std::cerr << "CPP_HID_REPLY seq=" << sequence << " kind=" << kind
                          << " status=" << (ack ? "ACK" : "WAIT") << '\n';
            if (ack) {
                last_ack = now;
                if (awaiting_hid && sequence == hid_seq) {
                    const QueuedHID delivered = queued_hid.front();
                    awaiting_hid = false;
                    queued_hid.pop_front();
                    hid_retries = 0;
                    if (delivered.automation && files)
                        files->acknowledged(delivered.automation->operation, delivered.automation->intent);
                    if (delivered.homing) {
                        if (--home_remaining == 0 && edge_tracker) {
                            edge_tracker->homed(now);
                            std::cerr << "CPP_IPHONE_EDGE_HOMED side="
                                      << (position == "left" ? "RIGHT" : "LEFT")
                                      << " reports=" << edge_config.home_steps << '\n';
                        }
                    } else if (delivered.return_fraction >= 0) {
                        if (!capture.control("RETURN " + std::to_string(delivered.return_fraction)))
                            throw std::runtime_error("Cannot return local MacBook pointer");
                        cancel_hid();
                        queued_hid.push_front({{'R', 0, 0}, false});
                        std::cerr << "CPP_DESKTOP_AUTO_RETURN fraction=" << delivered.return_fraction << '\n';
                    } else if (delivered.event.kind == 'B') {
                        remote_buttons_held = delivered.event.a != 0;
                    } else if (delivered.event.kind == 'R') {
                        remote_buttons_held = false;
                    } else if (delivered.event.kind == 'M' && edge_tracker &&
                               edge_tracker->ack_motion(delivered.event.a, remote_buttons_held, now)) {
                        if (!capture.control("RETURN"))
                            throw std::runtime_error("Cannot return local MacBook pointer");
                        cancel_hid();
                        queued_hid.push_front({{'R', 0, 0}, false});
                        std::cerr << "CPP_IPHONE_AUTO_RETURN side="
                                  << (position == "left" ? "RIGHT" : "LEFT")
                                  << " pointer_return_requested=true\n";
                    }
                }
            } else if (kind == 'S') {
                // S queries mounted status, not transient endpoint readiness.
                throw std::runtime_error("ESP32 USB HID disconnected (status WAIT); MacBook pointer restored");
            } else if (awaiting_hid && sequence == hid_seq) {
                awaiting_hid = false;
                // WAIT is explicitly undelivered: retry before later key/button transitions.
                if (++hid_retries >= 5) {
                    if (queued_hid.front().homing)
                        throw std::runtime_error("iPhone edge homing failed; local pointer restored");
                    if (kind != 'M' && kind != 'W')
                        throw std::runtime_error(std::string("ESP32 HID input not accepted (") + kind + "); local pointer restored");
                    queued_hid.pop_front();
                    hid_retries = 0;
                    if (now - last_mouse_wait_log > std::chrono::seconds(1)) {
                        std::cerr << "CPP_HID_BUSY kind=" << kind << " movement dropped after retries\n";
                        last_mouse_wait_log = now;
                    }
                }
                next_hid_attempt = now + std::chrono::milliseconds(2);
            } else {
                throw std::runtime_error("Unexpected ESP32 WK1 WAIT; local pointer restored");
            }
        }
        if (stopping.load()) break;
        if (exchange) exchange->tick();
        if (files) { files->tick(); sync_file_control(); }
        if (clipboard) {
            clipboard->tick();
            if (clipboard->disconnections() != clipboard_disconnections) {
                clipboard_disconnections = clipboard->disconnections();
                if (!input_only) (void)capture.control("CLIPBOARD CANCEL 0");
            }
        }
        if (clipboard_control) clipboard_control->tick();
        auto now = Clock::now();
        if (now - last_ack >= std::chrono::milliseconds(250))
            throw std::runtime_error("ESP32 serial heartbeat timed out; local pointer restored");
        if (awaiting_hid && now - last_hid_sent >= std::chrono::milliseconds(250))
            throw std::runtime_error("ESP32 HID report acknowledgement timed out; local pointer restored");
        if (now - last_ping >= std::chrono::milliseconds(100)) {
            send_live({'P', 0, 0});
            send_live({'S', 0, 0});
            last_ping = now;
        }
        if (now - last_link >= std::chrono::milliseconds(140) &&
            now - last_ack < std::chrono::milliseconds(200) && last_ack > last_link_ack) {
            if (!capture.control("LINK")) throw std::runtime_error("Lost local capture process");
            last_link = now;
            last_link_ack = last_ack; // Never renew a lease using the same stale ACK.
        }
        if (!awaiting_hid && !queued_hid.empty() && now >= next_hid_attempt) {
            hid_seq = send_live(queued_hid.front().event);
            awaiting_hid = true;
            last_hid_sent = now;
        }
        // Only one bulk frame follows user HID/heartbeat work. Alternate the
        // channels under load; an idle channel never delays the other channel.
        if(touch_capable && now-touch_query_at>=std::chrono::milliseconds(100)){
            if(sender.port.try_write_data("MT2?\n"))touch_query_at=now;
        }
        if(!touch_packets.empty()){
            if(!sender.port.try_write_data(touch_packets.front())){
                const auto end=touch_wire.leave();if(!end.empty())sender.port.write_all(end);
                touch_ready=false;capture.control("TOUCH_READY 0");touch_packets.clear();
            }
            if(!touch_packets.empty())touch_packets.pop();
        }
        auto send_bulk = [&](bool use_clipboard) {
            if (clipboard && Clock::now() < next_bulk) return false;
            const auto packet = use_clipboard ? (clipboard ? clipboard->next_frame() : std::string{}) :
                                               (exchange ? exchange->next_frame() : std::string{});
            if (packet.empty()) return false;
            if (use_clipboard) {
                const bool written = sender.port.try_write_data(packet);
                clipboard->record_uart_write(written);
                if (written == clipboard_uart_busy) {
                    clipboard_uart_busy = !written;
                    std::cerr << (written ? "CPP_CLIPBOARD_UART_RECOVERED\n" : "CPP_CLIPBOARD_UART_BACKPRESSURE\n");
                }
            } else sender.port.write_all(packet);
            clipboard_turn = !use_clipboard;
            // Unlike storage, C1 is not UART request/response paced. Reserve
            // 25% of line bandwidth for keyboard/mouse/heartbeat, preventing a
            // continuously writing companion from filling the serial driver.
            if (clipboard) next_bulk = Clock::now() + std::chrono::microseconds(
                (packet.size() * 10ULL * 1000000ULL * 4ULL + baud * 3ULL - 1ULL) / (baud * 3ULL));
            return true;
        };
        if (!send_bulk(clipboard_turn)) send_bulk(!clipboard_turn);

        // One wait wakes immediately for serial ACK OR new local input. Timer
        // deadlines cover keepalive, retry and failure; no fixed per-report cap.
        auto wake = std::min(last_ping + std::chrono::milliseconds(100),
                             last_ack + std::chrono::milliseconds(250));
        if(!touch_packets.empty())wake=std::min(wake,Clock::now()+std::chrono::milliseconds(1));
        if (awaiting_hid) wake = std::min(wake, last_hid_sent + std::chrono::milliseconds(250));
        if (!awaiting_hid && !queued_hid.empty()) wake = std::min(wake, next_hid_attempt);
        if (last_ack > last_link_ack)
            wake = std::min(wake, last_link + std::chrono::milliseconds(140));
        if (exchange) wake = std::min(wake, std::max(clipboard ? next_bulk : Clock::now(),
            Clock::now() + std::chrono::milliseconds(exchange->poll_delay_ms())));
        if (files) wake = std::min(wake, Clock::now() + std::chrono::milliseconds(files->poll_delay_ms()));
        if (clipboard) wake = std::min(wake, std::max(next_bulk,
            Clock::now() + std::chrono::milliseconds(clipboard->poll_delay_ms())));
        const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(wake - Clock::now()).count();
        std::vector<pollfd> inputs = {
            {capture.read_fd, POLLIN | POLLHUP | POLLERR, 0},
            {sender.port.poll_handle(), POLLIN | POLLHUP | POLLERR, 0},
        };
        if (exchange) exchange->add_poll(inputs);
        if (files) files->add_poll(inputs);
        if (clipboard) clipboard->add_poll(inputs);
        if (clipboard_control) clipboard_control->add_poll(inputs);
        const int ready = poll(inputs.data(), inputs.size(), remaining > 0 ? static_cast<int>(remaining) : 0);
        if (ready < 0 && errno != EINTR) throw std::runtime_error("Cannot poll local/serial input");
        if (ready > 0 && (inputs[0].revents & (POLLHUP | POLLERR | POLLNVAL)))
            throw std::runtime_error("MacBook capture process closed");
        if (ready > 0 && (inputs[0].revents & POLLIN)) {
            char data[2048];
            const auto n = ::read(capture.read_fd, data, sizeof(data));
            if (n > 0) {
                buf.append(data, static_cast<std::size_t>(n));
                if (buf.size() > 16384) throw std::runtime_error("local input queue overflow");
                std::size_t pos;
                while ((pos = buf.find('\n')) != std::string::npos) {
                    auto line = buf.substr(0, pos);
                    buf.erase(0, pos + 1);
                    if(line.rfind("H ",0)==0){
                        if(!raw_touch.empty()){
                            const bool remote=touch_ready&&desktop_pointer&&desktop_pointer->active()&&!desktop_return_pending;
                            const auto packet=touch_wire.accept(line,remote);
                            if(!packet.empty()){
                                if(packet.rfind("MT2D,",0)==0){
                                    if(!touch_packets.offer(packet)){
                                        const auto end=touch_wire.leave();if(!end.empty())sender.port.write_all(end);
                                        touch_ready=false;capture.control("TOUCH_READY 0");
                                    }
                                }
                                else{touch_packets.clear();sender.port.write_all(packet);}
                            }
                        }
                        continue;
                    }
                    if (clipboard && !input_only && (line.rfind("C COPY ", 0) == 0 || line.rfind("C PASTE ", 0) == 0 ||
                                      line.rfind("C CANCEL ", 0) == 0)) {
                        if (line.size() <= 256) {
                            std::istringstream intent(line);
                            std::vector<std::string> fields;
                            for (std::string field; intent >> field;) fields.push_back(field);
                            const bool valid_cancel = fields.size() == 3 && fields[1] == "CANCEL" &&
                                clipboard_token(fields[2]);
                            const bool valid_shortcut = fields.size() == 4 &&
                                (fields[1] == "COPY" || fields[1] == "PASTE") &&
                                (fields[2] == "OUT" || fields[2] == "IN") && clipboard_token(fields[3]);
                            const bool valid_local_copy = fields.size() == 5 && fields[1] == "COPY" &&
                                fields[2] == "OUT" && clipboard_token(fields[3]) && clipboard_token(fields[4]) &&
                                fields[4].find('.') == std::string::npos;
                            if (valid_cancel || valid_shortcut || valid_local_copy)
                                std::cerr << "CPP_CLIPBOARD_INTENT " << line << '\n';
                        }
                        continue;
                    }
                    if (files && line.rfind("F ", 0) == 0) {
                        if (line == "F CANCEL") {
                            files->cancel("USER_INPUT"); sync_file_control();
                        } else {
                            std::istringstream input(line);
                            std::string prefix, verb, direction, change, tail;
                            input >> prefix >> verb >> direction >> change;
                            uint64_t version = 0;
                            const auto parsed = std::from_chars(change.data(), change.data() + change.size(), version);
                            if (verb != "PASTE" || (direction != "OUT" && direction != "IN") ||
                                change.empty() || parsed.ec != std::errc{} ||
                                parsed.ptr != change.data() + change.size() || (input >> tail)) continue;
                            const auto id = files->offer();
                            release_automation(); sync_file_control();
                            std::cerr << "CPP_FILE_TRANSFER id=" << id << " direction=" << direction
                                      << " change=" << version << '\n';
                        }
                        continue;
                    }
                    if (line.rfind("D ", 0) == 0 && desktop_pointer) {
                        int width = 0, height = 0;
                        char tail = 0;
                        if (std::sscanf(line.c_str(), "D %d %d %c", &width, &height, &tail) != 2)
                            throw std::runtime_error("Malformed capture control-plane dimensions");
                        desktop_pointer->set_dimensions(width, height);
                        continue; // Local metadata, never a firmware command.
                    }
                    if (line.rfind("E ", 0) == 0) {
                        if (files && files->busy()) { files->cancel("USER_INPUT"); sync_file_control(); }
                        if (desktop_return_pending) continue;
                        if (edge_tracker || desktop_pointer) {
                            int fraction = 0, unused = 0;
                            char tail = 0;
                            if (std::sscanf(line.c_str(), "E %d %d %c", &fraction, &unused, &tail) != 2 ||
                                fraction < 0 || fraction > 10000 || unused != 0)
                                throw std::runtime_error("Malformed capture edge entry");
                            if (desktop_pointer) {
                                desktop_pointer->enter(fraction);
                                enqueue(desktop_pointer->report());
                            } else {
                                edge_tracker->begin_homing();
                                home_remaining = edge_tracker->homing_steps();
                                for (int i = 0; i < home_remaining; ++i)
                                    queued_hid.push_back({{'M', edge_tracker->homing_delta(), 0}, true});
                                std::cerr << "CPP_IPHONE_EDGE_HOMING side="
                                          << (position == "left" ? "RIGHT" : "LEFT")
                                          << " reports=" << home_remaining << '\n';
                            }
                        }
                        continue;
                    }
                    wk::Event event{};
                    if (!wk::parse_capture_line(line, event)) continue;
                    if (files && files->busy()) { files->cancel("USER_INPUT"); sync_file_control(); }
                    if (event.kind == 'R') {
                        cancel_hid();
                        queued_hid.push_back({event, false});
                        continue;
                    }
                    // After a return, discard already-buffered input until the
                    // next E handoff; cancelled clicks must never replay remotely.
                    if (desktop_pointer && (!desktop_pointer->active() || desktop_return_pending)) continue;
                    if (event.kind == 'B') local_buttons_held = event.a != 0;
                    if (desktop_pointer && event.kind == 'M') {
                        if (desktop_pointer->move(event.a, event.b, local_buttons_held)) {
                            enqueue(desktop_pointer->report());
                            queued_hid.back().return_fraction = desktop_pointer->y_fraction();
                            desktop_return_pending = true; // Return only after boundary A is ACKed.
                        } else {
                            enqueue(desktop_pointer->report());
                        }
                    } else {
                        enqueue(event);
                    }
                }
            }
        }
    }
}
#endif

int main(int argc, char **argv) {
    try {
#ifndef _WIN32
        signal(SIGPIPE, SIG_IGN);
        signal(SIGINT, on_stop);
        signal(SIGTERM, on_stop);
#endif
        std::string transport;
        std::string source = "probe";
        std::string capture = "build/macos-capture";
        std::string target = "desktop";
        std::string raw_touch;
        std::string position;
        std::string exchange_image, exchange_socket, file_socket, clipboard_socket, input_socket, setup_image, setup_socket;
        bool setup_flash = false;
        bool position_provided = false;
        wk::IPhoneEdgeConfig edge_config{};
        wk::DesktopPointerConfig desktop_config{};
        bool absolute_mouse = false;
        bool invert_scroll = false;
        double mouse_speed = 1.0;
        int baud = 921600;
        for (int i = 1; i < argc; ++i) {
            const std::string a = argv[i];
            if (a == "--self-test") { run_self_test(); return 0; }
            if (a == "--self-test-edge") { run_edge_self_test(); return 0; }
            if (a == "--no-auto-return") { edge_config.enabled = false; continue; }
            if (a == "--absolute-mouse") { absolute_mouse = true; continue; }
            if (a == "--invert-scroll") { invert_scroll = true; continue; }
            if (a == "--setup-flash") { setup_flash = true; continue; }
            if (i + 1 >= argc) throw std::runtime_error("missing argument for " + a);
            if (a == "--transport") transport = argv[++i];
            else if (a == "--source") source = argv[++i];
            else if (a == "--baud") baud = std::stoi(argv[++i]);
            else if (a == "--capture") capture = argv[++i];
            else if (a == "--raw-touch") raw_touch = argv[++i];
            else if (a == "--exchange-image") exchange_image = argv[++i];
            else if (a == "--exchange-socket") exchange_socket = argv[++i];
            else if (a == "--file-transfer-socket") file_socket = argv[++i];
            else if (a == "--clipboard-socket") clipboard_socket = argv[++i];
            else if (a == "--input-socket") input_socket = argv[++i];
            else if (a == "--setup-image") setup_image = argv[++i];
            else if (a == "--setup-socket") setup_socket = argv[++i];
            else if (a == "--target") target = argv[++i];
            else if (a == "--position") { position = argv[++i]; position_provided = true; }
            else if (a == "--edge-span") edge_config.span = std::stoi(argv[++i]);
            else if (a == "--edge-arm") edge_config.arm_depth = std::stoi(argv[++i]);
            else if (a == "--edge-push") edge_config.push = std::stoi(argv[++i]);
            else if (a == "--home-steps") edge_config.home_steps = std::stoi(argv[++i]);
            else if (a == "--mouse-speed") mouse_speed = std::stod(argv[++i]);
            else if (a == "--desktop-width") desktop_config.width = std::stoi(argv[++i]);
            else if (a == "--desktop-height") desktop_config.height = std::stoi(argv[++i]);
            else throw std::runtime_error("unknown option " + a);
        }
        if(raw_touch.empty()&&source=="macos"){
            const char *helper=std::getenv("WK_RAW_TOUCH_HELPER");if(helper)raw_touch=helper;
        }
        // Portable clipboard metadata uses its existing bounded local socket;
        // file bodies have a separate USB Bulk owner. Keep storage automation
        // excluded, but allow the clipboard coordinator beside native touch.
        if(!raw_touch.empty() && (raw_touch[0]!='/'||source!="macos"||target!="desktop"||!absolute_mouse||!file_socket.empty()||!exchange_image.empty()||!setup_image.empty()))
            throw std::runtime_error("raw-touch requires absolute Book desktop control and no exchange/setup storage channels");
        if (transport.empty())
            throw std::runtime_error("Usage: wiredkvm-native --transport SERIAL|tcp:127.0.0.1:PORT --source probe|check-hid|soak|demo|macos");
        if (baud < 9600 || baud > 2000000) throw std::runtime_error("bad serial baud");
        if (target != "desktop" && target != "iphone")
            throw std::runtime_error("--target must be desktop or iphone");
        if (absolute_mouse && target != "desktop")
            throw std::runtime_error("--absolute-mouse is supported only for --target desktop");
        if (exchange_image.empty() != exchange_socket.empty())
            throw std::runtime_error("--exchange-image and --exchange-socket must be supplied together");
        if (!exchange_image.empty() && (source != "macos" || target != "desktop"))
            throw std::runtime_error("exchange storage requires macos desktop control");
        if (setup_flash && setup_image.empty()) throw std::runtime_error("--setup-flash requires setup media");
        if (setup_image.empty() != setup_socket.empty())
            throw std::runtime_error("--setup-image and --setup-socket must be supplied together");
        if (!setup_image.empty() && (source != "macos" || target != "desktop" ||
            !exchange_image.empty() || !exchange_socket.empty() || !file_socket.empty() ||
            setup_image[0] != '/' || setup_socket[0] != '/'))
            throw std::runtime_error("setup media requires absolute image/socket paths, macos desktop control, and no exchange/file-transfer options");
        if (!file_socket.empty() && (source != "macos" || target != "desktop" ||
                                    !absolute_mouse || exchange_socket.empty() || file_socket == exchange_socket))
            throw std::runtime_error("file transfer requires absolute Mac exchange control and a separate socket");
        if (!clipboard_socket.empty() && (source != "macos" || target != "desktop" ||
            clipboard_socket == exchange_socket || clipboard_socket == file_socket || clipboard_socket == setup_socket))
            throw std::runtime_error("clipboard channel requires macos desktop control and a separate socket");
        if (!input_socket.empty() && (!clipboard_socket.empty() || source != "macos" ||
            target != "desktop" || !absolute_mouse || input_socket == exchange_socket ||
            input_socket == file_socket || input_socket == setup_socket))
            throw std::runtime_error("input channel requires absolute macos desktop control, a separate socket and no clipboard channel");
        if (!position_provided) position = target == "iphone" ? "left" : "right";
        if (position != "left" && position != "right")
            throw std::runtime_error("--position must be left or right");
        edge_config.validate();
        desktop_config.auto_return = edge_config.enabled;
        desktop_config.validate();
        if (!(mouse_speed >= 0.5 && mouse_speed <= 2.0))
            throw std::runtime_error("--mouse-speed must be 0.5..2.0");
#ifndef _WIN32
        std::unique_ptr<wk::ClipboardChannel> clipboard;
        if (!clipboard_socket.empty()) clipboard = std::make_unique<wk::ClipboardChannel>(clipboard_socket);
        else if (!input_socket.empty()) clipboard = std::make_unique<wk::ClipboardChannel>(input_socket, true);
        FDTransport connection(transport, baud);
#else
        if (transport.rfind("tcp:", 0) == 0)
            throw std::runtime_error("Windows simulator TCP adapter not yet implemented");
        WindowsSerial connection(transport, baud);
#endif
        Sender sender{connection, 0, {}};
#ifndef _WIN32
        if (clipboard) sender.unsolicited = [&](const std::string &line) { return clipboard->on_line(line); };
#endif
        if (source == "probe") {
            sender.wait_ready(); // no mouse or keyboard injection
            std::cout << "CPP_COM_PROBE_PASS (UART WK1 P->ACK, no keyboard/mouse)\n";
        } else if (source == "check-hid") {
            sender.wait_ready();
            if (absolute_mouse) sender.require_absolute();
            // S checks tud_mounted() without injecting any mouse or key.
            const auto acknowledged = sender.reply(sender.send({'S', 0, 0}), 1800, true);
            std::cout << (acknowledged ? "CPP_USB_HID_READY" : "CPP_USB_HID_NOT_CONNECTED")
                      << " (no key or cursor movement)\n";
        } else if (source == "soak") {
            // Non-injecting physical UART stress test: P (no-op) and S
            // (mounted status), both require a correctly sequenced response.
            // S may legitimately return WAIT while USB HID is unplugged.
            sender.wait_ready();
            constexpr int cycles = 160;
            int mounted = 0, unmounted = 0;
            auto start = Clock::now();
            for (int i = 0; i < cycles; ++i) {
                sender.reply(sender.send({'P', 0, 0}), 1500);
                auto configured = sender.reply(sender.send({'S', 0, 0}), 1500, true);
                if (configured) ++mounted; else ++unmounted;
            }
            const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                Clock::now() - start).count();
            std::cout << "CPP_COM_SOAK_PASS cycles=" << cycles
                      << " frames=" << cycles * 2 << " mounted=" << mounted
                      << " unmounted=" << unmounted << " elapsed_ms=" << elapsed
                      << " no_input_injected=true\n";
        } else if (source == "demo") {
            if (transport.rfind("tcp:", 0) != 0)
                throw std::runtime_error("demo injects input; allowed only in emulator mode");
            demo(sender);
        } else if (source == "macos") {
            sender.wait_ready();
#ifndef __APPLE__
            throw std::runtime_error("macOS source requires Swift capture on macOS");
#else
            live_macos(sender, capture, target == "iphone", position, edge_config, mouse_speed,
                       absolute_mouse, desktop_config, invert_scroll, exchange_image, exchange_socket, file_socket,
                       clipboard.get(), baud, setup_image, setup_socket, setup_flash, !input_socket.empty(), raw_touch);
#endif
        } else {
            throw std::runtime_error("unknown source: " + source);
        }
        return 0;
    } catch (const std::exception &err) {
        // Persist a bounded cause without device paths or arbitrary subprocess
        // output. The GUI's metadata-only logger otherwise drops the cause.
        const std::string_view reason(err.what());
        const char *code = "OTHER";
        if (reason == "ESP32 rejected WK1 packet: ERR,overflow") code = "WK1_OVERFLOW";
        else if (reason.find("ESP32 rejected") == 0) code = "WK1_REJECT";
        else if (reason.find("heartbeat timed out") != std::string_view::npos) code = "HEARTBEAT_TIMEOUT";
        else if (reason.find("acknowledgement timed out") != std::string_view::npos) code = "HID_ACK_TIMEOUT";
        else if (reason.find("COM stalled") != std::string_view::npos) code = "UART_STALLED";
        else if (reason.find("COM write timed out") != std::string_view::npos) code = "UART_WRITE_TIMEOUT";
        else if (reason.find("disappeared") != std::string_view::npos ||
                 reason.find("disconnected") != std::string_view::npos) code = "DISCONNECTED";
        std::cerr << "CPP_WIREDKVM_FAILURE code=" << code << '\n';
        std::cerr << "CPP_WIREDKVM_ERROR " << err.what() << '\n';
        return 1;
    }
}
