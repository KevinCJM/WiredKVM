#pragma once
// Absolute desktop HID: integrate deltas on a local virtual control plane.
// The target OS maps normalized HID coordinates to its own display geometry.
#include "wk_protocol.hpp"
#include <algorithm>
#include <stdexcept>

namespace wk {

struct DesktopPointerConfig {
    int width = 1920;
    int height = 1080;
    bool auto_return = true;
    void validate() const {
        if (width < 320 || width > 16384 || height < 320 || height > 16384)
            throw std::invalid_argument("--desktop-width/--desktop-height must be 320..16384 logical pixels");
    }
};

class DesktopPointer {
    DesktopPointerConfig config_;
    bool target_on_left_;
    bool active_ = false;
    int x_ = 0;
    int y_ = 0;
    int outward_push_ = 0;
public:
    DesktopPointer(DesktopPointerConfig config, bool target_on_left)
        : config_(config), target_on_left_(target_on_left) { config_.validate(); }

    void set_dimensions(int width, int height) {
        auto updated = config_;
        updated.width = width;
        updated.height = height;
        updated.validate();
        if (active_) throw std::runtime_error("Cannot change desktop control plane during a handoff");
        config_ = updated;
    }

    void enter(int y_fraction) {
        if (y_fraction < 0 || y_fraction > 10000)
            throw std::invalid_argument("desktop entry fraction must be 0..10000");
        active_ = true;
        x_ = target_on_left_ ? config_.width - 1 : 0;
        y_ = (y_fraction * (config_.height - 1) + 5000) / 10000;
        outward_push_ = 0;
    }
    void leave() { active_ = false; outward_push_ = 0; }
    bool active() const { return active_; }
    int y_fraction() const { return (y_ * 10000 + (config_.height - 1) / 2) / (config_.height - 1); }
    Event report() const {
        return {'A', (x_ * 32767 + (config_.width - 1) / 2) / (config_.width - 1),
                     (y_ * 32767 + (config_.height - 1) / 2) / (config_.height - 1)};
    }
    // Return only after continued outward movement at the Book-facing edge.
    // A held button clears push progress, so a drag cannot switch computers.
    bool move(int dx, int dy, bool buttons_held) {
        if (!active_) return false;
        const int before = x_;
        x_ = std::clamp(x_ + dx, 0, config_.width - 1);
        y_ = std::clamp(y_ + dy, 0, config_.height - 1);
        const int outward = target_on_left_ ? dx : -dx;
        const int distance = target_on_left_ ? config_.width - 1 - before : before;
        const int overflow = std::max(0, outward - distance);
        if (!config_.auto_return || buttons_held || outward <= 0 || overflow == 0) {
            outward_push_ = 0;
            return false;
        }
        outward_push_ = std::min(10000, outward_push_ + overflow);
        return outward_push_ >= 48;
    }
};
} // namespace wk
