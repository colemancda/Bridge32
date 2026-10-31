#pragma once

namespace b32::gl {

// Loads the host's OpenGL ES (and with it EAGLContext and CAEAGLLayer).
// Must run before a guest that uses EAGL is loaded, so its class
// references bind to the host classes.
void loadHostOpenGLES();

}  // namespace b32::gl
