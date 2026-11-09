# Running 32-bit Intel Mac apps: feasibility and plan

Status: proposal for review. Nothing here is implemented.

Decision 2026-11-08: Phase 0 uses Unicorn 2. The GPLv2 dependency is
accepted for the Mac shell; FEXCore stays the Phase 5 performance path.

## Verdict

Yes, with one correction to the framing: the x86 code can't be virtualized,
it has to be emulated, exactly as the ARM code is today.

- Apple Silicon has no x86 virtualization. Hypervisor.framework runs only
  arm64 guests, and Rosetta 2 translates x86_64 only; Apple dropped i386
  from it along with 32-bit processes in 10.15.
- So the model stays the Bridge32 model: a 32-bit guest address space, a
  JIT that runs the guest's instructions, and every import answered by the
  real 64-bit frameworks through thunks and the ObjC bridge. dynarmic is
  ARM-only, so the one component that has to be replaced outright is the
  CPU.

The good news is that the i386 Mac ABI is closer to Bridge32's existing
32-bit model than it first looks:

- Every C argument is a 4-byte stack word, 64-bit values are two words with
  no alignment padding, and varargs are a pointer into that word stream.
  That is the same word-stream model `Args` already implements for APCS, so
  the ~2,400 `c.args.*()` call sites in the thunks carry over untouched.
- `long`, `size_t`, `NSInteger` and `CGFloat` are 32-bit, `BOOL` is a
  signed char, blocks and `va_list` have the same layout. The type-encoding
  converter (`core/objc/Encoding.cpp`) and the CGFloat narrowing logic in
  `core/objc/Dispatch.mm` apply as they are.
- i386 Mac executables are little-endian Mach-O with the same load
  commands and bind opcodes the loader already handles for iPhone OS 2–3
  and iOS 4+: `LC_UNIXTHREAD` or `LC_MAIN`, a `__dyld` section or
  `LC_DYLD_INFO`, 4 KB `__PAGEZERO`, `__mod_init_func`.

The hard parts are, in order: picking and integrating an x86 JIT, the
legacy ("fragile") Objective-C runtime format the 32-bit Mac uses, AppKit's
reliance on KVO and bindings (which the current guest-to-guest dispatch
bypasses), and the long tail of Carbon-era C APIs that have no 64-bit host
implementation.

## What a 32-bit Intel Mac app is

The target is Cocoa apps built for Mac OS X 10.4–10.14, i386 slice:

| Aspect | iOS armv7 (today) | i386 Mac (proposed) |
| --- | --- | --- |
| CPU | ARMv6/v7, VFP, NEON | IA-32 with x87 (80-bit), MMX, SSE–SSSE3 (Core 2 baseline); SSE4.1 possible for Penryn-era builds |
| Calling convention | AAPCS: r0–r3 then stack words | cdecl: all stack words, 16-byte aligned call sites |
| Integer return | r0 / r0:r1 | EAX / EAX:EDX |
| Float return | r0 / r0:r1 (soft-float) | ST(0) on the x87 stack |
| Struct return | sret pointer in r0 for anything over 4 bytes | 1/2/4/8-byte structs in EAX:EDX; a struct of one float in ST(0); otherwise hidden pointer and the callee pops it (`ret $4`) |
| Thread-local | TPIDRURO via `mrc p15` | `%gs` segment base; `pthread_self` is `%gs:0` |
| ObjC runtime | Modern: `__DATA,__objc_classlist`, `class_ro_t`, `OBJC_IVAR_$_` offset variables | Legacy: `__OBJC,__module_info`, `__class`, `__meta_class`, `__cls_refs`, `__message_refs`; ivar offsets are immediates in the code |
| ObjC exceptions | zero-cost (`__objc_personality_v0`) | setjmp-based: `objc_exception_try_enter`/`try_exit`/`extract`/`match`/`throw` |
| Memory management | MRR or ARC | MRR; some apps compiled with ObjC GC (`-fobjc-gc`) and call `objc_assign_*` write barriers |
| Import stubs | `__la_symbol_ptr` + `dyld_stub_binder` | 10.6+: same. 10.4–10.5: `__IMPORT,__jump_table` with 5-byte `jmp` slots the loader must write x86 code into |
| libSystem symbols | plain names | `$UNIX2003`, `$INODE64`, `$1050`, `$NOCANCEL`, `$DARWIN_EXTSN` variants |
| UI framework | UIKit via Catalyst | AppKit natively; often with CoreServices/Carbon C APIs mixed in |

Verified locally (Xcode 27.2): `clang -arch i386 -target i386-apple-macos10.13`
still compiles C and ObjC and emits the legacy ObjC ABI (`__OBJC` sections,
`.objc_class_name_*` imports, `_setjmp` + `objc_exception_try_enter`); the
struct and float return rules above match its output (`retl $4` for a
four-float struct, EAX:EDX for a two-float struct, `fld` for doubles).
Neither Apple's `ld` nor the `ld64.lld` in the swiftly toolchain will link
i386 any more; see "Guest test toolchain".

## What carries over

| Component | Reuse | Work |
| --- | --- | --- |
| `core/mem` (4 GiB reservation, heap, layout) | As is | Larger main-thread stack (Mac default 8 MB), stack slot sizing; nothing else |
| `core/loader/MachO.cpp` | Most | `CPU_TYPE_I386` slice selection, `i386_thread_state` for `LC_UNIXTHREAD`, `S_SYMBOL_STUBS` jump-table patching, i386 scattered relocs (`GENERIC_RELOC_PB_LA_PTR` can be ignored since binding is eager), framework paths (`@executable_path/../Frameworks`, `@loader_path`) |
| `core/thunks/*` (libSystem, libc, pthread, posix, CF, CG, CoreText, sqlite, zlib, dispatch…) | As is for argument reading | `retF32`/`retF64` must land in ST(0), struct returns per the i386 rules, `setjmp`/`longjmp` and `deliverFault` layouts, symbol-suffix aliasing in the resolver, 32-bit-inode `struct stat` layout for non-`$INODE64` imports |
| `core/objc/Bridge.mm` object model | As is | The guest-half layout (isa + ivars at compiled offsets) is exactly what fragile ivars need: allocate `instance_size` bytes and the baked-in offsets just work |
| `core/objc` class realization (`setupImage`, `realizeGuestClass`, `addGuestMethods`) | Model yes, reader no | A second reader for the `__OBJC` segment feeding the same `ClassInfo` (method triples are the same `{SEL, types, IMP}`; ivars carry an `int offset` instead of an offset variable; class refs and super_class fields hold name strings that need fixing up to class pointers) |
| `core/objc/Dispatch.mm`, `Blocks.mm`, `arc.mm`, `reflection.mm` | Most | Replace the ~14 direct register reads in Dispatch with the ABI layer; stret callee-pop emulation; `objc_msgSend_fpret` entry point |
| `core/objc/foundation.mm`, `core/uikit/*`, `core/gl/gles.mm`, `core/audio/*` | Patterns only | New `core/appkit`, `core/gl/opengl.mm` (table-driven, like GLES), CoreAudio HAL additions |
| `core/cpu/DynarmicCpu.cpp` | None | New backend, see below |
| `app/main.mm` (Catalyst shell) | Structure | New AppKit shell target, no toolchain file: a plain host build |
| `tools/make-app.sh`, `sign-app.sh`, `update-shell.sh` | Most | Wrap a `.app` instead of an `.ipa`; copy `Contents/Frameworks` as guest libraries |

Code that touches ARM registers directly is small: about 120 call sites
across 19 files (`grep -E 'reg\(|setReg\(|extReg|Cpu::SP|Cpu::LR'`), and
Cpu.cpp, Dispatch.mm, posix.cpp (setjmp) and libc.cpp account for most.

## CPU engine: the one real decision

Requirements: 32-bit x86 user mode including x87, SSE through SSSE3,
`lock`-prefixed atomics that are atomic against other guest threads,
`%gs`-relative addressing, self-modifying code (Mono, LuaJIT and Flash all
exist in this app population), an arm64 JIT backend, one instance per
guest thread over shared memory, and a cheap way to leave the JIT at a
thunk stub and resume after it (dynarmic's `HaltExecution` on SVC today).

| Option | License | x86 coverage | Speed (est.) | Integration | Notes |
| --- | --- | --- | --- | --- | --- |
| **Unicorn 2** (QEMU TCG as a library) | GPLv2 | Complete (x87 80-bit softfloat, SSE4, AVX) | ~10–30× slower than native | Days: CMake submodule, `uc_mem_map_ptr` of committed guest pages, `UC_HOOK_INSN_INVALID` or `hlt` for stubs, `UC_X86_REG_GS` base via a GDT entry | Softmmu TLB on every access; `uc_emu_start` cost per thunk must be measured; atomics across engines likely need `CF_PARALLEL` forced on (small patch); GPL applies to the distributed shell |
| **FEXCore** (FEX-Emu) | MIT | Complete, 32-bit guests supported | ~2–4× slower than native | Weeks: Linux-first (signals, `mmap`, RWX JIT pages, allocator), already ported to Windows for ARM64EC so the core is portable | Assumes guest address == host address: needs the shell linked with `-pagezero_size 0x1000` and the guest reservation at host address 0, which also removes `base()+addr` from the whole bridge |
| Box64 "box32" dynarec | MIT | Good enough, not exact (x87 as double) | Fast | Weeks: ELF/Linux glue everywhere, globals | Lower fidelity; no Darwin port exists |
| QEMU TCG directly | GPLv2 | Complete | Better than Unicorn (no softmmu in user mode) | Weeks: no macOS user-mode target exists, would mean writing one | Everything Unicorn has, minus the packaging |
| In-house interpreter, JIT later | MIT | Whatever we write | Interpreter 50–100× slower | Months | Full control of the ABI boundary, but the x87/SSE correctness burden is ours |

A detailed comparison follows in "Engine comparison in depth".

Decision (2026-11-08): bring the stack up on Unicorn 2 behind the existing `Cpu`
interface, because the unknowns are in the loader, the legacy ObjC
runtime and AppKit, not in instruction semantics, and Unicorn gets a
correct CPU for a few days of work. Keep the interface engine-neutral
(see below) so FEXCore can replace it when a real app is CPU-bound. The
Phase 0 spike settles two numbers Unicorn must hit before committing to
it: thunk round-trip cost (an ObjC message to a host object is one) and
sustained translated-code speed on a loop benchmark.

Performance expectation to set for reviewers: a 2008 Core 2 Duo app under
Unicorn on an M-series Mac lands somewhere around a 2003-era Mac. Fine
for productivity apps and 2D games, not for 3D games; those are the case
for FEXCore later.

## Engine comparison in depth: Unicorn 2 versus FEXCore

Facts below were checked against the two repositories at these revisions
(shallow clones, 2026-11-08): Unicorn 2.1.4 (`7c5db94`, QEMU 5.0.1 base)
and FEX `16c1000` (FEX-2611 era). Where something was not verifiable it
is marked as an estimate.

### What each one is

**Unicorn 2** is QEMU's TCG packaged as a library with a stable C API. It
is full-system style emulation (softmmu with 4 KB guest pages,
`TARGET_PAGE_BITS 12`) without devices: you map memory, set registers,
and run. The x86 target is QEMU's: 31.7 k lines covering 16/32/64-bit,
x87 through softfloat's exact 80-bit `floatx80`, MMX, SSE through SSE4
and AVX (AVX is rejected explicitly, `VEX.L`, which is fine for our
apps). Default CPU model is Haswell; we would pick a Core 2 model so
CPUID matches the era.

**FEXCore** is the CPU core of FEX-Emu: an x86/x86-64 frontend, an IR
with optimization and register allocation passes, and an arm64
"splatter" backend over vixl. 69.6 k lines plus nine vendored
dependencies (vixl, fmt, xxhash, unordered_dense, range-v3, tiny-json,
SoftFloat-3e, cephes, optionally zydis). It is a user-mode design: guest
address equals host address, the frontend decodes by dereferencing the
guest RIP as a host pointer (`Frontend.cpp`), and 32-bit guests simply
live in the low 4 GB of the host process. The OS surface is behind two
interfaces, `FEXCore::Allocator` and `FEXCore::SignalDelegator`, and the
x86 syscall/HLE layer is outside the core (`HLE::SyscallHandler`).
FEXCore/Source has zero `__linux__` ifdefs and 16 `_WIN32` ones.

### Criteria that matter for Bridge32

| Criterion | Unicorn 2 | FEXCore |
| --- | --- | --- |
| License | GPLv2 (`COPYING`). The Mac shell binary becomes GPL; the arm shell is unaffected | MIT |
| Host platform support | macOS arm64 is a first-class target: `HAVE_PTHREAD_JIT_PROTECT` in `qemu/configure`, `jit_write_protect()` toggling in `translate-all.c`, M1 fixes through 2.1.4 | Linux and Windows only. Upstream has said it has no macOS plans; a Darwin port is ours to write and maintain as a fork |
| Memory model | Base+offset works: `uc_mem_map_ptr` maps our committed host pages (4 KB aligned) into each engine; unmapped guest pages raise `UC_ERR_*_UNMAPPED`, feeding `deliverFault` | Guest == host address. Requires the shell linked with `-pagezero_size 0x1000` and `GuestMemory` reserving `0x1000`–`0xFFFFFFFF` at its real address; every `base()+addr` then has `base()==0`, which is a small code change but a large assumption change |
| Host page size | Independent of host page size (its TLB is 4 KB guest pages over our 16 KB host pages) | `FEX_PAGE_SIZE` is a `constexpr 4096` with 88 references; SMC tracking (`mtrack`, the default) and the code cache assume 4 KB pages. Upstream only supports 4 KB kernels; Fedora Asahi runs it inside a 4 KB microVM for that reason. Needs an audit and probably a 16 KB build-time constant |
| JIT memory on Apple Silicon | Done: `MAP_JIT` + per-thread write protection toggles already in the code | `Allocator::VirtualAlloc(size, Execute=true)` expects RWX pages, used by `SharedCodeBufferManager`, `Dispatcher`, `CodeCache`. Needs `MAP_JIT` plus `pthread_jit_write_protect_np` toggles around every emit site, the way dynarmic does it |
| Faults and signals | None needed for correctness: faults are reported as errors from `uc_emu_start` | Required: SIGSEGV for SMC page tracking and guest faults, SIGBUS backpatching of unaligned atomics (`ArchHelpers/Arm64.cpp`, 2.2 k lines, reads host `mcontext`). The Linux `SignalDelegator` is 1.4 k lines; a Darwin one is new code against Darwin's `ucontext` layout |
| Leaving the JIT for a thunk | `UC_HOOK_INSN_INVALID` on a `ud2` stub (EIP stays on the stub, so the stub address is the thunk index) or `hlt` (`EXCP_HLT` ends `uc_emu_start`). `uc_emu_start` does no TB flush unless `count` is used, so per-call cost is bookkeeping only; measured in Phase 0 | `EnableExitOnHLT()` exists, or a `SyscallHandler`/`ThunkHandler` entry; the Windows WOW64 module shows the pattern |
| Atomics across guest threads | **Broken as shipped**: `curr_cflags()` returns 0, so `CF_PARALLEL` is never set and `tcg_gen_atomic_*` take the non-atomic `do_nonatomic_op` path. A one-line fork patch (return `CF_PARALLEL`) switches to the host-atomic helpers in `atomic_template.h`; also makes `tcg_gen_mb` emit real barriers | Native: LL/SC or LSE atomics, with configurable TSO emulation (`TSOEnabled`, `HalfBarrierTSOEnabled`, `StrictInProcessSplitLocks`) |
| Memory ordering (x86 TSO on a weak host) | Not emulated by QEMU TCG. Lock-free guest code that relies on x86 ordering can misbehave across threads | Emulated; the cost is configurable per app. Apple's hardware TSO mode is not reachable from a macOS user process, so it would be the software path |
| Self-modifying code | Per engine: `tlb_protect_code` + write bitmap invalidation. Each thread has its own TB cache, so code patched by thread A and cached by engine B is not invalidated automatically; we broadcast `uc_ctl_remove_cache` on `mprotect`/`sys_icache_invalidate`/`mmap` of executable pages | Shared code buffers with page tracking; Mono-specific handling (`MarkMonoDetected`) |
| Threads | One engine per guest thread over the same host memory, a pattern other projects use; no static mutable state in `uc.c` | One `InternalThreadState` per thread (`CreateThread`), built for it |
| x87 accuracy | Exact 80-bit softfloat | 64-bit by default (`X87F64`), with an exact SoftFloat-3e mode that is slower |
| 32-bit `%gs` | No `GS_BASE` write in 32-bit mode (commented out in `unicorn.c`); set it the x86 way: a GDT entry with the base, `GDTR`, then the GS selector | Native GDT model (`SetGDTBase`, `gdt_segment` in the WOW64 module) |
| Translation quality | QEMU 5.0 TCG: basic-block JIT, no IR optimization, softmmu lookups on every memory access (`UC_TLB_VIRTUAL` skips some MMU work, unbenchmarked) | Multi-block translation, IR passes, register allocation; forwards whole flag computations. Runs Steam games under Proton on arm64 Linux |
| Speed (estimate) | 10–30× slower than native; Phase 0 measures | 2–4× slower than native |
| Integration size | Backend ~600–900 lines against the `Cpu` interface, one submodule, one patch | A Darwin port: Allocator (~300 lines), SignalDelegator (~1–1.5 k), W^X toggles across 5–10 files, 16 KB page audit, build glue for 9 submodules, then an integration module like `Source/Windows/WOW64/Module.cpp` (974 lines, backed by ~4.4 k lines of CRT/WinAPI shims the Windows port needed) |
| Maintenance | Tracks upstream; our one patch is trivial to carry | Fork of a fast-moving project with no upstream interest in macOS |

### What the Windows port proves and does not

`Source/Windows/WOW64` is FEXCore used exactly as we would use it: a
32-bit x86 CPU with every syscall handled outside the core. It is 974
lines. It calls `CreateNewContext`, sets a `SyscallHandler`, maps the
guest GDT (`SetGDTBase`, `SetGDTLimit`), converts between FEX's
`CPUState` and the OS context, and reconstructs EFLAGS. That is a good
template for a Darwin module. What it does not remove: the port had to
ship its own CRT and Win32 shims (4.4 k lines) because FEXCore's
dependencies on the OS are small but real, and Windows gave it RWX pages,
4 KB pages and vectored exception handling, three things macOS on Apple
Silicon does not.

### How they fail

- Unicorn fails slow. Everything runs, atomics are fixed by the patch,
  and the risk is that message-heavy AppKit code or a game is too slow.
  The fix is to replace the backend, which the `Cpu` interface allows.
- FEXCore fails late. The port is a multi-week project before the first
  i386 `hello` runs, during which none of the loader, legacy ObjC or
  AppKit work can be tested on real x86 code. If a 16 KB page assumption
  or the W^X change hides a bug in the code cache, it shows up as
  mis-translation in a real app.

### Decision

Unicorn 2 was chosen on 2026-11-08 after this comparison. What that commits to:

1. Phase 0 on Unicorn 2 with the `CF_PARALLEL` patch applied from day one
   and both threading tests (a `lock xadd` counter across four guest
   threads, and a store-ordering test) in the harness.
2. The Mac shell's binaries are distributed under the GPLv2 (Unicorn's
   terms); the source stays MIT with a GPL dependency, and the README
   says so. The arm/Catalyst shell is unaffected. If that ever has to
   change, the FEXCore Darwin port is the exit: allocator, signal
   delegator, W^X, 16 KB audit, low-4 GB `GuestMemory`, in that order,
   with the WOW64 module as the template. Budget XL.
3. Either way, design `Cpu` so the engine is replaceable: no engine type
   in `Runtime`, `Thunks` or the bridge; the stub trap, fault delivery,
   thread-local base and context save/restore are the only engine-facing
   points.
4. Revisit after Phase 4: if any target app is CPU-bound under Unicorn,
   the FEXCore port starts then, with real apps to validate it against.

Sources consulted: Unicorn `include/unicorn/unicorn.h`, `uc.c`,
`qemu/accel/tcg/translate-all.c`, `qemu/tcg/tcg-op.c`,
`qemu/include/exec/exec-all.h`, `qemu/target/i386/unicorn.c`, `docs/FAQ.md`,
`ChangeLog`; FEX `FEXCore/include/FEXCore/Core/Context.h`,
`FEXCore/Source/Utils/ArchHelpers/Arm64.cpp`,
`FEXCore/Source/Interface/Config/Config.json.in`,
`Source/Windows/WOW64/Module.cpp`, `docs/SourceOutline.md`, the FEX wiki page
on ARM64EC (https://wiki.fex-emu.com/index.php/Development:ARM64EC), the
Fedora FEX change proposal on 4 KB page kernels
(https://www.fedoraproject.org/wiki/Changes/FEX), and the FEX author's
notes on 32-bit address space handling
(https://gist.github.com/Sonicadvance1/8c55565b2dbbbaef79bde800e40835d9).

## Architecture changes

### Guest-architecture abstraction

Make the guest architecture a compile-time choice (`-DB32_GUEST_ARCH=arm`
or `i386`) producing separate shells, rather than one binary that handles
both. A wrapped app has one architecture, and this keeps the hot paths
(`Args::u32`, `Call::ret`) inline.

- `core/cpu/Cpu.h` loses `Reg {SP, LR, PC}`, `kThumbBit`, `cpsr`, `extReg`
  from its public surface. It keeps `run`, `call(fn, words)`, `stop`,
  suspend/resume, thread binding, signal actions, and gains:
  `uint32_t arg(int i)` (i-th argument word), `sp()/setSp()`, `pc()`,
  `returnAddress()`, `setIntResult(u32)`, `setIntResult64(u64)`,
  `setFloatResult(double, bool isFloat)`, `double floatResult()`,
  `saveContext`/`restoreContext` blobs for setjmp and faults, and
  `returnFromThunk(popBytes)`.
- `Args`, `Call::ret*`, `Cpu::call` and `deliverFault` become per-arch
  implementations under `core/arch/arm/` and `core/arch/i386/`.
- Thunk stubs stop containing a return instruction. Today a stub is
  `svc #n; bx lr`. For i386 the stub is a single trapping instruction and
  the dispatcher performs the return itself: pop the return address into
  EIP, add 4 to ESP, plus 4 more when the thunk declared a hidden struct
  result. One stub shape covers both `ret` and `ret $4`. The thunk index is
  recovered from the stub address, not an immediate.
- Thunks return structs through `StructResult(c, size)`, applying the i386
  rules: 1/2/4/8 bytes to EAX:EDX, otherwise copied to the hidden pointer at
  argument word 0 and popped. The ObjC return paths add the lone `float` or
  `double` case, which goes to ST(0); no libSystem thunk returns one.

### Memory

- Keep `GuestMemory`'s base+offset reservation for the Unicorn path. Map
  pages into each engine as `GuestMemory::map` commits them (and on guest
  `mprotect`/`vm_protect`) so unmapped guest accesses surface as
  `UC_ERR_*_UNMAPPED` and feed the existing `deliverFault`.
- `Layout.h` gets an i386 variant: 8 MB main stack, 512 KB secondary
  stacks (Mac defaults), same heap window. Non-PIE i386 executables load at
  `0x1000` and 10.4-era ones are not slid; the layout must leave the low
  256 MB to the executable and its `__DATA`.
- `%gs` base per CPU points at the thread's TSD block (`Cpu::tsd`), with
  slot 0 holding the guest `pthread_t`.
- If FEXCore is adopted later, switch the reservation to host address 0
  by linking the shell with `-Wl,-pagezero_size,0x1000`, making guest and
  host pointers identical. Treat as a separate project; nothing in Phase
  0–3 depends on it.

### Loader

- Fat selection: `CPU_TYPE_I386`. Many 2006–2010 apps ship ppc+i386
  universal binaries; the i386 slice is what we want.
- `LC_UNIXTHREAD` with `x86_THREAD_STATE32` (eip at index 10); the
  process stack block for crt1's `start` is the same argc/argv/envp/apple
  block, 16-byte aligned.
- `S_SYMBOL_STUBS` sections with `reserved2 == 5` (`__IMPORT,__jump_table`):
  write `jmp rel32` to the thunk stub into each slot. `S_LAZY_SYMBOL_POINTERS`
  and `S_NON_LAZY_SYMBOL_POINTERS` bind as today.
- Classic relocations: `GENERIC_RELOC_VANILLA` as today; scattered
  `GENERIC_RELOC_PB_LA_PTR` skipped (eager binding makes them moot);
  `GENERIC_RELOC_SECTDIFF`/`LOCAL_SECTDIFF` only matter for slid dylibs
  without `LC_DYLD_INFO` (10.4–10.5 in-bundle frameworks); implement when
  one shows up, fatal with a clear message until then.
- Bundled frameworks (`Contents/Frameworks/*.framework`, Sparkle, Growl,
  the app's own) load as guest libraries through the existing guest
  library path, which already slides dylibs and resolves their exports.
- Symbol resolution aliases: strip `$UNIX2003`, `$1050`, `$NOCANCEL`,
  `$DARWIN_EXTSN` before registry lookup; `$INODE64` maps to the existing
  thunks (iOS always used 64-bit inodes) and the bare `stat`/`fstat`/
  `lstat`/`readdir` names get new thunks writing the old 32-bit-inode
  layout.
- `.objc_class_name_X` undefined symbols are the legacy form of
  `_OBJC_CLASS_$_X`; they bind to nothing (they exist only to force
  linking) and the resolver should return a harmless address.

### Legacy Objective-C runtime reader

A new `core/objc/LegacyImage.mm` that walks `__OBJC,__module_info` →
`__symbols` → class and category structs and produces the same
`ClassInfo` graph as `setupImage` does from `__objc_classlist`:

- `objc_class {isa, super_class, name, version, info, instance_size,
  ivars, methodLists, cache, protocols}`: `super_class` and `__cls_refs`
  entries hold name strings until fixed up; the bridge rewrites them to
  the guest class (guest classes) or the stub class for the host class
  (host classes), as the legacy runtime would.
- `__message_refs` are the selector references (rewrite to interned
  guest SELs, as `__objc_selrefs` today).
- `objc_ivar_list`: `{name, type, int offset}`. `GuestIvar` gains a fixed
  offset alternative to `offsetVar`. The guest half is `instance_size`
  bytes; the bytes where the host superclass's 32-bit ivars would have
  been are simply unused.
- Categories `{name, class_name, instance_methods, class_methods,
  protocols}` and protocols `{isa, name, protocol_list, instance_methods,
  class_methods}` map onto the existing category and protocol handling.
- `__image_info` flags say whether the image was compiled for GC. GC-only
  images never retain or release; run them with a "leak everything"
  policy (host objects created for them are never released) and log it.
- `objc_msgSend_fpret` joins the msgSend family; `objc_exception_*` are
  five small thunks over `_setjmp` (the existing setjmp context save makes
  `try_enter` trivial, and `throw` longjmps to the innermost registered
  buffer). `objc_assign_ivar/global/strongCast/weak` are plain stores.
- Properties: `objc_getProperty`/`objc_setProperty` (10.5+) with the
  atomic/copy flags; `object_getInstanceVariable`,
  `object_setInstanceVariable`, `class_getInstanceSize` with the fragile
  meaning.

### Dispatch and AppKit specifics

- KVO and bindings. Today a guest-to-guest `objc_msgSend` finds the IMP in
  the guest class chain and tail-calls it, so an observed guest object's
  setter runs without the `NSKVONotifying_*` interception the host
  installed on its host half. UIKit apps rarely noticed; Cocoa apps built
  on bindings (NSArrayController, `bind:toObject:withKeyPath:`) depend on
  it. Change: before the guest-to-guest fast path, check whether the
  receiver's host half's class is still its shadow class; if the host
  changed it (KVO, `object_setClass`), route the send through host
  dispatch so the host subclass runs, then the trampoline, then the guest
  IMP. One handle-table lookup per bridged send; measure it.
- Struct names: 32-bit AppKit encodes `{_NSRect={_NSPoint=ff}{_NSSize=ff}}`
  where the host says `{CGRect={CGPoint=dd}{CGSize=dd}}`. Add
  `_NSPoint`, `_NSSize`, `_NSRect` to the geometry set in `Encoding.cpp`
  and treat the pairs as equivalent where names are compared.
- `NSApplicationMain` is the host's, as `UIApplicationMain` is today. The
  shell's Info.plist carries the guest's `NSMainNibFile` and
  `NSPrincipalClass`; the shadow-class mechanism makes guest
  `NSApplication`/`NSView`/`NSWindowController` subclasses visible to nib
  loading and KVC, as it does for UIKit.
- Nibs: keyed nibs (10.2+ format, `keyedobjects.nib`) load on modern
  AppKit; non-keyed `objects.nib`-only nibs from 10.0–10.1 do not and are
  out of scope.
- AppKit's "linked on or after" checks read the main executable's SDK
  version through dyld, which is the shell's, not the guest's. Expect to
  opt out of modern behaviors by hand the way `B32GuestSDKVersion` does
  for UIKit (layer-backing, `NSWindow` tabbing, Auto Layout defaults, dark
  appearance). Set `NSRequiresAquaSystemAppearance` from the guest's
  deployment target.
- AppKit classes removed from 64-bit that 32-bit apps used:
  `NSQuickDrawView`, `NSMovieView`/`NSMovie`, QTKit, `NSOpenGLView` is
  still present. Stub the removed ones through `sdkstubs.mm`.

### Framework surface

In scope (host implementation exists, bridging is generic or table-driven):

- Foundation, AppKit, CoreFoundation, CoreGraphics, CoreText, ImageIO,
  QuartzCore, Security, SystemConfiguration, CFNetwork, sqlite, zlib.
- CoreServices subset that survived in 64-bit: `FSRef` calls, Alias
  Manager, Resource Manager, `Gestalt`, LaunchServices, UTType functions,
  Memory Manager `Handle`s. Handles are implemented in guest memory by us
  (a `Handle` is a guest pointer to a guest pointer; host Handles from the
  Resource Manager are copied into guest Handles).
- OpenGL through the host's OpenGL.framework (still present on arm64
  macOS, deprecated), via a generated `B32_C_FUNCTIONS` table like the
  GLES one, plus `NSOpenGLContext`/`CGL` and `AGL` emulated over `CGL`.
- CoreAudio HAL (`AudioDeviceAddIOProc` and friends), AudioUnit,
  AudioQueue, OpenAL (host framework still present), IOKit HID for input.
- BSD sockets for real this time (`sockaddr`, `fd_set`, `addrinfo` are
  easy; the iOS layer deliberately fails them).

Out of scope for the first releases, because there is no 64-bit host
implementation to call:

- Carbon UI: HIToolbox windows, controls, HIView, Carbon Events as the
  main event source, Navigation Services, Dialog Manager. Pure Carbon
  apps need a reimplementation of HIToolbox over AppKit, a separate
  project. Individual HIToolbox calls that do exist in 64-bit
  (`RegisterEventHotKey`, `TISCopyCurrentKeyboardInputSource`,
  `SetSystemUIMode`, `GetCurrentEventKeyModifiers`) are ordinary thunks.
- QuickDraw and the Sound Manager.
- QuickTime (C API and QTKit). Many games and media apps use it; a shim
  over AVFoundation covering `NewMovieFromFile`/`MoviesTask`-style playback
  and `GraphicsImport*` image loading is plausible later.
- Java bridge apps, Flash/Shockwave projectors, Steam client integration.

## Phases

Each phase ends with a runnable artifact and a test the next phase builds on.

### Phase 0: CPU spike (decides the engine)

- Add Unicorn 2 as a submodule, build it with CMake for arm64.
- `core/cpu/UnicornCpu.cpp` implementing the slimmed `Cpu` interface:
  memory mapping synced from `GuestMemory`, stub trap, `%gs` base, one
  engine per thread.
- Run `tests/guest/hello` and `rbtree` built for i386 under `b32-run`.
- Measure: thunk round trips per second (a loop of `strlen` calls) and a
  compute loop versus native.

Exit: numbers in hand. Unicorn is the chosen engine; the numbers set the
performance baseline Phase 5 is measured against, and a thunk round trip
costing more than a few microseconds is the trigger to start Phase 5 early.
Size: S for the backend, the measurement harness is the point.

### Phase 1: i386 ABI and loader

- `core/arch/i386/`: `Args`, `Call::ret*` including ST(0) and struct
  rules, `Cpu::call` (push words right-to-left, sentinel return address),
  `setjmp`/`longjmp` (18-word `jmp_buf`), `deliverFault` with the i386
  `ucontext`/`mcontext32` layout.
- Dispatcher-performed returns with callee pop.
- Loader: i386 slice, `x86_THREAD_STATE32`, jump tables, symbol suffix
  aliasing, 32-bit-inode stat family.
- `b32-inspect` reports i386 images.

Exit: `hello`, `cxx` (no throw), `rbtree` pass under `ctest` as i386.
Size: M.

### Phase 2: Legacy ObjC runtime

- `LegacyImage.mm` reader, fixups, `GuestIvar` fixed offsets.
- `objc_msgSend_fpret`, setjmp exceptions, GC barriers, property helpers.
- `objc` test built for i386 (MRR, `@try/@catch`, a category, a protocol,
  an ivar read through a fragile offset, `NSRange`/double returns).

Exit: `run-objc` passes as i386 with the same expected output as armv7.
Size: M–L.

### Phase 3: AppKit shell

- `app/mac/main.mm` and `core/appkit/`: the AppKit shell target
  (`-DB32_MAC=ON`, no toolchain file), guest `.app` wrapping in
  `make-app.sh` with `Contents/Frameworks` as guest libraries, log and
  container setup as today.
- KVO-aware guest dispatch, `_NS*` geometry names, linked-on-or-after
  opt-outs, removed-class stubs.
- A guest test app: nib with a window, a custom `NSView` subclass drawing
  with `NSBezierPath` in `-drawRect:`, a button with target/action, an
  `NSTextField` bound to a model property, a sheet, an `NSTimer`.

Exit: the test app runs wrapped, draws, responds to the button, and the
binding updates when guest code changes the model.
Size: L.

### Phase 4: Real apps, breadth

Pick three apps that stress different surfaces and iterate on missing
thunks, as the iOS side did with PAC-MAN and the Oceanhouse books:

1. A plain document-based Cocoa app from the 10.5–10.8 era (text or
   outline editor): nibs, NSDocument, bindings, printing.
2. An OpenGL game using `NSOpenGLView` or SDL 1.2 (bundled as a guest
   framework): OpenGL table, CoreAudio or OpenAL, HID input, timers.
3. A C++-heavy app with bundled frameworks and `libstdc++`: exceptions
   (see below), threads, sockets.

Exit: all three usable; `b32-inspect` unimplemented-import counts trend to
zero per app.
Size: ongoing.

### Phase 5: Performance path (conditional)

If Phase 4 apps are CPU-bound under Unicorn: FEXCore backend behind the
same `Cpu` interface, with the low-4 GB reservation. Independent of the
AppKit work by then.
Size: XL.

## Phase 0 results (2026-11-08)

Done on the `i386` branch, in the order the plan gives:

- Unicorn 2.1.4 is a submodule (`external/unicorn`), built by CMake with
  `-DB32_GUEST_ARCH=i386`; `external/unicorn-parallel.patch` (one line,
  `curr_cflags()` returns `CF_PARALLEL`) is applied at configure time.
- `Cpu` is architecture-neutral; `ArmCpu` (dynarmic) and `X86Cpu` (Unicorn)
  carry the calling conventions in `core/arch/`. The thunk stub on i386 is
  `hlt; ret`: the halt traps with the stub's index derived from its address,
  the ret runs on resume, and a tail call moves eip past it. Everything the
  shared thunk and ObjC files knew about ARM registers went through
  `arg()`, `setArg()`, `sp()`, `returnAddress()`, `setResult*()`,
  `frameChain()`, `threadState()` and `stubContext()`; the ARM host tools
  still build and link (their guest tests need an iOS SDK that wasn't
  available, so they were not rerun).
- The loader takes i386 slices, `x86_THREAD_STATE32` entry points, and
  aliases libSystem's `$UNIX2003`/`$INODE64`/`$NOCANCEL`/`$1050`/
  `$DARWIN_EXTSN` variants to the base thunks (hello imported
  `strtod$UNIX2003` on its first run).
- `hello`, `rbtree` and a new `threads` test pass under `ctest`. `threads`
  bumps a counter with `lock xadd` from four guest threads (exactly 800000,
  so the atomics patch holds; the unlocked twin counter shows real
  interleaving) and reads a double back from the host through ST(0).

Measured on the build machine (Apple M1 Pro), `tests/guest/bench`
built once natively for arm64 at -O1 and once for i386, best of two runs
(a second run under load was 1.7× slower across the board):

| Benchmark | Native arm64 | i386 under Unicorn | Ratio |
| --- | --- | --- | --- |
| Thunk round trip (`strlen` of a 20-byte string) | folded by the compiler | 32 ns per call | – |
| `fib(31)` (2.7 M calls) | 0.005 s | 0.298 s | ~60× |
| Byte sieve to 20 M | 0.062 s | 2.97 s | 48× |
| Mandelbrot 400×400 in doubles (SSE2) | 0.016 s | 0.218 s | 14× |
| `lock xadd` ×10 M, one thread | 0.069 s | 0.200 s | 3× |

What the numbers mean for the plan:

- The thunk trap is not a cost worth designing around: 32 ns is below the
  "few microseconds" trigger by two orders of magnitude, so a message to a
  host object will cost what the host dispatch costs.
- Translated code is where Unicorn is slow: 15–60× below native arm64 on
  integer code (call-heavy code worst, QEMU's indirect returns), 14× on
  SSE2 doubles. Relative to the 2008 Macs these apps ran on, that is
  roughly a late-1990s machine: enough for Cocoa productivity apps, not for
  3D games. The Phase 5 FEXCore port is triggered by app performance, not
  by thunk cost.

Findings that changed the code or the plan:

- SSE was disabled: Unicorn sets CR4.OSFXSR only for CPU models with XSAVE,
  and the Penryn model predates it, so `cvtsi2sd` faulted as an invalid
  instruction. `UnicornCpu` sets CR4.OSFXSR and OSXMMEXCPT itself.
- Loading `%gs` from the GDT made QEMU recompute the 32-bit code and stack
  flags from the reset-state CS and SS descriptors, truncating stack
  addresses to 16 bits. All six segment registers are loaded from the
  per-CPU GDT (code 0x08, data 0x10, GS 0x18 based at the TSD).
- Guest memory is mapped into an engine lazily, from the unmapped-access
  hook, one maximal run of committed pages at a time; the sentinel page
  that holds the GDTs is mapped eagerly because segment loads read it
  outside emulation.
- `UC_TLB_VIRTUAL` (Unicorn's own TLB) hangs with the lazy mapping hook; it
  was not pursued.
- A misaligned lock-prefixed instruction raises `EXCP_ATOMIC`, which Unicorn
  doesn't handle (QEMU's single-step fallback isn't compiled in); it
  surfaces as a fatal `UC_ERR_EXCEPTION` with the eip. Not hit yet.
- No i386 linker exists on a current Mac: Apple's `ld` refuses i386, `lld`
  never supported 32-bit Mach-O, and building ld64 from cctools-port was
  not permitted in the session that did this work. `tools/i386-link.py`
  (a single-object linker: vanilla relocations, synthesized stubs and lazy
  pointers, the object's own non-lazy pointers, LC_MAIN) links the C tests
  compiled with `-mdynamic-no-pic`. It will not link ObjC or C++ tests; an
  ld64 build (cctools-port, or `ld-classic` from Xcode 15/16) is needed
  before Phase 2.

## Phase 1 results (2026-11-09)

Phase 1's exit test holds: `hello`, `cxx` (no throw) and `rbtree` pass under
`ctest` built for i386, along with `threads` and three new guests. All eight
`ctest` entries pass in the `-DB32_GUEST_ARCH=i386` build.

| Guest | What it proves |
| --- | --- |
| `abi` | `long double` arguments (16 bytes of argument words, 4-aligned) through varargs and `strtold`; structs in EAX:EDX and through a callee-popped hidden pointer, with the stack pointer checked around the call; both `stat`, `dirent` and `statfs` layouts agreeing on the same files; `setjmp`; a SIGSEGV handler seeing the exact faulting EIP and address, and resuming from registers it rewrote in the `ucontext` |
| `objcabi` | `objc_msgSend_fpret` and `_stret` against host classes, in C so no ObjC metadata is involved; nil receivers leaving 0.0 on the x87 stack and popping the hidden pointer; guest methods called from the host (through key-value coding) returning `double`, `float` and a struct |
| `classic` | An `LC_UNIXTHREAD` executable entered at a crt1-style `start`, imports through a self-modifying `__IMPORT,__jump_table`, `__dyld_func_lookup` through `__DATA,__dyld`, and a dylib slid by plain, scattered and `R_ABS` local relocations |

`tools/i386-link.py` gained `--classic --entry` and `--dylib`, since no current
tool writes those formats. Real i386 images also load: TowerFall's executable
is reported by `b32-inspect` with only Mono's two imports unresolved, and two
Solarus dylibs (`LC_DYLD_INFO`) slide and bind through `dlopen`.

What landed:

- A hidden-pointer struct result is `StructResult` in a thunk, and
  `Bridge::returnToGuest` / `resultFromGuest` in the message and block paths.
  Both follow `arch::structReturnedInMemory` and `guestReturnClass`, so a
  result can go to memory, EAX:EDX or ST(0) (a lone `float` or `double` in a
  struct included) without the callers knowing the ABI.
- Variant symbols try the exact name, then the name with only `$INODE64` kept,
  then the base name, so `_opendir$INODE64$UNIX2003` works and layouts that
  differ get their own thunks.

Limits to carry forward:

- The floating-point part of the `ucontext` holds only default control words.
  A handler runs with the faulting code's FP state, which is restored when it
  returns, so it can't change FP registers through the context.
- `_signal` still records nothing; only `sigaction` handlers run.
- `tools/i386-link.py` links C and exception-free C++ from one object. (Phase 2
  extended it to ObjC; see below.)
- The armv7 guest tests were not rerun, because the iOS SDK they build against
  is on an unmounted volume. ARM host tools build, and the Catalyst-only files
  type-check. On ARM the struct, float and stat paths go through the same
  rules as before by construction, but that is not a test result.

## Phase 2 results (2026-11-09)

Phase 2's exit test holds: `run-objc` passes as i386 with the same expected
output as armv7, and all ten `ctest` entries pass in the i386 build.

`core/objc/LegacyImage.mm` reads the `__OBJC` segment. It fixes up in place
what guest code reads directly (`super_class`, metaclass links, class and
selector references), keeps each class at its own address, and makes modern
`class_ro_t`, ivar, method and protocol records for the rest of the bridge, so
message dispatch and reflection did not need a second format.
`core/objc/legacy_thunks.mm` adds setjmp-based exceptions and the garbage
collector's write barriers.

The `objclegacy` guest covers fragile ivars read directly, a chain of guest
superclasses with super sends, `+load`, `+initialize`, a category, atomic
properties, a protocol with an optional method, `double` and `NSRange` returns,
`@try/@catch/@finally`, an exception thrown by host code, a guest throw that
crosses host frames, a rethrow through `@finally`, a write barrier, and a class
made at run time with an ivar and a method.

A throw that can't reach its `@try` by longjmp, because host frames lie between
them, becomes a host exception. Host `@try` blocks see it as they would on a
real Mac, and the guest-to-host call site below the guest's `@try` turns it back
into a guest throw.

A real binary built by Apple's tools also goes through the reader: Breakpad's
`crash_report_sender` (i386 AppKit) has its classes, categories and protocols
read, and only 8 imports lack a thunk, 4 of them AppKit functions for Phase 3.

Corrections and limits:

- A real ld64 turned out not to be needed for these tests. `tools/i386-link.py`
  now writes a `__OBJC` segment and external relocations, which covers a
  single-object ObjC program. Multi-object test programs would still need one.
- Run-time classes get their shadow class at `objc_allocateClassPair`, so
  methods added before `objc_registerClassPair` are visible to the host at once.
- A GC-only image is detected and logged, but it was not run: nothing on this
  Mac is one. Without a collector its objects are never freed.
- Old binaries with `@"..."` compiled as `NSConstantString` objects
  (`-fno-constant-cfstrings`) are not handled.
- `class_getInstanceSize` of a host class reports the 64-bit host size, not the
  32-bit size a fragile subclass was compiled against.
- `run-objc` passes on i386 only so far. The armv7 tests still need the iOS SDK
  volume; ARM host tools build.

## Phase 3 results (2026-11-09)

Phase 3's exit test holds. `AppKitTest`, an i386 app with a compiled nib, runs
wrapped in the AppKit shell under `ctest` (`run-appkit`), and all twelve entries
pass in the `-DB32_GUEST_ARCH=i386 -DB32_MAC=ON` build. The app checks itself:

| Exit item | Check |
| --- | --- |
| Nib | The window, a guest `NSView` subclass, a button and a text field arrive through outlets to guest ivars |
| Draws | A guest `-drawRect:` with `NSRectFill` and `NSBezierPath`; pixels are read back from the view, and a saved PNG of the window showed the expected oval |
| Button | `performClick:` runs the guest action, which retitles the button |
| Binding | A guest setter's change reaches an `NSTextField` bound to the model |
| Sheet and timer | `beginSheet:` and `endSheet:returnCode:` reach the guest's did-end selector with its return code and context; a repeating `NSTimer` drives the whole test |

What landed:

- `app/mac/main.mm` is the shell, and `tools/make-app.sh` wraps a Mac `.app`
  when given one. The guest's Resources become the shell's, so `NSBundle
  mainBundle` is the guest's; its executable and Frameworks go in
  `Contents/B32Guest`, which keeps `@executable_path/../Frameworks` working
  without making them nested code the signature has to cover.
- The shell's Mach-O claims the 10.14 SDK (`vtool`), so AppKit's linked-on-or-after
  checks give guests the behaviors they were written for. This replaces most of
  the per-behavior opt-outs the plan expected. It has only been exercised by the
  test app so far.
- A nib's outlets get a made-up `setFoo:` on the shadow class for each object
  ivar without one. AppKit, unlike UIKit, doesn't fall back to KVC for outlets.
- Sends to an object the host moved off its shadow class go through the host, so
  KVO's setter runs. The binding test fails without this. It costs about 3% on a
  guest-to-guest send:

| Guest-to-guest send, 2M calls, 3 runs | ns per send |
| --- | --- |
| With the check | 722 to 746 (median 724) |
| Without it | 583 to 707 (median 702) |

Real-app status: Breakpad's `crash_report_sender` now has no unresolved imports,
wraps, launches, runs its ObjC startup and exits with its own error when given a
config file that doesn't exist. Its window was not exercised, because that takes
a config in Breakpad's private format. Real apps are Phase 4.

Limits to carry forward:

- `foundation.mm` now builds for the Mac with its UIKit parts compiled out, and
  `_NSFoundationVersionNumber` reports 10.14's value. The alert-panel and most
  geometry thunks in `core/appkit/appkit.mm` compile but no test calls them.
- The test app is built against today's SDK headers, with `prefix.h` declaring
  the two classes they hide from the legacy runtime. Its nib comes from today's
  `ibtool`. An old nib from a real app is still to be tried.
- `NSQuickDrawView` and `NSMovieView` are empty views. `NSMovie` is still
  present on the host, and QTKit's classes are not provided.
- `_signal` handlers still don't run, and the shell has no sandbox or
  entitlements, unlike the Catalyst shell.

## Phase 4 progress (2026-11-09)

Phase 4 is under way, against the real i386 apps available. This Mac has no
document-based Cocoa app to test with.

**Asphalt 6 (Gameloft, 2011) runs.** It is an AppKit, OpenGL and C++ game linked
against the system `libstdc++`, wrapped with `tools/make-app.sh`. It plays sound
and renders its menus and races with no GL errors: a captured frame shows lap 2
of 3 of a race, reached by clicks the app posted to itself. Over the last 75
seconds of that session, which covers the end of loading and the race, it
averaged about 16 frames per second. Keyboard steering hasn't been checked by a
script.

It needed:

- Desktop OpenGL through a table generated from the SDK's headers
  (`tools/gen-gl-table.py`, about 1,100 functions), CGL, and a real
  `CVDisplayLink` calling guest code.
- GCC's copy-on-write `std::string` and the iostream classes the game uses
  (`core/thunks/libstdcxx_string.cpp`, `libstdcxx_stream.cpp`), written against
  the object layouts its inline code expects. No guest `libstdc++` exists here.
- Shader source fixes for today's stricter GLSL compiler: names starting `GL_`
  can't be defined, so they're renamed, and stray text after `#endif` is dropped.
- A `-lockFocus` call before a guest view's first draw in a window. AppKit
  stopped making it in 10.14, and OpenGL views of the era attach their context
  there. Without it the context has no drawable and the screen stays black.
- QTKit stubs: its intro movies don't play.

The game contains a Mac App Store receipt check that calls `exit(173)`, and this
copy has no `_MASReceipt`. It hasn't run in any session so far. Nothing here
patches or fakes it: the libcrypto and keychain functions it uses have no thunks,
and the game will stop if it reaches them. 32 of its imports remain unimplemented.
Nearly all are that check's (libcrypto, the keychain, `ifstream`), and two are
C++ exception entry points, so a thrown C++ exception is still fatal.

**TowerFall (Mono, SDL2, OpenAL) is parked** at SDL's video setup, by request, to
do Asphalt first. Mono 2.10 boots and runs managed code. That took real Mach
ports for its exception thread, an i386-native `pthread_getspecific` (Mono reads
its instructions to inline thread-local access), an 8 MB main thread stack, and
a Unicorn patch (`external/unicorn-step-atomic.patch`) for locked instructions
the host can't do atomically, which otherwise retried forever.

Other limits:

- Display capture and mode changes succeed and do nothing, deliberately.
- HID reports no devices, so game controllers don't work yet.
- `glMapBuffer` returns NULL, and the `GLsync` functions aren't in the table.

Debugging options added: `B32_TRACE_SHADERS=1` logs shader sources and compile
logs, and `B32_GL_SNAPSHOT=path.png` saves every 60th presented frame.

## Cross-cutting items already missing on the iOS side

These block Mac apps sooner than iOS games, so they land in the plan:

- C++ exception unwinding (`cxxabi.cpp` is fatal on throw today). i386
  Mac uses DWARF `__eh_frame` (and compact unwind from 10.6): the planned
  approach of running a real guest `libstdc++`/`libgcc_s` as guest code
  works unchanged for i386 if the guest libraries are supplied, since the
  unwinder is then guest code reading guest tables. Requires the guest
  `libgcc_s.1.dylib` and `libstdc++.6.dylib` from an old SDK's
  `/usr/lib`, as the README already asks for on iOS.
- Static destructors never run (`__cxa_atexit` returns 0); document apps
  that save state in them will care.
- Real sockets.

## Guest test toolchain

- Compilation: the current Xcode's clang compiles i386 (verified). The
  current SDK's AppKit headers reject i386, so test sources either include
  a 10.13-or-earlier SDK (`-isysroot`) or declare the few AppKit
  interfaces they use by hand.
- Linking: neither Apple's `ld` (Xcode 27) nor `ld64.lld` 21 links i386.
  Options, in order of preference:
  1. `ld-classic` from an Xcode 15 or 16 toolchain, invoked directly; it
     is a universal binary and runs natively.
  2. Apple's open-source ld64 (ld64-609 or later with i386) built from
     source, or via `cctools-port`.
  3. Check prebuilt i386 test binaries into `tests/guest/prebuilt/` as a
     fallback so `ctest` works without any i386 linker.
- With Bridge32 resolving imports by name, tests can link with
  `-undefined dynamic_lookup` and no SDK stubs at all; ObjC class
  references work the same way.
- The tests Makefile grows an `ARCH=i386` mode selecting these.

## Risks and open questions

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Unicorn per-call overhead makes every host ObjC message expensive | GUI feels sluggish even when compute is fine | Phase 0 measures it; fall back to batching (`uc_emu_start` without count/timeout, no code hooks) or FEXCore |
| Unicorn compiles `lock` ops non-atomically (confirmed: `curr_cflags()` returns 0, so `CF_PARALLEL` is never set) | Races in inline atomics (libstdc++ refcounts, spinlocks) across guest threads | One-line fork patch returning `CF_PARALLEL`; covered by a four-thread `lock xadd` test in Phase 0 |
| Unicorn does not emulate x86 memory ordering on the weak arm64 host | Lock-free guest code can observe reordering across threads | Audit in Phase 4 per app; FEXCore's TSO emulation is the fallback |
| Unicorn's TB caches are per engine | Code patched by one guest thread and cached by another's engine runs stale | Broadcast `uc_ctl_remove_cache` from the `mprotect`, `mmap` and cache-flush thunks |
| FEXCore assumes 4 KB pages, RWX JIT memory and Linux-style signals | A Darwin port is weeks of work before the first instruction runs | Only taken if GPL is unacceptable or Unicorn proves too slow; the WOW64 module is the template |
| GPL for the distributed Mac shell | Licensing of binaries changes from MIT | State it in the README; the arm/iOS shell is unaffected; FEXCore path is MIT |
| x87 80-bit precision | Numeric drift versus a real Mac | Unicorn's softfloat is exact; FEXCore approximates with 64-bit, acceptable for apps |
| KVO routing cost and correctness | Bindings-heavy apps either don't update or every send slows | Cache per handle whether the host class is still the shadow class; invalidate on `object_setClass` and `addObserver:` thunks |
| AppKit linked-on-or-after behavior keyed to the shell's SDK | Visual and behavioral differences (layer-backed views, appearance) | Catalogue opt-outs per deployment target as the UIKit side did; consider linking the shell with an older deployment target |
| Fragile `instance_size` of host classes baked into guest code via `class_getInstanceSize` or `+alloc` overrides | Guest allocates too little for a host object | The host half is always host-allocated; only the guest half uses the baked size, which is correct by construction |
| Carbon and QuickTime use in otherwise Cocoa apps | App launches but a feature is dead | `b32-inspect` lists the imports up front; triage per app; stub with clear logs |
| Apps with their own JITs (Mono/Unity 32-bit Mac games, LuaJIT) | Wrong code after self-modification | TCG tracks writes to translated pages; verify with a test that patches code at run time |
| i386 linker availability for tests | No `ctest` coverage for i386 | Prebuilt binaries in the repo as a fallback |

Open questions for the reviewer:

1. Resolved 2026-11-08: Unicorn 2, GPL accepted for the Mac shell.
2. Which three apps are the Phase 4 targets? The plan assumes a document
   app, an OpenGL game and a C++ app with bundled frameworks.
3. Should the arm and i386 shells stay one repository with a
   compile-time `B32_GUEST_ARCH`, as proposed, or should the i386 work
   fork? The abstraction work in Phase 1 is the same either way.
4. Is Carbon HIToolbox emulation over AppKit something to leave room for
   in the design (a `core/carbon` with its own window/control model) or
   explicitly never?

## Rough size

New code before any real app runs: on the order of 8–12 k lines (Unicorn
backend ~0.8 k, i386 ABI layer ~0.5 k, loader ~0.5 k, legacy ObjC reader
~1 k, AppKit shell and support ~2 k, OpenGL table ~0.6 k generated, CoreServices
and sockets ~2 k, tests). Then the per-app thunk tail, which on the iOS side
has been the bulk of the commits.
