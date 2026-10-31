// Security and CommonCrypto.
//
// The keychain isn't available to an ad hoc signed, sandboxed app, so it's an
// empty one that accepts writes: lookups find nothing, and adds, updates and
// deletes succeed. SDKs keep install identifiers there and make new ones.

#include "core/Runtime.h"
#include "core/objc/Bridge.h"
#include "core/thunks/CTable.h"

#include <CommonCrypto/CommonCrypto.h>
#include <Security/Security.h>
#include <dlfcn.h>

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

// int SecRandomCopyBytes(SecRandomRef, size_t count, uint8_t *bytes)
B32_THUNK(_SecRandomCopyBytes) {
    c.args.ptr();
    size_t count = c.args.u32();
    arc4random_buf(c.mem.ptr<void>(c.args.ptr()), count);
    c.ret(0);
}
B32_DATA(_kSecRandomDefault, 4) {}  // NULL, as on iOS

// unsigned char *CC_SHA512(const void *data, CC_LONG len, unsigned char *md)
B32_THUNK(_CC_SHA512) {
    GuestAddr data = c.args.ptr();
    uint32_t length = c.args.u32();
    GuestAddr md = c.args.ptr();
    CC_SHA512(c.mem.ptr<void>(data), length, c.mem.ptr<unsigned char>(md));
    c.ret(md);
}

// --- certificates and trust (SSL pinning) ---------------------------------------------------------

namespace {
void *process() { return RTLD_DEFAULT; }
constexpr CFunction kTrust[] = {
    {"SecCertificateCreateWithData", "o:oo"}, {"SecCertificateCopyData", "o:o"},
    {"SecCertificateCopySubjectSummary", "o:o"}, {"SecPolicyCreateSSL", "o:uo"}, {"SecPolicyCreateBasicX509", "o:"},
    {"SecTrustSetAnchorCertificates", "i:oo"}, {"SecTrustSetAnchorCertificatesOnly", "i:ou"},
    {"SecTrustSetPolicies", "i:oo"}, {"SecTrustGetCertificateCount", "z:o"}, {"SecTrustGetCertificateAtIndex", "o:oz"},
    {"SecTrustCopyPublicKey", "o:o"}, {"SecTrustCopyExceptions", "o:o"}, {"SecTrustSetExceptions", "B:oo"},
    // SecTrustResultType is a 32-bit enum in both ABIs.
    {"SecTrustEvaluate", "i:op"},
};
}  // namespace

B32_C_FUNCTIONS(kTrust, process);

// OSStatus SecTrustCreateWithCertificates(CFTypeRef certificates, CFTypeRef policies, SecTrustRef *trust)
B32_THUNK(_SecTrustCreateWithCertificates) {
    CFTypeRef certificates = (CFTypeRef)c.rt.bridge().toHost(c.args.ptr());
    CFTypeRef policies = (CFTypeRef)c.rt.bridge().toHost(c.args.ptr());
    GuestAddr out = c.args.ptr();
    SecTrustRef trust = nullptr;
    OSStatus status = SecTrustCreateWithCertificates(certificates, policies, &trust);
    if (out) c.mem.write<uint32_t>(out, trust ? c.rt.bridge().toGuest((id)trust) : 0);
    c.ret(uint32_t(status));
}
