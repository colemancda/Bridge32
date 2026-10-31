// The device the guest believes it runs on, chosen from the app's
// UIDeviceFamily: an iPad 2 for iPad-only apps, an iPhone 3GS otherwise.
// Both have 1x screens, matching the UIScreen the guest sees.
#pragma once

namespace b32::device {

struct Profile {
    const char *machine;  // hw.machine, uname's machine
    const char *model;    // UIDevice model
    float screenWidth, screenHeight;
};

const Profile &current();
void useIPad();

}  // namespace b32::device
