#include "sdkstubs.h"

#include "Bridge.h"
#include "core/Log.h"
#include "core/Runtime.h"

#include <cstring>
#include <mutex>
#include <set>
#include <string>

namespace b32::objc {

namespace {

// Each class is either stubbed whole (`selectors` null: its API is class
// methods and singletons, so nil from +sharedInstance silences everything
// after it) or only in the listed methods (ad views the game may add to its
// layout, which must still be real views).
struct Rule {
    const char *sdk;
    const char *cls;
    const char *const *selectors;
};

constexpr const char *kGADView[] = {"loadRequest:", nullptr};
constexpr const char *kGADFullscreen[] = {"loadRequest:", "loadRequest:withAdUnitID:", "presentFromRootViewController:",
                                          "isReady", "hasBeenUsed", nullptr};

constexpr Rule kRules[] = {
    {"Flurry", "Flurry", nullptr},
    {"Flurry", "FlurryAnalytics", nullptr},
    {"Flurry", "FlurryAds", nullptr},
    {"Facebook", "Facebook", nullptr},
    {"Facebook", "FBSession", nullptr},
    {"Facebook", "FBSettings", nullptr},
    {"Facebook", "FBAppEvents", nullptr},
    {"Facebook", "FBAppCall", nullptr},
    {"Facebook", "FBSDKApplicationDelegate", nullptr},
    {"Facebook", "FBSDKAppEvents", nullptr},
    {"Facebook", "FBSDKSettings", nullptr},
    {"Facebook", "FBSDKAccessToken", nullptr},
    {"Facebook", "FBSDKLoginManager", nullptr},
    {"AdMob", "GADMobileAds", nullptr},
    {"AdMob", "GADBannerView", kGADView},
    {"AdMob", "DFPBannerView", kGADView},
    {"AdMob", "GADInterstitial", kGADFullscreen},
    {"AdMob", "DFPInterstitial", kGADFullscreen},
    {"AdMob", "GADRewardBasedVideoAd", kGADFullscreen},
    {"Chartboost", "Chartboost", nullptr},
    {"Chartboost", "CBAnalytics", nullptr},
    {"Vungle", "VungleSDK", nullptr},
    {"Vungle", "VGVunglePub", nullptr},
    {"AdColony", "AdColony", nullptr},
    {"Google Analytics", "GAI", nullptr},
    {"Google Analytics", "GANTracker", nullptr},
    {"Crashlytics", "Crashlytics", nullptr},
    {"Crashlytics", "Fabric", nullptr},
};

// mov r0, #0; mov r1, #0; bx lr: nil, 0, NO, 0.0 (soft-float) and 64-bit 0 alike.
GuestAddr zeroRoutine(Runtime &rt) {
    static GuestAddr routine = [&rt] {
        const uint32_t code[] = {0xe3a00000, 0xe3a01000, 0xe12fff1e};
        GuestAddr addr = rt.heap().alloc(sizeof code);
        rt.mem().copyIn(addr, code, sizeof code);
        return addr;
    }();
    return routine;
}

bool listed(const char *const *selectors, const char *name) {
    for (; *selectors; selectors++)
        if (std::strcmp(*selectors, name) == 0) return true;
    return false;
}

}  // namespace

void stubSdkClass(Bridge &bridge, Runtime &rt, ClassInfo *cls) {
    static const bool disabled = getenv("B32_NO_SDK_STUBS") != nullptr;
    if (disabled || cls->isMeta) return;
    const Rule *rule = nullptr;
    for (const Rule &r : kRules)
        if (cls->name == r.cls) rule = &r;
    if (!rule) return;

    GuestAddr zero = zeroRoutine(rt);
    size_t count = 0;
    for (ClassInfo *info : {cls, cls->meta}) {
        for (auto &[sel, method] : info->methods) {
            const char *name = bridge.selName(sel);
            // Teardown stays real: a dealloc that returns without freeing
            // leaves a dead object for the next release to trip over.
            bool teardown = std::strcmp(name, "dealloc") == 0 || std::strcmp(name, ".cxx_destruct") == 0;
            if (rule->selectors ? !listed(rule->selectors, name) : teardown) continue;
            method.imp = zero;
            // The guest's own method_t too, where its runtime and reflection read the IMP.
            if (method.entry) rt.mem().write<uint32_t>(method.entry + 8, zero);
            count++;
        }
    }
    static std::mutex lock;
    static std::set<std::string> logged;
    std::lock_guard guard(lock);
    if (logged.insert(rule->sdk).second) log("stubbing the %s SDK compiled into the app", rule->sdk);
    log("  %s: %zu methods return nil/0", cls->name.c_str(), count);
}

}  // namespace b32::objc
