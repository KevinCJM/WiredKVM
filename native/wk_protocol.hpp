#pragma once
// Portable WiredKVM WK1 codec. ESP32 firmware uses the same CRC-8/ATM.
#include <cstdint>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <string_view>

namespace wk {
struct Event {
    char kind;
    int a = 0;
    int b = 0;
};

inline bool valid(const Event &e) {
    switch (e.kind) {
        case 'M': case 'W': return -127 <= e.a && e.a <= 127 && -127 <= e.b && e.b <= 127;
        case 'A': return 0 <= e.a && e.a <= 32767 && 0 <= e.b && e.b <= 32767;
        case 'B': return 0 <= e.a && e.a <= 31 && e.b == 0;
        case 'K': return 0 <= e.a && e.a <= 31 && 0 <= e.b && e.b <= 255;
        case 'C': return 0 <= e.a && e.a <= 31 && e.b == 0;
        case 'T': return 4 <= e.a && e.a <= 223 && 0 <= e.b && e.b <= 2;
        case 'R': case 'P': case 'S': case 'Q': return e.a == 0 && e.b == 0;
        default: return false;
    }
}

inline uint8_t crc8(std::string_view bytes) {
    uint8_t crc = 0;
    for (unsigned char c : bytes) {
        crc ^= c;
        for (int n = 0; n < 8; ++n) {
            crc = (crc & 0x80) ? uint8_t((crc << 1) ^ 0x07) : uint8_t(crc << 1);
        }
    }
    return crc;
}

inline std::string frame(uint16_t seq, const Event &event) {
    if (!valid(event)) throw std::invalid_argument("out-of-range WK1 event");
    auto body = std::string("WK1,") + std::to_string(seq) + "," + event.kind +
                "," + std::to_string(event.a) + "," + std::to_string(event.b);
    const char digits[] = "0123456789ABCDEF";
    auto crc = crc8(body);
    body += ',';
    body += digits[crc >> 4];
    body += digits[crc & 15];
    body += '\n';
    if (body.size() > 96) throw std::invalid_argument("WK1 frame too long");
    return body;
}

// Swift capture emits: "M -3 4", "B 1 0", "C 9 0", "T 4 1", "R 0 0".
// "E y 0" is a local handoff marker; the controller handles it separately.
inline bool parse_capture_line(std::string_view s, Event &out) {
    if (s.empty()) return false;
    std::string line(s);
    // Avoid sscanf accepting garbage after the valid three fields.
    char k = 0, tail = 0;
    int a = 0, b = 0;
    const int count = std::sscanf(line.c_str(), " %c %d %d %c", &k, &a, &b, &tail);
    if (count != 3) return false;
    if (k == 'E') return false;
    out = {k, a, b};
    return valid(out);
}
} // namespace wk
