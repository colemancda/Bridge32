#include "Discs.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

#include <sys/mount.h>

#include <mutex>
#include <unordered_map>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

namespace b32::discs {
namespace {

// "disk6s2" → "disk6", and a synthesized slice ("disk1s2s1") down with it.
std::string wholeDevice(std::string device) {
    for (;;) {
        size_t cut = device.rfind('s');
        if (cut == std::string::npos || cut == 0 || device.find_first_not_of("0123456789", cut + 1) != std::string::npos) return device;
        device.erase(cut);
    }
}

// Media the Finder shows with an eject button: a disc image or a disc, as
// against the machine's own disks.
bool mediaIsDisc(const std::string &whole) {
    if (whole.empty()) return false;
    io_object_t media = IOServiceGetMatchingService(kIOMasterPortDefault, IOBSDNameMatching(kIOMasterPortDefault, 0, whole.c_str()));
    if (media == MACH_PORT_NULL) return false;
    auto flag = [&](CFStringRef name) {
        CFBooleanRef value = (CFBooleanRef)IORegistryEntryCreateCFProperty(media, name, kCFAllocatorDefault, 0);
        bool on = value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue(value);
        if (value) CFRelease(value);
        return on;
    };
    bool disc = flag(CFSTR("Ejectable")) && flag(CFSTR("Removable"));
    IOObjectRelease(media);
    return disc;
}

std::mutex lock;
std::unordered_map<std::string, bool> classified;  // by mount point

}  // namespace

std::vector<Volume> mounted() {
    std::vector<Volume> discs;
    struct statfs *mounts = nullptr;
    int count = ::getmntinfo(&mounts, MNT_NOWAIT);
    for (int i = 0; i < count; i++) {
        std::string mount = mounts[i].f_mntonname;
        if (mount.rfind("/Volumes/", 0) != 0) continue;
        bool disc;
        {
            std::lock_guard guard(lock);
            bool fresh = classified.find(mount) == classified.end();
            bool &slot = classified[mount];
            if (fresh) {
                std::string device = mounts[i].f_mntfromname;
                slot = device.rfind("/dev/", 0) == 0 && mediaIsDisc(wholeDevice(device.substr(5)));
            }
            disc = slot;
        }
        if (disc) {
            std::string device = mounts[i].f_mntfromname;  // "/dev/…" by the classification above
            discs.push_back({mount, device, "/dev/" + wholeDevice(device.substr(5))});
        }
    }
    return discs;
}

}  // namespace b32::discs
