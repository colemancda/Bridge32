// The legacy ("fragile") Objective-C runtime's image format, which every
// 32-bit Mac binary uses: __OBJC,__module_info leads to the classes and
// categories, and class references, superclasses and categories' targets are
// names until the runtime fixes them up.
//
// The reader fixes those up in place, because the guest's code reads some of
// them directly (a super send loads super_class from the class), and keeps
// each class at its own address. Everything else the bridge wants is made
// here in the modern format: a class_ro_t, an ivar list whose offset pointers
// point into the legacy list, protocol lists, and for each protocol a modern
// protocol_t (protocolData), so the rest of the bridge reads one format.

#include "Bridge.h"

#include "core/Log.h"
#include "core/Runtime.h"

#include <algorithm>
#include <cstring>

using namespace b32;
using namespace b32::objc;

namespace {
// struct objc_class { isa, super_class, name, version, info, instance_size,
// ivars, methodLists, cache, protocols, ivar_layout, ext }.
constexpr uint32_t kIsa = 0, kSuper = 4, kName = 8, kInfo = 16, kInstanceSize = 20, kIvars = 24, kMethods = 28,
                   kProtocols = 36, kExt = 44;
constexpr uint32_t kInfoHasExt = 0x800;  // CLS_EXT: the two fields after protocols exist
constexpr uint32_t kExtProperties = 8;   // objc_class_ext { size, weak_ivar_layout, properties }

// struct objc_category { name, class_name, instance_methods, class_methods, protocols, ... }.
constexpr uint32_t kCategoryName = 0, kCategoryClass = 4, kCategoryInstance = 8, kCategoryClassMethods = 12,
                   kCategoryProtocols = 16;

// struct objc_module { version, size, name, symtab }, and
// struct objc_symtab { sel_ref_cnt, refs, cls_def_cnt (16), cat_def_cnt (16), defs[] }.
constexpr uint32_t kModuleSize = 4, kModuleSymtab = 12;
constexpr uint32_t kSymtabClassCount = 8, kSymtabCategoryCount = 10, kSymtabDefs = 12;

// struct old_protocol { isa (its extension), name, protocol_list, instance_methods, class_methods },
// struct old_protocol_ext { size, optional_instance_methods, optional_class_methods, ... }.
constexpr uint32_t kProtocolSize = 20, kProtocolExt = 0, kProtocolList = 8, kProtocolInstance = 12, kProtocolClass = 16;
constexpr uint32_t kProtocolExtInstance = 4, kProtocolExtClass = 8;

// What the modern-format code reads.
constexpr uint32_t kRoSize = 40, kRoInstanceStart = 4, kRoInstanceSize = 8, kRoName = 16, kRoMethods = 20,
                   kRoProtocols = 24, kRoIvars = 28, kRoProperties = 36;
constexpr uint32_t kRoFlagMeta = 1;
constexpr uint32_t kModernProtocolSize = 32;
constexpr uint32_t kModernIvarSize = 20, kModernMethodSize = 12;

constexpr uint32_t kImageRequiresGc = 4;

// The alignment (log2) and size the first character of a type encoding gives;
// structs and arrays count as words, which only reflection sees.
std::pair<uint32_t, uint32_t> ivarShape(const char *type) {
    switch (type ? *type : 0) {
    case 'c': case 'C': case 'B': return {0, 1};
    case 's': case 'S': return {1, 2};
    case 'q': case 'Q': case 'd': return {2, 8};
    default: return {2, 4};
    }
}
}  // namespace

// A protocol_list as the modern { count, protocol_t *... }, flattening the
// legacy chain { next, count, list[] }. Entries stay the guest's protocols.
GuestAddr Bridge::makeLegacyProtocolList(GuestAddr list) {
    GuestMemory &mem = rt_.mem();
    std::vector<GuestAddr> protocols;
    for (GuestAddr l = list; l; l = mem.read<uint32_t>(l)) {
        uint32_t count = mem.read<uint32_t>(l + 4);
        for (uint32_t i = 0; i < count; i++) protocols.push_back(mem.read<uint32_t>(l + 8 + i * 4));
    }
    if (protocols.empty()) return 0;
    GuestAddr modern = rt_.heap().calloc(uint32_t(protocols.size()) + 1, 4);
    mem.write<uint32_t>(modern, uint32_t(protocols.size()));
    for (size_t i = 0; i < protocols.size(); i++) mem.write<uint32_t>(modern + 4 + uint32_t(i) * 4, protocols[i]);
    return modern;
}

// objc_method_description_list { count, { name, types }... } as a method list.
GuestAddr Bridge::makeLegacyDescriptionList(GuestAddr list) {
    if (!list) return 0;
    GuestMemory &mem = rt_.mem();
    uint32_t count = mem.read<uint32_t>(list);
    GuestAddr modern = rt_.heap().calloc(1, 8 + count * kModernMethodSize);
    mem.write<uint32_t>(modern, kModernMethodSize);
    mem.write<uint32_t>(modern + 4, count);
    for (uint32_t i = 0; i < count; i++) {
        GuestAddr entry = modern + 8 + i * kModernMethodSize;
        mem.write<uint32_t>(entry, mem.read<uint32_t>(list + 4 + i * 8));
        mem.write<uint32_t>(entry + 4, mem.read<uint32_t>(list + 8 + i * 8));
    }
    return modern;
}

// objc_method_list { obsolete, count, { SEL, types, IMP }... } already has the
// modern shape but for its first word: an entry size there makes it one.
void Bridge::prepareLegacyMethods(GuestAddr list) {
    if (!list) return;
    GuestMemory &mem = rt_.mem();
    mem.write<uint32_t>(list, kModernMethodSize);
    uint32_t count = mem.read<uint32_t>(list + 4);
    for (uint32_t i = 0; i < count; i++) {
        GuestAddr entry = list + 8 + i * kModernMethodSize;
        mem.write<uint32_t>(entry, guestSel(mem.cstr(mem.read<uint32_t>(entry))));
    }
}

GuestAddr Bridge::makeLegacyRo(uint32_t flags, GuestAddr name, GuestAddr methods, GuestAddr protocols, GuestAddr ivars,
                               GuestAddr properties, uint32_t instanceStart, uint32_t instanceSize) {
    GuestMemory &mem = rt_.mem();
    GuestAddr ro = rt_.heap().calloc(1, kRoSize);
    mem.write<uint32_t>(ro, flags);
    mem.write<uint32_t>(ro + kRoInstanceStart, instanceStart);
    mem.write<uint32_t>(ro + kRoInstanceSize, instanceSize);
    mem.write<uint32_t>(ro + kRoName, name);
    mem.write<uint32_t>(ro + kRoMethods, methods);
    mem.write<uint32_t>(ro + kRoProtocols, protocols);
    mem.write<uint32_t>(ro + kRoIvars, ivars);
    mem.write<uint32_t>(ro + kRoProperties, properties);
    return ro;
}

ClassInfo *Bridge::realizeLegacyClass(GuestAddr addr) {
    std::lock_guard guard(lock_);
    if (ClassInfo *existing = classInfo(addr)) return existing;
    GuestMemory &mem = rt_.mem();

    GuestAddr metaAddr = mem.read<uint32_t>(addr + kIsa);
    GuestAddr nameAddr = mem.read<uint32_t>(addr + kName);
    GuestAddr superName = mem.read<uint32_t>(addr + kSuper);
    ClassInfo *super = nullptr;
    if (superName) {
        std::string name = mem.cstr(superName);
        auto inImage = legacyClasses_.find(name);
        super = inImage != legacyClasses_.end() ? realizeLegacyClass(inImage->second) : classNamed(name);
        if (!super) super = stubForName(name);
    }

    auto *cls = new ClassInfo;
    auto *meta = new ClassInfo;
    cls->addr = addr;
    meta->addr = metaAddr;
    cls->name = meta->name = mem.cstr(nameAddr);
    cls->isGuest = meta->isGuest = true;
    meta->isMeta = true;
    cls->meta = meta;
    meta->instance = cls;
    cls->super = super;
    meta->super = super ? super->meta : cls;  // a root metaclass's superclass is its class

    // The fixups the guest and the legacy runtime's layout rely on.
    ClassInfo *rootMeta = meta;
    while (rootMeta->super && rootMeta->super->isMeta) rootMeta = rootMeta->super;
    mem.write<uint32_t>(addr + kSuper, super ? super->addr : 0);
    mem.write<uint32_t>(metaAddr + kIsa, rootMeta->addr);
    mem.write<uint32_t>(metaAddr + kSuper, meta->super->addr);

    // Ivars keep the offsets compiled into the guest's code, past where the
    // host superclass's 32-bit ivars would be; those bytes go unused.
    uint32_t instanceSize = std::max(mem.read<uint32_t>(addr + kInstanceSize), kObjectHeaderSize);
    cls->instanceSize = instanceSize;
    GuestAddr ivars = mem.read<uint32_t>(addr + kIvars), modernIvars = 0;
    uint32_t instanceStart = instanceSize;
    if (ivars) {
        // objc_ivar_list { count, { name, type, int offset }... }
        uint32_t count = mem.read<uint32_t>(ivars);
        modernIvars = rt_.heap().calloc(1, 8 + count * kModernIvarSize);
        mem.write<uint32_t>(modernIvars, kModernIvarSize);
        mem.write<uint32_t>(modernIvars + 4, count);
        for (uint32_t i = 0; i < count; i++) {
            GuestAddr legacy = ivars + 4 + i * 12;
            GuestAddr name = mem.read<uint32_t>(legacy), type = mem.read<uint32_t>(legacy + 4);
            GuestAddr offsetVar = legacy + 8;
            GuestAddr entry = modernIvars + 8 + i * kModernIvarSize;
            auto [align, size] = ivarShape(type ? mem.cstr(type) : nullptr);
            mem.write<uint32_t>(entry, offsetVar);
            mem.write<uint32_t>(entry + 4, name);
            mem.write<uint32_t>(entry + 8, type);
            mem.write<uint32_t>(entry + 12, align);
            mem.write<uint32_t>(entry + 16, size);
            instanceStart = std::min(instanceStart, mem.read<uint32_t>(offsetVar));
            cls->ivars.push_back({name ? mem.cstr(name) : "", offsetVar, type ? mem.cstr(type) : "", entry});
        }
    }

    GuestAddr methods = mem.read<uint32_t>(addr + kMethods), metaMethods = mem.read<uint32_t>(metaAddr + kMethods);
    prepareLegacyMethods(methods);
    prepareLegacyMethods(metaMethods);
    if (methods) addGuestMethods(cls, methods);
    if (metaMethods) addGuestMethods(meta, metaMethods);

    GuestAddr protocols = makeLegacyProtocolList(mem.read<uint32_t>(addr + kProtocols)), properties = 0;
    if (mem.read<uint32_t>(addr + kInfo) & kInfoHasExt)
        if (GuestAddr ext = mem.read<uint32_t>(addr + kExt)) properties = mem.read<uint32_t>(ext + kExtProperties);
    cls->ro = makeLegacyRo(0, nameAddr, methods, protocols, modernIvars, properties, instanceStart, instanceSize);
    meta->ro = makeLegacyRo(kRoFlagMeta, nameAddr, metaMethods, 0, 0, 0, 0, 0);

    finishGuestClass(cls);
    return cls;
}

void Bridge::setupLegacyImage(const Image &image) {
    const Section *modules = image.section("__OBJC", "__module_info");
    if (!modules) return;
    GuestMemory &mem = rt_.mem();

    if (const Section *info = image.section("__OBJC", "__image_info"))
        if (mem.read<uint32_t>(info->addr + 4) & kImageRequiresGc)
            log("%s requires garbage collection; objects it would have let go of are never freed", image.path.c_str());

    if (const Section *protocols = image.section("__OBJC", "__protocol"))
        for (uint32_t off = 0; off + kProtocolSize <= protocols->size; off += kProtocolSize) {
            GuestAddr proto = protocols->addr + off;
            GuestAddr ext = mem.read<uint32_t>(proto + kProtocolExt);
            GuestAddr modern = rt_.heap().calloc(1, kModernProtocolSize);
            mem.write<uint32_t>(modern + 4, mem.read<uint32_t>(proto + 4));
            mem.write<uint32_t>(modern + 8, makeLegacyProtocolList(mem.read<uint32_t>(proto + kProtocolList)));
            mem.write<uint32_t>(modern + 12, makeLegacyDescriptionList(mem.read<uint32_t>(proto + kProtocolInstance)));
            mem.write<uint32_t>(modern + 16, makeLegacyDescriptionList(mem.read<uint32_t>(proto + kProtocolClass)));
            if (ext) {
                mem.write<uint32_t>(modern + 20, makeLegacyDescriptionList(mem.read<uint32_t>(ext + kProtocolExtInstance)));
                mem.write<uint32_t>(modern + 24, makeLegacyDescriptionList(mem.read<uint32_t>(ext + kProtocolExtClass)));
            }
            mem.write<uint32_t>(proto + kProtocolExt, 0);  // no class, like a modern one in a file
            std::string name = mem.cstr(mem.read<uint32_t>(proto + 4));
            legacyProtocols_[proto] = modern;
            guestProtocols_[proto] = name;
            guestProtocolByName_.emplace(name, proto);
        }

    struct Module {
        GuestAddr defs;
        uint32_t classes, categories;
    };
    std::vector<Module> list;
    for (uint32_t off = 0; off < modules->size;) {
        uint32_t size = mem.read<uint32_t>(modules->addr + off + kModuleSize);
        if (!size) break;
        if (GuestAddr symtab = mem.read<uint32_t>(modules->addr + off + kModuleSymtab))
            list.push_back({symtab + kSymtabDefs, mem.read<uint16_t>(symtab + kSymtabClassCount),
                            mem.read<uint16_t>(symtab + kSymtabCategoryCount)});
        off += size;
    }

    // Superclasses may come later in the image, so names first.
    legacyClasses_.clear();
    for (const Module &m : list)
        for (uint32_t i = 0; i < m.classes; i++) {
            GuestAddr cls = mem.read<uint32_t>(m.defs + i * 4);
            legacyClasses_[mem.cstr(mem.read<uint32_t>(cls + kName))] = cls;
        }
    for (const Module &m : list)
        for (uint32_t i = 0; i < m.classes; i++) realizeLegacyClass(mem.read<uint32_t>(m.defs + i * 4));

    for (const Module &m : list)
        for (uint32_t i = 0; i < m.categories; i++) {
            GuestAddr cat = mem.read<uint32_t>(m.defs + (m.classes + i) * 4);
            std::string target = mem.cstr(mem.read<uint32_t>(cat + kCategoryClass));
            ClassInfo *cls = classNamed(target);
            if (!cls) cls = stubForName(target);
            GuestAddr instanceMethods = mem.read<uint32_t>(cat + kCategoryInstance);
            GuestAddr classMethods = mem.read<uint32_t>(cat + kCategoryClassMethods);
            prepareLegacyMethods(instanceMethods);
            prepareLegacyMethods(classMethods);
            addCategoryMethods(cls, mem.cstr(mem.read<uint32_t>(cat + kCategoryName)), instanceMethods, classMethods);
            if (GuestAddr protocols = makeLegacyProtocolList(mem.read<uint32_t>(cat + kCategoryProtocols)))
                guestClassProtocols_[cls->addr].push_back(protocols);
        }

    for (const auto &s : image.sections) {
        if (s.name == "__message_refs")
            for (uint32_t off = 0; off < s.size; off += 4)
                mem.write<uint32_t>(s.addr + off, guestSel(mem.cstr(mem.read<uint32_t>(s.addr + off))));
        if (s.name == "__cls_refs")
            for (uint32_t off = 0; off < s.size; off += 4) {
                std::string name = mem.cstr(mem.read<uint32_t>(s.addr + off));
                ClassInfo *cls = classNamed(name);
                if (!cls) cls = stubForName(name);
                mem.write<uint32_t>(s.addr + off, cls->addr);
            }
    }
    legacyClasses_.clear();
}
