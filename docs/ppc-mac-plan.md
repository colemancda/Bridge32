# Running 32-bit PowerPC Mac apps: feasibility and plan

Status: proposal for review. Nothing here is implemented. The spike results
below were run on 2026-11-09 against the patched Unicorn in `external/unicorn`.

Target decided 2026-11-09: **World of Goo 1.30** (`ppc_7400` only), which sets
the phase order below.

## Verdict

Yes, and the CPU is the easy part. The cost of this port is byte order.

- **The engine is already here.** Unicorn 2's PowerPC target runs G4 code,
  AltiVec included, on this tree with the existing patches. It matched the
  i386 guest's speed on the one comparable benchmark (fib(31): 0.025 s against
  0.026 s). No new JIT is needed; see "Spike results".
- **The Bridge32 model still holds.** A 32-bit guest address space, every
  import answered by the real 64-bit frameworks through thunks and the ObjC
  bridge. The legacy ObjC reader, the AppKit shell and the Carbon layer built
  for i386 are all reusable.
- **PowerPC is the first big-endian guest.** Every value that crosses between
  guest memory and a host API today does so by assuming both sides agree. That
  assumption is the whole of the new risk. Rosetta avoided most of it by running
  Apple's PowerPC frameworks under translation; Bridge32 has no such frameworks
  and answers every call natively, so it must convert at each boundary.

The conversion is less work than it sounds in most of the code, and more in
one place:

| Where guest data meets the host | Sites | Work |
| --- | --- | --- |
| `mem.read<T>` / `mem.write<T>`, all on arithmetic types | 1,382 | One change, inside `GuestMemory` |
| `c.args.*` in thunks | 3,073 | One change, inside `Args` and the CPU class |
| `.ptr<>` to bytes or `void` | ~256 | Bytes need nothing; each `void` needs a look |
| `.ptr<>` to typed data (`UInt32`, `AudioTimeStamp`, `wchar_t`...) | 84 | Convert each one |
| OpenGL vertex, index and uniform data | one subsystem | **The hard part**, see "OpenGL" |

## What a 32-bit PowerPC Mac app is

The target is Mach-O apps with a `ppc`, `ppc750` or `ppc7400` slice, built for
Mac OS X 10.2–10.5. Apps that are `ppc`+`i386` universal should keep using the
i386 slice; this port is for apps that never got one.

ABI details in this table come from Apple's published 32-bit PowerPC
conventions and GCC's documented behavior. Only the instruction-level rows have
been run here. Phase 1 must confirm the rest against real binaries.

| Aspect | i386 Mac (today) | PowerPC Mac (proposed) |
| --- | --- | --- |
| Byte order | Little | **Big** |
| Mach-O | Host-order headers | Every header, load command, symbol and relocation big-endian |
| Integer arguments | Stack words | `r3`–`r10`, then the stack at `24(r1)` |
| Float arguments | Stack words | `f1`–`f13`, and each still uses up 1 or 2 GPR slots |
| Varargs | Pointer into words | Same, `va_list` is a pointer; floats go in both GPRs and FPRs |
| 64-bit arguments | Two words, low first | Two words, **high first**, no alignment padding |
| Integer return | EAX, EAX:EDX | `r3`, `r3`:`r4` (high first) |
| Float return | ST(0) | `f1`; `long double` in `f1`:`f2` |
| Struct return | In registers up to 8 bytes | Up to 8 bytes in `r3`:`r4`, larger through a hidden pointer in `r3` that the callee doesn't pop (GCC's rule for Darwin; to confirm in Phase 1) |
| Return address | On the stack | Link register, saved by the callee |
| `sizeof(bool)` | 1 | **4** in C++ and `_Bool`; ObjC `BOOL` stays 1 |
| `long double` | 80-bit x87 | 128-bit double-double from 10.4 (`$LDBL128` symbols), 64-bit before |
| Struct alignment | 4-byte doubles | "Power" rules: 4-byte doubles, but 8 when a double is the first member |
| Import stubs | `__jump_table` or lazy pointers | `__picsymbolstub1` or `__symbol_stub1` through `__la_symbol_ptr` |
| Thread register | `%gs` | None to emulate; `pthread_self` is an import |
| ObjC dispatch | `objc_msgSend` import | Also `bla 0xfffeff00`, a fixed-address runtime page |
| ObjC struct send | `objc_msgSend_stret` | Same; `r3` is the result, `r4` self, `r5` the selector. No `_fpret` |
| Older format | n/a | CFM/PEF Carbon apps (`Joy!peff`), see Phase 7 |

## Spike results (2026-11-09)

Unicorn built from the patched `external/unicorn` with `UNICORN_ARCH=ppc`.
Hand-written PowerPC ran on a G4 model (`UC_CPU_PPC32_7447A_V1_2`), with guest
memory mapped through `uc_mem_map_ptr` exactly as `UnicornCpu` does for i386.

| Test | Result |
| --- | --- |
| Big-endian store to host-visible memory | Correct: `stw 0x12345678` reads back `12 34 56 78` |
| `sc` traps to `UC_HOOK_INTR` (n=8) and resumes at the next instruction | Works, three in a row |
| Addresses above 2 GB (`0xBFFF0000`) | Works |
| FPU without `MSR[FP]` | Stops with exception 7 |
| FPU with `MSR[FP]`, `lfd`/`fadd`/`fmul`/`stfd` | Correct (3.75 and 3.375) |
| AltiVec without `MSR[VEC]` | Stops with exception 73 |
| AltiVec with `MSR[VEC]`, `lvx`/`vaddfp`/`stvx` | Correct (11, 22, 33, 44) |
| `lmw`, `stmw`, `rlwimi`, `cntlzw`, `mfcr`, `mtcrf`, `dcbz`, `dcbf`, `icbi`, `sync`, `isync`, `fsel` | All execute |
| Unmapped write | Faults with PC on the exact instruction and earlier register writes intact |
| `lwarx`/`stwcx.`, 4 engines over shared memory, 2 M increments each | Exact: 8,000,000 |
| Timebase (`mftb`, `mfspr 268/269`) | **Broken: always 0**, even after 134 M instructions |
| fib(31) / fib(35) | 0.025 s / 0.169 s |
| Load/store loop, 50 M iterations (byte-swapped accesses) | 0.136 s, about 1.5 G memory operations/s, values verified |

The speed patches (`unicorn-parallel`, `unicorn-fast-writes`,
`unicorn-inline-exit-check`, `unicorn-step-atomic`) touch shared TCG code, and
they compiled and worked for this target. Floating-point and AltiVec speed were
not measured; both go through helpers rather than inline code and will be
slower than the integer numbers above.

### Unicorn work this found

1. **`tb_page_has_code` needs per-target names.** `unicorn-fast-writes.patch`
   adds it, but QEMU compiles each target separately and renames shared symbols
   through `qemu/<target>.h`. `UNICORN_ARCH=ppc` builds both `ppc` and `ppc64`,
   so linking fails with a duplicate symbol. Add the rename to the patch. The
   spike confirmed this fixes it.
2. **The timebase has to be implemented.** `mftb` needs to return a running
   count, in step with what the `mach_timebase_info` thunk reports. Games read
   it directly for timing, so a stuck zero means hangs in delay loops.
3. **AltiVec registers have no API.** `include/unicorn/ppc.h` exposes GPRs, FPRs,
   CR, LR, CTR, XER, MSR and FPSCR, but not `v0`–`v31`, `VSCR` or `VRSAVE`. They
   are needed for fault delivery, `setjmp`, and any thunk taking vector arguments.
4. **Every engine must start with `MSR[FP]` and `MSR[VEC]` set**, or the first
   FP or vector instruction stops the guest.

## What carries over

- `Cpu`, `Args`, the thunk registry and the table-driven thunks. A `c.args.u32()`
  keeps meaning "next argument word", because the ABI reserves GPR slots for
  float arguments. `f32`, `f64` and `u64` are already separate calls (206 sites),
  so only those need PowerPC-specific code.
- One Unicorn engine per guest thread over shared memory, lazy mapping through
  `UC_HOOK_MEM_UNMAPPED`, and fault delivery.
- The legacy ObjC reader (`LegacyImage.mm`), since PowerPC apps use the same
  `__OBJC` format, and setjmp-based ObjC exceptions.
- The AppKit shell, `tools/make-app.sh` (its `i386` slice check becomes
  per-architecture), bundled frameworks, `$UNIX2003`-style symbol aliases, resource forks.
- Whole files read and written by the guest. Data on disk needs no conversion;
  guest code does its own byte order.

Two things should get easier than on i386. Carbon resources are big-endian on
disk, so what the host Resource Manager returns should be able to go to the
guest raw; Phase 4 confirms this. And
`kCGBitmapByteOrder32Host` and `kAudioFormatFlagsNativeEndian` are compile-time
macros, so a PowerPC binary passes explicit big-endian flags that the host
understands.

## Byte order: the central decision

**Decision proposed: guest memory stays big-endian, and values convert at the
guest/host boundary.**

| Option | Verdict |
| --- | --- |
| Convert at the boundary (typed `GuestMemory`, per-field structs, per-format buffers) | **Chosen.** Costs nothing on paths that don't cross, and the conversion sites can be found and tested |
| PowerPC little-endian mode with address munging | Rejected. Strings and mixed-width access come out scrambled for host code, which is the same problem in a worse form |
| Run Apple's PowerPC frameworks under emulation, as Rosetta did | Rejected. They can't be redistributed, need a PowerPC OS on every machine, and still end in big-endian calls into the host at the kernel and GPU |

The shape of the change:

- `GuestMemory::read<T>` and `write<T>` swap by `sizeof(T)` when
  `B32_GUEST_BIG_ENDIAN` is set. That is compile-time, so ARM and i386 are
  unaffected. It covers 1,382 call sites at once.
- `ptr<T>` becomes a deliberate choice. In big-endian builds `ptr<T>` compiles
  only for byte-sized `T` and `void`. All 84 typed sites stop compiling until
  they are converted, so the compiler produces the audit list.
- `ptr<void>` (108 sites) is the part the compiler can't check. Each one gets
  reviewed, and most are genuinely opaque.
- Host structs placed over guest memory get a field table
  (`AudioStreamBasicDescription`, `AudioTimeStamp`, `statfs`, `utsname`...) and
  are copied in and out through it, not overlaid.
- `core/objc/Encoding.cpp` already repacks each struct field between guest and
  host for ObjC calls. Adding the swap there covers every ObjC struct argument.
- `wchar_t`, `UniChar`, `unichar` and `CGGlyph` arrays (22 sites) convert element by element.
- `memcpy` (134) and `reinterpret_cast` (134) in `core/` get reviewed in Phase 2.
  `GuestHeap`'s metadata is private to the host and can stay as it is.

## Architecture changes

### Guest architecture

Add `B32_GUEST_ARCH=ppc` and `B32_GUEST_PPC`, building its own shell as i386
does, with `UNICORN_ARCH=ppc` and a new `core/arch/ppc/PowerCpu.{h,cpp}`.

- `arg(i)`: `r3+i` for the first 8 words, then `24(r1) + 4i`. `Args::f32`/`f64`
  take the next FPR and still advance 1 or 2 words; in a `va_list` they read words.
- `Args::u64` and the 64-bit result are high word first.
- `structReturnedInMemory` is true above 8 bytes, and `popStructPointer` does
  nothing.
- `kFloatResultsInFpu = true`; `kLongDoubleWords = 4`, with `$LDBL128` thunks
  converting double-double to host `long double`.
- Thunk stub: `sc` then `blr`, which fits the existing 8 bytes. The index comes
  from the stub address, and the return is the guest's own instruction.
- `kMethodStubSize` is 16 and PowerPC needs 24 (`lis`/`ori` twice, `mtctr`,
  `bctr`), so it becomes per-architecture.
- `setjmp`/`longjmp` save `r1`, `r13`–`r31`, `f14`–`f31`, `v20`–`v31`, CR and LR
  in the guest's larger `jmp_buf`.
- Page 0xFFFEF000 holds the ObjC runtime page, so `bla 0xfffeff00` reaches a
  stub. The commpage at 0xFFFF8000 gets stubs for anything real apps call.

### Loader

- `kGuestCpuType = CPU_TYPE_POWERPC`, with `sliceRank` preferring `ppc7400`, then
  `ppc750`, then `ppc_all`. `ppc970` (G5-only) is out of scope.
- Headers, load commands, `nlist` and relocations are read through swapping
  accessors. Today they are `memcpy`d over host structs, so this is most of the
  loader's diff.
- `LC_UNIXTHREAD` with `PPC_THREAD_STATE`, where `srr0` is the entry point.
- Relocations: `PPC_RELOC_VANILLA` as today, `PB_LA_PTR` skipped, and for slid
  bundled dylibs the `HI16`/`LO16`/`HA16` and `*_SECTDIFF` families.
- `S_SYMBOL_STUBS` with `reserved2` of 20 or 32 need no rewriting; binding the
  lazy pointers is enough.

### OpenGL

The general design, for games that use vertex arrays. World of Goo is
immediate mode and needs only the first two bullets and the pointer calls
listed under "Target"; the rest waits for an app that needs it.

- **Textures:** set `GL_UNPACK_SWAP_BYTES` once and combine it with the guest's
  own setting. Multi-byte pixel types then convert in the driver; `GL_UNSIGNED_BYTE`
  and compressed formats are unaffected.
- **Immediate mode:** `glVertex3f` and friends arrive in registers and need
  nothing.
- **Pointer-taking calls:** `glVertex3fv`, `glMultMatrixf`, `glLightfv`,
  `glUniform*`, `glGet*`. The table in `opengl_table.inc` records only `p`.
  Extend `tools/gen-gl-table.py` to record element type and count, from the
  function name where it can.
- **Client arrays:** at draw time, copy `[first, first+count)` (or the index
  range) into a scratch buffer with each attribute swapped by its declared type,
  and point GL at that.
- **Index arrays:** swap 16- and 32-bit indices at draw.
- **VBOs:** the raw `glBufferData` bytes have no known layout until a
  `gl*Pointer` describes them, and interleaved formats mix widths. Keep a guest
  copy and treat them as client arrays at first, then cache the converted result
  by buffer generation and format. `glMapBuffer` writes to the guest copy.

### Audio

Host output wants native-endian samples. `hal.mm`, `audiounit.mm` and
`audioqueue.mm` (49 of the `ptr<>` sites) convert at the callback boundary,
where the guest's format description says what the bytes are.

### Carbon

`core/appkit/carbon*.mm` works unchanged where it goes through `Args`. Structs
such as `Rect`, `Point` and `EventRecord` move through typed accessors. GWorld
pixel maps are big-endian ARGB. `#pragma options align=mac68k` layouts apply
just as on i386.

## Target: World of Goo 1.30

`World of Goo.app` (2D Boy, 2008) is a good first target: a 1.4 MB `ppc_7400`
executable with no `i386` slice, no copy protection (the bundle isn't even
signed), and a small import surface. Measured from its Mach-O:

- **Loading:** `MH_EXECUTE`, `LC_UNIXTHREAD` (entry `0x2600`), `__PAGEZERO` at
  4 KB, text at `0x1000`, flags `0x10085` (no PIE). Imports bind through
  `__symbol_stub1` (16-byte non-PIC stubs) and `__la_symbol_ptr` (253 of them)
  plus `__nl_symbol_ptr`; there are 278 symbols and 651 indirect entries.
- **Libraries:** Carbon, AGL, OpenGL, ApplicationServices, CoreServices,
  CoreFoundation, IOKit, `libstdc++.6`, `libgcc_s.1`, `libmx`, `libcurl`,
  `libSystem`, and a bundled `libirrklang.dylib`.
- **260 imported symbols.** 188 already match an existing thunk by name; the 72
  that don't are an upper bound (data symbols and renamed functions are counted
  as misses), and about 30 of them are `libstdc++` string and stream members.
- **No Objective-C at all.** It is a Carbon app: `RunApplicationEventLoop`,
  event handlers, one window from a nib, a menu bar from a nib, `HIAboutBox`.
  The legacy ObjC reader and the AppKit nib path are not needed for it.
- **OpenGL is immediate mode.** `glBegin`, `glVertex3f`, `glTexCoord2f` and
  `glColor4f` take their values in registers, and there are no vertex arrays or
  buffers. The only pointer-taking calls are `glLoadMatrixf`, `glMultMatrixf`,
  `glGetFloatv`, `glGetBooleanv` and `glTexImage2D`. This replaces the large
  OpenGL conversion in the original plan with five small cases.
- **C++:** it catches exceptions (`__cxa_begin_catch`, `_Unwind_Resume`,
  `__gxx_personality_v0`) but never throws one itself (`__cxa_throw` isn't
  imported), so DWARF unwinding should rarely run.
- **Network:** `libcurl` (10 calls) for something optional. The first goal is a
  clean failure, so `curl_easy_init` returns NULL.
- **Audio:** irrKlang is a fat `ppc`+`i386` dylib. The game calls one function,
  `createIrrKlangDevice`; the rest is the dylib's own C++ vtables, mixing in
  guest code and writing to a CoreAudio HAL IO proc (`AudioDeviceAddIOProc`
  and six more). It loads as a guest library, its `ppc` slice, and the HAL
  buffers it fills are big-endian.
- **Direct hardware paths:** `CGDisplayCapture`, `CGDisplaySwitchToMode` and
  `CGDisplayFade` for fullscreen, and `IOKit` for something not yet identified
  (it imports nothing by name from IOKit, so likely only a link dependency).

## Phases

Each phase ends with a test that fails without it. The order follows World of
Goo: nothing that it doesn't reach is built before the game runs.

### Phase 0: CPU

`B32_GUEST_ARCH=ppc` builds. Fix the patch's symbol rename, patch the timebase
and AltiVec register access, add `PowerCpu`.
**Exit:** the spike cases as `ctest` tests under `tests/guest/ppc`, including
4-engine atomics and a running timebase.

### Phase 1: Big-endian memory, loader, ABI

Swapping `GuestMemory`, compile errors on typed `ptr<>`, the big-endian Mach-O
reader, `PPC_THREAD_STATE`, stubs, the `Args` rules, `setjmp`.
**Exit:** `b32-inspect` reads World of Goo and reports its imports, and a
hand-assembled PowerPC Mach-O calls `printf` with mixed int, double and 64-bit
arguments and prints the right text. ABI table confirmed or corrected against
the real binary's call sites.

### Phase 2: The audit

All 84 typed `ptr<>` sites, the `ptr<void>` review, struct field tables,
`wchar_t` and Unicode arrays, `memcpy` and `reinterpret_cast` review.
**Exit:** every file in `core/` the PowerPC build compiles has been reviewed,
and the guest tests that can be assembled for PowerPC pass.

### Phase 3: The runtime World of Goo needs

The `libstdc++` string and stream thunks, the 72 candidate imports, `libmx`
math, `__keymgr` and `__sF`, and the `curl` stubs.
**Exit:** World of Goo runs through its static initializers and reaches
`main` without an unimplemented-import fatal. `b32-inspect` shows
`unimplemented imports: 0`.

### Phase 4: Carbon, AGL and OpenGL

The Carbon event loop, window, nib and menu bar for a `ppc` guest, big-endian
`Rect`/`Point`/`EventRecord`, AGL contexts, and the five pointer-taking GL
calls with `GL_UNPACK_SWAP_BYTES` for textures.
**Exit:** the game's window opens and draws its first frame. Compare against the
same frame from the i386 build of a test scene.

### Phase 5: Audio

Load `libirrklang.dylib`'s `ppc` slice as a guest library, the CoreAudio HAL
IO proc with big-endian buffers.
**Exit:** the game's music plays at the right pitch without noise.

### Phase 6: Play

World of Goo starts, gets through a level with the mouse, and quits cleanly.
**Exit:** a recorded run, and the remaining thunk tail as a list.

### Later: other PowerPC apps

The legacy ObjC reader on big-endian images, struct swapping in
`Encoding.cpp`, the runtime page at `0xFFFEFF00`, AppKit nibs, Carbon beyond
what the game uses, and a PEF/CFM loader for Mac OS X 10.0-10.3 Carbon games
(transition vectors, the TOC register and `CarbonLib` imports). Each waits for
a specific app that needs it.

## Guest test toolchain

Nothing on this machine can build PowerPC Mach-O today. Xcode's clang refuses
the triple (`powerpc-apple-*`, `-arch ppc`). Clang will still compile `powerpc-unknown-linux-gnu` ELF objects,
which is how the spike was built, but that is the SysV ABI: it passes floats and
structs differently, and has no Mach-O or legacy ObjC.

1. **Phases 0-2: assembly plus a small linker.** PowerPC assembly through clang's
   ELF output, then `tools/ppc-link.py` to write a Mach-O, as `i386-link.py` does.
   Enough for CPU, loader and ABI tests, and hand-written assembly is the only way
   to assert exact register use anyway.
2. **Paths the game doesn't reach: a real Darwin PowerPC compiler.** Xcode 2.5–3.x's GCC
   running in a Mac OS X 10.4 or 10.5 guest on `qemu-system-ppc`, which is already
   installed through Homebrew. The same VM runs the test binaries for reference
   output. Built binaries go in `tests/guest/prebuilt-ppc/`, so `ctest` needs no VM.

## Risks and open questions

- **Vertex data on VBO-heavy games.** Swapping on each draw is the main performance
  unknown. Measure it early in Phase 5, on a real game if possible.
- **`ptr<void>` misses.** A missed conversion produces wrong numbers, not a crash,
  so these bugs will be slow to find. Comparing against i386 on universal apps is
  the best defense.
- **C++ exceptions.** PowerPC apps built with GCC use DWARF unwinding from
  `__eh_frame`. `core/thunks/cxxabi.cpp` has SjLj hooks that are fatal when
  raised, so this needs real work if a target app throws through guest frames.
- **Floating-point speed.** FP and AltiVec run through helpers and were not
  measured. Audio and physics code leans on both.
- **Inlined OS details.** Direct commpage calls and `mfspr` thread reads get
  handled as real apps turn them up.
- **GPLv2.** The same Unicorn dependency already accepted for the Mac shell.

Decision needed:

- **A Mac OS X 10.4 or 10.5 PowerPC install image and Xcode** would let
  later phases build PowerPC test programs with a real Darwin compiler under
  `qemu-system-ppc` (already installed). It isn't needed to reach World of Goo,
  which is itself a PowerPC binary, but it is the only way to test paths the game
  doesn't use. Until one exists, tests are hand-written assembly plus the game.

## Rough size

New code before a real app runs: about 5–8 k lines (PowerPC CPU and ABI ~0.6 k,
Unicorn patches ~0.2 k, big-endian loader ~0.5 k, the audit and struct tables
~1.5 k, OpenGL conversion ~1.5 k, audio ~0.3 k, test linker and tests ~1.5 k),
less than i386 because the runtime, shell and Carbon layer exist. Then the
per-app tail, as with every other guest.
