/*
 * midi/native: MIDI input from the system's MIDI sources (CoreMIDI on
 * macOS). An input is a port connected to one source or to all of them;
 * CoreMIDI calls back on its own thread, which parses the bytes into
 * messages and puts them into the input's ring, and slang takes them out
 * with read whenever it likes (a render isolate every block, a program
 * every frame). Nothing here runs slang on CoreMIDI's thread.
 *
 * A message is one uint32: status | data1 << 8 | data2 << 16 (channel
 * messages and the system messages that have data; sysex and clock are
 * dropped). One CoreMIDI client serves every VM of the process, made once;
 * each input has its own port, ring and lock, so isolates may each open
 * their own.
 *
 *   sources() -> {string}           the sources' names, in index order
 *   open(index) -> Input            index -1: every source
 *   read(input, buffer) -> int      messages into a uint32 buffer, count
 *   close(input)
 *   parse(bytes) -> {int}           what bytes from a source become (tests)
 *
 * Built into ../lib/<platform>/native.dylib by native/build.zig.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include "slang.h"

#define TNAME "midi.Input"
#define RING 4096
#define MAX_SOURCES 64

typedef struct Input {
    pthread_mutex_t lock;
    uint32_t ring[RING];
    uint32_t head; /* next to write */
    uint32_t tail; /* next to read */
    uint32_t dropped;
    /* parsing, per source: running status and a message in progress */
    uint8_t status[MAX_SOURCES];
    uint8_t data[MAX_SOURCES][2];
    uint8_t have[MAX_SOURCES];
    uint8_t in_sysex[MAX_SOURCES];
    int open;
#ifdef __APPLE__
    unsigned int port; /* MIDIPortRef */
#endif
} Input;

/* the userdata holds a pointer: the Input itself is never freed (see
 * l_close), so CoreMIDI's thread cannot write into freed memory */
typedef struct InputHandle {
    Input *in;
} InputHandle;

static void push(Input *in, uint32_t m) {
    pthread_mutex_lock(&in->lock);
    in->ring[in->head % RING] = m;
    in->head++;
    if (in->head - in->tail > RING) {
        /* full: the oldest goes */
        in->tail = in->head - RING;
        in->dropped++;
    }
    pthread_mutex_unlock(&in->lock);
}

/* how many data bytes a status takes */
static int data_bytes(uint8_t status) {
    switch (status & 0xF0) {
    case 0xC0:
    case 0xD0:
        return 1;
    case 0xF0:
        if (status == 0xF1 || status == 0xF3) return 1;
        if (status == 0xF2) return 2;
        return 0;
    default:
        return 2;
    }
}

/* the bytes of one source, into messages */
static void parse(Input *in, int src, const uint8_t *bytes, int n) {
    if (src < 0 || src >= MAX_SOURCES) src = 0;
    for (int i = 0; i < n; i++) {
        uint8_t b = bytes[i];
        if (b >= 0xF8) {
            /* real time (clock, start, stop...): dropped, without
             * disturbing a message in progress */
            continue;
        }
        if (b & 0x80) {
            if (b == 0xF0) {
                in->in_sysex[src] = 1;
                continue;
            }
            if (b == 0xF7) {
                in->in_sysex[src] = 0;
                continue;
            }
            in->in_sysex[src] = 0;
            in->status[src] = b;
            in->have[src] = 0;
            if (data_bytes(b) == 0) {
                if (b < 0xF0 || b == 0xF6) push(in, b);
                in->status[src] = 0;
            }
            continue;
        }
        if (in->in_sysex[src] || in->status[src] == 0) continue;
        in->data[src][in->have[src]++] = b;
        int need = data_bytes(in->status[src]);
        if (in->have[src] >= need) {
            uint32_t m = in->status[src] | ((uint32_t)in->data[src][0] << 8);
            if (need == 2) m |= (uint32_t)in->data[src][1] << 16;
            push(in, m);
            in->have[src] = 0;
            /* system common messages have no running status */
            if (in->status[src] >= 0xF0) in->status[src] = 0;
        }
    }
}

static Input *new_input(void) {
    Input *in = calloc(1, sizeof(Input));
    pthread_mutex_init(&in->lock, NULL);
    in->open = 1;
    return in;
}

static Input *check_input(slang_State *S, int idx) {
    InputHandle *h = slang_checkudata(S, idx, TNAME);
    if (h == NULL) return NULL;
    if (h->in == NULL || !h->in->open) {
        slang_error(S, "midi: the input is closed");
        return NULL;
    }
    return h->in;
}

/* read(input, buffer) -> int: as many messages as the uint32 buffer holds */
static int l_read(slang_State *S) {
    Input *in = check_input(S, 1);
    if (in == NULL) return SLANG_ERROR;
    size_t count = 0, size = 0;
    uint32_t *out = slang_checkbuffer(S, 2, &count, &size);
    if (slang_failed(S)) return SLANG_ERROR;
    if (size != 4) return slang_error(S, "midi.read: the buffer must be of uint32");
    size_t n = 0;
    pthread_mutex_lock(&in->lock);
    while (in->tail != in->head && n < count) {
        out[n++] = in->ring[in->tail % RING];
        in->tail++;
    }
    pthread_mutex_unlock(&in->lock);
    slang_pushint(S, (int64_t)n);
    return 1;
}

/* parse(bytes: string) -> {int}: the messages bytes from one source
 * become, as read gives them (for tests: no device needed) */
static int l_parse(slang_State *S) {
    size_t n = 0;
    const char *bytes = slang_checklstring(S, 1, &n);
    if (slang_failed(S)) return SLANG_ERROR;
    Input *in = new_input();
    parse(in, 0, (const uint8_t *)bytes, (int)n);
    slang_newtable(S);
    int64_t k = 0;
    while (in->tail != in->head) {
        slang_pushint(S, in->ring[in->tail % RING]);
        slang_seti(S, -2, k++);
        in->tail++;
    }
    pthread_mutex_destroy(&in->lock);
    free(in);
    return 1;
}

#ifdef __APPLE__
#include <CoreMIDI/CoreMIDI.h>

static MIDIClientRef client;
static OSStatus client_status = -1;
static pthread_once_t client_once = PTHREAD_ONCE_INIT;

static void make_client(void) {
    client_status = MIDIClientCreate(CFSTR("slang"), NULL, NULL, &client);
}

static int ensure_client(slang_State *S) {
    pthread_once(&client_once, make_client);
    if (client_status != noErr) {
        slang_error(S, "midi: CoreMIDI could not start (error %d)", (int)client_status);
        return 0;
    }
    return 1;
}

/* CoreMIDI's thread: the packets of a source (its index is the
 * connection's refcon) into the input's ring */
static void read_proc(const MIDIPacketList *list, void *port_ref, void *src_ref) {
    Input *in = port_ref;
    int src = (int)(intptr_t)src_ref;
    const MIDIPacket *p = &list->packet[0];
    for (UInt32 i = 0; i < list->numPackets; i++) {
        parse(in, src, p->data, p->length);
        p = MIDIPacketNext(p);
    }
}

static void source_name(MIDIEndpointRef src, char *out, size_t size) {
    CFStringRef name = NULL;
    out[0] = 0;
    if (MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &name) != noErr || name == NULL) {
        MIDIObjectGetStringProperty(src, kMIDIPropertyName, &name);
    }
    if (name != NULL) {
        CFStringGetCString(name, out, (CFIndex)size, kCFStringEncodingUTF8);
        CFRelease(name);
    }
}

/* sources() -> {string} */
static int l_sources(slang_State *S) {
    if (!ensure_client(S)) return SLANG_ERROR;
    slang_newtable(S);
    ItemCount n = MIDIGetNumberOfSources();
    for (ItemCount i = 0; i < n; i++) {
        char name[256];
        source_name(MIDIGetSource(i), name, sizeof name);
        slang_pushstring(S, name);
        slang_seti(S, -2, (int64_t)i);
    }
    return 1;
}

/* the port goes; the Input stays allocated (a few kilobytes) in case
 * CoreMIDI's thread is still delivering a packet */
static void close_handle(void *data) {
    InputHandle *h = data;
    if (h->in != NULL && h->in->open) {
        h->in->open = 0;
        MIDIPortDispose(h->in->port);
    }
}

/* open(index) -> Input: index -1 connects every source */
static int l_open(slang_State *S) {
    int64_t index = slang_checkint(S, 1);
    if (slang_failed(S)) return SLANG_ERROR;
    if (!ensure_client(S)) return SLANG_ERROR;
    ItemCount n = MIDIGetNumberOfSources();
    if (index >= (int64_t)n) return slang_error(S, "midi.open: there is no source %lld", (long long)index);
    Input *in = new_input();
    MIDIPortRef port;
    OSStatus st = MIDIInputPortCreate(client, CFSTR("slang input"), read_proc, in, &port);
    if (st != noErr) {
        free(in);
        return slang_error(S, "midi.open: no port (error %d)", (int)st);
    }
    in->port = port;
    for (ItemCount i = 0; i < n; i++) {
        if (index < 0 || (ItemCount)index == i) {
            MIDIPortConnectSource(port, MIDIGetSource(i), (void *)(intptr_t)i);
        }
    }
    InputHandle *h = slang_newuserdata(S, sizeof(InputHandle), TNAME, close_handle);
    h->in = in;
    return 1;
}

/* close(input) (an input that is collected closes too) */
static int l_close(slang_State *S) {
    InputHandle *h = slang_checkudata(S, 1, TNAME);
    if (h == NULL) return SLANG_ERROR;
    close_handle(h);
    return 0;
}

#else

/* other systems: no sources yet (ALSA and Windows are to come) */
static int l_sources(slang_State *S) {
    slang_newtable(S);
    return 1;
}

static int l_open(slang_State *S) {
    return slang_error(S, "midi.open: MIDI input is only supported on macOS so far");
}

static int l_close(slang_State *S) {
    (void)S;
    return 0;
}

#endif

static const slang_Reg funcs[] = {
    {"sources", l_sources},
    {"open", l_open},
    {"read", l_read},
    {"close", l_close},
    {"parse", l_parse},
    {NULL, NULL},
};

SLANG_EXPORT int slang_ext_version_midi_native(void) {
    return SLANG_API_VERSION;
}

SLANG_EXPORT int slang_open_midi_native(slang_State *S) {
    slang_newmodule(S, funcs);
    return 1;
}
