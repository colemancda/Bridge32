// Guest threads for the APIs that make their own (Multiprocessing Services' tasks), started as pthread_create
// starts them (pthread.cpp).
#pragma once

#include "core/mem/GuestMemory.h"

#include <cstdint>
#include <functional>

namespace b32 {

class Runtime;

// Runs fn(arg) on a new guest thread, detached; `finished` is called on that thread with what fn returned
// (or what it exited with). The answer is the thread's pthread_t.
GuestAddr startGuestThread(Runtime &rt, GuestAddr fn, GuestAddr arg, std::function<void(uint32_t result)> finished);
// The pthread_t of the calling thread when the guest started it (pthread_create, startGuestThread), else 0.
GuestAddr startedGuestThread();

}  // namespace b32
