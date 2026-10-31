// Blocks across the bridge.
//
// A guest block is a 32-bit Block_literal in guest memory:
//   { isa, flags, reserved, invoke, descriptor, captured variables... }
// with descriptor { reserved, size, [copy, dispose], [signature, layout] }.
// Its isa is one of the guest's _NSConcrete{Global,Stack,Malloc}Block, which
// are plain guest variables here.
//
// Ownership lives on the host. When a guest block crosses over it becomes a
// host block laid out by hand as libclosure expects, whose invoke is a libffi
// closure into the guest's invoke, so host code can copy, retain, release and
// call it like any block:
//  - a global guest block gets a global host block, made once and kept
//  - a stack guest block is first copied to the guest heap (running its copy
//    helper), and the copy gets a malloc'd host block that owns it: when the
//    host block's last reference goes, the guest copy's dispose helper runs
//    and the copy is freed
//  - a heap copy maps back to its host block
// A host block crossing the other way gets a guest block literal whose invoke
// is a thunk that calls the host block (it keeps the host block alive).
//
// The guest's own block runtime (_Block_copy, _Block_release, objc_retainBlock,
// [block copy]...) goes through the host blocks, so both sides agree on every
// block's lifetime.
#pragma once

#include "core/mem/GuestMemory.h"

#include <objc/objc.h>

namespace b32::objc {

class Bridge;

namespace blocks {

// Whether `object`'s isa is one of the guest's block classes.
bool isGuestBlock(Bridge &bridge, GuestAddr object);

// The host block for a guest block (+0: cached, or autoreleased when new), or
// nil if `object` isn't a guest block.
id toHost(Bridge &bridge, GuestAddr object);

// The guest block for a host block, or 0 if `object` isn't a block.
GuestAddr toGuest(Bridge &bridge, id object);

// The guest's Block_copy and Block_release.
GuestAddr copy(Bridge &bridge, GuestAddr block);
void release(Bridge &bridge, GuestAddr block);

}  // namespace blocks
}  // namespace b32::objc
