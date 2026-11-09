// The AppKit shell for i386 Mac apps. tools/make-app.sh wraps a guest .app into
// a copy of this app: the guest's Resources become the shell's, so NSBundle
// mainBundle, its nibs and its Info.plist are the guest's, and its executable
// and frameworks go in Contents/B32Guest, keeping their relative layout. The
// guest's NSApplicationMain becomes the host's.

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/cpu/UnicornCpu.h"

#import <AppKit/AppKit.h>
#include <unistd.h>

#include <string>

int main(int argc, char **argv) {
    @autoreleasepool {
        NSBundle *bundle = [NSBundle mainBundle];
        NSString *executable = [bundle objectForInfoDictionaryKey:@"B32GuestExecutable"];
        if (!executable) {
            std::fprintf(stderr, "Bridge32: no B32GuestExecutable in Info.plist; wrap an app with tools/make-app.sh\n");
            return 1;
        }
        NSString *guest = [bundle.bundlePath stringByAppendingPathComponent:@"Contents/B32Guest"];
        NSString *path = [[guest stringByAppendingPathComponent:@"MacOS"] stringByAppendingPathComponent:executable];

        // Launched from Finder there's no terminal: log to a file, unless
        // B32_LOG_TO_STDERR is set.
        if (!isatty(STDERR_FILENO) && !getenv("B32_LOG_TO_STDERR")) {
            NSString *logs = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/Bridge32"];
            [[NSFileManager defaultManager] createDirectoryAtPath:logs withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *log = [logs stringByAppendingPathComponent:[executable stringByAppendingPathExtension:@"log"]];
            std::fclose(std::fopen(log.fileSystemRepresentation, "w"));
            std::freopen(log.fileSystemRepresentation, "a", stderr);
            std::freopen(log.fileSystemRepresentation, "a", stdout);
        }
        setvbuf(stdout, nullptr, _IOLBF, 0);
        setvbuf(stderr, nullptr, _IONBF, 0);

        // Old apps have no state to restore, and tabs and restoration both
        // change how their windows behave.
        [NSUserDefaults.standardUserDefaults registerDefaults:@{@"ApplePersistenceIgnoreState" : @YES}];
        NSWindow.allowsAutomaticWindowTabbing = NO;

        // Never destroyed: quitting runs exit()'s static destructors while the
        // guest's threads are still running.
        static b32::Runtime &rt = *new b32::Runtime([](b32::GuestMemory &mem, b32::Cpu::SvcHandler handler) -> std::unique_ptr<b32::Cpu> {
            return std::make_unique<b32::UnicornCpu>(mem, std::move(handler));
        });
        if (const char *dir = getenv("B32_GUEST_LIBS")) rt.addGuestLibraryDir(dir);
        // A guest's libraries: its Frameworks folder and, for apps that set
        // DYLD_LIBRARY_PATH in a launcher script, folders beside the executable.
        rt.addGuestLibraryDir([guest stringByAppendingPathComponent:@"Frameworks"].fileSystemRepresentation);
        NSString *macos = [guest stringByAppendingPathComponent:@"MacOS"];
        rt.addGuestLibraryDir(macos.fileSystemRepresentation);
        for (NSString *entry in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:macos error:nil]) {
            BOOL isDirectory = NO;
            NSString *full = [macos stringByAppendingPathComponent:entry];
            if ([[NSFileManager defaultManager] fileExistsAtPath:full isDirectory:&isDirectory] && isDirectory)
                rt.addGuestLibraryDir(full.fileSystemRepresentation);
        }
        // A launcher script usually cd's there first.
        if ([[bundle objectForInfoDictionaryKey:@"B32GuestChdir"] boolValue]) chdir(macos.fileSystemRepresentation);
        rt.load(path.fileSystemRepresentation);
        b32::log("loaded %s", path.fileSystemRepresentation);

        std::vector<std::string> guestArgv = {path.fileSystemRepresentation};
        for (int i = 1; i < argc; i++) guestArgv.push_back(argv[i]);
        std::vector<std::string> envp = {std::string("HOME=") + NSHomeDirectory().fileSystemRepresentation,
                                         std::string("TMPDIR=") + NSTemporaryDirectory().fileSystemRepresentation,
                                         std::string("USER=") + NSUserName().UTF8String, "PATH=/usr/bin:/bin:/usr/sbin:/sbin"};
        // Returns only if the guest's main does (NSApplicationMain never does).
        return rt.run(guestArgv, envp);
    }
}
