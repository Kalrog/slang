/* The part of SDL3 (3.4) the window package uses, as slang/ffi reads it:
   copied from SDL's headers with SDL_DECLSPEC, SDLCALL and the analyzer
   annotations left out. SDL_Event is a union in SDL; here it is 128 bytes
   the package reads as the event struct its type names. Check it against
   SDL's headers when tool/build.sh moves to a new version. */

typedef uint8_t Uint8;
typedef int16_t Sint16;
typedef uint16_t Uint16;
typedef int32_t Sint32;
typedef uint32_t Uint32;
typedef int64_t Sint64;
typedef uint64_t Uint64;

typedef Uint32 SDL_InitFlags;
typedef Uint64 SDL_WindowFlags;
typedef Uint32 SDL_WindowID;
typedef Uint32 SDL_DisplayID;
typedef Uint32 SDL_PropertiesID;
typedef Uint32 SDL_KeyboardID;
typedef Uint32 SDL_MouseID;
typedef Uint32 SDL_JoystickID;
typedef Uint32 SDL_Keycode;
typedef Uint16 SDL_Keymod;
typedef int SDL_Scancode;
typedef Uint32 SDL_MouseButtonFlags;
typedef int SDL_MouseWheelDirection;
typedef Uint32 SDL_EventType;
typedef int SDL_GamepadAxis;
typedef int SDL_GamepadButton;
typedef Uint32 SDL_PixelFormat;
typedef Uint32 SDL_MessageBoxFlags;
typedef void *SDL_MetalView;
typedef struct SDL_Window SDL_Window;
typedef struct SDL_Gamepad SDL_Gamepad;
typedef struct SDL_DisplayModeData SDL_DisplayModeData;

#define SDL_INIT_AUDIO 0x00000010
#define SDL_INIT_VIDEO 0x00000020
#define SDL_INIT_JOYSTICK 0x00000200
#define SDL_INIT_GAMEPAD 0x00002000
#define SDL_INIT_EVENTS 0x00004000

#define SDL_WINDOW_FULLSCREEN 0x0000000000000001
#define SDL_WINDOW_OCCLUDED 0x0000000000000004
#define SDL_WINDOW_HIDDEN 0x0000000000000008
#define SDL_WINDOW_BORDERLESS 0x0000000000000010
#define SDL_WINDOW_RESIZABLE 0x0000000000000020
#define SDL_WINDOW_MINIMIZED 0x0000000000000040
#define SDL_WINDOW_MAXIMIZED 0x0000000000000080
#define SDL_WINDOW_INPUT_FOCUS 0x0000000000000200
#define SDL_WINDOW_MOUSE_FOCUS 0x0000000000000400
#define SDL_WINDOW_HIGH_PIXEL_DENSITY 0x0000000000002000
#define SDL_WINDOW_ALWAYS_ON_TOP 0x0000000000010000
#define SDL_WINDOW_VULKAN 0x0000000010000000
#define SDL_WINDOW_METAL 0x0000000020000000

#define SDL_KMOD_LSHIFT 0x0001
#define SDL_KMOD_RSHIFT 0x0002
#define SDL_KMOD_LCTRL 0x0040
#define SDL_KMOD_RCTRL 0x0080
#define SDL_KMOD_LALT 0x0100
#define SDL_KMOD_RALT 0x0200
#define SDL_KMOD_LGUI 0x0400
#define SDL_KMOD_RGUI 0x0800

#define SDL_MESSAGEBOX_ERROR 0x00000010
#define SDL_MESSAGEBOX_WARNING 0x00000020
#define SDL_MESSAGEBOX_INFORMATION 0x00000040

#define SDL_PROP_WINDOW_COCOA_WINDOW_POINTER "SDL.window.cocoa.window"
#define SDL_PROP_WINDOW_WIN32_HWND_POINTER "SDL.window.win32.hwnd"
#define SDL_PROP_WINDOW_WIN32_INSTANCE_POINTER "SDL.window.win32.instance"
#define SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER "SDL.window.wayland.display"
#define SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER "SDL.window.wayland.surface"
#define SDL_PROP_WINDOW_X11_DISPLAY_POINTER "SDL.window.x11.display"
#define SDL_PROP_WINDOW_X11_WINDOW_NUMBER "SDL.window.x11.window"

/* SDL_EventType (the ones the package reads) */
#define SDL_EVENT_QUIT 0x100
#define SDL_EVENT_WINDOW_SHOWN 0x202
#define SDL_EVENT_WINDOW_HIDDEN 0x203
#define SDL_EVENT_WINDOW_EXPOSED 0x204
#define SDL_EVENT_WINDOW_MOVED 0x205
#define SDL_EVENT_WINDOW_RESIZED 0x206
#define SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED 0x207
#define SDL_EVENT_WINDOW_METAL_VIEW_RESIZED 0x208
#define SDL_EVENT_WINDOW_MINIMIZED 0x209
#define SDL_EVENT_WINDOW_MAXIMIZED 0x20A
#define SDL_EVENT_WINDOW_RESTORED 0x20B
#define SDL_EVENT_WINDOW_MOUSE_ENTER 0x20C
#define SDL_EVENT_WINDOW_MOUSE_LEAVE 0x20D
#define SDL_EVENT_WINDOW_FOCUS_GAINED 0x20E
#define SDL_EVENT_WINDOW_FOCUS_LOST 0x20F
#define SDL_EVENT_WINDOW_CLOSE_REQUESTED 0x210
#define SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED 0x214
#define SDL_EVENT_WINDOW_OCCLUDED 0x216
#define SDL_EVENT_WINDOW_ENTER_FULLSCREEN 0x217
#define SDL_EVENT_WINDOW_LEAVE_FULLSCREEN 0x218
#define SDL_EVENT_KEY_DOWN 0x300
#define SDL_EVENT_KEY_UP 0x301
#define SDL_EVENT_TEXT_INPUT 0x303
#define SDL_EVENT_MOUSE_MOTION 0x400
#define SDL_EVENT_MOUSE_BUTTON_DOWN 0x401
#define SDL_EVENT_MOUSE_BUTTON_UP 0x402
#define SDL_EVENT_MOUSE_WHEEL 0x403
#define SDL_EVENT_GAMEPAD_AXIS_MOTION 0x650
#define SDL_EVENT_GAMEPAD_BUTTON_DOWN 0x651
#define SDL_EVENT_GAMEPAD_BUTTON_UP 0x652
#define SDL_EVENT_GAMEPAD_ADDED 0x653
#define SDL_EVENT_GAMEPAD_REMOVED 0x654
#define SDL_EVENT_DROP_FILE 0x1000

typedef struct SDL_Rect { int x; int y; int w; int h; } SDL_Rect;

typedef struct SDL_DisplayMode {
    SDL_DisplayID displayID;
    SDL_PixelFormat format;
    int w;
    int h;
    float pixel_density;
    float refresh_rate;
    int refresh_rate_numerator;
    int refresh_rate_denominator;
    SDL_DisplayModeData *internal;
} SDL_DisplayMode;

typedef struct SDL_Event { Uint32 type; Uint8 padding[124]; } SDL_Event;

typedef struct SDL_CommonEvent {
    Uint32 type; Uint32 reserved; Uint64 timestamp;
} SDL_CommonEvent;

typedef struct SDL_WindowEvent {
    SDL_EventType type; Uint32 reserved; Uint64 timestamp;
    SDL_WindowID windowID;
    Sint32 data1;
    Sint32 data2;
} SDL_WindowEvent;

typedef struct SDL_KeyboardEvent {
    SDL_EventType type; Uint32 reserved; Uint64 timestamp;
    SDL_WindowID windowID;
    SDL_KeyboardID which;
    SDL_Scancode scancode;
    SDL_Keycode key;
    SDL_Keymod mod;
    Uint16 raw;
    bool down;
    bool repeat;
} SDL_KeyboardEvent;

typedef struct SDL_TextInputEvent {
    SDL_EventType type; Uint32 reserved; Uint64 timestamp;
    SDL_WindowID windowID;
    const char *text;
} SDL_TextInputEvent;

typedef struct SDL_MouseMotionEvent {
    SDL_EventType type; Uint32 reserved; Uint64 timestamp;
    SDL_WindowID windowID;
    SDL_MouseID which;
    SDL_MouseButtonFlags state;
    float x;
    float y;
    float xrel;
    float yrel;
} SDL_MouseMotionEvent;

typedef struct SDL_MouseButtonEvent {
    SDL_EventType type; Uint32 reserved; Uint64 timestamp;
    SDL_WindowID windowID;
    SDL_MouseID which;
    Uint8 button;
    bool down;
    Uint8 clicks;
    Uint8 padding;
    float x;
    float y;
} SDL_MouseButtonEvent;

typedef struct SDL_MouseWheelEvent {
    SDL_EventType type; Uint32 reserved; Uint64 timestamp;
    SDL_WindowID windowID;
    SDL_MouseID which;
    float x;
    float y;
    SDL_MouseWheelDirection direction;
    float mouse_x;
    float mouse_y;
    Sint32 integer_x;
    Sint32 integer_y;
} SDL_MouseWheelEvent;

typedef struct SDL_GamepadDeviceEvent {
    SDL_EventType type; Uint32 reserved; Uint64 timestamp;
    SDL_JoystickID which;
} SDL_GamepadDeviceEvent;

typedef struct SDL_GamepadAxisEvent {
    SDL_EventType type; Uint32 reserved; Uint64 timestamp;
    SDL_JoystickID which;
    Uint8 axis;
    Uint8 padding1;
    Uint8 padding2;
    Uint8 padding3;
    Sint16 value;
    Uint16 padding4;
} SDL_GamepadAxisEvent;

typedef struct SDL_GamepadButtonEvent {
    SDL_EventType type; Uint32 reserved; Uint64 timestamp;
    SDL_JoystickID which;
    Uint8 button;
    bool down;
    Uint8 padding1;
    Uint8 padding2;
} SDL_GamepadButtonEvent;

typedef struct SDL_DropEvent {
    SDL_EventType type; Uint32 reserved; Uint64 timestamp;
    SDL_WindowID windowID;
    float x;
    float y;
    const char *source;
    const char *data;
} SDL_DropEvent;

bool SDL_Init(SDL_InitFlags flags);
void SDL_Quit(void);
void SDL_QuitSubSystem(SDL_InitFlags flags);
bool SDL_InitSubSystem(SDL_InitFlags flags);
const char * SDL_GetError(void);
int SDL_GetVersion(void);
const char * SDL_GetRevision(void);
bool SDL_SetHint(const char *name, const char *value);
bool SDL_SetAppMetadata(const char *appname, const char *appversion, const char *appidentifier);
SDL_Window * SDL_CreateWindow(const char *title, int w, int h, SDL_WindowFlags flags);
void SDL_DestroyWindow(SDL_Window *window);
SDL_WindowID SDL_GetWindowID(SDL_Window *window);
SDL_Window * SDL_GetWindowFromID(SDL_WindowID id);
bool SDL_GetWindowSize(SDL_Window *window, int *w, int *h);
bool SDL_SetWindowSize(SDL_Window *window, int w, int h);
bool SDL_GetWindowSizeInPixels(SDL_Window *window, int *w, int *h);
float SDL_GetWindowPixelDensity(SDL_Window *window);
float SDL_GetWindowDisplayScale(SDL_Window *window);
const char * SDL_GetWindowTitle(SDL_Window *window);
bool SDL_SetWindowTitle(SDL_Window *window, const char *title);
bool SDL_GetWindowPosition(SDL_Window *window, int *x, int *y);
bool SDL_SetWindowPosition(SDL_Window *window, int x, int y);
bool SDL_SetWindowFullscreen(SDL_Window *window, bool fullscreen);
SDL_WindowFlags SDL_GetWindowFlags(SDL_Window *window);
bool SDL_SetWindowResizable(SDL_Window *window, bool resizable);
bool SDL_ShowWindow(SDL_Window *window);
bool SDL_HideWindow(SDL_Window *window);
bool SDL_RaiseWindow(SDL_Window *window);
bool SDL_MaximizeWindow(SDL_Window *window);
bool SDL_MinimizeWindow(SDL_Window *window);
bool SDL_RestoreWindow(SDL_Window *window);
bool SDL_SetWindowMinimumSize(SDL_Window *window, int min_w, int min_h);
bool SDL_SetWindowAlwaysOnTop(SDL_Window *window, bool on_top);
bool SDL_SetWindowBordered(SDL_Window *window, bool bordered);
SDL_PropertiesID SDL_GetWindowProperties(SDL_Window *window);
void * SDL_GetPointerProperty(SDL_PropertiesID props, const char *name, void *default_value);
Sint64 SDL_GetNumberProperty(SDL_PropertiesID props, const char *name, Sint64 default_value);
SDL_MetalView SDL_Metal_CreateView(SDL_Window *window);
void SDL_Metal_DestroyView(SDL_MetalView view);
void * SDL_Metal_GetLayer(SDL_MetalView view);
bool SDL_PollEvent(SDL_Event *event);
bool SDL_WaitEventTimeout(SDL_Event *event, Sint32 timeoutMS);
void SDL_PumpEvents(void);
const bool * SDL_GetKeyboardState(int *numkeys);
const char * SDL_GetKeyName(SDL_Keycode key);
SDL_Keycode SDL_GetKeyFromName(const char *name);
SDL_Scancode SDL_GetScancodeFromName(const char *name);
const char * SDL_GetScancodeName(SDL_Scancode scancode);
SDL_Keymod SDL_GetModState(void);
SDL_Keycode SDL_GetKeyFromScancode(SDL_Scancode scancode, SDL_Keymod modstate, bool key_event);
bool SDL_StartTextInput(SDL_Window *window);
bool SDL_StopTextInput(SDL_Window *window);
bool SDL_TextInputActive(SDL_Window *window);
SDL_MouseButtonFlags SDL_GetMouseState(float *x, float *y);
SDL_MouseButtonFlags SDL_GetRelativeMouseState(float *x, float *y);
bool SDL_SetWindowRelativeMouseMode(SDL_Window *window, bool enabled);
bool SDL_GetWindowRelativeMouseMode(SDL_Window *window);
bool SDL_ShowCursor(void);
bool SDL_HideCursor(void);
bool SDL_CursorVisible(void);
void SDL_WarpMouseInWindow(SDL_Window *window, float x, float y);
SDL_Gamepad * SDL_OpenGamepad(SDL_JoystickID instance_id);
void SDL_CloseGamepad(SDL_Gamepad *gamepad);
const char * SDL_GetGamepadName(SDL_Gamepad *gamepad);
Sint16 SDL_GetGamepadAxis(SDL_Gamepad *gamepad, SDL_GamepadAxis axis);
bool SDL_GetGamepadButton(SDL_Gamepad *gamepad, SDL_GamepadButton button);
SDL_JoystickID * SDL_GetGamepads(int *count);
SDL_JoystickID SDL_GetGamepadID(SDL_Gamepad *gamepad);
SDL_Gamepad * SDL_GetGamepadFromID(SDL_JoystickID instance_id);
bool SDL_RumbleGamepad(SDL_Gamepad *gamepad, Uint16 low_frequency_rumble, Uint16 high_frequency_rumble, Uint32 duration_ms);
const char * SDL_GetGamepadStringForAxis(SDL_GamepadAxis axis);
const char * SDL_GetGamepadStringForButton(SDL_GamepadButton button);
SDL_GamepadAxis SDL_GetGamepadAxisFromString(const char *str);
SDL_GamepadButton SDL_GetGamepadButtonFromString(const char *str);
char * SDL_GetClipboardText(void);
bool SDL_SetClipboardText(const char *text);
bool SDL_HasClipboardText(void);
void SDL_free(void *mem);
Uint64 SDL_GetTicks(void);
Uint64 SDL_GetTicksNS(void);
void SDL_DelayNS(Uint64 ns);
SDL_DisplayID SDL_GetPrimaryDisplay(void);
bool SDL_GetDisplayBounds(SDL_DisplayID displayID, SDL_Rect *rect);
float SDL_GetDisplayContentScale(SDL_DisplayID displayID);
const SDL_DisplayMode * SDL_GetCurrentDisplayMode(SDL_DisplayID displayID);
SDL_DisplayID SDL_GetDisplayForWindow(SDL_Window *window);
bool SDL_ShowSimpleMessageBox(SDL_MessageBoxFlags flags, const char *title, const char *message, SDL_Window *window);
bool SDL_OpenURL(const char *url);

/* audio (SDL_audio.h) */
typedef Uint32 SDL_AudioDeviceID;
typedef int SDL_AudioFormat;
typedef struct SDL_AudioStream SDL_AudioStream;
typedef struct SDL_AudioSpec { SDL_AudioFormat format; int channels; int freq; } SDL_AudioSpec;
#define SDL_AUDIO_U8 0x0008
#define SDL_AUDIO_S16 0x8010
#define SDL_AUDIO_S32 0x8020
#define SDL_AUDIO_F32 0x8120
#define SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK 0xFFFFFFFF
#define SDL_AUDIO_DEVICE_DEFAULT_RECORDING 0xFFFFFFFE

/* the callback is declared as a plain pointer: the package passes NULL */
SDL_AudioStream * SDL_OpenAudioDeviceStream(SDL_AudioDeviceID devid, const SDL_AudioSpec *spec, void *callback, void *userdata);
void SDL_DestroyAudioStream(SDL_AudioStream *stream);
bool SDL_PutAudioStreamData(SDL_AudioStream *stream, const void *buf, int len);
int SDL_GetAudioStreamData(SDL_AudioStream *stream, void *buf, int len);
int SDL_GetAudioStreamQueued(SDL_AudioStream *stream);
int SDL_GetAudioStreamAvailable(SDL_AudioStream *stream);
bool SDL_ResumeAudioStreamDevice(SDL_AudioStream *stream);
bool SDL_PauseAudioStreamDevice(SDL_AudioStream *stream);
SDL_AudioDeviceID SDL_GetAudioStreamDevice(SDL_AudioStream *stream);
SDL_AudioDeviceID SDL_OpenAudioDevice(SDL_AudioDeviceID devid, const SDL_AudioSpec *spec);
void SDL_CloseAudioDevice(SDL_AudioDeviceID devid);
bool SDL_PauseAudioDevice(SDL_AudioDeviceID devid);
bool SDL_ResumeAudioDevice(SDL_AudioDeviceID devid);
bool SDL_SetAudioDeviceGain(SDL_AudioDeviceID devid, float gain);
float SDL_GetAudioDeviceGain(SDL_AudioDeviceID devid);
const char * SDL_GetAudioDeviceName(SDL_AudioDeviceID devid);
bool SDL_GetAudioDeviceFormat(SDL_AudioDeviceID devid, SDL_AudioSpec *spec, int *sample_frames);
SDL_AudioStream * SDL_CreateAudioStream(const SDL_AudioSpec *src_spec, const SDL_AudioSpec *dst_spec);
bool SDL_BindAudioStream(SDL_AudioDeviceID devid, SDL_AudioStream *stream);
void SDL_UnbindAudioStream(SDL_AudioStream *stream);
bool SDL_FlushAudioStream(SDL_AudioStream *stream);
bool SDL_ClearAudioStream(SDL_AudioStream *stream);
bool SDL_SetAudioStreamGain(SDL_AudioStream *stream, float gain);
bool SDL_SetAudioStreamFrequencyRatio(SDL_AudioStream *stream, float ratio);
bool SDL_LoadWAV(const char *path, SDL_AudioSpec *spec, Uint8 **audio_buf, Uint32 *audio_len);
const char * SDL_GetCurrentAudioDriver(void);
