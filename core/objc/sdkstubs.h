// Third-party SDKs compiled into games (ads, analytics, social, crash
// reporting) whose services are gone or that only get in the way under
// Bridge32. Their entry points are made to return nil/0/NO, which ObjC's
// nil messaging carries through the rest of the game's calls.
#pragma once

namespace b32 {
class Runtime;
}

namespace b32::objc {

class Bridge;
struct ClassInfo;

// Replaces the methods of a guest class (and its metaclass) that belongs to
// a stubbed SDK, before anything can call them. B32_NO_SDK_STUBS=1 turns it off.
void stubSdkClass(Bridge &bridge, Runtime &rt, ClassInfo *cls);

}  // namespace b32::objc
