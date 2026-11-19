// setjmp and longjmp for the PowerPC guest, in the guest's own jmp_buf (PowerCpu::saveJmpBuf has
// the layout). The signal mask isn't saved: nothing blocks signals in a guest.

#include "PowerCpu.h"

#include "core/thunks/Thunks.h"

namespace b32 {
namespace {
PowerCpu &power(Call &c) { return static_cast<PowerCpu &>(c.cpu); }

void setjmpHere(Call &c) {
    power(c).saveJmpBuf(c.args.ptr());
    c.ret(0);
}
void longjmpHere(Call &c) {
    GuestAddr buf = c.args.ptr();
    c.cpu.longjmpTo(buf, c.args.u32());
}
}  // namespace

B32_THUNK(_setjmp) { setjmpHere(c); }
B32_THUNK(__setjmp) { setjmpHere(c); }
B32_THUNK(_sigsetjmp) { setjmpHere(c); }
B32_THUNK(_longjmp) { longjmpHere(c); }
B32_THUNK(__longjmp) { longjmpHere(c); }
B32_THUNK(_siglongjmp) { longjmpHere(c); }

}  // namespace b32
