// The discs a Mac guest should see: the volumes the host mounted from disc
// media (disc images and actual discs), which a guest of the era would have
// known as CDs. getmntinfo reports them read-only, and IOKit, in
// core/appkit/macsys.mm, gives each an IOCDMedia registry of its own.
#pragma once

#include <string>
#include <vector>

namespace b32::discs {

struct Volume {
    std::string mount;   // "/Volumes/Age of Mythology"
    std::string device;  // the mount's f_mntfromname, "/dev/disk6s2"
    std::string whole;   // the media with slice suffixes gone, "/dev/disk6"
};

// The disc volumes mounted now. Each mount is classified through IOKit once,
// as media comes and goes while a guest runs.
std::vector<Volume> mounted();

}  // namespace b32::discs
