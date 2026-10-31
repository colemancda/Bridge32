#include "Device.h"

namespace b32::device {

namespace {
const Profile kIPhone = {"iPhone2,1", "iPhone", 320, 480};
const Profile kIPad = {"iPad2,1", "iPad", 768, 1024};
const Profile *profile = &kIPhone;
}  // namespace

const Profile &current() { return *profile; }
void useIPad() { profile = &kIPad; }

}  // namespace b32::device
