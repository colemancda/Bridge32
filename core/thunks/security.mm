// Security and CommonCrypto.
//
// The keychain isn't available to an ad hoc signed, sandboxed app, so it's an
// empty one that accepts writes: lookups find nothing, and adds, updates and
// deletes succeed. SDKs keep install identifiers there and make new ones.

#include "core/Runtime.h"
#include "core/objc/Bridge.h"

#include <CommonCrypto/CommonCrypto.h>
#include <Security/Security.h>

using namespace b32;

// OSStatus SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result)
B32_THUNK(_SecItemCopyMatching) {
    c.args.ptr();
    if (GuestAddr result = c.args.ptr()) c.mem.write<uint32_t>(result, 0);
    c.ret(uint32_t(errSecItemNotFound));
}
B32_THUNK(_SecItemAdd) {
    c.args.ptr();
    if (GuestAddr result = c.args.ptr()) c.mem.write<uint32_t>(result, 0);
    c.ret(errSecSuccess);
}
B32_THUNK(_SecItemUpdate) { c.ret(errSecSuccess); }
B32_THUNK(_SecItemDelete) { c.ret(errSecSuccess); }

// void CCHmac(CCHmacAlgorithm, const void *key, size_t keyLength, const void *data,
//             size_t dataLength, void *macOut)
B32_THUNK(_CCHmac) {
    CCHmacAlgorithm algorithm = c.args.u32();
    GuestAddr key = c.args.ptr();
    size_t keyLength = c.args.u32();
    GuestAddr data = c.args.ptr();
    size_t dataLength = c.args.u32();
    GuestAddr out = c.args.ptr();
    CCHmac(algorithm, key ? c.mem.ptr<void>(key) : nullptr, keyLength, data ? c.mem.ptr<void>(data) : nullptr,
           dataLength, c.mem.ptr<void>(out));
}

// CCCryptorStatus CCCrypt(CCOperation, CCAlgorithm, CCOptions, const void *key, size_t keyLength,
//     const void *iv, const void *dataIn, size_t dataInLength, void *dataOut,
//     size_t dataOutAvailable, size_t *dataOutMoved)
B32_THUNK(_CCCrypt) {
    CCOperation op = c.args.u32();
    CCAlgorithm algorithm = c.args.u32();
    CCOptions options = c.args.u32();
    GuestAddr key = c.args.ptr();
    size_t keyLength = c.args.u32();
    GuestAddr iv = c.args.ptr(), in = c.args.ptr();
    size_t inLength = c.args.u32();
    GuestAddr out = c.args.ptr();
    size_t outAvailable = c.args.u32();
    GuestAddr moved = c.args.ptr();
    auto ptr = [&](GuestAddr p) { return p ? c.mem.ptr<void>(p) : nullptr; };
    size_t outMoved = 0;
    CCCryptorStatus status = CCCrypt(op, algorithm, options, ptr(key), keyLength, ptr(iv), ptr(in), inLength,
                                     ptr(out), outAvailable, &outMoved);
    if (moved) c.mem.write<uint32_t>(moved, uint32_t(outMoved));
    c.ret(uint32_t(status));
}
