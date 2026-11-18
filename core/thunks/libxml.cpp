// libxml2's SAX parser, which is how some Mac games read their XML data. The parsing is the host's
// libxml2; the handler is the guest's, a table of callbacks that are called here with the strings copied
// into guest memory for as long as each call lasts.

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/thunks/Thunks.h"

#include <libxml/parser.h>

#include <cstring>
#include <vector>

using namespace b32;

namespace {
// The guest's xmlSAXHandler: 32-bit function pointers in libxml2's field order.
enum Slot : uint32_t {
    kStartDocument = 12, kEndDocument = 13, kStartElement = 14, kEndElement = 15, kCharacters = 17,
    kIgnorableWhitespace = 18, kComment = 20, kWarning = 21, kError = 22, kFatalError = 23, kCdataBlock = 25,
    kInitialized = 27, kStartElementNs = 29,
};
constexpr uint32_t kSax2Magic = 0xDEEDBEAF;

struct Parse {
    Call &c;
    GuestAddr handler, user;
    GuestAddr callback(Slot slot) const { return c.mem.read<uint32_t>(handler + slot * 4); }
};
Parse &parseOf(void *context) { return *static_cast<Parse *>(context); }

// A host string in guest memory until the callback returns.
struct GuestText {
    Call &c;
    GuestAddr addr = 0;
    GuestText(Call &call, const void *bytes, size_t length) : c(call) {
        if (!bytes) return;
        addr = c.heap.alloc(uint32_t(length + 1));
        c.mem.copyIn(addr, bytes, length);
        c.mem.write<uint8_t>(addr + uint32_t(length), 0);
    }
    GuestText(Call &call, const xmlChar *text) : GuestText(call, text, text ? std::strlen(reinterpret_cast<const char *>(text)) : 0) {}
    GuestText(const GuestText &) = delete;
    ~GuestText() {
        if (addr) c.heap.free(addr);
    }
};

void startDocument(void *context) {
    Parse &p = parseOf(context);
    p.c.cpu.call(p.callback(kStartDocument), {p.user});
}
void endDocument(void *context) {
    Parse &p = parseOf(context);
    p.c.cpu.call(p.callback(kEndDocument), {p.user});
}
// void startElement(ctx, name, atts): atts is name, value, name, value, ..., NULL, or NULL itself.
void startElement(void *context, const xmlChar *name, const xmlChar **attributes) {
    Parse &p = parseOf(context);
    GuestText guestName(p.c, name);
    std::vector<std::unique_ptr<GuestText>> texts;
    GuestAddr list = 0;
    if (attributes) {
        size_t count = 0;
        while (attributes[count]) count++;
        list = p.c.heap.alloc(uint32_t((count + 1) * 4));
        for (size_t i = 0; i < count; i++) {
            texts.push_back(std::make_unique<GuestText>(p.c, attributes[i]));
            p.c.mem.write<uint32_t>(list + uint32_t(i * 4), texts.back()->addr);
        }
        p.c.mem.write<uint32_t>(list + uint32_t(count * 4), 0);
    }
    p.c.cpu.call(p.callback(kStartElement), {p.user, guestName.addr, list});
    if (list) p.c.heap.free(list);
}
void endElement(void *context, const xmlChar *name) {
    Parse &p = parseOf(context);
    GuestText guestName(p.c, name);
    p.c.cpu.call(p.callback(kEndElement), {p.user, guestName.addr});
}
// void characters(ctx, text, length): the text isn't terminated; the copy is, which does no harm.
void text(void *context, const xmlChar *chars, int length, Slot slot) {
    Parse &p = parseOf(context);
    GuestText guest(p.c, chars, size_t(length));
    p.c.cpu.call(p.callback(slot), {p.user, guest.addr, uint32_t(length)});
}
void characters(void *context, const xmlChar *chars, int length) { text(context, chars, length, kCharacters); }
void ignorableWhitespace(void *context, const xmlChar *chars, int length) { text(context, chars, length, kIgnorableWhitespace); }
void cdataBlock(void *context, const xmlChar *chars, int length) { text(context, chars, length, kCdataBlock); }
void comment(void *context, const xmlChar *value) {
    Parse &p = parseOf(context);
    GuestText guest(p.c, value);
    p.c.cpu.call(p.callback(kComment), {p.user, guest.addr});
}
// The guest's warning and error callbacks take printf arguments, which can't be passed on from here, so
// what the parser has to say goes to the log.
void report(void *, const char *format, ...) {
    char message[512];
    va_list arguments;
    va_start(arguments, format);
    std::vsnprintf(message, sizeof message, format, arguments);
    va_end(arguments);
    size_t length = std::strlen(message);
    while (length && message[length - 1] == '\n') message[--length] = 0;
    log("libxml2: %s", message);
}

// The host handler for a guest one: only the callbacks the guest has.
xmlSAXHandler hostHandler(const Parse &p) {
    xmlSAXHandler handler = {};
    if (p.c.mem.read<uint32_t>(p.handler + kInitialized * 4) == kSax2Magic && p.callback(kStartElementNs))
        log("libxml2: the guest's SAX2 namespace callbacks aren't called; its SAX1 ones are");
    if (p.callback(kStartDocument)) handler.startDocument = startDocument;
    if (p.callback(kEndDocument)) handler.endDocument = endDocument;
    if (p.callback(kStartElement)) handler.startElement = startElement;
    if (p.callback(kEndElement)) handler.endElement = endElement;
    if (p.callback(kCharacters)) handler.characters = characters;
    if (p.callback(kIgnorableWhitespace)) handler.ignorableWhitespace = ignorableWhitespace;
    if (p.callback(kCdataBlock)) handler.cdataBlock = cdataBlock;
    if (p.callback(kComment)) handler.comment = comment;
    handler.warning = report;
    handler.error = report;
    handler.fatalError = report;
    return handler;
}
}  // namespace

// int xmlSAXUserParseFile(xmlSAXHandlerPtr sax, void *user_data, const char *filename): 0 if the document
// was well formed. The callbacks' first argument is user_data.
B32_THUNK(_xmlSAXUserParseFile) {
    GuestAddr sax = c.args.ptr(), user = c.args.u32(), filename = c.args.ptr();
    if (!sax || !filename) {
        c.ret(uint32_t(-1));
        return;
    }
    Parse parse{c, sax, user};
    xmlSAXHandler handler = hostHandler(parse);
    c.ret(uint32_t(xmlSAXUserParseFile(&handler, &parse, c.mem.cstr(filename))));
}
// int xmlSAXUserParseMemory(xmlSAXHandlerPtr sax, void *user_data, const char *buffer, int size)
B32_THUNK(_xmlSAXUserParseMemory) {
    GuestAddr sax = c.args.ptr(), user = c.args.u32(), buffer = c.args.ptr();
    int size = c.args.i32();
    if (!sax || !buffer || size <= 0) {
        c.ret(uint32_t(-1));
        return;
    }
    Parse parse{c, sax, user};
    xmlSAXHandler handler = hostHandler(parse);
    c.ret(uint32_t(xmlSAXUserParseMemory(&handler, &parse, c.mem.ptr<char>(buffer), size)));
}
