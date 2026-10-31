// A hook between the GCD thunks and the UIKit layer, which isn't in every
// build: while it's set and returns true, a dispatch_async to the main queue
// is held by the hook instead of queued (see uikit::holdLaunchWork).
#pragma once

namespace b32 {

// Takes a dispatch_queue_t and a dispatch_block_t.
using MainQueueHold = bool (*)(void *queue, void *block);
extern MainQueueHold mainQueueHold;

}  // namespace b32
