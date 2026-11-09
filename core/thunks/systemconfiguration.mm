// SystemConfiguration network reachability. Targets are real host objects
// with real flags; change callbacks aren't delivered yet, so apps see the
// state they ask for and no updates.

#include "CTable.h"
#include "core/Log.h"
#include "core/Runtime.h"
#include "core/objc/Bridge.h"

#include <SystemConfiguration/SystemConfiguration.h>
#include <dlfcn.h>

using namespace b32;

namespace {
void *systemConfiguration() { return RTLD_DEFAULT; }

constexpr CFunction kReachability[] = {
    {"SCNetworkReachabilityCreateWithName", "o:op"},
    {"SCNetworkReachabilityGetFlags", "B:op"},  // SCNetworkReachabilityFlags is 32-bit in both ABIs
};
}  // namespace

B32_C_FUNCTIONS(kReachability, systemConfiguration);

// SCNetworkReachabilityCreateWithAddress(CFAllocatorRef, const struct sockaddr *): a
// sockaddr is a length and family byte and then address bytes (a port or IPv4
// address already in network order), so its layout is the same in every ABI.
B32_THUNK(_SCNetworkReachabilityCreateWithAddress) {
    c.args.ptr();
    auto *address = static_cast<const struct sockaddr *>(c.mem.ptr<void>(c.args.ptr()));
    SCNetworkReachabilityRef target = SCNetworkReachabilityCreateWithAddress(nullptr, address);
    c.ret(c.rt.bridge().toGuest((id)target));
}

B32_THUNK(_SCNetworkReachabilitySetCallback) { c.ret(1); }
B32_THUNK(_SCNetworkReachabilityScheduleWithRunLoop) { c.ret(1); }
B32_THUNK(_SCNetworkReachabilityUnscheduleFromRunLoop) { c.ret(1); }

// Reachability changes aren't delivered to the guest yet, so there's no
// queue to schedule them on; accepting it is enough.
B32_THUNK(_SCNetworkReachabilitySetDispatchQueue) { c.ret(1); }

// CaptiveNetwork: no Wi-Fi details for the guest (macOS only gives them out
// with location permission), as when an iPhone isn't on Wi-Fi.
B32_THUNK(_CNCopySupportedInterfaces) { c.ret(0); }
B32_THUNK(_CNCopyCurrentNetworkInfo) { c.ret(0); }
