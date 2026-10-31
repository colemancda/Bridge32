// The out-of-line parts of GCC 4.2's libstdc++ that iPhone OS apps import:
// std::list and std::_Rb_tree node algorithms, the copy-on-write std::string
// representation, iostream init and __dynamic_cast. They work on the guest's
// own data structures in guest memory.

#include "Thunks.h"
#include "core/Log.h"
#include "core/Runtime.h"

#include <cstring>
#include <functional>

using namespace b32;

// --- std::list: _List_node_base { next, prev } ---------------------------------

// void _List_node_base::hook(_List_node_base *position)
B32_THUNK(__ZNSt15_List_node_base4hookEPS_) {
    GuestAddr self = c.args.ptr();
    GuestAddr position = c.args.ptr();
    GuestAddr prev = c.mem.read<uint32_t>(position + 4);
    c.mem.write<uint32_t>(self, position);
    c.mem.write<uint32_t>(self + 4, prev);
    c.mem.write<uint32_t>(prev, self);
    c.mem.write<uint32_t>(position + 4, self);
}

// void _List_node_base::unhook()
B32_THUNK(__ZNSt15_List_node_base6unhookEv) {
    GuestAddr self = c.args.ptr();
    GuestAddr next = c.mem.read<uint32_t>(self), prev = c.mem.read<uint32_t>(self + 4);
    c.mem.write<uint32_t>(prev, next);
    c.mem.write<uint32_t>(next + 4, prev);
}

// --- std::_Rb_tree --------------------------------------------------------------------
// _Rb_tree_node_base { int color (red 0, black 1); parent; left; right }. The
// tree's header node has parent = root, left = leftmost, right = rightmost,
// and the root's parent is the header.

namespace {

constexpr uint32_t kRed = 0, kBlack = 1;

struct Tree {
    GuestMemory &mem;
    uint32_t color(GuestAddr n) const { return mem.read<uint32_t>(n); }
    GuestAddr parent(GuestAddr n) const { return mem.read<uint32_t>(n + 4); }
    GuestAddr left(GuestAddr n) const { return mem.read<uint32_t>(n + 8); }
    GuestAddr right(GuestAddr n) const { return mem.read<uint32_t>(n + 12); }
    void setColor(GuestAddr n, uint32_t v) { mem.write<uint32_t>(n, v); }
    void setParent(GuestAddr n, GuestAddr v) { mem.write<uint32_t>(n + 4, v); }
    void setLeft(GuestAddr n, GuestAddr v) { mem.write<uint32_t>(n + 8, v); }
    void setRight(GuestAddr n, GuestAddr v) { mem.write<uint32_t>(n + 12, v); }

    GuestAddr minimum(GuestAddr n) const {
        while (left(n)) n = left(n);
        return n;
    }
    GuestAddr maximum(GuestAddr n) const {
        while (right(n)) n = right(n);
        return n;
    }

    GuestAddr increment(GuestAddr x) const {
        if (right(x)) return minimum(right(x));
        GuestAddr y = parent(x);
        while (x == right(y)) {
            x = y;
            y = parent(y);
        }
        // Incrementing the rightmost node of a one-node tree reaches the header.
        return right(x) != y ? y : x;
    }

    GuestAddr decrement(GuestAddr x) const {
        // The header (red, and its parent's parent) decrements to the rightmost node.
        if (color(x) == kRed && parent(parent(x)) == x) return right(x);
        if (left(x)) return maximum(left(x));
        GuestAddr y = parent(x);
        while (x == left(y)) {
            x = y;
            y = parent(y);
        }
        return y;
    }

    // Rotations keep `root` (the header's parent slot) up to date.
    void rotateLeft(GuestAddr x, GuestAddr header) {
        GuestAddr y = right(x);
        setRight(x, left(y));
        if (left(y)) setParent(left(y), x);
        setParent(y, parent(x));
        if (x == root(header))
            setRoot(header, y);
        else if (x == left(parent(x)))
            setLeft(parent(x), y);
        else
            setRight(parent(x), y);
        setLeft(y, x);
        setParent(x, y);
    }

    void rotateRight(GuestAddr x, GuestAddr header) {
        GuestAddr y = left(x);
        setLeft(x, right(y));
        if (right(y)) setParent(right(y), x);
        setParent(y, parent(x));
        if (x == root(header))
            setRoot(header, y);
        else if (x == right(parent(x)))
            setRight(parent(x), y);
        else
            setLeft(parent(x), y);
        setRight(y, x);
        setParent(x, y);
    }

    GuestAddr root(GuestAddr header) const { return parent(header); }
    void setRoot(GuestAddr header, GuestAddr n) { setParent(header, n); }

    void insertAndRebalance(bool insertLeft, GuestAddr x, GuestAddr p, GuestAddr header) {
        setParent(x, p);
        setLeft(x, 0);
        setRight(x, 0);
        setColor(x, kRed);

        if (insertLeft) {
            setLeft(p, x);  // also makes leftmost = x when p is the header
            if (p == header) {
                setRoot(header, x);
                setRight(header, x);
            } else if (p == left(header)) {
                setLeft(header, x);
            }
        } else {
            setRight(p, x);
            if (p == right(header)) setRight(header, x);
        }

        // Restore the red-black properties.
        while (x != root(header) && color(parent(x)) == kRed) {
            GuestAddr xp = parent(x), xpp = parent(xp);
            if (xp == left(xpp)) {
                GuestAddr y = right(xpp);
                if (y && color(y) == kRed) {
                    setColor(xp, kBlack);
                    setColor(y, kBlack);
                    setColor(xpp, kRed);
                    x = xpp;
                } else {
                    if (x == right(xp)) {
                        x = xp;
                        rotateLeft(x, header);
                        xp = parent(x);
                    }
                    setColor(xp, kBlack);
                    setColor(xpp, kRed);
                    rotateRight(xpp, header);
                }
            } else {
                GuestAddr y = left(xpp);
                if (y && color(y) == kRed) {
                    setColor(xp, kBlack);
                    setColor(y, kBlack);
                    setColor(xpp, kRed);
                    x = xpp;
                } else {
                    if (x == left(xp)) {
                        x = xp;
                        rotateRight(x, header);
                        xp = parent(x);
                    }
                    setColor(xp, kBlack);
                    setColor(xpp, kRed);
                    rotateLeft(xpp, header);
                }
            }
        }
        setColor(root(header), kBlack);
    }

    // Unlinks z and rebalances; returns the node to destroy (z itself).
    GuestAddr rebalanceForErase(GuestAddr z, GuestAddr header) {
        GuestAddr y = z;  // node actually removed from its position
        GuestAddr x = 0, xParent = 0;

        if (!left(y)) {
            x = right(y);
        } else if (!right(y)) {
            x = left(y);
        } else {
            y = minimum(right(y));  // z's successor
            x = right(y);
        }

        if (y != z) {
            // Relink y in place of z.
            setParent(left(z), y);
            setLeft(y, left(z));
            if (y != right(z)) {
                xParent = parent(y);
                if (x) setParent(x, parent(y));
                setLeft(parent(y), x);
                setRight(y, right(z));
                setParent(right(z), y);
            } else {
                xParent = y;
            }
            if (root(header) == z)
                setRoot(header, y);
            else if (left(parent(z)) == z)
                setLeft(parent(z), y);
            else
                setRight(parent(z), y);
            setParent(y, parent(z));
            uint32_t yColor = color(y);
            setColor(y, color(z));
            setColor(z, yColor);
            y = z;  // y now points to the node to delete
        } else {
            xParent = parent(y);
            if (x) setParent(x, parent(y));
            if (root(header) == z)
                setRoot(header, x);
            else if (left(parent(z)) == z)
                setLeft(parent(z), x);
            else
                setRight(parent(z), x);
            if (left(header) == z) setLeft(header, right(z) ? minimum(x) : parent(z));
            if (right(header) == z) setRight(header, left(z) ? maximum(x) : parent(z));
        }

        if (color(y) != kRed) {
            while (x != root(header) && (!x || color(x) == kBlack)) {
                if (x == left(xParent)) {
                    GuestAddr w = right(xParent);
                    if (color(w) == kRed) {
                        setColor(w, kBlack);
                        setColor(xParent, kRed);
                        rotateLeft(xParent, header);
                        w = right(xParent);
                    }
                    if ((!left(w) || color(left(w)) == kBlack) && (!right(w) || color(right(w)) == kBlack)) {
                        setColor(w, kRed);
                        x = xParent;
                        xParent = parent(xParent);
                    } else {
                        if (!right(w) || color(right(w)) == kBlack) {
                            setColor(left(w), kBlack);
                            setColor(w, kRed);
                            rotateRight(w, header);
                            w = right(xParent);
                        }
                        setColor(w, color(xParent));
                        setColor(xParent, kBlack);
                        if (right(w)) setColor(right(w), kBlack);
                        rotateLeft(xParent, header);
                        break;
                    }
                } else {
                    GuestAddr w = left(xParent);
                    if (color(w) == kRed) {
                        setColor(w, kBlack);
                        setColor(xParent, kRed);
                        rotateRight(xParent, header);
                        w = left(xParent);
                    }
                    if ((!right(w) || color(right(w)) == kBlack) && (!left(w) || color(left(w)) == kBlack)) {
                        setColor(w, kRed);
                        x = xParent;
                        xParent = parent(xParent);
                    } else {
                        if (!left(w) || color(left(w)) == kBlack) {
                            setColor(right(w), kBlack);
                            setColor(w, kRed);
                            rotateLeft(w, header);
                            w = left(xParent);
                        }
                        setColor(w, color(xParent));
                        setColor(xParent, kBlack);
                        if (left(w)) setColor(left(w), kBlack);
                        rotateRight(xParent, header);
                        break;
                    }
                }
            }
            if (x) setColor(x, kBlack);
        }
        return y;
    }
};

}  // namespace

B32_THUNK(__ZSt18_Rb_tree_incrementPSt18_Rb_tree_node_base) { c.ret(Tree{c.mem}.increment(c.args.ptr())); }
B32_THUNK(__ZSt18_Rb_tree_incrementPKSt18_Rb_tree_node_base) { c.ret(Tree{c.mem}.increment(c.args.ptr())); }
B32_THUNK(__ZSt18_Rb_tree_decrementPSt18_Rb_tree_node_base) { c.ret(Tree{c.mem}.decrement(c.args.ptr())); }
B32_THUNK(__ZSt18_Rb_tree_decrementPKSt18_Rb_tree_node_base) { c.ret(Tree{c.mem}.decrement(c.args.ptr())); }

// void _Rb_tree_insert_and_rebalance(bool insert_left, node *x, node *p, node &header)
B32_THUNK(__ZSt29_Rb_tree_insert_and_rebalancebPSt18_Rb_tree_node_baseS0_RS_) {
    bool insertLeft = (c.args.u32() & 0xff) != 0;
    GuestAddr x = c.args.ptr(), p = c.args.ptr(), header = c.args.ptr();
    Tree{c.mem}.insertAndRebalance(insertLeft, x, p, header);
}

// node *_Rb_tree_rebalance_for_erase(node *z, node &header)
B32_THUNK(__ZSt28_Rb_tree_rebalance_for_erasePSt18_Rb_tree_node_baseRS_) {
    GuestAddr z = c.args.ptr();
    c.ret(Tree{c.mem}.rebalanceForErase(z, c.args.ptr()));
}

// --- copy-on-write std::string --------------------------------------------------------
// The string holds a pointer to its characters, preceded by
// _Rep { size_t length; size_t capacity; int refcount }. Empty strings share
// _S_empty_rep_storage and are never freed.

namespace {
GuestAddr emptyRep = 0;
}  // namespace

B32_DATA(__ZNSs4_Rep20_S_empty_rep_storageE, 16) { emptyRep = addr; }

// std::string::~string(): drop a reference to the rep; the last owner frees it.
B32_THUNK(__ZNSsD1Ev) {
    GuestAddr self = c.args.ptr();
    GuestAddr rep = c.mem.read<uint32_t>(self) - 12;
    if (rep != emptyRep) {
        auto *refcount = c.mem.ptr<int32_t>(rep + 8);
        if (__atomic_fetch_sub(refcount, 1, __ATOMIC_ACQ_REL) <= 0) c.heap.free(rep);
    }
    c.ret(self);
}
B32_THUNK(__ZNSsD2Ev) {
    GuestAddr self = c.args.ptr();
    GuestAddr rep = c.mem.read<uint32_t>(self) - 12;
    if (rep != emptyRep) {
        auto *refcount = c.mem.ptr<int32_t>(rep + 8);
        if (__atomic_fetch_sub(refcount, 1, __ATOMIC_ACQ_REL) <= 0) c.heap.free(rep);
    }
    c.ret(self);
}

// --- iostreams: std::cout and friends aren't bridged, so there is nothing to set up --

B32_THUNK(__ZNSt8ios_base4InitC1Ev) { c.ret(c.args.ptr()); }
B32_THUNK(__ZNSt8ios_base4InitD1Ev) { c.ret(c.args.ptr()); }

// --- errors that would throw -------------------------------------------------------------

B32_THUNK(__ZSt17__throw_bad_allocv) { fatal("guest threw std::bad_alloc (from 0x%08x)", c.cpu.reg(Cpu::LR)); }
B32_THUNK(__ZSt20__throw_length_errorPKc) { fatal("guest threw std::length_error: %s", c.mem.cstr(c.args.ptr())); }
B32_THUNK(__ZSt20__throw_out_of_rangePKc) { fatal("guest threw std::out_of_range: %s", c.mem.cstr(c.args.ptr())); }
B32_THUNK(__ZSt9terminatev) { fatal("guest called std::terminate (from 0x%08x)", c.cpu.reg(Cpu::LR)); }
B32_THUNK(___cxa_rethrow) { fatal("guest rethrew a C++ exception; exceptions are not supported yet"); }

// --- __dynamic_cast ----------------------------------------------------------------------
// type_info layouts (Itanium ABI, 32-bit):
//   __class_type_info     { vtable, name }
//   __si_class_type_info  { vtable, name, base_type }
//   __vmi_class_type_info { vtable, name, flags, base_count, { base_type, offset_flags }[] }
// The kind comes from which runtime vtable the type_info points into.

namespace {

enum class TypeKind { Class, Single, Multiple, Other };

TypeKind kindOf(Call &c, GuestAddr type) {
    GuestAddr vtable = c.mem.read<uint32_t>(type);
    if (vtable == c.rt.dataSymbol("__ZTVN10__cxxabiv117__class_type_infoE") + 8) return TypeKind::Class;
    if (vtable == c.rt.dataSymbol("__ZTVN10__cxxabiv120__si_class_type_infoE") + 8) return TypeKind::Single;
    if (vtable == c.rt.dataSymbol("__ZTVN10__cxxabiv121__vmi_class_type_infoE") + 8) return TypeKind::Multiple;
    return TypeKind::Other;
}

bool sameType(Call &c, GuestAddr a, GuestAddr b) {
    if (a == b) return true;
    // Weak type_info may be duplicated; the mangled names identify the type.
    return std::strcmp(c.mem.cstr(c.mem.read<uint32_t>(a + 4)), c.mem.cstr(c.mem.read<uint32_t>(b + 4))) == 0;
}

// Finds `target` among the public bases of the object at `object` of type
// `type`; returns its address or 0. Virtual bases are located through the
// vtable's vbase offsets.
GuestAddr findBase(Call &c, GuestAddr object, GuestAddr type, GuestAddr target) {
    if (sameType(c, type, target)) return object;
    switch (kindOf(c, type)) {
    case TypeKind::Single:
        return findBase(c, object, c.mem.read<uint32_t>(type + 8), target);
    case TypeKind::Multiple: {
        uint32_t count = c.mem.read<uint32_t>(type + 12);
        for (uint32_t i = 0; i < count; i++) {
            GuestAddr base = c.mem.read<uint32_t>(type + 16 + i * 8);
            int32_t offsetFlags = c.mem.read<int32_t>(type + 20 + i * 8);
            if (!(offsetFlags & 2)) continue;  // not public
            int32_t offset = offsetFlags >> 8;
            if (offsetFlags & 1) {  // virtual: offset indexes the vtable
                GuestAddr vptr = c.mem.read<uint32_t>(object);
                offset = c.mem.read<int32_t>(vptr + offset);
            }
            if (GuestAddr found = findBase(c, object + offset, base, target)) return found;
        }
        return 0;
    }
    default: return 0;
    }
}

}  // namespace

// void *__dynamic_cast(const void *src, const __class_type_info *srcType,
//                      const __class_type_info *dstType, ptrdiff_t src2dst)
B32_THUNK(___dynamic_cast) {
    GuestAddr src = c.args.ptr();
    c.args.ptr();  // static source type: the dynamic type is what matters
    GuestAddr dstType = c.args.ptr();
    if (!src) {
        c.ret(0);
        return;
    }
    // vtable[-2] is offset-to-top, vtable[-1] the dynamic type.
    GuestAddr vptr = c.mem.read<uint32_t>(src);
    int32_t offsetToTop = c.mem.read<int32_t>(vptr - 8);
    GuestAddr dynamicType = c.mem.read<uint32_t>(vptr - 4);
    GuestAddr whole = src + offsetToTop;
    c.ret(findBase(c, whole, dynamicType, dstType));
}
