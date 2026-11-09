// libcurl, for the old Mac apps that link it to phone home (World of Goo's
// score and update checks). There's no network layer behind it yet: a handle
// is never handed out, so the app takes its offline path, and every call that
// could be made without one answers "nothing happened".

#include "Thunks.h"

using namespace b32;

B32_THUNK(_curl_global_init) { c.ret(0); }
B32_THUNK(_curl_global_cleanup) {}
// CURL *curl_easy_init(void): NULL, which is how it reports it couldn't.
B32_THUNK(_curl_easy_init) { c.ret(0); }
B32_THUNK(_curl_easy_cleanup) {}
// CURLE_FAILED_INIT (2) for what needs a handle.
B32_THUNK(_curl_easy_setopt) { c.ret(2); }
B32_THUNK(_curl_easy_perform) { c.ret(2); }
// struct curl_slist *curl_slist_append(list, const char *): no list
B32_THUNK(_curl_slist_append) { c.ret(0); }
B32_THUNK(_curl_slist_free_all) {}
// CURL_FORMADD_MEMORY (1)
B32_THUNK(_curl_formadd) { c.ret(1); }
B32_THUNK(_curl_formfree) {}
