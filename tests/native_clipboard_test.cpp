// Socket-only unit tests. Never opens serial hardware or captures user input.
#define main wiredkvm_application_main
#include "../native/wiredkvm.cpp"
#undef main
#include <cassert>

using Channel = wk::ClipboardChannel;
static int connect_client(const std::string &path) {
    const auto fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
    assert(fd >= 0);
    sockaddr_un address{}; address.sun_family = AF_UNIX;
    std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
    assert(::connect(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) == 0);
    return fd;
}
static void complete_send(int fd, const void *bytes, std::size_t size) {
    const auto *cursor = static_cast<const char *>(bytes);
    while (size) {
        const auto n = ::send(fd, cursor, size, 0);
        assert(n > 0); cursor += n; size -= static_cast<std::size_t>(n);
    }
}
static std::string without_newline(std::string line) { line.pop_back(); return line; }

class FakeTransport : public Transport {
public:
    std::deque<std::string> lines;
    void write_all(const std::string &) override {}
    int read_line(std::string &line, int) override {
        if (lines.empty()) return 0;
        line = lines.front(); lines.pop_front(); return 1;
    }
};

int main(int argc, char **argv) {
    assert(argc == 2);
    const std::string directory = argv[1], path = directory + "/channel.sock";
    Channel::Report report{};
    for (std::size_t i = 0; i < report.size(); ++i) report[i] = static_cast<uint8_t>(i);
    assert(Channel::crc32(report) == 0x100ece8cU); // independent IEEE reference
    const auto encoded = Channel::encode(report), line = without_newline(encoded);
    Channel::Report decoded{};
    assert(encoded.size() == 141 && Channel::decode(line, decoded) && decoded == report);
    for (const auto &bad : {line.substr(1), line + "0", line.substr(0, 131) + ",00000000",
                            std::string("C1,A") + line.substr(4), encoded})
        assert(!Channel::decode(bad, decoded));
    FakeTransport transport;
    transport.lines = {line, "C1,broken", "ACK,17"};
    unsigned received = 0;
    Sender sender{transport, 0, [&](const std::string &value) {
        if (value.rfind("C1,", 0)) return false;
        ++received; return true;
    }};
    assert(sender.reply(17, 100)); assert(received == 2);

    {
        Channel channel(path);
        struct stat st{}; assert(::lstat(path.c_str(), &st) == 0 && (st.st_mode & 0777) == 0600);
        int client = connect_client(path); channel.tick();
        complete_send(client, report.data(), 17); channel.tick(); assert(channel.next_frame().empty());
        complete_send(client, report.data() + 17, report.size() - 17); channel.tick();
        assert(channel.next_frame() == encoded); assert(channel.next_frame().empty());

        // Interactive input precedes queued clipboard bulk, while its own
        // complete reports retain order (including fragmented gestures).
        Channel::Report scroll = report, gesture1 = report, gesture2 = report;
        std::memcpy(scroll.data(), "WKSC", 4);
        std::memcpy(gesture1.data(), "WKG1", 4); gesture1[5] = 1;
        std::memcpy(gesture2.data(), "WKG1", 4); gesture2[5] = 2;
        for (const auto &item : {report, scroll, gesture1, gesture2})
            complete_send(client, item.data(), item.size());
        channel.tick();
        for (const auto &item : {scroll, gesture1, gesture2, report})
            assert(channel.next_frame() == Channel::encode(item));
        assert(channel.next_frame().empty());

        complete_send(client, report.data(), report.size());
        for (unsigned i = 0; i < 20; ++i) complete_send(client, gesture1.data(), gesture1.size());
        channel.tick();
        for (unsigned i = 0; i < 16; ++i) assert(channel.next_frame() == Channel::encode(gesture1));
        assert(channel.next_frame() == encoded); // Clipboard progress under sustained gestures.
        for (unsigned i = 0; i < 4; ++i) assert(channel.next_frame() == Channel::encode(gesture1));
        assert(channel.next_frame().empty());

        // Full queues apply backpressure without growing or losing the 65th report.
        for (unsigned i = 0; i < 65; ++i) complete_send(client, report.data(), report.size());
        channel.tick();
        for (unsigned i = 0; i < 64; ++i) assert(channel.next_frame() == encoded);
        assert(channel.next_frame().empty()); channel.tick(); assert(channel.next_frame() == encoded);
        assert(channel.next_frame().empty());

        assert(channel.on_line("C1,broken")); assert(!channel.on_line("ACK,1"));
        for (unsigned i = 0; i < 65; ++i) assert(channel.on_line(line));
        channel.tick();
        std::array<uint8_t, 4097> bytes{};
        std::size_t got = 0;
        while (got < 4096) {
            const auto n = ::recv(client, bytes.data() + got, 4096 - got, 0);
            assert(n > 0); got += static_cast<std::size_t>(n);
        }
        for (std::size_t i = 0; i < got; ++i) assert(bytes[i] == report[i % 64]);
        assert(::recv(client, bytes.data(), 1, MSG_DONTWAIT) < 0 && (errno == EAGAIN || errno == EWOULDBLOCK));

        // Second clients cannot take over or inject into the active session.
        int extra = connect_client(path); channel.tick();
        assert(::recv(extra, bytes.data(), 1, 0) == 0); ::close(extra);
        complete_send(client, report.data(), report.size()); channel.tick();
        channel.on_line(line);
        ::close(client); channel.tick(); assert(channel.next_frame().empty());
        client = connect_client(path); channel.tick();
        assert(::recv(client, bytes.data(), 1, MSG_DONTWAIT) < 0);
        complete_send(client, report.data(), 13); channel.tick();
        ::close(client); channel.tick();
        client = connect_client(path); channel.tick();
        complete_send(client, report.data(), report.size()); channel.tick();
        assert(channel.next_frame() == encoded); assert(channel.next_frame().empty());
        ::close(client); channel.tick();

        // An existing live listener is never unlinked by another instance.
        bool in_use = false;
        try { Channel duplicate(path); } catch (const std::runtime_error &) { in_use = true; }
        assert(in_use); assert(::lstat(path.c_str(), &st) == 0);
    }
    assert(::access(path.c_str(), F_OK) != 0);
    {
        // Input-only mode must never transport clipboard/file messages, even
        // when the peer still runs a full Companion. Both directions filter.
        Channel channel(path, true);
        const int client = connect_client(path); channel.tick();
        for (const auto *magic : {"WKC3", "WKF3", "WKB5", "WKI1", "junk"}) {
            auto blocked = report; std::memcpy(blocked.data(), magic, 4);
            complete_send(client, blocked.data(), 19); channel.tick();
            complete_send(client, blocked.data() + 19, 45); channel.tick();
            assert(channel.next_frame().empty());
            assert(channel.on_line(without_newline(Channel::encode(blocked))));
        }
        channel.tick();
        uint8_t byte{};
        assert(::recv(client, &byte, 1, MSG_DONTWAIT) < 0);
        for (const auto *magic : {"WKSC", "WKG1", "WKG2"}) {
            auto input = report; std::memcpy(input.data(), magic, 4);
            complete_send(client, input.data(), input.size()); channel.tick();
            assert(channel.next_frame() == Channel::encode(input));
            assert(channel.on_line(without_newline(Channel::encode(input)))); channel.tick();
            Channel::Report received{}; std::size_t offset = 0;
            while (offset < received.size()) {
                const auto n = ::recv(client, received.data() + offset, received.size() - offset, 0);
                assert(n > 0); offset += static_cast<std::size_t>(n);
            }
            assert(received == input);
        }
        ::close(client); channel.tick(); assert(channel.next_frame().empty());
        std::cout << "INPUT_ONLY_CHANNEL_PASS clipboard_blocked_both_directions=true\n";
    }
    bool unsafe = false;
    assert(::chmod(directory.c_str(), 0755) == 0);
    try { Channel channel(path); } catch (const std::runtime_error &) { unsafe = true; }
    assert(unsafe); assert(::chmod(directory.c_str(), 0700) == 0);

    // Destructor removes only the socket inode it originally created.
    int replacement = -1;
    {
        Channel channel(path);
        assert(::rename(path.c_str(), (path + ".old").c_str()) == 0);
        replacement = ::socket(AF_UNIX, SOCK_STREAM, 0); assert(replacement >= 0);
        sockaddr_un address{}; address.sun_family = AF_UNIX;
        std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
        assert(::bind(replacement, reinterpret_cast<sockaddr *>(&address), sizeof(address)) == 0);
    }
    assert(::access(path.c_str(), F_OK) == 0);
    ::close(replacement); ::unlink(path.c_str()); ::unlink((path + ".old").c_str());

    // Metadata is cumulative and bounded to one line/second, without payloads
    // or filesystem paths. Exercise each drop domain independently.
    std::ostringstream statistics;
    auto *previous_errors = std::cerr.rdbuf(statistics.rdbuf());
    {
        Channel channel(path);
        channel.on_line(line); // No local companion, not a full-queue drop.
        const int client = connect_client(path); channel.tick();
        for (unsigned i = 0; i < 65; ++i) complete_send(client, report.data(), report.size());
        channel.tick();
        assert(channel.next_frame() == encoded); channel.record_uart_write(true);
        assert(channel.next_frame() == encoded); channel.record_uart_write(false);
        channel.on_line("C1,broken");
        channel.on_line(line.substr(0, 132) + "00000000");
        for (unsigned i = 0; i < 65; ++i) channel.on_line(line);
        channel.tick(); // 65th Unix report enters; 64 inbound reports leave.
        channel.on_line(line); // One queued inbound report is cleared on EOF.
        ::close(client); channel.tick();
        std::this_thread::sleep_for(std::chrono::milliseconds(1020)); channel.tick();
        const auto first = statistics.str();
        const auto start = first.find("CPP_CLIPBOARD_STATS ");
        assert(start != std::string::npos);
        const auto stats = first.substr(start, first.find('\n', start) - start);
        for (const auto *expected : {"unix_rx=65 ", "uart_rx=67 ", "unix_tx=64 ", "uart_tx=1 ",
                                    "crc_reject=1 ", "format_reject=1 ", "queue_drop=1 ",
                                    "no_client_drop=1 ", "uart_drop=1 ", "disconnect_drop_uart=63 ",
                                    "disconnect_drop_unix=1 ", "q_uart=0 ", "q_unix=0 ",
                                    "q_uart_max=64 ", "q_unix_max=64 ", "connections=1 ", "connected=0"})
            assert(stats.find(expected) != std::string::npos);
        channel.on_line(line);
        for (unsigned i = 0; i < 100; ++i) channel.tick();
        assert(statistics.str() == first); // Counter change does not bypass rate limit.
        std::this_thread::sleep_for(std::chrono::milliseconds(1020)); channel.tick();
        const auto second = statistics.str();
        assert(second.find("CPP_CLIPBOARD_STATS ", start + 1) != std::string::npos);
        assert(second.find("uart_rx=68 ") != std::string::npos);
        assert(second.find("no_client_drop=2 ") != std::string::npos);
        assert(second.find("CPP_CLIPBOARD_DISCONNECTED reason=") != std::string::npos);
        assert(second.find(" errno=0\n") != std::string::npos);
        assert(second.find(line) == std::string::npos && second.find(directory) == std::string::npos);
    }
    std::cerr.rdbuf(previous_errors);
    std::cout << "CLIPBOARD_STATS_TEST_PASS\n";
    std::cout << "CLIPBOARD_CHANNEL_UNIT_PASS\n";
}
