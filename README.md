# Bridge32

Run 32-bit iOS apps on Mac Catalyst through host frameworks.

Apple Silicon Macs can run iPhone apps, but only 64-bit ones; armv6 and armv7
apps from the iPhone OS 2 – iOS 10 era have nowhere to go. Bridge32 runs their
ARM code with [dynarmic](https://github.com/azahar-emu/dynarmic) and answers
every system call, C function and Objective-C message with the real 64-bit
frameworks on the Mac: UIKit, Foundation, Core Graphics, Core Text, OpenGL ES,
OpenAL, Audio Toolbox and the rest. Nothing of iOS is reimplemented; the
bridge converts between the guest's 32-bit ABI and the host's.

A wrapped app is an ordinary Mac app: a copy of the Bridge32 shell with the
guest's bundle inside, with its own bundle identifier, container and Dock
entry.

## How it works

- **Loader** (`core/loader`): maps the guest Mach-O (armv6 or armv7, `LC_MAIN`
  or `LC_UNIXTHREAD`) and any guest libraries into a 4 GB guest address space
  (`core/mem`), and binds its imports to thunks.
- **CPU** (`core/cpu`): dynarmic's A32 frontend and arm64 backend, with
  fastmem, one CPU per guest thread and the exclusive monitor shared between
  them.
- **Thunks** (`core/thunks`): libSystem, pthreads, libc++/libstdc++ runtime
  pieces, Core Foundation, Core Graphics, Core Text, zlib, sqlite, dispatch
  and more. Each import is a `B32_THUNK`, a `B32_DATA` constant or a row in a
  `B32_C_FUNCTIONS` table that converts arguments from a signature string.
- **Objective-C bridge** (`core/objc`): guest classes are registered with the
  host runtime, so host objects and guest objects message each other directly.
  Arguments and results are converted from their type encodings (CGFloat is
  32-bit in the guest, structs are repacked, blocks are wrapped both ways).
- **UIKit, GL and audio** (`core/uikit`, `core/gl`, `core/audio`): the shell's
  scene hosts the guest's windows at its original screen size and scales them
  with the Mac window; OpenGL ES goes to the OpenGL ES framework in macOS's
  iOSSupport tree, with render scaling; game controllers can drive touches or
  the accelerometer.

## Requirements

- An Apple Silicon Mac and a recent Xcode
- CMake 3.24+ and Ninja
- Decrypted 32-bit `.ipa` files or `.app` bundles
- Optional: armv6/armv7 builds of libstdc++, libgcc_s, libc++, libc++abi and
  libxml2 (an old iPhoneOS SDK's `/usr/lib`) for apps that link them

## Building

```sh
git clone --recursive https://github.com/colemancda/Bridge32.git
cd Bridge32
cmake -S . -B build/catalyst -G Ninja -DCMAKE_TOOLCHAIN_FILE=cmake/catalyst.cmake
cmake --build build/catalyst
```

This builds `build/catalyst/Bridge32.app`, the shell every app is wrapped
into. A plain host build (`cmake -S . -B build/host -G Ninja`) gives only the
command-line tools.

## Wrapping an app

```sh
tools/make-app.sh Game.ipa build/apps/Game.app
open build/apps/Game.app
```

Options:

| Option | Effect |
| --- | --- |
| `--guest-libs DIR` | Copies guest builds of libstdc++ and friends into the app (or set `B32_GUEST_LIBS`) |
| `--orientation landscape-right\|landscape-left\|portrait` | Overrides the app's launch orientation |
| `--device iphone\|ipad` | Sets the device the guest sees when its `UIDeviceFamily` says otherwise |
| `--controller tilt\|swipe` | Maps a controller's stick and D-pad to the accelerometer (racing games) or to swipes (maze games) |
| `--fps` | Shows a frame rate counter and logs slow frames |

After rebuilding the shell, put it into apps you've already wrapped without
copying their files again:

```sh
tools/update-shell.sh build/apps/*.app
```

`tools/sign-app.sh` signs an app ad hoc with the shell's entitlements, adding
Bluetooth only when the guest links CoreBluetooth. Both scripts above call it.

Launch wrapped apps with `open` rather than running the binary from a
terminal: otherwise macOS privacy checks treat the terminal as responsible and
may kill the app on its first Bluetooth or location call.

## Logs and debugging

A wrapped app logs to
`~/Library/Containers/<bundle id>.bridge32/Data/Library/Logs/bridge32.log`.
These environment variables (pass them with `open --env NAME=value`) help
when an app misbehaves:

| Variable | Effect |
| --- | --- |
| `B32_LOG_TO_STDERR=1` | Log to stderr instead of the container |
| `B32_TRACE_THUNKS=1` or a substring | Log every import called, or those whose names contain it |
| `B32_TRACE_SENDS=1` | Log every guest-to-host message |
| `B32_TRACE_CALLS=1` or a substring | Log host-to-guest method calls, or those whose selector contains it |
| `B32_TRACE_FILES=1` | Log file system calls |
| `B32_TRACE_LOCKS=1` | Log guest mutex traffic |
| `B32_TRACE_RAW_POINTERS=1` | Log guest stack pointers handed to the host as they are |
| `B32_GL_ERRORS=1` | Name the GL call that raised each error |
| `B32_DUMP_WINDOW=1` | Draw the key window to `$TMPDIR/b32-window.png` every 5 seconds |
| `B32_DUMP_FRAMES=1` | Dump presented OpenGL ES frames |
| `B32_SHOW_FPS=1` | Frame rate counter and slow-frame log |
| `B32_RENDER_SCALE=n` | Pin the GL render scale (1 turns scaling off) |
| `B32_TAPS="sec:x,y ..."` | Script taps and drags for testing without a person at the Mac |
| `B32_CONTROLLER`, `B32_CONTROLLER_BUTTONS` | Controller mapping, as in `--controller`, and on-screen buttons |
| `B32_HEAP_REDZONE=1` | Red zones after guest heap blocks, for overflows |
| `B32_HEAP_QUARANTINE=1` | Never reuse freed guest blocks, for use-after-free |
| `B32_NO_FASTMEM=1` | Route guest memory through callbacks so a debugger sees host crashes directly (slow) |
| `B32_NO_SDK_STUBS=1` | Don't replace methods of stubbed third-party SDKs |

## Command-line tools

- `b32-inspect <binary>` loads a guest binary without running it and reports
  its entry point, sections, linked libraries and the imports Bridge32
  doesn't implement yet.
- `b32-run <binary>` runs a guest executable headless, with no UIKit.

## Tests

The guest tests in `tests/guest` are small armv7 programs (C, C++,
Objective-C, UIKit and OpenGL ES 1) built against an iPhoneOS SDK:

```sh
make -C tests/guest SDK=/path/to/iPhoneOS9.3.sdk
ctest --test-dir build/host
```

## Status

Bridge32 is a work in progress, and each new app tends to need a few more
thunks. Apps known to run include PAC-MAN 1.0.2 (armv6, with touch and
audio) and Oceanhouse Media's Smithsonian Dinosaurs book with narration. The
Dr. Seuss Collection runs, but its books are App Store on-demand resources,
which can't be downloaded outside the App Store.

## License

MIT; see [LICENSE](LICENSE). dynarmic is under its own license in
`external/dynarmic`.
