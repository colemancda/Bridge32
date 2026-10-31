// Grand Central Dispatch on the host's libdispatch. Queues, groups,
// semaphores and sources are host objects (OS_dispatch_*) that the bridge
// proxies like any other; guest blocks become host blocks (core/objc/Blocks.h),
// so the host's queues run guest code on their own threads, each of which
// gets a guest CPU when it first calls in.
//
// What needs converting by hand: dispatch_time_t is 64-bit (two guest
// words), dispatch_once's predicate is a 32-bit long, the *_f variants take
// guest functions, and the framework's globals (_dispatch_main_q, the queue
// attributes and source types) are guest variables aliased to the host's.

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/objc/Bridge.h"

#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>

#include <mutex>

using namespace b32;

namespace {

objc::Bridge &bridge(Call &c) { return c.rt.bridge(); }
template <typename T> T object(Call &c) { return (T)bridge(c).toHost(c.args.ptr()); }
GuestAddr guest(Call &c, id object) { return bridge(c).toGuest(object); }

// A guest function and its context, for the *_f variants.
struct GuestFunction {
    GuestAddr fn, context;
};
void callGuestFunction(void *data) {
    auto *f = static_cast<GuestFunction *>(data);
    Runtime::threadCpu().call(f->fn, {f->context});
    delete f;
}
GuestFunction *guestFunction(Call &c) {
    GuestAddr context = c.args.ptr();
    return new GuestFunction{c.args.ptr(), context};
}

bool isData(Call &c, GuestAddr p, const char *symbol) { return p && p == c.rt.dataSymbol(symbol); }

dispatch_queue_attr_t queueAttr(Call &c, GuestAddr attr) {
    return isData(c, attr, "__dispatch_queue_attr_concurrent") ? DISPATCH_QUEUE_CONCURRENT : DISPATCH_QUEUE_SERIAL;
}

dispatch_source_type_t sourceType(Call &c, GuestAddr type) {
    if (isData(c, type, "__dispatch_source_type_timer")) return DISPATCH_SOURCE_TYPE_TIMER;
    if (isData(c, type, "__dispatch_source_type_data_add")) return DISPATCH_SOURCE_TYPE_DATA_ADD;
    if (isData(c, type, "__dispatch_source_type_data_or")) return DISPATCH_SOURCE_TYPE_DATA_OR;
    if (isData(c, type, "__dispatch_source_type_read")) return DISPATCH_SOURCE_TYPE_READ;
    if (isData(c, type, "__dispatch_source_type_write")) return DISPATCH_SOURCE_TYPE_WRITE;
    if (isData(c, type, "__dispatch_source_type_signal")) return DISPATCH_SOURCE_TYPE_SIGNAL;
    if (isData(c, type, "__dispatch_source_type_vnode")) return DISPATCH_SOURCE_TYPE_VNODE;
    fatal("unsupported dispatch source type 0x%08x", type);
}

}  // namespace

// --- the framework's globals ----------------------------------------------------------------

// dispatch_get_main_queue() is &_dispatch_main_q.
B32_DATA(__dispatch_main_q, 64) { rt.bridge().aliasObject(addr, dispatch_get_main_queue()); }
// Compared by address in queueAttr() and sourceType().
B32_DATA(__dispatch_queue_attr_concurrent, 16) {}
B32_DATA(__dispatch_source_type_timer, 16) {}
B32_DATA(__dispatch_source_type_data_add, 16) {}
B32_DATA(__dispatch_source_type_data_or, 16) {}
B32_DATA(__dispatch_source_type_read, 16) {}
B32_DATA(__dispatch_source_type_write, 16) {}
B32_DATA(__dispatch_source_type_signal, 16) {}
B32_DATA(__dispatch_source_type_vnode, 16) {}

// --- queues ------------------------------------------------------------------------------------

B32_THUNK(_dispatch_get_global_queue) {
    long priority = c.args.i32();
    c.ret(guest(c, dispatch_get_global_queue(priority, c.args.u32())));
}
B32_THUNK(_dispatch_get_main_queue) { c.ret(guest(c, dispatch_get_main_queue())); }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
B32_THUNK(_dispatch_get_current_queue) { c.ret(guest(c, dispatch_get_current_queue())); }
#pragma clang diagnostic pop

// dispatch_queue_t dispatch_queue_create(const char *label, dispatch_queue_attr_t attr)
B32_THUNK(_dispatch_queue_create) {
    GuestAddr label = c.args.ptr();
    dispatch_queue_attr_t attr = queueAttr(c, c.args.ptr());
    c.ret(guest(c, dispatch_queue_create(label ? c.mem.cstr(label) : nullptr, attr)));
}

B32_THUNK(_dispatch_queue_get_label) {
    const char *label = dispatch_queue_get_label(object<dispatch_queue_t>(c));
    c.ret(label ? c.rt.internString(label) : 0);
}

B32_THUNK(_dispatch_set_target_queue) {
    auto obj = object<dispatch_object_t>(c);
    dispatch_set_target_queue(obj, object<dispatch_queue_t>(c));
}

namespace {
// libdispatch crashes on a null queue or block; say which, with the guest's values.
void checkQueueAndBlock(Call &c, const char *fn, id queue, id block) {
    if (!queue || !block)
        fatal("%s with %s (queue 0x%08x, block 0x%08x, from 0x%08x)", fn, queue ? "no block" : "no queue",
              c.cpu.reg(0), c.cpu.reg(1), c.cpu.reg(Cpu::LR));
}
}  // namespace

B32_THUNK(_dispatch_async) {
    auto queue = object<dispatch_queue_t>(c);
    auto block = object<dispatch_block_t>(c);
    checkQueueAndBlock(c, "dispatch_async", queue, block);
    dispatch_async(queue, block);
}
B32_THUNK(_dispatch_sync) {
    auto queue = object<dispatch_queue_t>(c);
    auto block = object<dispatch_block_t>(c);
    checkQueueAndBlock(c, "dispatch_sync", queue, block);
    dispatch_sync(queue, block);
}
B32_THUNK(_dispatch_barrier_async) {
    auto queue = object<dispatch_queue_t>(c);
    dispatch_barrier_async(queue, object<dispatch_block_t>(c));
}
B32_THUNK(_dispatch_barrier_sync) {
    auto queue = object<dispatch_queue_t>(c);
    dispatch_barrier_sync(queue, object<dispatch_block_t>(c));
}

// void dispatch_after(dispatch_time_t when, dispatch_queue_t, dispatch_block_t)
B32_THUNK(_dispatch_after) {
    dispatch_time_t when = c.args.u64();
    auto queue = object<dispatch_queue_t>(c);
    dispatch_after(when, queue, object<dispatch_block_t>(c));
}

// void dispatch_apply(size_t iterations, dispatch_queue_t, void (^block)(size_t))
B32_THUNK(_dispatch_apply) {
    size_t iterations = c.args.u32();
    auto queue = object<dispatch_queue_t>(c);
    dispatch_apply(iterations, queue, object<void (^)(size_t)>(c));
}

B32_THUNK(_dispatch_async_f) {
    auto queue = object<dispatch_queue_t>(c);
    dispatch_async_f(queue, guestFunction(c), callGuestFunction);
}
B32_THUNK(_dispatch_sync_f) {
    auto queue = object<dispatch_queue_t>(c);
    dispatch_sync_f(queue, guestFunction(c), callGuestFunction);
}
B32_THUNK(_dispatch_after_f) {
    dispatch_time_t when = c.args.u64();
    auto queue = object<dispatch_queue_t>(c);
    dispatch_after_f(when, queue, guestFunction(c), callGuestFunction);
}

// void dispatch_once(dispatch_once_t *predicate, dispatch_block_t): the
// predicate is a 32-bit long, ~0 once done. The block runs right here.
namespace {
std::recursive_mutex onceLock;
}
B32_THUNK(_dispatch_once) {
    GuestAddr predicate = c.args.ptr(), block = c.args.ptr();
    if (c.mem.read<int32_t>(predicate) == -1) return;
    std::lock_guard guard(onceLock);
    if (c.mem.read<int32_t>(predicate) == -1) return;
    c.cpu.call(c.mem.read<uint32_t>(block + 12), {block});  // the block's invoke
    c.mem.write<int32_t>(predicate, -1);
}
B32_THUNK(_dispatch_once_f) {
    GuestAddr predicate = c.args.ptr(), context = c.args.ptr(), fn = c.args.ptr();
    if (c.mem.read<int32_t>(predicate) == -1) return;
    std::lock_guard guard(onceLock);
    if (c.mem.read<int32_t>(predicate) == -1) return;
    c.cpu.call(fn, {context});
    c.mem.write<int32_t>(predicate, -1);
}

// --- objects -------------------------------------------------------------------------------------

B32_THUNK(_dispatch_retain) { [object<id>(c) retain]; }
B32_THUNK(_dispatch_release) { [object<id>(c) release]; }
B32_THUNK(_dispatch_suspend) { dispatch_suspend(object<dispatch_object_t>(c)); }
B32_THUNK(_dispatch_resume) { dispatch_resume(object<dispatch_object_t>(c)); }

// --- time --------------------------------------------------------------------------------------

// dispatch_time_t dispatch_time(dispatch_time_t when, int64_t delta)
B32_THUNK(_dispatch_time) {
    dispatch_time_t when = c.args.u64();
    c.ret64(dispatch_time(when, int64_t(c.args.u64())));
}

// dispatch_time_t dispatch_walltime(const struct timespec *when, int64_t delta):
// the guest's timespec is two 32-bit words.
B32_THUNK(_dispatch_walltime) {
    GuestAddr when = c.args.ptr();
    int64_t delta = int64_t(c.args.u64());
    if (!when) {
        c.ret64(dispatch_walltime(nullptr, delta));
        return;
    }
    struct timespec ts = {c.mem.read<int32_t>(when), c.mem.read<int32_t>(when + 4)};
    c.ret64(dispatch_walltime(&ts, delta));
}

// --- groups ----------------------------------------------------------------------------------

B32_THUNK(_dispatch_group_create) { c.ret(guest(c, dispatch_group_create())); }
B32_THUNK(_dispatch_group_enter) { dispatch_group_enter(object<dispatch_group_t>(c)); }
B32_THUNK(_dispatch_group_leave) { dispatch_group_leave(object<dispatch_group_t>(c)); }
B32_THUNK(_dispatch_group_async) {
    auto group = object<dispatch_group_t>(c);
    auto queue = object<dispatch_queue_t>(c);
    dispatch_group_async(group, queue, object<dispatch_block_t>(c));
}
B32_THUNK(_dispatch_group_async_f) {
    auto group = object<dispatch_group_t>(c);
    auto queue = object<dispatch_queue_t>(c);
    dispatch_group_async_f(group, queue, guestFunction(c), callGuestFunction);
}
B32_THUNK(_dispatch_group_notify) {
    auto group = object<dispatch_group_t>(c);
    auto queue = object<dispatch_queue_t>(c);
    dispatch_group_notify(group, queue, object<dispatch_block_t>(c));
}
// long dispatch_group_wait(dispatch_group_t, dispatch_time_t timeout)
B32_THUNK(_dispatch_group_wait) {
    auto group = object<dispatch_group_t>(c);
    c.ret(uint32_t(dispatch_group_wait(group, c.args.u64())));
}

// --- semaphores --------------------------------------------------------------------------------

B32_THUNK(_dispatch_semaphore_create) { c.ret(guest(c, dispatch_semaphore_create(c.args.i32()))); }
B32_THUNK(_dispatch_semaphore_signal) { c.ret(uint32_t(dispatch_semaphore_signal(object<dispatch_semaphore_t>(c)))); }
// long dispatch_semaphore_wait(dispatch_semaphore_t, dispatch_time_t timeout)
B32_THUNK(_dispatch_semaphore_wait) {
    auto semaphore = object<dispatch_semaphore_t>(c);
    c.ret(uint32_t(dispatch_semaphore_wait(semaphore, c.args.u64())));
}

// --- sources -----------------------------------------------------------------------------------

// dispatch_source_t dispatch_source_create(dispatch_source_type_t, uintptr_t handle,
//                                          unsigned long mask, dispatch_queue_t)
B32_THUNK(_dispatch_source_create) {
    dispatch_source_type_t type = sourceType(c, c.args.ptr());
    uintptr_t handle = c.args.u32();
    unsigned long mask = c.args.u32();
    c.ret(guest(c, dispatch_source_create(type, handle, mask, object<dispatch_queue_t>(c))));
}
// void dispatch_source_set_timer(dispatch_source_t, dispatch_time_t start, uint64_t interval, uint64_t leeway)
B32_THUNK(_dispatch_source_set_timer) {
    auto source = object<dispatch_source_t>(c);
    dispatch_time_t start = c.args.u64();
    uint64_t interval = c.args.u64();
    dispatch_source_set_timer(source, start, interval, c.args.u64());
}
B32_THUNK(_dispatch_source_set_event_handler) {
    auto source = object<dispatch_source_t>(c);
    dispatch_source_set_event_handler(source, object<dispatch_block_t>(c));
}
B32_THUNK(_dispatch_source_set_cancel_handler) {
    auto source = object<dispatch_source_t>(c);
    dispatch_source_set_cancel_handler(source, object<dispatch_block_t>(c));
}
B32_THUNK(_dispatch_source_cancel) { dispatch_source_cancel(object<dispatch_source_t>(c)); }
B32_THUNK(_dispatch_source_get_data) { c.ret(uint32_t(dispatch_source_get_data(object<dispatch_source_t>(c)))); }
B32_THUNK(_dispatch_source_merge_data) {
    auto source = object<dispatch_source_t>(c);
    dispatch_source_merge_data(source, c.args.u32());
}

// --- queue-specific values -------------------------------------------------------------------
// Keys and values are guest words, kept as is (the guest only compares them).
// A guest destructor isn't run: the value is the guest's to free.

// void dispatch_queue_set_specific(dispatch_queue_t, const void *key, void *context, dispatch_function_t)
B32_THUNK(_dispatch_queue_set_specific) {
    auto queue = object<dispatch_queue_t>(c);
    auto key = reinterpret_cast<const void *>(uintptr_t(c.args.ptr()));
    auto context = reinterpret_cast<void *>(uintptr_t(c.args.ptr()));
    dispatch_queue_set_specific(queue, key, context, nullptr);
}
B32_THUNK(_dispatch_queue_get_specific) {
    auto queue = object<dispatch_queue_t>(c);
    auto key = reinterpret_cast<const void *>(uintptr_t(c.args.ptr()));
    c.ret(uint32_t(uintptr_t(dispatch_queue_get_specific(queue, key))));
}
B32_THUNK(_dispatch_get_specific) {
    auto key = reinterpret_cast<const void *>(uintptr_t(c.args.ptr()));
    c.ret(uint32_t(uintptr_t(dispatch_get_specific(key))));
}
