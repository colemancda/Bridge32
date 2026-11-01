// SQLite on the host's libsqlite3. Database and statement pointers are guest
// handles; text read from a statement is copied into guest memory that stays
// valid until the statement steps, resets or is finalized, as SQLite promises.

#include "CTable.h"
#include "Thunks.h"
#include "core/Log.h"
#include "core/Runtime.h"

#include <dlfcn.h>
#include <sqlite3.h>

#include <algorithm>
#include <cstring>
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

// int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs)
B32_THUNK(_sqlite3_open_v2) {
    const char *path = c.mem.cstr(c.args.ptr());
    GuestAddr out = c.args.ptr();
    int flags = c.args.i32();
    GuestAddr vfs = c.args.ptr();
    sqlite3 *db = nullptr;
    int rc = sqlite3_open_v2(path, &db, flags, vfs ? c.mem.cstr(vfs) : nullptr);
    c.mem.write<uint32_t>(out, handleFor(db));
    if (rc != SQLITE_OK) log("sqlite3_open_v2(%s) failed: %s", path, db ? sqlite3_errmsg(db) : "?");
    c.ret(uint32_t(rc));
}

B32_THUNK(_sqlite3_close) {
    sqlite3 *db = object<sqlite3>(c.args.u32());
    int rc = sqlite3_close(db);
    if (rc == SQLITE_OK) forget(db);
    c.ret(uint32_t(rc));
}

// int sqlite3_prepare_v2(sqlite3 *, const char *sql, int nByte, sqlite3_stmt **, const char **tail),
// and the legacy sqlite3_prepare with the same arguments.
namespace {
using Prepare = int (*)(sqlite3 *, const char *, int, sqlite3_stmt **, const char **);
void prepare(Call &c, Prepare function, const char *name) {
    sqlite3 *db = object<sqlite3>(c.args.u32());
    GuestAddr sql = c.args.ptr();
    int bytes = c.args.i32();
    GuestAddr outStmt = c.args.ptr();
    GuestAddr outTail = c.args.ptr();
    sqlite3_stmt *stmt = nullptr;
    const char *tail = nullptr;
    int rc = function(db, c.mem.cstr(sql), bytes, &stmt, &tail);
    if (outStmt) c.mem.write<uint32_t>(outStmt, handleFor(stmt));
    // The tail points into the guest's own SQL string.
    if (outTail) c.mem.write<uint32_t>(outTail, tail ? c.mem.guestAddrOf(tail) : 0);
    if (rc != SQLITE_OK) log("%s failed: %s", name, sqlite3_errmsg(db));
    c.ret(uint32_t(rc));
}
}  // namespace
B32_THUNK(_sqlite3_prepare_v2) { prepare(c, sqlite3_prepare_v2, "sqlite3_prepare_v2"); }
B32_THUNK(_sqlite3_prepare) { prepare(c, sqlite3_prepare, "sqlite3_prepare"); }

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

// const void *sqlite3_column_blob(sqlite3_stmt *, int): copied like text.
B32_THUNK(_sqlite3_column_blob) {
    sqlite3_stmt *stmt = object<sqlite3_stmt>(c.args.u32());
    int column = c.args.i32();
    const void *blob = sqlite3_column_blob(stmt, column);
    if (!blob) {
        c.ret(0);
        return;
    }
    int length = sqlite3_column_bytes(stmt, column);
    GuestAddr copy = c.heap.alloc(uint32_t(std::max(length, 1)));
    c.mem.copyIn(copy, blob, uint32_t(length));
    {
        std::lock_guard guard(lock);
        columnText[stmt].push_back(copy);
    }
    c.ret(copy);
}

B32_THUNK(_sqlite3_column_int64) {
    sqlite3_stmt *stmt = object<sqlite3_stmt>(c.args.u32());
    c.ret64(uint64_t(sqlite3_column_int64(stmt, c.args.i32())));
}

// int sqlite3_bind_int64(sqlite3_stmt *, int, sqlite3_int64)
B32_THUNK(_sqlite3_bind_int64) {
    sqlite3_stmt *stmt = object<sqlite3_stmt>(c.args.u32());
    int index = c.args.i32();
    c.ret(uint32_t(sqlite3_bind_int64(stmt, index, int64_t(c.args.u64()))));
}

// int sqlite3_bind_blob(sqlite3_stmt *, int, const void *, int n, void (*destructor)(void *))
B32_THUNK(_sqlite3_bind_blob) {
    sqlite3_stmt *stmt = object<sqlite3_stmt>(c.args.u32());
    int index = c.args.i32();
    GuestAddr blob = c.args.ptr();
    int length = c.args.i32();
    GuestAddr destructor = c.args.ptr();
    int rc = sqlite3_bind_blob(stmt, index, blob ? c.mem.ptr<void>(blob) : nullptr, length, SQLITE_TRANSIENT);
    if (destructor && destructor != 0xffffffff) c.cpu.call(destructor, {blob});
    c.ret(uint32_t(rc));
}

// int sqlite3_exec(sqlite3 *, const char *sql, int (*callback)(void *, int, char **, char **),
//                  void *arg, char **errmsg): each row's strings are copied into
// guest memory for the guest callback.
B32_THUNK(_sqlite3_exec) {
    sqlite3 *db = object<sqlite3>(c.args.u32());
    const char *sql = c.mem.cstr(c.args.ptr());
    struct Exec {
        Call *c;
        GuestAddr callback, arg;
    } exec{&c, c.args.ptr(), c.args.ptr()};
    GuestAddr errmsgOut = c.args.ptr();
    auto row = [](void *data, int count, char **values, char **names) -> int {
        auto *e = static_cast<Exec *>(data);
        if (!e->callback) return 0;
        Call &c = *e->c;
        std::vector<GuestAddr> copies;
        auto copy = [&](const char *s) {
            if (!s) return GuestAddr(0);
            GuestAddr g = c.heap.alloc(uint32_t(std::strlen(s) + 1));
            c.mem.copyIn(g, s, std::strlen(s) + 1);
            copies.push_back(g);
            return g;
        };
        GuestAddr guestValues = c.heap.calloc(uint32_t(std::max(count, 1)), 4);
        GuestAddr guestNames = c.heap.calloc(uint32_t(std::max(count, 1)), 4);
        for (int i = 0; i < count; i++) {
            c.mem.write<uint32_t>(guestValues + uint32_t(i) * 4, copy(values[i]));
            c.mem.write<uint32_t>(guestNames + uint32_t(i) * 4, copy(names[i]));
        }
        auto result = int32_t(c.cpu.call(e->callback, {e->arg, uint32_t(count), guestValues, guestNames}));
        for (GuestAddr g : copies) c.heap.free(g);
        c.heap.free(guestValues);
        c.heap.free(guestNames);
        return result;
    };
    char *errmsg = nullptr;
    int rc = sqlite3_exec(db, sql, row, &exec, errmsgOut ? &errmsg : nullptr);
    if (errmsgOut) {
        // Freed by the guest with sqlite3_free, which frees guest heap memory.
        GuestAddr copy = 0;
        if (errmsg) {
            copy = c.heap.alloc(uint32_t(std::strlen(errmsg) + 1));
            c.mem.copyIn(copy, errmsg, std::strlen(errmsg) + 1);
            sqlite3_free(errmsg);
        }
        c.mem.write<uint32_t>(errmsgOut, copy);
    }
    c.ret(uint32_t(rc));
}

B32_THUNK(_sqlite3_free) { c.heap.free(c.args.ptr()); }

// const char *sqlite3_column_name(sqlite3_stmt *, int): copied like text.
B32_THUNK(_sqlite3_column_name) {
    sqlite3_stmt *stmt = object<sqlite3_stmt>(c.args.u32());
    const char *name = sqlite3_column_name(stmt, c.args.i32());
    if (!name) {
        c.ret(0);
        return;
    }
    GuestAddr copy = c.heap.alloc(uint32_t(std::strlen(name) + 1));
    c.mem.copyIn(copy, name, std::strlen(name) + 1);
    {
        std::lock_guard guard(lock);
        columnText[stmt].push_back(copy);
    }
    c.ret(copy);
}

B32_THUNK(_sqlite3_last_insert_rowid) { c.ret64(uint64_t(sqlite3_last_insert_rowid(object<sqlite3>(c.args.u32())))); }
B32_THUNK(_sqlite3_libversion) { c.ret(c.rt.internString(sqlite3_libversion())); }

// sqlite3_stmt *sqlite3_next_stmt(sqlite3 *, sqlite3_stmt *)
B32_THUNK(_sqlite3_next_stmt) {
    sqlite3 *db = object<sqlite3>(c.args.u32());
    uint32_t after = c.args.u32();
    sqlite3_stmt *next = sqlite3_next_stmt(db, after ? object<sqlite3_stmt>(after) : nullptr);
    c.ret(next ? handleFor(next) : 0);
}

// Guest SQL functions aren't bridged: registering one reports success, and
// queries that call it fail.
// int sqlite3_create_function(sqlite3 *, const char *name, int nArg, int encoding, void *,
//     void (*xFunc)(...), void (*xStep)(...), void (*xFinal)(...))
B32_THUNK(_sqlite3_create_function) {
    c.args.u32();
    log("sqlite3_create_function(%s): guest SQL functions aren't supported", c.mem.cstr(c.args.ptr()));
    c.ret(SQLITE_OK);
}
B32_THUNK(_sqlite3_user_data) { c.ret(0); }

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
    {"sqlite3_bind_parameter_count", "i:h"}, {"sqlite3_bind_parameter_index", "i:hp"},
    {"sqlite3_busy_timeout", "i:hi"}, {"sqlite3_data_count", "i:h"}, {"sqlite3_threadsafe", "i:"},
};
}  // namespace

B32_C_FUNCTIONS(kSqlite, sqliteLibrary);
