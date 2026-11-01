// The Mac Catalyst shell. tools/make-app.sh wraps a guest .app into a copy of
// this app: the guest's files go in Contents/Resources (so NSBundle
// mainBundle is the game's bundle) and B32GuestExecutable in Info.plist names
// the guest binary. The guest's UIApplicationMain becomes the host's.

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/cpu/DynarmicCpu.h"
#include "core/gl/GLES.h"
#include "core/uikit/UIKitSupport.h"

#include <dynarmic/interface/exclusive_monitor.h>

#import <UIKit/UIKit.h>
#include <unistd.h>

#include <atomic>
#include <string>

int main(int argc, char **argv) {
    @autoreleasepool {
        NSBundle *bundle = [NSBundle mainBundle];
        NSString *executable = [bundle objectForInfoDictionaryKey:@"B32GuestExecutable"];
        if (!executable) {
            std::fprintf(stderr, "Bridge32: no B32GuestExecutable in Info.plist; wrap a game with tools/make-app.sh\n");
            return 1;
        }
        NSString *path = [bundle.resourcePath stringByAppendingPathComponent:executable];

        // Launched from Finder there's no terminal: log into the container
        // (Library/Logs/bridge32.log), unless B32_LOG_TO_STDERR is set.
        if (!isatty(STDERR_FILENO) && !getenv("B32_LOG_TO_STDERR")) {
            NSString *logs = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"];
            [[NSFileManager defaultManager] createDirectoryAtPath:logs withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *log = [logs stringByAppendingPathComponent:@"bridge32.log"];
            // Both in append mode: with separate file offsets, stderr's
            // writes would land on top of stdout's.
            std::fclose(std::fopen(log.fileSystemRepresentation, "w"));
            std::freopen(log.fileSystemRepresentation, "a", stderr);
            std::freopen(log.fileSystemRepresentation, "a", stdout);
        }
        setvbuf(stdout, nullptr, _IOLBF, 0);

        // iOS puts the app bundle next to Documents/ in its sandbox, and some
        // engines find their data by looking there.
        if (NSString *bundleName = [bundle objectForInfoDictionaryKey:@"B32GuestBundleName"]) {
            NSString *link = [NSHomeDirectory() stringByAppendingPathComponent:bundleName];
            [[NSFileManager defaultManager] removeItemAtPath:link error:nil];
            [[NSFileManager defaultManager] createSymbolicLinkAtPath:link withDestinationPath:bundle.resourcePath error:nil];
        }

        // No AppKit window restoration: after a crash it would stop the next
        // launch at a modal "reopen windows?" alert, and games have no windows to restore.
        [NSUserDefaults.standardUserDefaults registerDefaults:@{@"ApplePersistenceIgnoreState" : @YES}];

        // An iOS app starts in /, and some engines drop the leading slash from
        // their paths. The Mac sandbox starts us in the container instead.
        chdir("/");

        // SDL in iOS-9-era games names an MFi controller by vendor, product and
        // button mask, and its database only knows Apple's own MFi pads. Brand
        // controllers the Mac reports through GameController (DualSense, DualShock 4,
        // Xbox, Switch Pro) get mappings here, in the iOS 9 layout SDL reads
        // them in: A B X Y, shoulders, pause; D-pad hat; sticks and triggers.
        // A name checksum of 0000 matches any name. Not set if already in the environment.
        {
            const char *layout = "a:b0,b:b1,x:b2,y:b3,leftshoulder:b4,rightshoulder:b5,start:b6,"
                                 "dpup:h0.1,dpright:h0.2,dpdown:h0.4,dpleft:h0.8,"
                                 "leftx:a0,lefty:a1,lefttrigger:a2,rightx:a3,righty:a4,righttrigger:a5,platform:iOS,";
            std::string mappings;
            for (auto [guid, name] : {std::pair{"050000004c050000e60c00004f066d00", "DualSense (MFi)"},
                                      std::pair{"050000004c050000cc0900004f066d00", "DualShock 4 (MFi)"},
                                      std::pair{"050000005e040000e00200004f066d00", "Xbox Controller (MFi)"},
                                      std::pair{"050000007e050000092000004f066d00", "Switch Pro Controller (MFi)"}})
                mappings += std::string(guid) + "," + name + "," + layout + "\n";
            setenv("SDL_GAMECONTROLLERCONFIG", mappings.c_str(), 0);
        }
        b32::uikit::configureHost();
        b32::gl::loadHostOpenGLES();

        static auto *monitor = new decltype(b32::DynarmicCpu::makeMonitor())(b32::DynarmicCpu::makeMonitor());
        static std::atomic<size_t> nextProcessor{0};
        // Never destroyed: quitting runs exit()'s static destructors while the
        // guest's threads are still running, and they'd use it after it's gone.
        static b32::Runtime &rt = *new b32::Runtime([](b32::GuestMemory &mem, b32::Cpu::SvcHandler handler) -> std::unique_ptr<b32::Cpu> {
            return std::make_unique<b32::DynarmicCpu>(mem, std::move(handler), b32::DynarmicCpu::Arch::V7,
                                                      monitor->get(), nextProcessor++);
        });
        // make-app.sh copies guest libraries (--guest-libs) into the bundle.
        rt.addGuestLibraryDir([NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"B32GuestLibraries"]
                                  .fileSystemRepresentation);
        if (const char *dir = getenv("B32_GUEST_LIBS")) rt.addGuestLibraryDir(dir);
        rt.load(path.fileSystemRepresentation);
        b32::log("loaded %s", path.fileSystemRepresentation);

        std::vector<std::string> guestArgv = {path.fileSystemRepresentation};
        std::vector<std::string> envp = {std::string("HOME=") + NSHomeDirectory().fileSystemRepresentation,
                                         std::string("TMPDIR=") + NSTemporaryDirectory().fileSystemRepresentation};
        // Returns only if the guest's main does (UIApplicationMain never does).
        return rt.run(guestArgv, envp);
    }
}
