#pragma once

namespace b32 {
struct Call;
}

namespace b32::gl {

// Loads the host's OpenGL ES (and with it EAGLContext and CAEAGLLayer).
// Must run before a guest that uses EAGL is loaded, so its class
// references bind to the host classes.
void loadHostOpenGLES();

// Runs `hook` each time the guest presents a frame, on the guest's thread
// and before the frame is shown: once per game update, for game-specific
// input (core/games). Register before the guest runs.
using PresentHook = void (*)(Call &c);
void addPresentHook(PresentHook hook);

}  // namespace b32::gl
