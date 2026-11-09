// Security and CommonCrypto.
//
// The keychain isn't available to an ad hoc signed, sandboxed app, so it's an
// empty one that accepts writes: lookups find nothing, and adds, updates and
// deletes succeed. SDKs keep install identifiers there and make new ones.

#include "core/Runtime.h"
#include "core/objc/Bridge.h"
#include "core/thunks/CTable.h"

#import <Foundation/Foundation.h>
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

// CCCryptorRef: the guest holds a handle to the host's cryptor.
namespace {
CCCryptorRef cryptor(Call &c) { return static_cast<CCCryptorRef>(hostPointer(c.args.u32())); }
void *bytesAt(Call &c, GuestAddr p) { return p ? c.mem.ptr<void>(p) : nullptr; }
}  // namespace

// CCCryptorStatus CCCryptorCreate(CCOperation, CCAlgorithm, CCOptions, const void *key,
//     size_t keyLength, const void *iv, CCCryptorRef *cryptorRef)
B32_THUNK(_CCCryptorCreate) {
    CCOperation op = c.args.u32();
    CCAlgorithm algorithm = c.args.u32();
    CCOptions options = c.args.u32();
    GuestAddr key = c.args.ptr();
    size_t keyLength = c.args.u32();
    GuestAddr iv = c.args.ptr(), out = c.args.ptr();
    CCCryptorRef ref = nullptr;
    CCCryptorStatus status = CCCryptorCreate(op, algorithm, options, bytesAt(c, key), keyLength, bytesAt(c, iv), &ref);
    if (out) c.mem.write<uint32_t>(out, ref ? hostHandle(ref) : 0);
    c.ret(uint32_t(status));
}
// CCCryptorStatus CCCryptorCreateWithMode(CCOperation, CCMode, CCAlgorithm, CCPadding,
//     const void *iv, const void *key, size_t keyLength, const void *tweak, size_t tweakLength,
//     int numRounds, CCModeOptions, CCCryptorRef *cryptorRef)
B32_THUNK(_CCCryptorCreateWithMode) {
    CCOperation op = c.args.u32();
    CCMode mode = c.args.u32();
    CCAlgorithm algorithm = c.args.u32();
    CCPadding padding = c.args.u32();
    GuestAddr iv = c.args.ptr(), key = c.args.ptr();
    size_t keyLength = c.args.u32();
    GuestAddr tweak = c.args.ptr();
    size_t tweakLength = c.args.u32();
    int rounds = c.args.i32();
    CCModeOptions options = c.args.u32();
    GuestAddr out = c.args.ptr();
    CCCryptorRef ref = nullptr;
    CCCryptorStatus status = CCCryptorCreateWithMode(op, mode, algorithm, padding, bytesAt(c, iv), bytesAt(c, key),
                                                     keyLength, bytesAt(c, tweak), tweakLength, rounds, options, &ref);
    if (out) c.mem.write<uint32_t>(out, ref ? hostHandle(ref) : 0);
    c.ret(uint32_t(status));
}
// CCCryptorStatus CCCryptorUpdate(CCCryptorRef, const void *dataIn, size_t dataInLength,
//     void *dataOut, size_t dataOutAvailable, size_t *dataOutMoved)
B32_THUNK(_CCCryptorUpdate) {
    CCCryptorRef ref = cryptor(c);
    GuestAddr in = c.args.ptr();
    size_t inLength = c.args.u32();
    GuestAddr out = c.args.ptr();
    size_t outAvailable = c.args.u32();
    GuestAddr moved = c.args.ptr();
    size_t outMoved = 0;
    CCCryptorStatus status = CCCryptorUpdate(ref, bytesAt(c, in), inLength, bytesAt(c, out), outAvailable, &outMoved);
    if (moved) c.mem.write<uint32_t>(moved, uint32_t(outMoved));
    c.ret(uint32_t(status));
}
// CCCryptorStatus CCCryptorFinal(CCCryptorRef, void *dataOut, size_t dataOutAvailable, size_t *dataOutMoved)
B32_THUNK(_CCCryptorFinal) {
    CCCryptorRef ref = cryptor(c);
    GuestAddr out = c.args.ptr();
    size_t outAvailable = c.args.u32();
    GuestAddr moved = c.args.ptr();
    size_t outMoved = 0;
    CCCryptorStatus status = CCCryptorFinal(ref, bytesAt(c, out), outAvailable, &outMoved);
    if (moved) c.mem.write<uint32_t>(moved, uint32_t(outMoved));
    c.ret(uint32_t(status));
}
// size_t CCCryptorGetOutputLength(CCCryptorRef, size_t inputLength, bool final)
B32_THUNK(_CCCryptorGetOutputLength) {
    CCCryptorRef ref = cryptor(c);
    size_t inLength = c.args.u32();
    c.ret(uint32_t(CCCryptorGetOutputLength(ref, inLength, c.args.u32() & 0xff)));
}
// CCCryptorStatus CCCryptorReset(CCCryptorRef, const void *iv)
B32_THUNK(_CCCryptorReset) {
    CCCryptorRef ref = cryptor(c);
    c.ret(uint32_t(CCCryptorReset(ref, bytesAt(c, c.args.ptr()))));
}
// CCCryptorStatus CCCryptorRelease(CCCryptorRef)
B32_THUNK(_CCCryptorRelease) {
    CCCryptorRef ref = cryptor(c);
    if (!ref) {
        c.ret(0);
        return;
    }
    forgetHostHandle(ref);
    c.ret(uint32_t(CCCryptorRelease(ref)));
}

// int CCKeyDerivationPBKDF(CCPBKDFAlgorithm, const char *password, size_t passwordLen,
//     const uint8_t *salt, size_t saltLen, CCPseudoRandomAlgorithm prf, unsigned rounds,
//     uint8_t *derivedKey, size_t derivedKeyLen)
B32_THUNK(_CCKeyDerivationPBKDF) {
    CCPBKDFAlgorithm algorithm = c.args.u32();
    GuestAddr password = c.args.ptr();
    size_t passwordLength = c.args.u32();
    GuestAddr salt = c.args.ptr();
    size_t saltLength = c.args.u32();
    CCPseudoRandomAlgorithm prf = c.args.u32();
    unsigned rounds = c.args.u32();
    GuestAddr key = c.args.ptr();
    size_t keyLength = c.args.u32();
    c.ret(uint32_t(CCKeyDerivationPBKDF(algorithm, static_cast<const char *>(bytesAt(c, password)), passwordLength,
                                        static_cast<const uint8_t *>(bytesAt(c, salt)), saltLength, prf, rounds,
                                        static_cast<uint8_t *>(bytesAt(c, key)), keyLength)));
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
    {"SecKeyGetBlockSize", "z:o"},
    // OSStatus SecKeyRawVerify(SecKeyRef, SecPadding, const uint8_t *signedData, size_t,
    //                          const uint8_t *sig, size_t)
    {"SecKeyRawVerify", "i:oupzpz"},
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

// --- keys ---------------------------------------------------------------------------------------
// Keys are generated in memory; with no keychain behind this app, permanent
// ones aren't kept.

// OSStatus SecKeyGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey)
B32_THUNK(_SecKeyGeneratePair) {
    CFDictionaryRef parameters = (CFDictionaryRef)c.rt.bridge().toHost(c.args.ptr());
    GuestAddr publicOut = c.args.ptr(), privateOut = c.args.ptr();
    // Asking for permanent keys would go to the keychain, which refuses this app.
    NSMutableDictionary *params = [[(__bridge NSDictionary *)parameters mutableCopy] autorelease];
    [params removeObjectForKey:(id)kSecAttrIsPermanent];
    for (id key in @[ (id)kSecPublicKeyAttrs, (id)kSecPrivateKeyAttrs ]) {
        NSMutableDictionary *attrs = [[params[key] mutableCopy] autorelease];
        if (!attrs) continue;
        [attrs removeObjectForKey:(id)kSecAttrIsPermanent];
        params[key] = attrs;
    }
    SecKeyRef publicKey = nullptr, privateKey = nullptr;
    OSStatus status = SecKeyGeneratePair((CFDictionaryRef)params, &publicKey, &privateKey);
    if (publicOut) c.mem.write<uint32_t>(publicOut, publicKey ? c.rt.bridge().toGuest((id)publicKey) : 0);
    if (privateOut) c.mem.write<uint32_t>(privateOut, privateKey ? c.rt.bridge().toGuest((id)privateKey) : 0);
    c.ret(uint32_t(status));
}

// OSStatus SecKeyRawSign(SecKeyRef, SecPadding, const uint8_t *dataToSign, size_t,
//                        uint8_t *sig, size_t *sigLen): sigLen is a 32-bit size_t in the guest.
B32_THUNK(_SecKeyRawSign) {
    SecKeyRef key = (SecKeyRef)c.rt.bridge().toHost(c.args.ptr());
    SecPadding padding = c.args.u32();
    GuestAddr data = c.args.ptr();
    size_t length = c.args.u32();
    GuestAddr sig = c.args.ptr(), sigLen = c.args.ptr();
    size_t outLength = sigLen ? c.mem.read<uint32_t>(sigLen) : 0;
#if TARGET_OS_MACCATALYST
    OSStatus status = SecKeyRawSign(key, padding, c.mem.ptr<uint8_t>(data), length, c.mem.ptr<uint8_t>(sig), &outLength);
#else
    // The macOS SDK doesn't declare SecKeyRawSign; SecKeyCreateSignature with
    // the algorithm the padding names does the same for RSA keys.
    SecKeyAlgorithm algorithm;
    switch (padding) {
    case kSecPaddingNone: algorithm = kSecKeyAlgorithmRSASignatureRaw; break;
    case kSecPaddingPKCS1: algorithm = kSecKeyAlgorithmRSASignatureDigestPKCS1v15Raw; break;
    case kSecPaddingPKCS1SHA1: algorithm = kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA1; break;
    case kSecPaddingPKCS1SHA224: algorithm = kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA224; break;
    case kSecPaddingPKCS1SHA256: algorithm = kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA256; break;
    case kSecPaddingPKCS1SHA384: algorithm = kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA384; break;
    case kSecPaddingPKCS1SHA512: algorithm = kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA512; break;
    default: c.ret(uint32_t(errSecParam)); return;
    }
    OSStatus status = errSecSuccess;
    CFDataRef input = CFDataCreate(nullptr, c.mem.ptr<uint8_t>(data), CFIndex(length));
    CFErrorRef error = nullptr;
    CFDataRef signature = SecKeyCreateSignature(key, algorithm, input, &error);
    CFRelease(input);
    if (!signature) {
        status = error ? OSStatus(CFErrorGetCode(error)) : errSecParam;
        if (error) CFRelease(error);
    } else if (size_t(CFDataGetLength(signature)) > outLength) {
        status = errSecBufferTooSmall;
        CFRelease(signature);
    } else {
        outLength = size_t(CFDataGetLength(signature));
        std::memcpy(c.mem.ptr<uint8_t>(sig), CFDataGetBytePtr(signature), outLength);
        CFRelease(signature);
    }
#endif
    if (sigLen) c.mem.write<uint32_t>(sigLen, uint32_t(outLength));
    c.ret(uint32_t(status));
}

// --- incremental digests and HMAC: the contexts are arrays of 32-bit words in both ABIs ---------

B32_THUNK(_CC_SHA1_Init) { c.ret(uint32_t(CC_SHA1_Init(c.mem.ptr<CC_SHA1_CTX>(c.args.ptr())))); }
B32_THUNK(_CC_SHA1_Update) {
    auto *ctx = c.mem.ptr<CC_SHA1_CTX>(c.args.ptr());
    GuestAddr data = c.args.ptr();
    c.ret(uint32_t(CC_SHA1_Update(ctx, c.mem.ptr<void>(data), c.args.u32())));
}
B32_THUNK(_CC_SHA1_Final) {
    GuestAddr md = c.args.ptr();
    c.ret(uint32_t(CC_SHA1_Final(c.mem.ptr<unsigned char>(md), c.mem.ptr<CC_SHA1_CTX>(c.args.ptr()))));
}
B32_THUNK(_CC_SHA384) {
    GuestAddr data = c.args.ptr();
    uint32_t length = c.args.u32();
    GuestAddr md = c.args.ptr();
    CC_SHA384(c.mem.ptr<void>(data), length, c.mem.ptr<unsigned char>(md));
    c.ret(md);
}
B32_THUNK(_CCHmacInit) {
    auto *ctx = c.mem.ptr<CCHmacContext>(c.args.ptr());
    CCHmacAlgorithm algorithm = c.args.u32();
    GuestAddr key = c.args.ptr();
    CCHmacInit(ctx, algorithm, key ? c.mem.ptr<void>(key) : nullptr, c.args.u32());
}
B32_THUNK(_CCHmacUpdate) {
    auto *ctx = c.mem.ptr<CCHmacContext>(c.args.ptr());
    GuestAddr data = c.args.ptr();
    CCHmacUpdate(ctx, c.mem.ptr<void>(data), c.args.u32());
}
B32_THUNK(_CCHmacFinal) {
    auto *ctx = c.mem.ptr<CCHmacContext>(c.args.ptr());
    CCHmacFinal(ctx, c.mem.ptr<void>(c.args.ptr()));
}
