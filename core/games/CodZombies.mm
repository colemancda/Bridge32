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
// shoulder picks the special grenade, Options pauses.
//
// In the menus, the D-pad or left stick moves between buttons, A presses,
// B or Options goes back; see the menu section.

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/gl/GLES.h"
#include "core/uikit/UIKitSupport.h"
#include "core/thunks/Thunks.h"

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <UIKit/UIKit.h>
#include <CommonCrypto/CommonDigest.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstring>
#include <deque>
#include <map>
#include <optional>
#include <set>
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

// --- touches ------------------------------------------------------------------------------
// The menus (and the pause button) only take touches. Touches are delivered
// to the game's view the way UIKit would, from points of the game's
// landscape screen. The game is wrapped landscape-right, so its landscape
// (x, y) is the portrait view's (width - y, x).

using Point = std::pair<float, float>;
enum class Phase { Down, Move, Up };
struct Step {
    int ms;  // after the gesture starts
    Phase phase;
    Point point;
};
using Gesture = std::vector<Step>;

std::atomic<double> gestureBusyUntil{0};  // seconds of uptime
std::atomic<float> screenWidth{460}, screenHeight{320};  // the game's landscape screen

double uptime() { return NSProcessInfo.processInfo.systemUptime; }
bool gestureBusy() { return uptime() < gestureBusyUntil.load(); }

void perform(Gesture gesture);

Gesture tap(Point point) { return {{0, Phase::Down, point}, {60, Phase::Up, point}}; }

Gesture drag(Point from, Point to, int moves, int intervalMs, int holdMs) {
    Gesture steps = {{0, Phase::Down, from}};
    for (int i = 1; i <= moves; i++) {
        float t = float(i) / float(moves);
        steps.push_back({intervalMs * i, Phase::Move,
                         {from.first + (to.first - from.first) * t, from.second + (to.second - from.second) * t}});
    }
    steps.push_back({intervalMs * moves + holdMs, Phase::Up, to});
    return steps;
}

// Points of the landscape screen, from its top left.
constexpr Point kPausePoint = {19, 20};  // the score, which opens the pause menu
constexpr Point kBackPoint = {22, 296};  // the Back button shared by the menus

}  // namespace

// Just enough of UITouch and UIEvent for the game's touch methods.
@interface B32CodTouch : NSObject
@property (nonatomic, retain) UIWindow *window;
@property (nonatomic, retain) UIView *view;
@property (nonatomic) CGPoint location, previousLocation;  // in the window
@property (nonatomic) UITouchPhase phase;
@property (nonatomic) NSTimeInterval timestamp;
@property (nonatomic) NSUInteger tapCount;
@end

@implementation B32CodTouch
- (void)dealloc {
    [_window release];
    [_view release];
    [super dealloc];
}
- (CGPoint)locationInView:(UIView *)view { return view ? [_window convertPoint:_location toView:view] : _location; }
- (CGPoint)previousLocationInView:(UIView *)view {
    return view ? [_window convertPoint:_previousLocation toView:view] : _previousLocation;
}
@end

@interface B32CodTouchEvent : NSObject
@property (nonatomic, retain) NSSet *allTouches;
@property (nonatomic) NSTimeInterval timestamp;
@end

@implementation B32CodTouchEvent
- (void)dealloc {
    [_allTouches release];
    [super dealloc];
}
- (UIEventType)type { return UIEventTypeTouches; }
- (NSSet *)touchesForView:(UIView *)view { return _allTouches; }
- (NSSet *)touchesForWindow:(UIWindow *)window { return _allTouches; }
@end

namespace {

// The game's view: what a touch in the middle of its window hits.
UIView *gameView() {
    UIWindow *window = uikit::guestKeyWindow();
    if (!window) return nil;
    return [window hitTest:CGPointMake(CGRectGetMidX(window.bounds), CGRectGetMidY(window.bounds)) withEvent:nil];
}

CGPoint viewPoint(UIView *view, Point p) { return CGPointMake(view.bounds.size.width - p.second, p.first); }

CGRect viewRect(UIView *view, float x, float y, float w, float h) {
    return CGRectMake(view.bounds.size.width - (y + h), x, h, w);
}

void perform(Gesture gesture) {
    if (gesture.empty()) return;
    gestureBusyUntil = uptime() + gesture.back().ms / 1000.0 + 0.05;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *view = gameView();
        if (!view) return;
        B32CodTouch *touch = [[B32CodTouch alloc] init];
        touch.window = view.window;
        touch.view = view;
        touch.tapCount = 1;
        B32CodTouchEvent *event = [[B32CodTouchEvent alloc] init];
        event.allTouches = [NSSet setWithObject:touch];
        for (size_t i = 0; i < gesture.size(); i++) {
            Step step = gesture[i];
            bool last = i + 1 == gesture.size();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(step.ms) * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                CGPoint location = [view convertPoint:viewPoint(view, step.point) toView:nil];
                touch.previousLocation = step.phase == Phase::Down ? location : touch.location;
                touch.location = location;
                touch.timestamp = event.timestamp = uptime();
                NSSet *touches = event.allTouches;
                switch (step.phase) {
                case Phase::Down:
                    touch.phase = UITouchPhaseBegan;
                    [view touchesBegan:touches withEvent:(UIEvent *)event];
                    break;
                case Phase::Move:
                    touch.phase = UITouchPhaseMoved;
                    [view touchesMoved:touches withEvent:(UIEvent *)event];
                    break;
                case Phase::Up:
                    touch.phase = UITouchPhaseEnded;
                    [view touchesEnded:touches withEvent:(UIEvent *)event];
                    break;
                }
                if (last) {
                    [touch release];
                    [event release];
                }
            });
        }
    });
}

// The game's landscape screen, from its view (kept for the menu code, which
// runs off the main thread).
void updateScreenSize() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (UIView *view = gameView()) {
            screenWidth = float(view.bounds.size.height);
            screenHeight = float(view.bounds.size.width);
        }
    });
}

// --- menu navigation -------------------------------------------------------------------------
// Ported from codwawzpc's src/codwawzpc/menu.rs. Each menu button, slider and
// scrolling list registers a touch region with the game's touch manager
// (CIwTouchManager). Every frame outside play, the enabled regions are read
// and one is kept focused: directions move the focus to the nearest region
// that way, A taps it, left and right drag a focused slider, and moving past
// the last visible row of a list drags the list by a row. Focus is shown the
// game's own way where it has one (the blood smear of a "selected" menu item,
// a list's selected row), otherwise with an outline.

namespace menu {

constexpr GuestAddr kTouchManager = 0xa1a56c;  // CIwTouchManager *; regions at +4, count at +8

constexpr uint32_t kButton = 0x2af4c8;   // CDoubleTouchComponent<CIwTouchButton>: buttons, list rows
constexpr uint32_t kSlider = 0x2a7af0;   // CIwTouchSlider
constexpr uint32_t kTracker = 0x2a8bec;  // CIwTouchTracker: a scrolling list's drag area

constexpr uint32_t kAchievementItem = 0x2b4440;  // CGuiTouchButtonAchievementMenuItem
// GUI elements that draw a blood smear when highlighted.
constexpr uint32_t kBloodClasses[] = {0x2b0d8c, 0x2b4440, 0x2a869c, 0x2ae53c, 0x2a989c};
constexpr uint32_t kAchievementList = 0x2b1658;  // CGuiFrameAchievementList
constexpr uint32_t kListSelected = 0x130;        // its selected row's GUI element

// Offsets in a menu item GUI element.
constexpr uint32_t kItemName = 4, kItemParent = 0x3c, kItemRegion = 0xa0, kItemHighlight = 0x190, kItemSelected = 0x1a4;
// Offsets in a touch region.
constexpr uint32_t kRegionRect = 0x40, kRegionEnabled = 0x55, kRegionSliderValue = 0x60;

constexpr uint32_t kMaxRegions = 1024;
constexpr float kSliderStep = 0.1f;
constexpr size_t kMaxPending = 4;
constexpr uint32_t kSettleFrames = 2;
constexpr float kNavPress = 0.6f, kNavRelease = 0.4f;
constexpr double kRepeatDelay = 0.4, kRepeatInterval = 0.12;

struct Rect {
    float x = 0, y = 0, w = 0, h = 0;
    float right() const { return x + w; }
    float bottom() const { return y + h; }
    Point center() const { return {x + w / 2, y + h / 2}; }
    bool empty() const { return w <= 0 || h <= 0; }
    Rect intersect(const Rect &o) const {
        float nx = std::max(x, o.x), ny = std::max(y, o.y);
        return {nx, ny, std::max(std::min(right(), o.right()) - nx, 0.0f), std::max(std::min(bottom(), o.bottom()) - ny, 0.0f)};
    }
    bool operator==(const Rect &o) const { return x == o.x && y == o.y && w == o.w && h == o.h; }
};

Rect screen() { return {0, 0, screenWidth.load(), screenHeight.load()}; }
bool coversScreen(const Rect &r) {
    Rect s = screen();
    return r.x <= 0 && r.y <= 0 && r.right() >= s.w && r.bottom() >= s.h;
}

enum class Highlight { Outline, Flag, Select, Tap };
enum class Kind { Button, Slider, ScrollArea };
enum class Dir { Up, Down, Left, Right };

struct Raw {
    uint32_t addr;
    bool tracker = false;
    Kind kind = Kind::Button;
    Highlight highlight = Highlight::Outline;
    bool selected = false;
    float value = 0, thumb = 0;  // sliders
    Rect rect;
};

struct Region {
    uint32_t addr;
    Kind kind;
    Highlight highlight;
    bool selected;
    float value, thumb;
    Rect rect;     // the part that can be seen and touched
    float height;  // as registered (a list's row height)
    int list;      // index into Screen::lists, or -1
    bool hidden;   // scrolled out of its list
};

struct Command {
    bool activate;
    Dir dir;
};

// What a command does.
struct Action {
    enum Type { None, Focus, FocusAndScroll, ScrollThenMove, Scroll, Adjust, Tap } type = None;
    uint32_t addr = 0;
    int list = -1;
    Dir dir = Dir::Up;
    Rect rect;
    float amount = 0;
    Point point;
};

struct Screen {
    std::vector<Region> regions;
    std::vector<Rect> lists;

    explicit Screen(const std::vector<Raw> &raw) {
        for (const Raw &r : raw)
            if (r.tracker) lists.push_back(r.rect);
        std::vector<bool> used(lists.size());
        for (const Raw &r : raw) {
            if (r.tracker) continue;
            // A row spans its list, and rows scrolled out are parked just
            // outside it.
            int list = -1;
            for (size_t i = 0; i < lists.size(); i++) {
                const Rect &l = lists[i];
                if (r.rect.x == l.x && r.rect.w == l.w && r.rect.h < l.h && r.rect.bottom() > l.y - r.rect.h &&
                    r.rect.y < l.bottom() + r.rect.h) {
                    list = int(i);
                    break;
                }
            }
            Rect rect;
            bool hidden;
            if (list >= 0) {
                used[size_t(list)] = true;
                float cy = r.rect.center().second;
                hidden = cy <= lists[size_t(list)].y || cy > lists[size_t(list)].bottom();
                rect = r.rect.intersect(lists[size_t(list)]);
            } else {
                rect = r.rect.intersect(screen());
                hidden = rect.empty();
            }
            regions.push_back({r.addr, r.kind, r.highlight, r.selected, r.value, r.thumb, rect, r.rect.h, list, hidden});
        }
        size_t t = 0;
        for (const Raw &r : raw) {
            if (!r.tracker) continue;
            if (!used[t])
                regions.push_back({r.addr, Kind::ScrollArea, Highlight::Outline, false, 0, 0, r.rect.intersect(screen()),
                                   r.rect.h, -1, false});
            t++;
        }
        // A screen-sized region (such as "touch to start") only matters when
        // there is nothing else.
        bool others = std::any_of(regions.begin(), regions.end(), [](const Region &r) { return !coversScreen(r.rect) && !r.hidden; });
        if (others)
            regions.erase(std::remove_if(regions.begin(), regions.end(), [](const Region &r) { return coversScreen(r.rect); }),
                          regions.end());
    }

    const Region *get(uint32_t addr) const {
        for (const Region &r : regions)
            if (r.addr == addr) return &r;
        return nullptr;
    }

    // Identifies the screen independently of list scrolling.
    std::vector<uint32_t> signature() const {
        std::vector<uint32_t> s;
        for (const Region &r : regions)
            if (r.list < 0) s.push_back(r.addr);
        return s;
    }

    // A list's selected row, else the first region in reading order.
    std::optional<uint32_t> first() const {
        for (const Region &r : regions)
            if (!r.hidden && r.list >= 0 && r.kind == Kind::Button && r.selected) return r.addr;
        const Region *best = nullptr;
        for (const Region &r : regions)
            if (!r.hidden && (!best || std::make_pair(r.rect.y, r.rect.x) < std::make_pair(best->rect.y, best->rect.x))) best = &r;
        return best ? std::optional<uint32_t>(best->addr) : std::nullopt;
    }

    std::vector<const Region *> rows(int list) const {
        std::vector<const Region *> out;
        for (const Region &r : regions)
            if (r.list == list) out.push_back(&r);
        return out;
    }

    Action step(const Region &focus, Command command) const {
        Action a;
        if (command.activate) {
            if (focus.kind == Kind::Button && !focus.hidden) {
                a.type = Action::Tap;
                a.point = focus.rect.center();
            }
            return a;
        }
        Dir dir = command.dir;
        bool vertical = dir == Dir::Up || dir == Dir::Down;
        if (focus.kind == Kind::Slider && !vertical) {
            a.type = Action::Adjust;
            a.addr = focus.addr;
            a.amount = dir == Dir::Left ? -kSliderStep : kSliderStep;
            return a;
        }
        if (focus.kind == Kind::ScrollArea && vertical) {
            a.type = Action::Scroll;
            a.rect = focus.rect;
            a.dir = dir;
            a.amount = 40;
            return a;
        }
        if (focus.list >= 0 && vertical) {
            auto r = rows(focus.list);
            size_t at = size_t(std::find(r.begin(), r.end(), &focus) - r.begin());
            std::optional<size_t> next;
            if (dir == Dir::Up) {
                if (at > 0) next = at - 1;
            } else {
                next = at + 1;
            }
            if (next && *next < r.size()) {
                a.addr = r[*next]->addr;
                if (r[*next]->hidden) {
                    a.type = Action::FocusAndScroll;
                    a.list = focus.list;
                    a.dir = dir;
                } else {
                    a.type = Action::Focus;
                }
            } else {
                a.type = Action::ScrollThenMove;
                a.list = focus.list;
                a.dir = dir;
            }
            return a;
        }
        if (auto next = nearest(focus, dir)) {
            a.type = Action::Focus;
            a.addr = *next;
        }
        return a;
    }

    // After ScrollThenMove: the row that scrolled in next to `from`, or else
    // (the list ended) the nearest region outside the list.
    std::optional<uint32_t> stepAfterScroll(uint32_t from, Dir dir) const {
        const Region *focus = get(from);
        if (!focus || focus->list < 0) return std::nullopt;
        auto r = rows(focus->list);
        size_t at = size_t(std::find(r.begin(), r.end(), focus) - r.begin());
        std::optional<size_t> next;
        if (dir == Dir::Up) {
            if (at > 0) next = at - 1;
        } else {
            next = at + 1;
        }
        if (next && *next < r.size() && !r[*next]->hidden) return r[*next]->addr;
        return nearest(*focus, dir);
    }

    // The region closest to `focus` in a direction, preferring ones in line
    // with it.
    std::optional<uint32_t> nearest(const Region &focus, Dir dir) const {
        auto [fx, fy] = focus.rect.center();
        auto gap = [](float a0, float a1, float b0, float b1) { return std::max({b0 - a1, a0 - b1, 0.0f}); };
        std::optional<std::pair<float, uint32_t>> best;
        for (const Region &r : regions) {
            if (r.hidden || r.addr == focus.addr || (focus.list >= 0 && r.list == focus.list)) continue;
            auto [cx, cy] = r.rect.center();
            float along, across;
            switch (dir) {
            case Dir::Up: along = fy - cy; across = gap(focus.rect.x, focus.rect.right(), r.rect.x, r.rect.right()); break;
            case Dir::Down: along = cy - fy; across = gap(focus.rect.x, focus.rect.right(), r.rect.x, r.rect.right()); break;
            case Dir::Left: along = fx - cx; across = gap(focus.rect.y, focus.rect.bottom(), r.rect.y, r.rect.bottom()); break;
            case Dir::Right: along = cx - fx; across = gap(focus.rect.y, focus.rect.bottom(), r.rect.y, r.rect.bottom()); break;
            }
            if (along <= 1) continue;
            float score = along + 2 * across;
            if (!best || score < best->first) best = std::make_pair(score, r.addr);
        }
        return best ? std::optional<uint32_t>(best->second) : std::nullopt;
    }
};

// Drag a list's contents by `amount` points so the rows move against `dir`,
// slowly enough that the list doesn't keep scrolling after.
Gesture scrollGesture(Rect list, Dir dir, float amount) {
    float x = list.x + std::min(list.w / 4, 60.0f);
    float from, to;
    if (dir == Dir::Down) {
        from = list.y + list.h * 0.7f;
        to = from - amount;
    } else {
        from = list.y + list.h * 0.3f;
        to = from + amount;
    }
    return drag({x, from}, {x, to}, 6, 25, 150);
}

Gesture sliderGesture(Rect rect, float value, float thumb, float delta) {
    float range = std::max(rect.w - thumb, 1.0f);
    float low = rect.x + thumb / 2;
    float from = low + range * std::clamp(value, 0.0f, 1.0f);
    float to = std::clamp(from + range * delta, low, low + range);
    float y = rect.center().second;
    return drag({from, y}, {to, y}, 2, 30, 30);
}

std::optional<Rect> readRect(Runtime &rt, GuestAddr at) {
    if (!rt.mem().isMapped(at) || !rt.mem().isMapped(at + 7)) return std::nullopt;
    return Rect{float(rt.mem().read<int16_t>(at)), float(rt.mem().read<int16_t>(at + 2)),
                float(rt.mem().read<int16_t>(at + 4)), float(rt.mem().read<int16_t>(at + 6))};
}

// The hash IwGui finds elements by: djb2 of the lowercased name.
uint32_t nameHash(const char *name) {
    uint32_t hash = 5381;
    for (const char *p = name; *p; p++) hash = hash * 33 + uint32_t(std::tolower(*p));
    return hash;
}

// The enabled regions of the touch manager.
std::vector<Raw> readRegions(Runtime &rt) {
    std::vector<Raw> out;
    auto manager = peek(rt, kTouchManager);
    if (!manager || !*manager) return out;
    auto list = peek(rt, *manager + 4), count = peek(rt, *manager + 8);
    if (!list || !count) return out;
    for (uint32_t i = 0; i < std::min(*count, kMaxRegions); i++) {
        auto object = peek(rt, *list + i * 4);
        if (!object || !*object) break;
        if (peek8(rt, *object + kRegionEnabled).value_or(0) == 0) continue;
        auto rect = readRect(rt, *object + kRegionRect);
        if (!rect || rect->empty()) continue;
        Raw raw{*object};
        raw.rect = *rect;
        auto cls = peek(rt, *object);
        if (cls == kButton) {
            uint32_t element = *object - kItemRegion;
            uint32_t elementClass = peek(rt, element).value_or(0);
            bool blood = std::find(std::begin(kBloodClasses), std::end(kBloodClasses), elementClass) != std::end(kBloodClasses) &&
                         peek(rt, element + kItemHighlight).value_or(0) != 0;
            if (!blood) {
                raw.highlight = Highlight::Outline;
            } else if (elementClass == kAchievementItem) {
                uint32_t parent = peek(rt, element + kItemParent).value_or(0);
                raw.highlight = peek(rt, parent + kItemName) == nameHash("va_buttonContainer") ? Highlight::Tap : Highlight::Select;
            } else {
                raw.highlight = Highlight::Flag;
            }
            raw.selected = blood && peek8(rt, element + kItemSelected) == 1;
        } else if (cls == kTracker) {
            raw.tracker = true;
        } else if (cls == kSlider) {
            auto word = peek(rt, *object + kRegionSliderValue);
            if (!word) continue;
            raw.kind = Kind::Slider;
            raw.value = float(*word & 0xffff) / 4096;
            raw.thumb = float(*word >> 16);
        } else {
            continue;
        }
        out.push_back(raw);
    }
    return out;
}

void poke8(Runtime &rt, GuestAddr a, uint8_t value) {
    if (a >= 0x1000 && rt.mem().isMapped(a)) rt.mem().write<uint8_t>(a, value);
}

struct Flagged {
    uint32_t region, element, cls;
    uint8_t was;
};

struct State {
    std::optional<uint32_t> focus;
    std::map<std::vector<uint32_t>, uint32_t> remembered;  // focus per screen, so Back returns to the opener
    std::deque<Command> pending;
    uint32_t idleFrames = 0;
    std::optional<std::pair<uint32_t, Dir>> afterScroll;
    std::optional<uint32_t> tapped;
    std::optional<Flagged> flagged;
    std::set<uint32_t> flagLost;  // regions whose selected flag the game keeps clearing
    bool shown = false;           // the controller was used in the menus, so show the focus
    // Held directions (D-pad or stick) and when each repeats next.
    bool held[4] = {};
    double repeatAt[4] = {};
    bool a = false, b = false, menuButton = false;
};

State state;

std::vector<Gesture> update(const Screen &screen, bool idle) {
    std::vector<Gesture> gestures;
    if (screen.regions.empty()) {
        // Loading or between screens: input now would act on whatever shows
        // up next.
        state.pending.clear();
        state.focus.reset();
        return gestures;
    }
    while (state.pending.size() > kMaxPending) state.pending.pop_front();
    auto signature = screen.signature();
    if (!state.focus || !screen.get(*state.focus)) {
        state.focus.reset();
        if (auto it = state.remembered.find(signature); it != state.remembered.end())
            if (const Region *r = screen.get(it->second); r && !r->hidden) state.focus = it->second;
        if (!state.focus) state.focus = screen.first();
    }
    if (idle) {
        if (auto after = state.afterScroll) {
            state.afterScroll.reset();
            if (auto next = screen.stepAfterScroll(after->first, after->second)) state.focus = next;
        }
        // An achievement row is selected (showing its details) by tapping it.
        if (const Region *r = state.focus ? screen.get(*state.focus) : nullptr;
            r && r->kind == Kind::Button && r->highlight == Highlight::Tap && !r->selected && !r->hidden && state.tapped != r->addr) {
            state.tapped = r->addr;
            gestures.push_back(tap(r->rect.center()));
            return gestures;
        }
        // One command at a time: each may change the screen.
        const Region *focus = state.focus ? screen.get(*state.focus) : nullptr;
        if (focus && !state.pending.empty()) {
            Command command = state.pending.front();
            state.pending.pop_front();
            Action a = screen.step(*focus, command);
            switch (a.type) {
            case Action::None: break;
            case Action::Focus: state.focus = a.addr; break;
            case Action::FocusAndScroll:
                state.focus = a.addr;
                gestures.push_back(scrollGesture(screen.lists[size_t(a.list)], a.dir, screen.get(a.addr)->height));
                break;
            case Action::ScrollThenMove:
                state.afterScroll = std::make_pair(focus->addr, a.dir);
                gestures.push_back(scrollGesture(screen.lists[size_t(a.list)], a.dir, focus->height));
                break;
            case Action::Scroll: gestures.push_back(scrollGesture(a.rect, a.dir, a.amount)); break;
            case Action::Adjust:
                if (const Region *r = screen.get(a.addr); r && r->kind == Kind::Slider)
                    gestures.push_back(sliderGesture(r->rect, r->value, r->thumb, a.amount));
                break;
            case Action::Tap: gestures.push_back(tap(a.point)); break;
            }
        }
    }
    if (state.focus) state.remembered[signature] = *state.focus;
    return gestures;
}

// Sets the selected flag of the focused menu item, and clears it on the one
// focused before; a hidden focus gives the item back the flag it had.
void syncFlag(Runtime &rt, std::optional<uint32_t> region) {
    if (auto flagged = state.flagged) {
        if (region == flagged->region) {
            if (peek8(rt, flagged->element + kItemSelected) != 0) return;
            // Something clears it every frame (a list showing its own
            // selection): outline this one instead.
            state.flagLost.insert(flagged->region);
        } else if (peek(rt, flagged->element) == flagged->cls) {
            poke8(rt, flagged->element + kItemSelected, region ? 0 : flagged->was);
        }
        state.flagged.reset();
    }
    if (!region || state.flagLost.count(*region)) return;
    uint32_t element = *region - kItemRegion;
    auto cls = peek(rt, element);
    auto was = peek8(rt, element + kItemSelected);
    if (!cls || !was) return;
    poke8(rt, element + kItemSelected, 1);
    state.flagged = Flagged{*region, element, *cls, *was};
}

// The outline for a focus the game doesn't show itself, in the game's view.
UIView *outlineView = nil;

void showOutline(std::optional<Rect> rect) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *view = gameView();
        if (!rect || !view) {
            outlineView.hidden = YES;
            return;
        }
        if (!outlineView) {
            outlineView = [[UIView alloc] init];
            outlineView.userInteractionEnabled = NO;
            outlineView.layer.borderColor = [UIColor colorWithRed:0.75 green:0.05 blue:0.05 alpha:1].CGColor;
            outlineView.layer.borderWidth = 2;
            outlineView.layer.cornerRadius = 3;
        }
        if (outlineView.superview != view) [view addSubview:outlineView];
        outlineView.frame = CGRectInset(viewRect(view, rect->x, rect->y, rect->w, rect->h), -2, -2);
        outlineView.hidden = NO;
    });
}

void reset() {
    if (state.flagged) state.flagged.reset();
    state.pending.clear();
    state.shown = false;
    for (bool &h : state.held) h = false;
    showOutline(std::nullopt);
}

// Directions from the D-pad or left stick (press and release thresholds,
// repeating while held), A to activate.
void readCommands(GCExtendedGamepad *pad) {
    double now = uptime();
    float x = pad.dpad.xAxis.value, y = pad.dpad.yAxis.value;
    if (std::hypot(x, y) < 0.5f) {
        x = pad.leftThumbstick.xAxis.value;
        y = pad.leftThumbstick.yAxis.value;
    }
    const Dir dirs[4] = {Dir::Up, Dir::Down, Dir::Left, Dir::Right};
    const float amount[4] = {y, -y, -x, x};
    for (int i = 0; i < 4; i++) {
        bool held = state.held[i] ? amount[i] > kNavRelease : amount[i] >= kNavPress;
        if (held && !state.held[i]) {
            state.pending.push_back({false, dirs[i]});
            state.repeatAt[i] = now + kRepeatDelay;
            state.shown = true;
        } else if (held && now >= state.repeatAt[i]) {
            state.pending.push_back({false, dirs[i]});
            state.repeatAt[i] = now + kRepeatInterval;
        }
        state.held[i] = held;
    }
    bool a = pad.buttonA.pressed;
    if (a && !state.a) {
        state.pending.push_back({true, Dir::Up});
        state.shown = true;
    }
    state.a = a;
}

void frame(Runtime &rt, GCExtendedGamepad *pad) {
    readCommands(pad);
    Screen screen(readRegions(rt));
    state.idleFrames = gestureBusy() ? 0 : state.idleFrames + 1;
    std::vector<Gesture> gestures = update(screen, state.idleFrames >= kSettleFrames);
    if (!gestures.empty()) state.idleFrames = 0;
    for (Gesture &g : gestures) perform(std::move(g));

    const Region *focus = state.focus ? screen.get(*state.focus) : nullptr;
    std::optional<Rect> outline;
    if (focus && state.shown && !focus->hidden && !focus->rect.empty()) {
        bool own = focus->kind == Kind::Button &&
                   ((focus->highlight == Highlight::Flag && !state.flagLost.count(focus->addr)) ||
                    focus->highlight == Highlight::Select || focus->highlight == Highlight::Tap);
        if (!own) outline = focus->rect;
    }
    showOutline(outline);
    std::optional<uint32_t> flag;
    if (focus && state.shown && focus->kind == Kind::Button && focus->highlight == Highlight::Flag && !focus->hidden &&
        !state.flagLost.count(focus->addr))
        flag = focus->addr;
    syncFlag(rt, flag);
    // A focused level row becomes its list's selected row.
    if (focus && state.shown && focus->kind == Kind::Button && focus->highlight == Highlight::Select && !focus->selected &&
        !focus->hidden) {
        uint32_t element = focus->addr - kItemRegion;
        if (auto list = peek(rt, element + kItemParent); list && peek(rt, *list) == kAchievementList)
            poke(rt, *list + kListSelected, element);
    }
}

}  // namespace menu

// Releases everything held in play, delivering the releases that complete
// an action (using, throwing a grenade).
void releasePlay(Call &c) {
    if (state.a) postAction(c, kInteractEnd);
    if (state.r1) postAction(c, kGrenadeThrow);
    state.lookRemainder = {0, 0};
    state.fire = state.aim = state.sprint = false;
    state.a = state.b = state.x = state.y = state.l1 = state.r1 = state.r3 = false;
}

void frame(Call &c) {
    if (!supported(c.rt)) return;
    GCController *controller = GCController.current ?: GCController.controllers.firstObject;
    GCExtendedGamepad *pad = controller.extendedGamepad;
    auto now = Clock::now();
    float dt = state.lastFrame ? std::min(std::chrono::duration<float>(now - *state.lastFrame).count(), kMaxFrameTime) : 0;
    state.lastFrame = now;
    updateScreenSize();
    auto player = playingPlayer(c.rt);
    if (!pad) {
        if (player) releasePlay(c);
        menu::reset();
        return;
    }

    // Options (Menu) pauses during play and goes back in the menus, as does B
    // in the menus.
    bool menuButton = pad.buttonMenu.pressed;
    bool menuPressed = menuButton && !menu::state.menuButton;
    menu::state.menuButton = menuButton;

    if (player) {
        menu::reset();
        if (menuPressed && !gestureBusy()) {
            releasePlay(c);
            perform(tap(kPausePoint));
            return;
        }
        hideTouchControls(c.rt);
        play(c, *player, pad, dt, now);
        return;
    }

    releasePlay(c);
    bool b = pad.buttonB.pressed;
    bool bPressed = b && !menu::state.b;
    menu::state.b = b;
    if ((menuPressed || bPressed) && !gestureBusy()) {
        perform(tap(kBackPoint));
        return;
    }
    menu::frame(c.rt, pad);
}

[[maybe_unused]] const int registered = (gl::addPresentHook(frame), 0);

}  // namespace
