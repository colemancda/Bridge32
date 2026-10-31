/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */
// Game controller play for Call of Duty: World at War: Zombies 1.5.0.
//
// Ported from codwawzpc (https://github.com/aurelioochoa/codwawzpc), whose
// src/codwawzpc/native.rs and src/codwawz_controls.rs this follows: the
// addresses, offsets and behavior are theirs.
//
// The game keeps the keyboard controller of its desktop builds. It and the
// touch HUD drive the player the same way: they post Event_AnaloguePadPosition
// for movement and Event_PlayerAction for firing, reloading and the rest to
// the local player. Once per presented frame, while a controller is connected
// and a level is being played, this posts those events through the game's own
// functions, writes stick look into the player's input controller, and hides
// the on-screen sticks and buttons. Menus stay on touch (clicks).
//
// Every address belongs to the one executable codwawzpc supports (checked by
// SHA-256), and objects are checked by vtable before use.
//
// Controls: left stick moves (click: sprint), right stick looks (click:
// melee), right trigger fires, left trigger aims, A uses, X reloads, Y swaps
// weapons, B melees, right shoulder throws a grenade (held: cooks it), left
// shoulder picks the special grenade.

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/gl/GLES.h"
#include "core/thunks/Thunks.h"

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#include <CommonCrypto/CommonDigest.h>

#include <chrono>
#include <cmath>
#include <cstring>
#include <optional>
#include <vector>

using namespace b32;

namespace {

// --- the supported executable ------------------------------------------------------------

constexpr const char *kExecutableSHA256 = "4c940898943a1ac63318083b17bc04219251ad4b3cd2b846eaf41c1702f98f0d";

namespace addr {
// (unused, const int *state, const short vector[2], bool look): posts
// Event_AnaloguePadPosition to the player. State 2 posts the vector as given.
constexpr GuestAddr kPostPadPosition = 0x158664;
// (unused, int action): posts Event_PlayerAction to the player.
constexpr GuestAddr kPostPlayerAction = 0x15893c;
constexpr GuestAddr kGame = 0xa15080;          // CGame *
constexpr GuestAddr kLevelManager = 0xa1a54c;  // CLevelManager *; +8 is the local player CEnt
constexpr GuestAddr kOptions = 0xa1a558;       // game options; +0x84 are the controls
constexpr GuestAddr kGuiManager = 0xa1a548;    // CIwGuiManager *
constexpr GuestAddr kCameras = 0xa1a5b4;       // camera settings, a look range per player state
}  // namespace addr

namespace vtable {
constexpr uint32_t kGame = 0x2b4784;
constexpr uint32_t kGameStateIngame = 0x2a9754;
constexpr uint32_t kEnt = 0x2b46dc;
constexpr uint32_t kPlayerLocal = 0x2a4c98;
constexpr uint32_t kPlayerInputControllerLocal = 0x2b3204;
constexpr uint32_t kGuiFrame = 0x2a3550;
constexpr uint32_t kGuiFrameHud = 0x2a402c;
constexpr uint32_t kGuiTouchAnaloguePad = 0x2ae414;
constexpr uint32_t kGuiTouchButtonIcon = 0x2ad1d8;
constexpr uint32_t kGuiTouchGestureArea = 0x2ae4a8;
}  // namespace vtable

constexpr uint32_t kGameStateIngame = 2;    // CGame's state while in a level
constexpr uint32_t kIngameStatePlaying = 0; // not paused, not game over
constexpr uint32_t kPlayerStateWalk = 0, kPlayerStateRun = 1, kPlayerStateAim = 2;

// Event_PlayerAction numbers.
enum Action : uint32_t {
    kInteractStart = 1,
    kInteractEnd = 2,
    kFire = 3,
    kFireHeld = 4,
    kToggleAim = 5,
    kToggleRun = 6,
    kReload = 7,
    kGrenadeStart = 8,
    kGrenadeThrow = 9,
    kCycleSpecial = 10,
    kMelee = 11,
    kSwapWeapon = 12,
};

constexpr float kPadFull = 4096;         // full deflection of an analogue pad
constexpr float kFullTurn = 4096;        // game angle units per turn
constexpr uint32_t kGuiVisible = 0x8;    // CIwGuiElement flag: drawn
constexpr float kStickDegreesPerSecond = 180;
constexpr float kMoveDeadzone = 0.2f, kLookDeadzone = 0.15f;
constexpr float kTriggerPress = 0.5f, kTriggerRelease = 0.3f;
constexpr float kSprintRelease = 0.3f;   // forward deflection below which a clicked-in sprint stops
constexpr float kMaxFrameTime = 0.1f;    // longest frame look integrates over
using Clock = std::chrono::steady_clock;
constexpr auto kToggleTimeout = std::chrono::seconds(1);

bool supported(Runtime &rt) {
    static const bool ok = [&] {
        NSData *data = [NSData dataWithContentsOfFile:@(rt.image().path.c_str())];
        if (!data) return false;
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(data.bytes, CC_LONG(data.length), digest);
        char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
        for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(hex + i * 2, 3, "%02x", digest[i]);
        bool match = std::strcmp(hex, kExecutableSHA256) == 0;
        if (match) log("CoD Zombies 1.5.0: game controller play enabled");
        return match;
    }();
    return ok;
}

// --- guest memory -------------------------------------------------------------------------

std::optional<uint32_t> peek(Runtime &rt, GuestAddr a) {
    if (a < 0x1000 || !rt.mem().isMapped(a) || !rt.mem().isMapped(a + 3)) return std::nullopt;
    return rt.mem().read<uint32_t>(a);
}
std::optional<uint8_t> peek8(Runtime &rt, GuestAddr a) {
    if (a < 0x1000 || !rt.mem().isMapped(a)) return std::nullopt;
    return rt.mem().read<uint8_t>(a);
}
void poke(Runtime &rt, GuestAddr a, uint32_t value) {
    if (a >= 0x1000 && rt.mem().isMapped(a) && rt.mem().isMapped(a + 3)) rt.mem().write<uint32_t>(a, value);
}
bool vtableIs(Runtime &rt, uint32_t object, uint32_t vtable) { return object && peek(rt, object) == vtable; }
std::optional<uint32_t> peekObject(Runtime &rt, GuestAddr a, uint32_t vtable) {
    auto object = peek(rt, a);
    return object && vtableIs(rt, *object, vtable) ? object : std::nullopt;
}

struct Player {
    uint32_t controller;  // CPlayerInputControllerLocal
    uint32_t local;       // CPlayerLocal
};

// The local player, if the game is in a level and playing.
std::optional<Player> playingPlayer(Runtime &rt) {
    auto game = peekObject(rt, addr::kGame, vtable::kGame);
    if (!game || peek(rt, *game + 0x20) != kGameStateIngame) return std::nullopt;
    // The game's states are (wrapper, id) pairs; each wrapper holds its
    // state object at +0x10.
    std::optional<uint32_t> ingame;
    for (uint32_t i = 0; i < 8 && !ingame; i++) {
        uint32_t entry = *game + 0xb4 + i * 8;
        auto wrapper = peek(rt, entry);
        if (wrapper && *wrapper && peek(rt, entry + 4) == kGameStateIngame) ingame = *wrapper + 0x10;
    }
    if (!ingame || !vtableIs(rt, *ingame, vtable::kGameStateIngame) || peek(rt, *ingame + 0x10) != kIngameStatePlaying)
        return std::nullopt;
    auto level = peek(rt, addr::kLevelManager);
    if (!level || !*level) return std::nullopt;
    auto ent = peekObject(rt, *level + 8, vtable::kEnt);
    if (!ent) return std::nullopt;
    auto controller = peekObject(rt, *ent + 0xa8, vtable::kPlayerInputControllerLocal);
    auto local = peekObject(rt, *ent + 0x98, vtable::kPlayerLocal);
    if (!controller || !local) return std::nullopt;
    return Player{*controller, *local};
}

// The touch control frame the HUD shows (dual stick A or B, or tilt).
std::optional<uint32_t> currentHudLayout(Runtime &rt) {
    auto manager = peek(rt, addr::kGuiManager);
    if (!manager || !*manager) return std::nullopt;
    uint32_t root = *manager + 0xb8;  // the root GUI element is embedded in the manager
    auto frames = peek(rt, root + 0x50), count = peek(rt, root + 0x54);
    if (!frames || !count) return std::nullopt;
    for (uint32_t i = 0; i < std::min<uint32_t>(*count, 256); i++) {
        auto frame = peek(rt, *frames + i * 4);
        if (frame && vtableIs(rt, *frame, vtable::kGuiFrameHud)) {
            auto layout = peek(rt, *frame + 0x9c);
            if (layout && *layout) return layout;
            return std::nullopt;
        }
    }
    return std::nullopt;
}

// Stops drawing the sticks and touch buttons; the rest of the HUD stays.
void hideTouchControls(Runtime &rt) {
    auto layout = currentHudLayout(rt);
    if (!layout) return;
    std::vector<std::pair<uint32_t, int>> pending = {{*layout, 0}};
    while (!pending.empty()) {
        auto [frame, depth] = pending.back();
        pending.pop_back();
        auto children = peek(rt, frame + 0x50), count = peek(rt, frame + 0x54);
        if (!children || !count) continue;
        for (uint32_t i = 0; i < std::min<uint32_t>(*count, 64); i++) {
            auto child = peek(rt, *children + i * 4);
            if (!child) break;
            auto cls = peek(rt, *child);
            if (!cls) continue;
            if (*cls == vtable::kGuiTouchAnaloguePad || *cls == vtable::kGuiTouchButtonIcon ||
                *cls == vtable::kGuiTouchGestureArea) {
                if (auto flags = peek(rt, *child + 0xc); flags && (*flags & kGuiVisible))
                    poke(rt, *child + 0xc, *flags & ~kGuiVisible);
            } else if (*cls == vtable::kGuiFrame && depth < 3) {
                pending.push_back({*child, depth + 1});
            }
        }
    }
}

// The camera's pitch limits for a player state.
std::optional<std::pair<int32_t, int32_t>> pitchRange(Runtime &rt, uint32_t playerState) {
    auto cameras = peek(rt, addr::kCameras);
    if (!cameras || !*cameras) return std::nullopt;
    auto camera = peek(rt, *cameras + 0x28 + std::min<uint32_t>(playerState, 16) * 4);
    if (!camera || !*camera) return std::nullopt;
    auto points = peek(rt, *camera + 0x10), count = peek(rt, *camera + 0x14);
    if (!points || !count || !*count) return std::nullopt;
    int32_t low = INT32_MAX, high = INT32_MIN;
    for (uint32_t i = 0; i < std::min<uint32_t>(*count, 16); i++) {
        auto pitch = peek(rt, *points + i * 8 + 4);
        if (!pitch) return std::nullopt;
        low = std::min(low, int32_t(*pitch));
        high = std::max(high, int32_t(*pitch));
    }
    return std::make_pair(low, high);
}

// The "Invert Y Axis" setting of the game's own options.
bool gameInvertsLook(Runtime &rt) {
    auto options = peek(rt, addr::kOptions);
    if (!options || !*options) return false;
    uint32_t controls = *options + 0x84;
    auto scheme = peek8(rt, controls + 9);
    auto table = peek(rt, controls + 0x24);
    if (!scheme || !table) return false;
    uint32_t s = *scheme == 3 ? 2 : *scheme;
    return peek8(rt, *table + s * 10 + 8).value_or(0) != 0;
}

// --- controller --------------------------------------------------------------------------

std::pair<float, float> deadzoned(float x, float y, float deadzone) {
    float magnitude = std::hypot(x, y);
    if (magnitude <= deadzone) return {0, 0};
    float scaled = std::min((magnitude - deadzone) / (1 - deadzone), 1.0f);
    return {x / magnitude * scaled, y / magnitude * scaled};
}

struct Toggle {
    Clock::time_point at;
    uint32_t playerState;
};

// True when the player's state changed since the toggle, or it had time to.
bool settled(const std::optional<Toggle> &toggle, uint32_t playerState, Clock::time_point now) {
    return !toggle || toggle->playerState != playerState || now >= toggle->at + kToggleTimeout;
}

struct State {
    GuestAddr scratch = 0;  // POST_PAD_POSITION's arguments
    std::optional<Clock::time_point> lastFrame;
    std::pair<float, float> lookRemainder{0, 0};
    std::optional<Toggle> aimToggle, runToggle;
    // Held last frame, for presses and releases.
    bool fire = false, aim = false, sprint = false;
    bool a = false, b = false, x = false, y = false, l1 = false, r1 = false, r3 = false;
};

State state;

void postPadPosition(Call &c, float x, float y) {
    if (!state.scratch) state.scratch = c.heap.alloc(8);
    c.mem.write<int32_t>(state.scratch, 2);
    c.mem.write<int16_t>(state.scratch + 4, int16_t(std::lround(x)));
    c.mem.write<int16_t>(state.scratch + 6, int16_t(std::lround(y)));
    c.cpu.call(addr::kPostPadPosition, {0, state.scratch, state.scratch + 4, 0});
}

void postAction(Call &c, uint32_t action) { c.cpu.call(addr::kPostPlayerAction, {0, action}); }

// A button's press (and, for some, release) as player actions.
void button(Call &c, bool now, bool &was, std::optional<uint32_t> onPress, std::optional<uint32_t> onRelease = {}) {
    if (now && !was && onPress) postAction(c, *onPress);
    if (!now && was && onRelease) postAction(c, *onRelease);
    was = now;
}

// Stick look: yaw is a per-frame delta the player update consumes; pitch is
// absolute and limited to the camera's range for the player state.
void look(Call &c, const Player &player, float yaw, float pitch) {
    Runtime &rt = c.rt;
    if (gameInvertsLook(rt)) pitch = -pitch;
    float totalYaw = state.lookRemainder.first + yaw, totalPitch = state.lookRemainder.second + pitch;
    float wholeYaw = std::trunc(totalYaw), wholePitch = std::trunc(totalPitch);
    state.lookRemainder = {totalYaw - wholeYaw, totalPitch - wholePitch};
    if (int32_t dy = int32_t(wholeYaw)) {
        if (auto current = peek(rt, player.controller + 0x24))
            poke(rt, player.controller + 0x24, uint32_t(int32_t(*current) + dy));
    }
    if (int32_t dp = int32_t(wholePitch)) {
        auto current = peek(rt, player.controller + 0x20);
        auto range = pitchRange(rt, peek(rt, player.local + 0xf0).value_or(kPlayerStateWalk));
        if (!current || !range) return;
        int32_t value = int32_t(*current);
        if (dp > 0 && value < range->second) poke(rt, player.controller + 0x20, uint32_t(std::min(value + dp, range->second)));
        else if (dp < 0 && value > range->first) poke(rt, player.controller + 0x20, uint32_t(std::max(value + dp, range->first)));
        else state.lookRemainder.second = 0;
    }
}

void play(Call &c, const Player &player, GCExtendedGamepad *pad, float dt, Clock::time_point now) {
    Runtime &rt = c.rt;

    // Movement: the left stick, scaled to the pad's full deflection.
    auto [mx, my] = deadzoned(pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value, kMoveDeadzone);
    if (float magnitude = std::hypot(mx, my); magnitude > 0) {
        float scale = kPadFull / std::max(magnitude, 1.0f);
        postPadPosition(c, mx * scale, my * scale);
    }

    // Fire: a press, then held while automatic weapons keep firing.
    float trigger = pad.rightTrigger.value;
    bool fire = state.fire ? trigger > kTriggerRelease : trigger >= kTriggerPress;
    if (fire && !state.fire) postAction(c, kFire);
    else if (fire) postAction(c, kFireHeld);
    state.fire = fire;

    // Aiming and running are toggles: post one when the player's state
    // differs from the controls, then wait for it to take effect.
    float aimTrigger = pad.leftTrigger.value;
    state.aim = state.aim ? aimTrigger > kTriggerRelease : aimTrigger >= kTriggerPress;
    uint32_t playerState = peek(rt, player.local + 0xf0).value_or(kPlayerStateWalk);
    Toggle toggle{now, playerState};
    bool aiming = playerState == kPlayerStateAim;
    bool canAim = playerState == kPlayerStateWalk || playerState == kPlayerStateRun;
    if (settled(state.aimToggle, playerState, now) && ((state.aim && canAim) || (!state.aim && aiming))) {
        postAction(c, kToggleAim);
        state.aimToggle = toggle;
    }
    // A clicked-in sprint lasts while moving forward; running needs forward
    // movement fast enough, which the game flags.
    if (pad.leftThumbstickButton.pressed) state.sprint = true;
    if (my < kSprintRelease) state.sprint = false;
    bool canRun = playerState == kPlayerStateWalk && peek8(rt, player.local + 0xd6) == 1;
    bool wantRun = state.sprint && my > 0 && !state.aim;
    bool running = playerState == kPlayerStateRun;
    if (settled(state.runToggle, playerState, now) && ((wantRun && canRun) || (!wantRun && running))) {
        postAction(c, kToggleRun);
        state.runToggle = toggle;
    }

    button(c, pad.buttonA.pressed, state.a, kInteractStart, kInteractEnd);
    button(c, pad.buttonX.pressed, state.x, kReload);
    button(c, pad.buttonY.pressed, state.y, kSwapWeapon);
    button(c, pad.buttonB.pressed, state.b, kMelee);
    button(c, pad.rightThumbstickButton.pressed, state.r3, kMelee);
    button(c, pad.rightShoulder.pressed, state.r1, kGrenadeStart, kGrenadeThrow);
    button(c, pad.leftShoulder.pressed, state.l1, kCycleSpecial);

    // Look: a squared response, fine near the centre and fast at the edge.
    auto [lx, ly] = deadzoned(pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value, kLookDeadzone);
    if (float magnitude = std::hypot(lx, ly); magnitude > 0) {
        float rate = kStickDegreesPerSecond * kFullTurn / 360 * magnitude * dt;
        look(c, player, lx * rate, ly * rate);
    }
}

void frame(Call &c) {
    if (!supported(c.rt)) return;
    GCController *controller = GCController.current ?: GCController.controllers.firstObject;
    GCExtendedGamepad *pad = controller.extendedGamepad;
    auto now = Clock::now();
    float dt = state.lastFrame ? std::min(std::chrono::duration<float>(now - *state.lastFrame).count(), kMaxFrameTime) : 0;
    state.lastFrame = now;
    auto player = playingPlayer(c.rt);
    if (!pad || !player) {
        // Release what was held, so nothing carries into the next level.
        state.lookRemainder = {0, 0};
        state.fire = state.aim = state.sprint = false;
        state.a = state.b = state.x = state.y = state.l1 = state.r1 = state.r3 = false;
        return;
    }
    hideTouchControls(c.rt);
    play(c, *player, pad, dt, now);
}

[[maybe_unused]] const int registered = (gl::addPresentHook(frame), 0);

}  // namespace
