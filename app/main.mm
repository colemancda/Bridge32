// The Mac Catalyst shell. tools/make-app.sh wraps a guest .app into a copy of
// this app: the guest's files go in Contents/Resources (so NSBundle
// mainBundle is the game's bundle) and B32GuestExecutable in Info.plist names
// the guest binary. The guest's UIApplicationMain becomes the host's.

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/cpu/DynarmicCpu.h"
#include "core/uikit/UIKitSupport.h"

#include <dynarmic/interface/exclusive_monitor.h>

#import <UIKit/UIKit.h>
#include <unistd.h>

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
            std::freopen(log.fileSystemRepresentation, "w", stderr);
            std::freopen(log.fileSystemRepresentation, "a", stdout);
        }
        setvbuf(stdout, nullptr, _IOLBF, 0);

        b32::uikit::configureHost();

        static auto monitor = b32::DynarmicCpu::makeMonitor();
        static b32::Runtime rt([](b32::GuestMemory &mem, b32::Cpu::SvcHandler handler) -> std::unique_ptr<b32::Cpu> {
            return std::make_unique<b32::DynarmicCpu>(mem, std::move(handler), b32::DynarmicCpu::Arch::V7,
                                                      monitor.get(), 0);
        });
        rt.load(path.fileSystemRepresentation);
        b32::log("loaded %s", path.fileSystemRepresentation);

        std::vector<std::string> guestArgv = {path.fileSystemRepresentation};
        std::vector<std::string> envp = {std::string("HOME=") + NSHomeDirectory().fileSystemRepresentation,
                                         std::string("TMPDIR=") + NSTemporaryDirectory().fileSystemRepresentation};
        // Returns only if the guest's main does (UIApplicationMain never does).
        return rt.run(guestArgv, envp);
    }
}
