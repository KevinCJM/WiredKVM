#pragma once
// Approximate iPhone USB HID pointer edge from ACKed *relative* mouse deltas.
// iOS does not expose cursor coordinates over ordinary USB HID.
#include <algorithm>
#include <chrono>
#include <stdexcept>
#include <string>

namespace wk {

using EdgeClock = std::chrono::steady_clock;

struct IPhoneEdgeConfig {
    bool enabled = true;
    int span = 650;          // Virtual phone width in ACKed HID delta units.
    int arm_depth = 80;      // Move this far inward before auto-return can arm.
    int push = 65;           // Extra outward delta past the calibrated edge.
    int home_steps = 24;     // Re-home by pushing toward the MacBook-side edge.
    int home_delta = 120;    // HID max is 127 per report.

    void validate() const {
        if (span < 200 || span > 3000)
            throw std::invalid_argument("--edge-span must be 200..3000");
        if (arm_depth < 20 || arm_depth > span / 2)
            throw std::invalid_argument("--edge-arm must be 20..edge-span/2");
        if (push < 20 || push > 400)
            throw std::invalid_argument("--edge-push must be 20..400");
        if (home_steps < 4 || home_steps > 64)
            throw std::invalid_argument("--home-steps must be 4..64");
    }
};

class IPhoneEdgeTracker {
public:
    explicit IPhoneEdgeTracker(IPhoneEdgeConfig config, bool phone_on_left)
        : config_(config), phone_on_left_(phone_on_left) {
        config_.validate();
    }

    // Called on the E handoff signal, before sending the homing HID reports.
    void begin_homing() {
        active_ = true;
        homed_ = false;
        armed_ = false;
        depth_ = 0;
        outward_push_ = 0;
    }

    // Called only after all homing HID movements have been ACKed by the ESP32.
    void homed(EdgeClock::time_point now) {
        homed_ = true;
        depth_ = 0;
        outward_push_ = 0;
        armed_ = false;
        homed_at_ = now;
    }

    void leave() {
        active_ = false;
        homed_ = false;
        armed_ = false;
        depth_ = 0;
        outward_push_ = 0;
    }

    bool is_tracking() const { return active_ && homed_; }
    bool is_armed() const { return armed_; }
    int depth() const { return depth_; }
    int push_progress() const { return outward_push_; }
    int homing_delta() const { return phone_on_left_ ? config_.home_delta : -config_.home_delta; }
    int homing_steps() const { return config_.home_steps; }

    // Positive outward delta means motion TOWARD the adjacent MacBook:
    // phone on left -> rightward; phone on right -> leftward.
    // Return true only for an ACKed report crossing the calibrated edge.
    bool ack_motion(int dx, bool buttons_held, EdgeClock::time_point now) {
        if (!is_tracking()) return false;
        const int outward = phone_on_left_ ? dx : -dx;
        const int previous_depth = depth_;
        depth_ = std::clamp(depth_ - outward, 0, config_.span);

        // Prevent accidental instant bounce right after the handoff.
        if (!armed_ && depth_ >= config_.arm_depth &&
            now - homed_at_ >= std::chrono::milliseconds(300)) {
            armed_ = true;
        }
        // If the user moved far inward during the first 300ms, arm as soon
        // as subsequent real movement occurs after the cooldown.
        if (!armed_ && previous_depth >= config_.arm_depth &&
            now - homed_at_ >= std::chrono::milliseconds(300)) {
            armed_ = true;
        }

        if (buttons_held || !armed_ || outward <= 0) {
            outward_push_ = 0;
            return false;
        }
        const int overflow = std::max(0, outward - previous_depth);
        if (overflow == 0) {
            outward_push_ = 0;
            return false;
        }
        if (now - last_outward_push_ > std::chrono::milliseconds(650))
            outward_push_ = 0;
        last_outward_push_ = now;
        outward_push_ = std::min(10000, outward_push_ + overflow);
        return outward_push_ >= config_.push;
    }

private:
    IPhoneEdgeConfig config_;
    bool phone_on_left_;
    bool active_ = false;
    bool homed_ = false;
    bool armed_ = false;
    int depth_ = 0;          // 0: MacBook-adjacent edge, span: far edge.
    int outward_push_ = 0;
    EdgeClock::time_point homed_at_{};
    EdgeClock::time_point last_outward_push_{};
};

} // namespace wk
