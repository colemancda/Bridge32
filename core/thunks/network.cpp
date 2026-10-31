// BSD sockets and name lookup on the host's network stack.
//
// Most structures look the same to both ABIs, so guest pointers pass straight
// through: sockaddr and its variants (they carry their own length),
// socklen_t, fd_set (32 32-bit words), struct linger, struct in_addr. The rest
// is converted:
//  - struct timeval: two 32-bit words in the guest, a 64-bit tv_sec on the host
//  - hostent, addrinfo and ifaddrs, which are full of pointers: built in
//    guest memory from the host's results
// Sockets never raise SIGPIPE (SO_NOSIGPIPE), which would end the whole app.

#include "Thunks.h"
#include "core/Runtime.h"

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>
#include <vector>

using namespace b32;

namespace {

void *hostPtr(Call &c, GuestAddr p) { return p ? c.mem.ptr<void>(p) : nullptr; }
socklen_t *hostLen(Call &c, GuestAddr p) { return p ? c.mem.ptr<socklen_t>(p) : nullptr; }

// Returns a socket call's result, setting the guest's errno on failure.
void result(Call &c, long value) {
    if (value < 0) setGuestErrno(c, errno);
    c.ret(uint32_t(int32_t(value)));
}

void noSigpipe(int fd) {
    int on = 1;
    if (fd >= 0) ::setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
}

struct timeval readTimeval(Call &c, GuestAddr p) {
    return {c.mem.read<int32_t>(p), c.mem.read<int32_t>(p + 4)};
}

void writeTimeval(Call &c, GuestAddr p, const struct timeval &tv) {
    c.mem.write<int32_t>(p, int32_t(tv.tv_sec));
    c.mem.write<int32_t>(p + 4, tv.tv_usec);
}

bool isTimeout(int level, int name) { return level == SOL_SOCKET && (name == SO_RCVTIMEO || name == SO_SNDTIMEO); }

// Copies bytes into a fresh guest allocation.
GuestAddr guestCopy(Call &c, const void *data, size_t size) {
    GuestAddr p = c.heap.alloc(uint32_t(size));
    c.mem.copyIn(p, data, size);
    return p;
}
GuestAddr guestString(Call &c, const char *s) { return s ? guestCopy(c, s, std::strlen(s) + 1) : 0; }
GuestAddr guestSockaddr(Call &c, const struct sockaddr *sa) { return sa ? guestCopy(c, sa, sa->sa_len) : 0; }

}  // namespace

// --- sockets -------------------------------------------------------------------------------

B32_THUNK(_socket) {
    int domain = c.args.i32(), type = c.args.i32();
    int fd = ::socket(domain, type, c.args.i32());
    noSigpipe(fd);
    result(c, fd);
}

B32_THUNK(_bind) {
    int fd = c.args.i32();
    auto *addr = static_cast<sockaddr *>(hostPtr(c, c.args.ptr()));
    result(c, ::bind(fd, addr, c.args.u32()));
}

B32_THUNK(_connect) {
    int fd = c.args.i32();
    auto *addr = static_cast<sockaddr *>(hostPtr(c, c.args.ptr()));
    result(c, ::connect(fd, addr, c.args.u32()));
}

B32_THUNK(_listen) {
    int fd = c.args.i32();
    result(c, ::listen(fd, c.args.i32()));
}

B32_THUNK(_accept) {
    int fd = c.args.i32();
    auto *addr = static_cast<sockaddr *>(hostPtr(c, c.args.ptr()));
    int client = ::accept(fd, addr, hostLen(c, c.args.ptr()));
    noSigpipe(client);
    result(c, client);
}

B32_THUNK(_shutdown) {
    int fd = c.args.i32();
    result(c, ::shutdown(fd, c.args.i32()));
}

B32_THUNK(_send) {
    int fd = c.args.i32();
    void *buf = hostPtr(c, c.args.ptr());
    size_t len = c.args.u32();
    result(c, ::send(fd, buf, len, c.args.i32()));
}

B32_THUNK(_recv) {
    int fd = c.args.i32();
    void *buf = hostPtr(c, c.args.ptr());
    size_t len = c.args.u32();
    result(c, ::recv(fd, buf, len, c.args.i32()));
}

// ssize_t sendto(int, const void *, size_t, int flags, const struct sockaddr *, socklen_t)
B32_THUNK(_sendto) {
    int fd = c.args.i32();
    void *buf = hostPtr(c, c.args.ptr());
    size_t len = c.args.u32();
    int flags = c.args.i32();
    auto *to = static_cast<sockaddr *>(hostPtr(c, c.args.ptr()));
    result(c, ::sendto(fd, buf, len, flags, to, c.args.u32()));
}

// ssize_t recvfrom(int, void *, size_t, int flags, struct sockaddr *, socklen_t *)
B32_THUNK(_recvfrom) {
    int fd = c.args.i32();
    void *buf = hostPtr(c, c.args.ptr());
    size_t len = c.args.u32();
    int flags = c.args.i32();
    auto *from = static_cast<sockaddr *>(hostPtr(c, c.args.ptr()));
    result(c, ::recvfrom(fd, buf, len, flags, from, hostLen(c, c.args.ptr())));
}

B32_THUNK(_getsockname) {
    int fd = c.args.i32();
    auto *addr = static_cast<sockaddr *>(hostPtr(c, c.args.ptr()));
    result(c, ::getsockname(fd, addr, hostLen(c, c.args.ptr())));
}

B32_THUNK(_getpeername) {
    int fd = c.args.i32();
    auto *addr = static_cast<sockaddr *>(hostPtr(c, c.args.ptr()));
    result(c, ::getpeername(fd, addr, hostLen(c, c.args.ptr())));
}

// int setsockopt(int, int level, int name, const void *value, socklen_t)
B32_THUNK(_setsockopt) {
    int fd = c.args.i32(), level = c.args.i32(), name = c.args.i32();
    GuestAddr value = c.args.ptr();
    socklen_t len = c.args.u32();
    if (isTimeout(level, name) && value) {
        struct timeval tv = readTimeval(c, value);
        result(c, ::setsockopt(fd, level, name, &tv, sizeof tv));
        return;
    }
    result(c, ::setsockopt(fd, level, name, hostPtr(c, value), len));
}

// int getsockopt(int, int level, int name, void *value, socklen_t *len)
B32_THUNK(_getsockopt) {
    int fd = c.args.i32(), level = c.args.i32(), name = c.args.i32();
    GuestAddr value = c.args.ptr(), len = c.args.ptr();
    if (isTimeout(level, name) && value) {
        struct timeval tv{};
        socklen_t size = sizeof tv;
        int r = ::getsockopt(fd, level, name, &tv, &size);
        if (r == 0) {
            writeTimeval(c, value, tv);
            if (len) c.mem.write<uint32_t>(len, 8);
        }
        result(c, r);
        return;
    }
    result(c, ::getsockopt(fd, level, name, hostPtr(c, value), hostLen(c, len)));
}

// int select(int, fd_set *, fd_set *, fd_set *, struct timeval *)
B32_THUNK(_select) {
    int n = c.args.i32();
    auto *readSet = static_cast<fd_set *>(hostPtr(c, c.args.ptr()));
    auto *writeSet = static_cast<fd_set *>(hostPtr(c, c.args.ptr()));
    auto *errorSet = static_cast<fd_set *>(hostPtr(c, c.args.ptr()));
    GuestAddr timeout = c.args.ptr();
    struct timeval tv{};
    if (timeout) tv = readTimeval(c, timeout);
    int r = ::select(n, readSet, writeSet, errorSet, timeout ? &tv : nullptr);
    if (timeout) writeTimeval(c, timeout, tv);  // like Linux, Darwin leaves it; harmless either way
    result(c, r);
}

// --- interfaces ---------------------------------------------------------------------------------

B32_THUNK(_if_nametoindex) { c.ret(::if_nametoindex(c.mem.cstr(c.args.ptr()))); }

// int getifaddrs(struct ifaddrs **): each guest node
//   { ifa_next, ifa_name, ifa_flags, ifa_addr, ifa_netmask, ifa_dstaddr, ifa_data }
// is its own allocation, with its name and addresses in separate ones.
B32_THUNK(_getifaddrs) {
    GuestAddr out = c.args.ptr();
    struct ifaddrs *list = nullptr;
    if (::getifaddrs(&list) != 0) {
        result(c, -1);
        return;
    }
    GuestAddr first = 0, previous = 0;
    for (struct ifaddrs *i = list; i; i = i->ifa_next) {
        GuestAddr node = c.heap.calloc(1, 28);
        c.mem.write<uint32_t>(node + 4, guestString(c, i->ifa_name));
        c.mem.write<uint32_t>(node + 8, i->ifa_flags);
        c.mem.write<uint32_t>(node + 12, guestSockaddr(c, i->ifa_addr));
        c.mem.write<uint32_t>(node + 16, guestSockaddr(c, i->ifa_netmask));
        c.mem.write<uint32_t>(node + 20, guestSockaddr(c, i->ifa_dstaddr));
        if (previous) c.mem.write<uint32_t>(previous, node);
        else first = node;
        previous = node;
    }
    ::freeifaddrs(list);
    c.mem.write<uint32_t>(out, first);
    c.ret(0);
}

B32_THUNK(_freeifaddrs) {
    for (GuestAddr node = c.args.ptr(); node;) {
        GuestAddr next = c.mem.read<uint32_t>(node);
        for (uint32_t offset : {4u, 12u, 16u, 20u})
            if (GuestAddr p = c.mem.read<uint32_t>(node + offset)) c.heap.free(p);
        c.heap.free(node);
        node = next;
    }
}

// --- addresses --------------------------------------------------------------------------------

B32_THUNK(_inet_addr) { c.ret(::inet_addr(c.mem.cstr(c.args.ptr()))); }

// int inet_aton(const char *, struct in_addr *)
B32_THUNK(_inet_aton) {
    const char *s = c.mem.cstr(c.args.ptr());
    auto *addr = static_cast<in_addr *>(hostPtr(c, c.args.ptr()));
    c.ret(uint32_t(::inet_aton(s, addr)));
}

// char *inet_ntoa(struct in_addr): the result lives in a per-thread buffer.
B32_THUNK(_inet_ntoa) {
    static thread_local GuestAddr buffer = 0;
    if (!buffer) buffer = c.heap.calloc(1, 16);
    struct in_addr addr = {c.args.u32()};
    const char *s = ::inet_ntoa(addr);
    c.mem.copyIn(buffer, s, std::strlen(s) + 1);
    c.ret(buffer);
}

// int inet_pton(int af, const char *src, void *dst)
B32_THUNK(_inet_pton) {
    int af = c.args.i32();
    const char *src = c.mem.cstr(c.args.ptr());
    c.ret(uint32_t(::inet_pton(af, src, hostPtr(c, c.args.ptr()))));
}

// const char *inet_ntop(int af, const void *src, char *dst, socklen_t size)
B32_THUNK(_inet_ntop) {
    int af = c.args.i32();
    void *src = hostPtr(c, c.args.ptr());
    GuestAddr dst = c.args.ptr();
    socklen_t size = c.args.u32();
    c.ret(::inet_ntop(af, src, static_cast<char *>(hostPtr(c, dst)), size) ? dst : 0);
}

// --- name lookup -----------------------------------------------------------------------------

namespace {
// struct hostent { char *h_name; char **h_aliases; int h_addrtype, h_length; char **h_addr_list; },
// rebuilt per thread for each lookup.
GuestAddr guestHostent(Call &c, const struct hostent *h) {
    static thread_local std::vector<GuestAddr> previous;
    for (GuestAddr p : previous) c.heap.free(p);
    previous.clear();
    if (!h) return 0;
    auto keep = [&](GuestAddr p) { previous.push_back(p); return p; };
    auto pointerList = [&](char **items, size_t itemSize) {
        size_t count = 0;
        while (items && items[count]) count++;
        GuestAddr list = keep(c.heap.calloc(uint32_t(count + 1), 4));
        for (size_t i = 0; i < count; i++) {
            size_t size = itemSize ? itemSize : std::strlen(items[i]) + 1;
            c.mem.write<uint32_t>(list + uint32_t(i) * 4, keep(guestCopy(c, items[i], size)));
        }
        return list;
    };
    GuestAddr out = keep(c.heap.calloc(1, 20));
    c.mem.write<uint32_t>(out, keep(guestString(c, h->h_name)));
    c.mem.write<uint32_t>(out + 4, pointerList(h->h_aliases, 0));
    c.mem.write<int32_t>(out + 8, h->h_addrtype);
    c.mem.write<int32_t>(out + 12, h->h_length);
    c.mem.write<uint32_t>(out + 16, pointerList(h->h_addr_list, size_t(h->h_length)));
    return out;
}
}  // namespace

B32_THUNK(_gethostbyname) { c.ret(guestHostent(c, ::gethostbyname(c.mem.cstr(c.args.ptr())))); }

// struct hostent *gethostbyaddr(const void *addr, socklen_t len, int type)
B32_THUNK(_gethostbyaddr) {
    void *addr = hostPtr(c, c.args.ptr());
    socklen_t len = c.args.u32();
    c.ret(guestHostent(c, ::gethostbyaddr(addr, len, c.args.i32())));
}

// int getaddrinfo(const char *node, const char *service, const struct addrinfo *hints,
//                 struct addrinfo **res)
// Guest addrinfo: { ai_flags, ai_family, ai_socktype, ai_protocol, ai_addrlen,
//                   ai_canonname, ai_addr, ai_next }, 32 bytes.
B32_THUNK(_getaddrinfo) {
    GuestAddr node = c.args.ptr(), service = c.args.ptr(), hintsAddr = c.args.ptr(), out = c.args.ptr();
    struct addrinfo hints{};
    if (hintsAddr) {
        hints.ai_flags = c.mem.read<int32_t>(hintsAddr);
        hints.ai_family = c.mem.read<int32_t>(hintsAddr + 4);
        hints.ai_socktype = c.mem.read<int32_t>(hintsAddr + 8);
        hints.ai_protocol = c.mem.read<int32_t>(hintsAddr + 12);
    }
    struct addrinfo *list = nullptr;
    int r = ::getaddrinfo(node ? c.mem.cstr(node) : nullptr, service ? c.mem.cstr(service) : nullptr,
                          hintsAddr ? &hints : nullptr, &list);
    if (r != 0) {
        c.ret(uint32_t(r));
        return;
    }
    GuestAddr first = 0, previous = 0;
    for (struct addrinfo *i = list; i; i = i->ai_next) {
        GuestAddr info = c.heap.calloc(1, 32);
        c.mem.write<int32_t>(info, i->ai_flags);
        c.mem.write<int32_t>(info + 4, i->ai_family);
        c.mem.write<int32_t>(info + 8, i->ai_socktype);
        c.mem.write<int32_t>(info + 12, i->ai_protocol);
        c.mem.write<uint32_t>(info + 16, i->ai_addrlen);
        c.mem.write<uint32_t>(info + 20, guestString(c, i->ai_canonname));
        c.mem.write<uint32_t>(info + 24, i->ai_addr ? guestCopy(c, i->ai_addr, i->ai_addrlen) : 0);
        if (previous) c.mem.write<uint32_t>(previous + 28, info);
        else first = info;
        previous = info;
    }
    ::freeaddrinfo(list);
    c.mem.write<uint32_t>(out, first);
    c.ret(0);
}

B32_THUNK(_freeaddrinfo) {
    for (GuestAddr info = c.args.ptr(); info;) {
        GuestAddr next = c.mem.read<uint32_t>(info + 28);
        for (uint32_t offset : {20u, 24u})
            if (GuestAddr p = c.mem.read<uint32_t>(info + offset)) c.heap.free(p);
        c.heap.free(info);
        info = next;
    }
}

B32_THUNK(_gai_strerror) { c.ret(c.rt.internString(::gai_strerror(c.args.i32()))); }

// int getnameinfo(const struct sockaddr *, socklen_t, char *host, socklen_t hostlen,
//                 char *serv, socklen_t servlen, int flags)
B32_THUNK(_getnameinfo) {
    auto *sa = static_cast<sockaddr *>(hostPtr(c, c.args.ptr()));
    socklen_t salen = c.args.u32();
    auto *host = static_cast<char *>(hostPtr(c, c.args.ptr()));
    socklen_t hostlen = c.args.u32();
    auto *serv = static_cast<char *>(hostPtr(c, c.args.ptr()));
    socklen_t servlen = c.args.u32();
    c.ret(uint32_t(::getnameinfo(sa, salen, host, hostlen, serv, servlen, c.args.i32())));
}
