/*
 * microphone/native: audio input from the system's capture devices
 * (CoreAudio on macOS, through an AudioQueue). An input records from one
 * device into a ring of float samples on the queue's own thread; slang
 * takes them out with read whenever it likes (a render isolate every
 * block, a program every frame). Nothing here runs slang on the audio
 * thread.
 *
 * The queue converts what the device gives to the format asked for (float
 * samples, interleaved, at the rate and channel count open was given), so
 * a 44.1 kHz microphone reads as 48 kHz when 48000 was asked. When the ring
 * is full the oldest frames go (counted as dropped): a reader that falls
 * behind hears the latest sound, not a growing delay.
 *
 *   devices() -> {{name, uid, channels, sample_rate, default}}
 *   permission() -> string          "granted", "denied", "restricted",
 *                                   "undetermined" or "unknown"
 *   open(uid, rate, channels, frames) -> Input    uid "": the default device
 *   virtual(rate, channels, frames) -> Input      no device: write feeds it
 *   read(input, buffer) -> int      frames into a float buffer, count
 *   write(input, buffer) -> int     frames from a float buffer into the ring
 *   waiting(input) -> int           frames ready to read
 *   level(input) -> float           the peak since the last call (0..1)
 *   dropped(input) -> int           frames lost to a full ring, in all
 *   close(input)
 *
 * Built into ../lib/<platform>/native.dylib by native/build.zig.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <pthread.h>
#include "slang.h"

#define TNAME "microphone.Input"
#define QUEUE_BUFFERS 3

typedef struct Input {
    pthread_mutex_t lock;
    float *ring;     /* frames * channels samples */
    uint64_t frames; /* the ring's length in frames */
    uint64_t head;   /* frames written, in all */
    uint64_t tail;   /* frames read, in all */
    uint64_t dropped;
    float peak;
    int channels;
    double rate;
    int open;
#ifdef __APPLE__
    void *queue; /* AudioQueueRef */
#endif
} Input;

typedef struct InputHandle {
    Input *in;
} InputHandle;

/* n frames of interleaved samples into the ring (the audio thread, or
 * write); the oldest go when it is full */
static void push(Input *in, const float *src, uint64_t n) {
    int ch = in->channels;
    float peak = 0.0f;
    for (uint64_t i = 0; i < n * (uint64_t)ch; i++) {
        float a = fabsf(src[i]);
        if (a > peak) peak = a;
    }
    pthread_mutex_lock(&in->lock);
    if (n > in->frames) {
        /* more than the ring holds: only the last of it (the check
         * below counts what is skipped as dropped) */
        in->head += n - in->frames;
        src += (n - in->frames) * (uint64_t)ch;
        n = in->frames;
    }
    uint64_t done = 0;
    while (done < n) {
        uint64_t at = (in->head + done) % in->frames;
        uint64_t run = n - done;
        if (at + run > in->frames) run = in->frames - at;
        memcpy(in->ring + at * (uint64_t)ch, src + done * (uint64_t)ch, run * (uint64_t)ch * sizeof(float));
        done += run;
    }
    in->head += n;
    if (in->head - in->tail > in->frames) {
        in->dropped += in->head - in->tail - in->frames;
        in->tail = in->head - in->frames;
    }
    if (peak > in->peak) in->peak = peak;
    pthread_mutex_unlock(&in->lock);
}

static Input *new_input(double rate, int channels, uint64_t frames) {
    Input *in = calloc(1, sizeof(Input));
    if (in == NULL) return NULL;
    in->ring = calloc(frames * (uint64_t)channels, sizeof(float));
    if (in->ring == NULL) {
        free(in);
        return NULL;
    }
    pthread_mutex_init(&in->lock, NULL);
    in->frames = frames;
    in->channels = channels;
    in->rate = rate;
    in->open = 1;
    return in;
}

static void free_input(Input *in) {
    pthread_mutex_destroy(&in->lock);
    free(in->ring);
    free(in);
}

static void stop_device(Input *in);

/* the finalizer and close: the device stops (synchronously, so its thread
 * is done with the ring), then the memory goes */
static void close_handle(void *data) {
    InputHandle *h = data;
    if (h->in == NULL) return;
    stop_device(h->in);
    free_input(h->in);
    h->in = NULL;
}

static Input *check_input(slang_State *S, int idx) {
    InputHandle *h = slang_checkudata(S, idx, TNAME);
    if (h == NULL) return NULL;
    if (h->in == NULL) {
        slang_error(S, "microphone: the input is closed");
        return NULL;
    }
    return h->in;
}

/* the float buffer at idx, as whole frames of the input's channels */
static float *check_frames(slang_State *S, Input *in, int idx, uint64_t *frames) {
    size_t count = 0, size = 0;
    float *p = slang_checkbuffer(S, idx, &count, &size);
    if (slang_failed(S)) return NULL;
    const char *t = slang_buffertype(S, idx);
    if (size != 4 || t == NULL || strcmp(t, "float") != 0) {
        slang_error(S, "microphone: the buffer must be of float");
        return NULL;
    }
    *frames = count / (uint64_t)in->channels;
    return p;
}

static int check_options(slang_State *S, int first, double *rate, int *channels, uint64_t *frames) {
    *rate = slang_checknumber(S, first);
    int64_t ch = slang_checkint(S, first + 1);
    int64_t n = slang_checkint(S, first + 2);
    if (slang_failed(S)) return 0;
    if (*rate < 1000 || *rate > 384000) {
        slang_error(S, "microphone.open: a sample rate of %g is not one", *rate);
        return 0;
    }
    if (ch < 1 || ch > 32) {
        slang_error(S, "microphone.open: %lld channels are not possible", (long long)ch);
        return 0;
    }
    if (n < 64 || n > (int64_t)1 << 28) {
        slang_error(S, "microphone.open: a ring of %lld frames is not possible", (long long)n);
        return 0;
    }
    *channels = (int)ch;
    *frames = (uint64_t)n;
    return 1;
}

static int push_input(slang_State *S, Input *in) {
    InputHandle *h = slang_newuserdata(S, sizeof(InputHandle), TNAME, close_handle);
    h->in = in;
    return 1;
}

/* virtual(rate, channels, frames) -> Input: a ring with no device behind
 * it, filled by write (tests, or a file played as if it were heard) */
static int l_virtual(slang_State *S) {
    double rate;
    int ch;
    uint64_t frames;
    if (!check_options(S, 1, &rate, &ch, &frames)) return SLANG_ERROR;
    Input *in = new_input(rate, ch, frames);
    if (in == NULL) return slang_error(S, "microphone: out of memory");
    return push_input(S, in);
}

/* read(input, buffer) -> int: as many whole frames as wait and fit */
static int l_read(slang_State *S) {
    Input *in = check_input(S, 1);
    if (in == NULL) return SLANG_ERROR;
    uint64_t room = 0;
    float *out = check_frames(S, in, 2, &room);
    if (out == NULL) return SLANG_ERROR;
    int ch = in->channels;
    pthread_mutex_lock(&in->lock);
    uint64_t n = in->head - in->tail;
    if (n > room) n = room;
    uint64_t done = 0;
    while (done < n) {
        uint64_t at = (in->tail + done) % in->frames;
        uint64_t run = n - done;
        if (at + run > in->frames) run = in->frames - at;
        memcpy(out + done * (uint64_t)ch, in->ring + at * (uint64_t)ch, run * (uint64_t)ch * sizeof(float));
        done += run;
    }
    in->tail += n;
    pthread_mutex_unlock(&in->lock);
    slang_pushint(S, (int64_t)n);
    return 1;
}

/* write(input, buffer) -> int: the buffer's whole frames into the ring */
static int l_write(slang_State *S) {
    Input *in = check_input(S, 1);
    if (in == NULL) return SLANG_ERROR;
    uint64_t n = 0;
    float *src = check_frames(S, in, 2, &n);
    if (src == NULL) return SLANG_ERROR;
    push(in, src, n);
    slang_pushint(S, (int64_t)n);
    return 1;
}

static int l_waiting(slang_State *S) {
    Input *in = check_input(S, 1);
    if (in == NULL) return SLANG_ERROR;
    pthread_mutex_lock(&in->lock);
    uint64_t n = in->head - in->tail;
    pthread_mutex_unlock(&in->lock);
    slang_pushint(S, (int64_t)n);
    return 1;
}

static int l_level(slang_State *S) {
    Input *in = check_input(S, 1);
    if (in == NULL) return SLANG_ERROR;
    pthread_mutex_lock(&in->lock);
    float p = in->peak;
    in->peak = 0.0f;
    pthread_mutex_unlock(&in->lock);
    slang_pushdouble(S, p);
    return 1;
}

static int l_dropped(slang_State *S) {
    Input *in = check_input(S, 1);
    if (in == NULL) return SLANG_ERROR;
    pthread_mutex_lock(&in->lock);
    uint64_t n = in->dropped;
    pthread_mutex_unlock(&in->lock);
    slang_pushint(S, (int64_t)n);
    return 1;
}

/* close(input) (an input that is collected closes too) */
static int l_close(slang_State *S) {
    InputHandle *h = slang_checkudata(S, 1, TNAME);
    if (h == NULL) return SLANG_ERROR;
    close_handle(h);
    return 0;
}

#ifdef __APPLE__
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>

static const char *status_text(OSStatus st, char *buf) {
    /* four printable characters are a code CoreAudio spells */
    uint32_t c = (uint32_t)st;
    char s[4] = {(char)(c >> 24), (char)(c >> 16), (char)(c >> 8), (char)c};
    for (int i = 0; i < 4; i++) {
        if (s[i] < 32 || s[i] > 126) {
            snprintf(buf, 32, "%d", (int)st);
            return buf;
        }
    }
    snprintf(buf, 32, "'%c%c%c%c'", s[0], s[1], s[2], s[3]);
    return buf;
}

/* the queue's thread: a buffer of recorded frames into the ring, and the
 * buffer back to the queue */
static void input_proc(void *user, AudioQueueRef q, AudioQueueBufferRef buf, const AudioTimeStamp *t,
                       UInt32 packets, const AudioStreamPacketDescription *desc) {
    (void)t;
    (void)packets;
    (void)desc;
    Input *in = user;
    uint64_t n = buf->mAudioDataByteSize / (sizeof(float) * (uint64_t)in->channels);
    if (n > 0) push(in, buf->mAudioData, n);
    if (in->open) AudioQueueEnqueueBuffer(q, buf, 0, NULL);
}

static void stop_device(Input *in) {
    if (!in->open) return;
    in->open = 0;
    if (in->queue != NULL) {
        /* synchronous: when they return, the callback has run its last */
        AudioQueueStop(in->queue, true);
        AudioQueueDispose(in->queue, true);
        in->queue = NULL;
    }
}

static CFStringRef copy_string(AudioObjectID id, AudioObjectPropertySelector sel) {
    AudioObjectPropertyAddress a = {sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    CFStringRef s = NULL;
    UInt32 size = sizeof s;
    if (AudioObjectGetPropertyData(id, &a, 0, NULL, &size, &s) != noErr) return NULL;
    return s;
}

static void push_cfstring(slang_State *S, CFStringRef s) {
    char buf[512];
    buf[0] = 0;
    if (s != NULL) CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8);
    slang_pushstring(S, buf);
}

static int input_channels(AudioObjectID id) {
    AudioObjectPropertyAddress a = {kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput,
                                    kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(id, &a, 0, NULL, &size) != noErr || size == 0) return 0;
    AudioBufferList *list = malloc(size);
    if (list == NULL) return 0;
    int n = 0;
    if (AudioObjectGetPropertyData(id, &a, 0, NULL, &size, list) == noErr) {
        for (UInt32 i = 0; i < list->mNumberBuffers; i++) n += (int)list->mBuffers[i].mNumberChannels;
    }
    free(list);
    return n;
}

static AudioObjectID default_input(void) {
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    AudioObjectID id = kAudioObjectUnknown;
    UInt32 size = sizeof id;
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, &id);
    return id;
}

/* devices() -> {{name, uid, channels, sample_rate, default}}: the devices
 * that can record */
static int l_devices(slang_State *S) {
    slang_newtable(S);
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size) != noErr) return 1;
    AudioObjectID *ids = malloc(size);
    if (ids == NULL) return 1;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, ids) != noErr) {
        free(ids);
        return 1;
    }
    AudioObjectID def = default_input();
    int64_t k = 0;
    for (UInt32 i = 0; i < size / sizeof(AudioObjectID); i++) {
        int ch = input_channels(ids[i]);
        if (ch == 0) continue;
        slang_newtable(S);
        CFStringRef name = copy_string(ids[i], kAudioObjectPropertyName);
        push_cfstring(S, name);
        slang_setfield(S, -2, "name");
        if (name != NULL) CFRelease(name);
        CFStringRef uid = copy_string(ids[i], kAudioDevicePropertyDeviceUID);
        push_cfstring(S, uid);
        slang_setfield(S, -2, "uid");
        if (uid != NULL) CFRelease(uid);
        slang_pushint(S, ch);
        slang_setfield(S, -2, "channels");
        AudioObjectPropertyAddress ra = {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal,
                                         kAudioObjectPropertyElementMain};
        Float64 rate = 0;
        UInt32 rs = sizeof rate;
        AudioObjectGetPropertyData(ids[i], &ra, 0, NULL, &rs, &rate);
        slang_pushdouble(S, rate);
        slang_setfield(S, -2, "sample_rate");
        slang_pushbool(S, ids[i] == def);
        slang_setfield(S, -2, "default");
        slang_seti(S, -2, k++);
    }
    free(ids);
    return 1;
}

/* permission() -> string: whether this process may record, as macOS's
 * privacy settings say ([AVCaptureDevice authorizationStatusForMediaType:
 * AVMediaTypeAudio], through the Objective-C runtime). A process that may
 * not records silence. */
static int l_permission(slang_State *S) {
    static void *av = NULL;
    if (av == NULL) av = dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation", RTLD_LAZY);
    Class cls = av ? objc_getClass("AVCaptureDevice") : NULL;
    if (cls == NULL) {
        slang_pushstring(S, "unknown");
        return 1;
    }
    /* AVMediaTypeAudio is the NSString @"soun"; a CFString is one */
    long st = ((long (*)(id, SEL, id))objc_msgSend)((id)cls, sel_registerName("authorizationStatusForMediaType:"),
                                                    (id)CFSTR("soun"));
    const char *names[] = {"undetermined", "restricted", "denied", "granted"};
    slang_pushstring(S, st >= 0 && st <= 3 ? names[st] : "unknown");
    return 1;
}

/* open(uid, rate, channels, frames) -> Input: records from the device of
 * uid ("" the default input) until closed */
static int l_open(slang_State *S) {
    size_t uid_len = 0;
    const char *uid = slang_checklstring(S, 1, &uid_len);
    double rate;
    int ch;
    uint64_t frames;
    if (slang_failed(S) || !check_options(S, 2, &rate, &ch, &frames)) return SLANG_ERROR;
    Input *in = new_input(rate, ch, frames);
    if (in == NULL) return slang_error(S, "microphone: out of memory");
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof f);
    f.mSampleRate = rate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked;
    f.mBitsPerChannel = 32;
    f.mChannelsPerFrame = (UInt32)ch;
    f.mBytesPerFrame = 4 * (UInt32)ch;
    f.mFramesPerPacket = 1;
    f.mBytesPerPacket = 4 * (UInt32)ch;
    char err[32];
    AudioQueueRef q = NULL;
    /* no run loop: the queue calls back on a thread of its own */
    OSStatus st = AudioQueueNewInput(&f, input_proc, in, NULL, NULL, 0, &q);
    if (st != noErr) {
        free_input(in);
        return slang_error(S, "microphone.open: no input queue (%s)", status_text(st, err));
    }
    in->queue = q;
    if (uid_len > 0) {
        CFStringRef s = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
        st = AudioQueueSetProperty(q, kAudioQueueProperty_CurrentDevice, &s, sizeof s);
        CFRelease(s);
        if (st != noErr) {
            stop_device(in);
            free_input(in);
            return slang_error(S, "microphone.open: the device cannot record (%s)", status_text(st, err));
        }
    }
    /* about 10 ms a buffer: what reaches the ring comes that often */
    UInt32 bytes = (UInt32)(rate / 100) * f.mBytesPerFrame;
    for (int i = 0; i < QUEUE_BUFFERS; i++) {
        AudioQueueBufferRef b = NULL;
        st = AudioQueueAllocateBuffer(q, bytes, &b);
        if (st == noErr) st = AudioQueueEnqueueBuffer(q, b, 0, NULL);
        if (st != noErr) {
            stop_device(in);
            free_input(in);
            return slang_error(S, "microphone.open: no buffers (%s)", status_text(st, err));
        }
    }
    st = AudioQueueStart(q, NULL);
    if (st != noErr) {
        stop_device(in);
        free_input(in);
        return slang_error(S, "microphone.open: recording does not start (%s)", status_text(st, err));
    }
    return push_input(S, in);
}

#else

/* other systems: no devices yet (ALSA/PipeWire and WASAPI are to come) */
static void stop_device(Input *in) {
    in->open = 0;
}

static int l_devices(slang_State *S) {
    slang_newtable(S);
    return 1;
}

static int l_permission(slang_State *S) {
    slang_pushstring(S, "unknown");
    return 1;
}

static int l_open(slang_State *S) {
    return slang_error(S, "microphone.open: recording is only supported on macOS so far");
}

#endif

static const slang_Reg funcs[] = {
    {"devices", l_devices},
    {"permission", l_permission},
    {"open", l_open},
    {"virtual", l_virtual},
    {"read", l_read},
    {"write", l_write},
    {"waiting", l_waiting},
    {"level", l_level},
    {"dropped", l_dropped},
    {"close", l_close},
    {NULL, NULL},
};

SLANG_EXPORT int slang_ext_version_microphone_native(void) {
    return SLANG_API_VERSION;
}

SLANG_EXPORT int slang_open_microphone_native(slang_State *S) {
    slang_newmodule(S, funcs);
    return 1;
}
