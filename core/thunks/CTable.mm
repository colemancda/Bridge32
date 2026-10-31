#include "CTable.h"

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/objc/Bridge.h"

#include <dlfcn.h>
#include <ffi/ffi.h>

#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace b32 {

namespace {

struct Description {
    const CFunction *function;
    LibraryLoader library;
};

std::unordered_map<std::string, Description> &descriptions() {
    static std::unordered_map<std::string, Description> table;
    return table;
}

BufferBoundQuery bufferBound = nullptr;

ffi_type *ffiFor(char code) {
    switch (code) {
    case 'v': return &ffi_type_void;
    case 'i': return &ffi_type_sint32;
    case 'u': return &ffi_type_uint32;
    case 'f': return &ffi_type_float;
    case 'z': return &ffi_type_sint64;
    case 'B': return &ffi_type_uint8;
    case 'p': case 'a': case 'e': case 'h': case 's': return &ffi_type_pointer;
    default: fatal("bad C signature code '%c'", code);
    }
}

struct Prepared {
    void *fn;
    char ret;
    std::string args;
    ffi_cif cif;
    std::vector<ffi_type *> types;
};

std::mutex lock;
std::unordered_map<const char *, Prepared *> preparedByName;  // keyed by the thunk entry's name pointer

Prepared &prepare(Call &c) {
    std::lock_guard guard(lock);
    if (auto it = preparedByName.find(c.name); it != preparedByName.end()) return *it->second;
    const Description &d = descriptions().at(c.name);
    auto *p = new Prepared;
    p->ret = d.function->sig[0];
    p->args = d.function->sig + 2;
    p->fn = dlsym(d.library(), d.function->name);
    if (!p->fn) fatal("the host library has no %s", d.function->name);
    for (char a : p->args) p->types.push_back(ffiFor(a));
    if (ffi_prep_cif(&p->cif, FFI_DEFAULT_ABI, unsigned(p->types.size()), ffiFor(p->ret), p->types.data()) != FFI_OK)
        fatal("libffi rejected %s", d.function->name);
    preparedByName[c.name] = p;
    return *p;
}

// Opaque host pointers ('h') as guest handles.
std::vector<void *> handles = {nullptr};
std::unordered_map<void *, uint32_t> handleOf;

uint32_t toHandle(void *p) {
    if (!p) return 0;
    std::lock_guard guard(lock);
    auto [it, inserted] = handleOf.emplace(p, uint32_t(handles.size()));
    if (inserted) handles.push_back(p);
    return it->second;
}

void *fromHandle(uint32_t h) {
    std::lock_guard guard(lock);
    if (h >= handles.size()) fatal("bad host handle %u", h);
    return handles[h];
}

void *pointerOrOffset(Call &c, uint32_t word, char code) {
    if (!word) return nullptr;
    if (bufferBound && bufferBound(code)) return reinterpret_cast<void *>(uintptr_t(word));
    return c.mem.ptr<void>(word);
}

void cThunk(Call &c) {
    Prepared &p = prepare(c);
    union Value {
        int32_t i;
        uint32_t u;
        float f;
        int64_t z;
        void *ptr;
    };
    Value values[16];
    void *slots[16];
    uint32_t firstArg = c.cpu.reg(0);
    for (size_t k = 0; k < p.args.size(); k++) {
        Value &v = values[k];
        uint32_t word = c.args.u32();
        switch (p.args[k]) {
        case 'i': v.i = int32_t(word); break;
        case 'u': v.u = word; break;
        case 'f': std::memcpy(&v.f, &word, 4); break;
        case 'z': v.z = int32_t(word); break;
        case 'p': v.ptr = word ? c.mem.ptr<void>(word) : nullptr; break;
        case 'a': case 'e': v.ptr = pointerOrOffset(c, word, p.args[k]); break;
        case 'h': v.ptr = fromHandle(word); break;
        }
        slots[k] = &v;
    }

    alignas(16) uint8_t result[16] = {};
    ffi_call(&p.cif, FFI_FN(p.fn), result, slots);

    switch (p.ret) {
    case 'v': break;
    case 'i': case 'u': c.ret(*reinterpret_cast<uint32_t *>(result)); break;
    case 'f': c.ret(*reinterpret_cast<uint32_t *>(result)); break;
    case 'B': c.ret(result[0]); break;
    case 'h': c.ret(toHandle(*reinterpret_cast<void **>(result))); break;
    case 's': {
        static std::unordered_map<std::string, GuestAddr> strings;
        const char *s = *reinterpret_cast<const char **>(result);
        if (!s) {
            c.ret(0);
            break;
        }
        std::string key = std::string(c.name) + "#" + std::to_string(firstArg);
        auto it = strings.find(key);
        if (it == strings.end()) it = strings.emplace(key, c.rt.bridge().guestCString(s, nil)).first;
        c.ret(it->second);
        break;
    }
    default: fatal("bad return code '%c' for %s", p.ret, c.name);
    }
}

}  // namespace

void registerCFunctions(const CFunction *functions, size_t count, LibraryLoader library) {
    for (size_t i = 0; i < count; i++) {
        std::string symbol = std::string("_") + functions[i].name;
        descriptions().emplace(symbol, Description{&functions[i], library});
        ThunkRegistry::all().emplace(symbol, cThunk);
    }
}

void setBufferBoundQuery(BufferBoundQuery query) { bufferBound = query; }

void objcConstant(Runtime &rt, GuestAddr addr, const char *name) {
    auto *value = static_cast<id *>(dlsym(RTLD_DEFAULT, name));
    if (!value) log("host has no constant %s", name);
    rt.mem().write<uint32_t>(addr, value ? rt.bridge().toGuest(*value) : 0);
}

}  // namespace b32
