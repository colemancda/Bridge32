// SQLite on the host's libsqlite3. Database and statement pointers are guest
// handles; text read from a statement is copied into guest memory that stays
// valid until the statement steps, resets or is finalized, as SQLite promises.

#include "CTable.h"
#include "Thunks.h"
#include "core/Log.h"
#include "core/Runtime.h"

#include <dlfcn.h>
#include <sqlite3.h>

#include <mutex>
#include <unordered_map>
#include <vector>

using namespace b32;

namespace {

std::mutex lock;
std::unordered_map<sqlite3_stmt *, std::vector<GuestAddr>> columnText;  // guest copies per statement

uint32_t handleFor(void *p) { return hostHandle(p); }
template <typename T> T *object(uint32_t h) { return static_cast<T *>(hostPointer(h)); }

void releaseText(Call &c, sqlite3_stmt *stmt) {
    std::lock_guard guard(lock);
    auto it = columnText.find(stmt);
    if (it == columnText.end()) return;
    for (GuestAddr a : it->second) c.heap.free(a);
    columnText.erase(it);
}

void forget(void *p) { forgetHostHandle(p); }

}  // namespace

// int sqlite3_open(const char *filename, sqlite3 **ppDb)
B32_THUNK(_sqlite3_open) {
    const char *path = c.mem.cstr(c.args.ptr());
    GuestAddr out = c.args.ptr();
    sqlite3 *db = nullptr;
    int rc = sqlite3_open(path, &db);
    c.mem.write<uint32_t>(out, handleFor(db));
    if (rc != SQLITE_OK) log("sqlite3_open(%s) failed: %s", path, db ? sqlite3_errmsg(db) : "?");
    c.ret(uint32_t(rc));
}

B32_THUNK(_sqlite3_close) {
    sqlite3 *db = object<sqlite3>(c.args.u32());
    int rc = sqlite3_close(db);
    if (rc == SQLITE_OK) forget(db);
    c.ret(uint32_t(rc));
}

// int sqlite3_prepare_v2(sqlite3 *, const char *sql, int nByte, sqlite3_stmt **, const char **tail)
B32_THUNK(_sqlite3_prepare_v2) {
    sqlite3 *db = object<sqlite3>(c.args.u32());
    GuestAddr sql = c.args.ptr();
    int bytes = c.args.i32();
    GuestAddr outStmt = c.args.ptr();
    GuestAddr outTail = c.args.ptr();
    sqlite3_stmt *stmt = nullptr;
    const char *tail = nullptr;
    int rc = sqlite3_prepare_v2(db, c.mem.cstr(sql), bytes, &stmt, &tail);
    if (outStmt) c.mem.write<uint32_t>(outStmt, handleFor(stmt));
    // The tail points into the guest's own SQL string.
    if (outTail) c.mem.write<uint32_t>(outTail, tail ? c.mem.guestAddrOf(tail) : 0);
    if (rc != SQLITE_OK) log("sqlite3_prepare_v2 failed: %s", sqlite3_errmsg(db));
    c.ret(uint32_t(rc));
}

B32_THUNK(_sqlite3_step) {
    sqlite3_stmt *stmt = object<sqlite3_stmt>(c.args.u32());
    releaseText(c, stmt);
    c.ret(uint32_t(sqlite3_step(stmt)));
}

B32_THUNK(_sqlite3_reset) {
    sqlite3_stmt *stmt = object<sqlite3_stmt>(c.args.u32());
    releaseText(c, stmt);
    c.ret(uint32_t(sqlite3_reset(stmt)));
}

B32_THUNK(_sqlite3_finalize) {
    sqlite3_stmt *stmt = object<sqlite3_stmt>(c.args.u32());
    releaseText(c, stmt);
    forget(stmt);
    c.ret(uint32_t(sqlite3_finalize(stmt)));
}

// const unsigned char *sqlite3_column_text(sqlite3_stmt *, int iCol)
B32_THUNK(_sqlite3_column_text) {
    sqlite3_stmt *stmt = object<sqlite3_stmt>(c.args.u32());
    int column = c.args.i32();
    const unsigned char *text = sqlite3_column_text(stmt, column);
    if (!text) {
        c.ret(0);
        return;
    }
    int length = sqlite3_column_bytes(stmt, column);
    GuestAddr copy = c.heap.alloc(uint32_t(length + 1));
    c.mem.copyIn(copy, text, uint32_t(length + 1));
    {
        std::lock_guard guard(lock);
        columnText[stmt].push_back(copy);
    }
    c.ret(copy);
}

// int sqlite3_bind_text(sqlite3_stmt *, int, const char *, int n, void (*destructor)(void *))
// SQLite gets its own copy; a guest destructor runs as soon as it's done.
B32_THUNK(_sqlite3_bind_text) {
    sqlite3_stmt *stmt = object<sqlite3_stmt>(c.args.u32());
    int index = c.args.i32();
    GuestAddr text = c.args.ptr();
    int length = c.args.i32();
    GuestAddr destructor = c.args.ptr();
    int rc = sqlite3_bind_text(stmt, index, text ? c.mem.cstr(text) : nullptr, length, SQLITE_TRANSIENT);
    if (destructor && destructor != 0xffffffff) c.cpu.call(destructor, {text});
    c.ret(uint32_t(rc));
}

B32_THUNK(_sqlite3_errmsg) {
    sqlite3 *db = object<sqlite3>(c.args.u32());
    c.ret(c.rt.internString(sqlite3_errmsg(db)));
}

namespace {
void *sqliteLibrary() { return RTLD_DEFAULT; }

constexpr CFunction kSqlite[] = {
    {"sqlite3_column_int", "i:hi"}, {"sqlite3_column_double", "d:hi"}, {"sqlite3_column_count", "i:h"},
    {"sqlite3_column_type", "i:hi"}, {"sqlite3_column_bytes", "i:hi"}, {"sqlite3_bind_int", "i:hii"},
    {"sqlite3_bind_double", "i:hid"}, {"sqlite3_bind_null", "i:hi"}, {"sqlite3_clear_bindings", "i:h"},
    {"sqlite3_changes", "i:h"}, {"sqlite3_errcode", "i:h"},
};
}  // namespace

B32_C_FUNCTIONS(kSqlite, sqliteLibrary);
