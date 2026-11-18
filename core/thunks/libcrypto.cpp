// OpenSSL's libcrypto (0.9.7, which Mac OS X shipped), as far as the games that link it get.

#include "core/thunks/Thunks.h"

using namespace b32;

// int CRYPTO_set_mem_functions(malloc, realloc, free): 1 for done. Nothing here allocates on the
// guest's behalf, so there is nothing to switch over.
B32_THUNK(_CRYPTO_set_mem_functions) { c.ret(1); }
