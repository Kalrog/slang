// window: windows, keyboard, mouse and gamepads for slang, through SDL3
// (https://libsdl.org) and slang/ffi. The package ships SDL built for
// macOS (lib/<platform>, built by tool/build.sh) and reads
// include/window.h, the part of SDL's API it uses, when it loads.
//
//   local window = require("window")
//   local win = window.open({title: "hello", width: 800, height: 600})
//   for(win.open){
//     for(let local e in values(win:events())){
//       if(e.type == "key_down" and e.key == "escape"){
//         win:close()
//       }
//     }
//   }
//
// A window draws nothing itself: its [Window.native] handle is what a
// renderer draws into (the gpu package's device:surface(win) takes the
// window). Events are tables with a type ("key_down", "mouse_move",
// "resize", ...) and the fields of that type; README.md lists them.
// Keys are named as SDL names them, in lower case with _ for spaces
// ("a", "space", "left_shift", "f1", "escape", "return").
// [c] holds the declared SDL functions and constants under their C names.
// WINDOW_SDL names another SDL3 library (a file path).
//
// In a browser (slang's graphics VM, `make wasm-gfx`) a window is the
// page's canvas (the element with the id "canvas"): its size is the
// window's, and it has the keyboard while it has the focus. There is one
// window, and no sound (window/audio needs threads).
local ffi = require("slang/ffi")
local os = require("slang/os")
local str = require("slang/string")
local math = require("slang/math")

// ------------------------------------------------------------ the library

local sdl = require("window/sdl")
local C = sdl.C
local lib = sdl.lib
local K = sdl.K

local window = {}

// Every declared SDL function and constant under its C name
// (window.c.SDL_GetTicks()): the escape hatch for what the package does
// not wrap. Windows give theirs as [Window.handle].
window.c = ffi.c_layer(lib, "window.c")

local func fail(what){
  raise(concat("window: ", what, ": ", lib.SDL_GetError()))
}

local func check(ok, what){
  if(not ok){
    fail(what)
  }
}

check(
  lib.SDL_Init(K.SDL_INIT_VIDEO | K.SDL_INIT_GAMEPAD | K.SDL_INIT_EVENTS),
  "SDL_Init",
)

// ------------------------------------------------------------ names

// SDL's name of a key in slang: "Left Shift" -> "left_shift"
local func slang_name(name){
  return str.replace(str.lower(name), " ", "_")
}

// slang's name back to SDL's (SDL compares names without case)
local func sdl_name(name){
  return str.replace(name, "_", " ")
}

local key_names = {}
local func key_name(keycode){
  local n = key_names[keycode]
  if(n == null){
    n = slang_name(lib.SDL_GetKeyName(keycode))
    key_names[keycode] = n
  }
  return n
}

local scancode_names = {}
local func scancode_name(scancode){
  local n = scancode_names[scancode]
  if(n == null){
    n = slang_name(lib.SDL_GetScancodeName(scancode))
    scancode_names[scancode] = n
  }
  return n
}

local scancodes = {}
local func scancode_of(name){
  local s = scancodes[name]
  if(s == null){
    s = lib.SDL_GetScancodeFromName(sdl_name(name))
    if(s == 0){
      raise(concat("window: no key named ", name))
    }
    scancodes[name] = s
  }
  return s
}

local button_names = {"left", "middle", "right", "x1", "x2"}
local button_numbers = {left: 1, middle: 2, right: 3, x1: 4, x2: 5}

local func button_number(b){
  if(type(b) == "string"){
    local n = button_numbers[b]
    if(n == null){
      raise(concat("window: no mouse button named ", b))
    }
    return n
  }
  return b
}

local func mods_of(m){
  return {
    shift: (m & (K.SDL_KMOD_LSHIFT | K.SDL_KMOD_RSHIFT)) != 0,
    ctrl: (m & (K.SDL_KMOD_LCTRL | K.SDL_KMOD_RCTRL)) != 0,
    alt: (m & (K.SDL_KMOD_LALT | K.SDL_KMOD_RALT)) != 0,
    gui: (m & (K.SDL_KMOD_LGUI | K.SDL_KMOD_RGUI)) != 0,
  }
}

// ------------------------------------------------------------ windows

local windows_by_id = {}
// events taken in and not yet handed out
local pending = {}

local window_methods = {}
local window_get = {}
local window_set = {}

// A window on the screen. Made by [open]; its size, title and state are
// properties, and its events come from [Window.events].
// type Window
// [handle]: the SDL_Window pointer, for window.c
// [id]: SDL's id of the window
local window_meta = {
  __type: "window.Window",
  __index: window_methods,
  __get: window_get,
  __set: window_set,
}

local func live(self){
  if(self.handle == null){
    raise("window: the window is closed")
  }
  return self.handle
}

local func int_pair(f, self){
  local w = ffi.new("int", 1, C)
  local h = ffi.new("int", 1, C)
  check(f(live(self), w, h), "size")
  return {w[0], h[0]}
}

local flag_options = {
  resizable: K.SDL_WINDOW_RESIZABLE,
  fullscreen: K.SDL_WINDOW_FULLSCREEN,
  hidden: K.SDL_WINDOW_HIDDEN,
  borderless: K.SDL_WINDOW_BORDERLESS,
  always_on_top: K.SDL_WINDOW_ALWAYS_ON_TOP,
  maximized: K.SDL_WINDOW_MAXIMIZED,
}

// open(options?: OpenOptions) -> Window
// A new window, shown at once unless hidden is set.
//   window.open({title: "game", width: 1280, height: 720, resizable: true})
// type OpenOptions = {title?: string, width?: int, height?: int,
//   resizable?: bool, fullscreen?: bool, hidden?: bool, borderless?: bool,
//   always_on_top?: bool, maximized?: bool, high_dpi?: bool,
//   position?: {int}, min_size?: {int}}
// [width], [height]: the size in points (800 x 600 by default); pixels may
//   be more on a high density display ([Window.pixel_size])
// [high_dpi]: a full resolution back buffer on high density displays
//   (true by default)
// [position]: {x, y} on the screen (centered by default)
// [min_size]: {width, height} the window cannot be made smaller than
func window.open(options){
  options = options or {}
  local flags = 0
  for(let local e in entries(flag_options)){
    if(options[e[0]]){
      flags = flags | e[1]
    }
  }
  if(options.high_dpi != false){
    flags = flags | K.SDL_WINDOW_HIGH_PIXEL_DENSITY
  }
  if(os.platform() == "macos-aarch64" or os.platform() == "macos-x86_64"){
    flags = flags | K.SDL_WINDOW_METAL
  }
  local handle = lib.SDL_CreateWindow(
    options.title or "slang",
    options.width or 800,
    options.height or 600,
    flags,
  )
  if(handle == null){
    fail("SDL_CreateWindow")
  }
  local self = {handle: handle, id: lib.SDL_GetWindowID(handle)}
  self.@meta = window_meta
  self.is_open = true
  windows_by_id[self.id] = self
  if(options.position != null){
    lib.SDL_SetWindowPosition(handle, options.position[0], options.position[1])
  }
  if(options.min_size != null){
    lib.SDL_SetWindowMinimumSize(
      handle, options.min_size[0], options.min_size[1]
    )
  }
  return self
}

// close(): destroys the window; [Window.open] is false from then on.
// Closing twice does nothing.
func window_methods.close(self){
  if(self.handle == null){
    return
  }
  if(self.metal_view != null){
    lib.SDL_Metal_DestroyView(self.metal_view)
    self.metal_view = null
  }
  lib.SDL_DestroyWindow(self.handle)
  windows_by_id[self.id] = null
  self.handle = null
  self.is_open = false
}

// open(self) -> bool
// Whether the window is still open: false once its close button was
// pressed (or the program was asked to quit) or [Window.close] ran. Reading
// it takes the waiting events in, so `for(win.open){ ... }` is a main loop.
func window_get.open(self){
  window.poll()
  return self.is_open
}

// title(self) -> string
// The title bar's text; settable.
func window_get.title(self){
  return lib.SDL_GetWindowTitle(live(self))
}
func window_set.title(self, v){
  check(lib.SDL_SetWindowTitle(live(self), v), "title")
}

// size(self) -> {int}
// {width, height} in points; settable.
func window_get.size(self){
  return int_pair(lib.SDL_GetWindowSize, self)
}
func window_set.size(self, v){
  check(lib.SDL_SetWindowSize(live(self), v[0], v[1]), "size")
}

// width(self) -> int
// The width in points.
func window_get.width(self){
  return window_get.size(self)[0]
}

// height(self) -> int
// The height in points.
func window_get.height(self){
  return window_get.size(self)[1]
}

// pixel_size(self) -> {int}
// {width, height} in pixels: what a renderer draws (the size in points
// times [Window.pixel_density]).
func window_get.pixel_size(self){
  return int_pair(lib.SDL_GetWindowSizeInPixels, self)
}

// pixel_density(self) -> number
// Pixels per point (2 on a Retina display).
func window_get.pixel_density(self){
  return lib.SDL_GetWindowPixelDensity(live(self))
}

// display_scale(self) -> number
// How much the display's settings ask content to be scaled.
func window_get.display_scale(self){
  return lib.SDL_GetWindowDisplayScale(live(self))
}

// position(self) -> {int}
// {x, y} on the screen; settable.
func window_get.position(self){
  return int_pair(lib.SDL_GetWindowPosition, self)
}
func window_set.position(self, v){
  check(lib.SDL_SetWindowPosition(live(self), v[0], v[1]), "position")
}

local func has_flag(self, f){
  return (lib.SDL_GetWindowFlags(live(self)) & f) != 0
}

// fullscreen(self) -> bool
// Whether the window fills the screen; settable.
func window_get.fullscreen(self){
  return has_flag(self, K.SDL_WINDOW_FULLSCREEN)
}
func window_set.fullscreen(self, v){
  check(lib.SDL_SetWindowFullscreen(live(self), v), "fullscreen")
}

// resizable(self) -> bool
// Whether the user can resize the window; settable.
func window_get.resizable(self){
  return has_flag(self, K.SDL_WINDOW_RESIZABLE)
}
func window_set.resizable(self, v){
  check(lib.SDL_SetWindowResizable(live(self), v), "resizable")
}

// focused(self) -> bool
// Whether the window has the keyboard.
func window_get.focused(self){
  return has_flag(self, K.SDL_WINDOW_INPUT_FOCUS)
}

// minimized(self) -> bool
// Whether the window is minimized.
func window_get.minimized(self){
  return has_flag(self, K.SDL_WINDOW_MINIMIZED)
}

// occluded(self) -> bool
// Whether the window is hidden behind others (nothing to draw then).
func window_get.occluded(self){
  return has_flag(self, K.SDL_WINDOW_OCCLUDED)
}

// relative_mouse(self) -> bool
// Whether the mouse is captured: the cursor hidden and held in the
// window, mouse_move events reporting only motion (dx, dy), as for a
// mouse-look camera; settable.
func window_get.relative_mouse(self){
  return lib.SDL_GetWindowRelativeMouseMode(live(self))
}
func window_set.relative_mouse(self, v){
  check(lib.SDL_SetWindowRelativeMouseMode(live(self), v), "relative_mouse")
}

// text_input(self) -> bool
// Whether "text" events arrive (typed characters, with the keyboard
// layout and input methods applied); settable, off by default.
func window_get.text_input(self){
  return lib.SDL_TextInputActive(live(self))
}
func window_set.text_input(self, v){
  if(v){
    check(lib.SDL_StartTextInput(live(self)), "text_input")
  } else {
    check(lib.SDL_StopTextInput(live(self)), "text_input")
  }
}

local func is_macos(){
  return str.starts_with(os.platform(), "macos")
}

// native(self) -> Native
// What a renderer needs to draw into the window, by platform:
// {kind: "metal", layer} (a CAMetalLayer, macOS), {kind: "x11", display,
// window}, {kind: "wayland", display, surface}, {kind: "windows", hwnd,
// hinstance}, {kind: "canvas", selector} (the page's canvas, in a
// browser). Pointers are ffi pointers.
// type Native = {kind: string, layer?: ffi.Pointer, display?: ffi.Pointer,
//   window?: int, surface?: ffi.Pointer, hwnd?: ffi.Pointer,
//   hinstance?: ffi.Pointer, selector?: string}
func window_get.native(self){
  local handle = live(self)
  if(str.starts_with(os.platform(), "emscripten")){
    return {kind: "canvas", selector: "#canvas"}
  }
  if(is_macos()){
    if(self.metal_view == null){
      self.metal_view = lib.SDL_Metal_CreateView(handle)
      if(self.metal_view == null){
        fail("SDL_Metal_CreateView")
      }
    }
    return {kind: "metal", layer: lib.SDL_Metal_GetLayer(self.metal_view)}
  }
  local props = lib.SDL_GetWindowProperties(handle)
  local func pointer(name){
    return lib.SDL_GetPointerProperty(props, K[name], null)
  }
  local hwnd = pointer("SDL_PROP_WINDOW_WIN32_HWND_POINTER")
  if(hwnd != null){
    return {
      kind: "windows", hwnd: hwnd,
      hinstance: pointer("SDL_PROP_WINDOW_WIN32_INSTANCE_POINTER")
    }
  }
  local wl = pointer("SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER")
  if(wl != null){
    return {
      kind: "wayland", display: wl,
      surface: pointer("SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER")
    }
  }
  local x11 = pointer("SDL_PROP_WINDOW_X11_DISPLAY_POINTER")
  if(x11 != null){
    return {
      kind: "x11", display: x11,
      window: lib.SDL_GetNumberProperty(
        props, K.SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0
      )
    }
  }
  raise("window: no native handle for this platform")
}

// show(): shows a hidden window
func window_methods.show(self){
  check(lib.SDL_ShowWindow(live(self)), "show")
}

// hide(): hides the window
func window_methods.hide(self){
  check(lib.SDL_HideWindow(live(self)), "hide")
}

// raise_window(): brings the window to the front and gives it the keyboard
func window_methods.raise_window(self){
  check(lib.SDL_RaiseWindow(live(self)), "raise_window")
}

// maximize(): makes the window as large as the screen allows
func window_methods.maximize(self){
  check(lib.SDL_MaximizeWindow(live(self)), "maximize")
}

// minimize(): minimizes the window
func window_methods.minimize(self){
  check(lib.SDL_MinimizeWindow(live(self)), "minimize")
}

// restore(): undoes maximize and minimize
func window_methods.restore(self){
  check(lib.SDL_RestoreWindow(live(self)), "restore")
}

// warp_mouse(x: number, y: number): moves the cursor to x, y in the window
func window_methods.warp_mouse(self, x, y){
  lib.SDL_WarpMouseInWindow(live(self), x, y)
}

// message(text: string, options?: {title?: string, kind?: string})
// Shows a message box over the window and waits until it is dismissed.
// [kind]: "information" (default), "warning" or "error"
func window_methods.message(self, text, options){
  window.message(text, options, self)
}

// events() -> {Event}
// The events since the last call that belong to this window, or to no
// window (quit, gamepads), oldest first.
func window_methods.events(self){
  window.poll()
  local mine = {}
  local rest = {}
  for(let local e in values(pending)){
    if(e.window == null or e.window == self){
      append(mine, e)
    } else {
      append(rest, e)
    }
  }
  pending = rest
  return mine
}

// ------------------------------------------------------------ gamepads

// an axis from SDL's -32768..32767 to -1..1
local func axis_value(v){
  if(v < 0){
    return v / 32768.0
  }
  return v / 32767.0
}

local gamepads_by_id = {}

local gamepad_methods = {}
local gamepad_get = {}

// A gamepad, opened when it is connected (a "gamepad_added" event).
// Buttons and axes are named as SDL names them: buttons "south", "east",
// "west", "north" (the face buttons by position), "back", "guide",
// "start", "left_stick", "right_stick", "left_shoulder",
// "right_shoulder", "dpad_up", "dpad_down", "dpad_left", "dpad_right";
// axes "leftx", "lefty", "rightx", "righty", "left_trigger",
// "right_trigger".
// type Gamepad
// [id]: SDL's id of the gamepad
// [handle]: the SDL_Gamepad pointer, for window.c
local gamepad_meta = {
  __type: "window.Gamepad",
  __index: gamepad_methods,
  __get: gamepad_get,
}

local axis_codes = {}
local button_codes = {}
local func code_of(cache, f, name, what){
  local c = cache[name]
  if(c == null){
    c = f(name)
    if(c < 0){
      raise(concat("window: no gamepad ", what, " named ", name))
    }
    cache[name] = c
  }
  return c
}

local func gamepad_of(id){
  local g = gamepads_by_id[id]
  if(g == null){
    local handle = lib.SDL_OpenGamepad(id)
    if(handle == null){
      return null
    }
    g = {id: id, handle: handle}
    g.@meta = gamepad_meta
    gamepads_by_id[id] = g
  }
  return g
}

// name(self) -> string
// The gamepad's product name.
func gamepad_get.name(self){
  return lib.SDL_GetGamepadName(self.handle) or ""
}

// connected(self) -> bool
// Whether the gamepad is still connected.
func gamepad_get.connected(self){
  return gamepads_by_id[self.id] == self
}

// axis(name: string) -> number
// An axis from -1 to 1 (triggers 0 to 1).
func gamepad_methods.axis(self, name){
  return axis_value(lib.SDL_GetGamepadAxis(self.handle, code_of(
    axis_codes, lib.SDL_GetGamepadAxisFromString, name, "axis"
  )))
}

// button(name: string) -> bool
// Whether a button is held.
func gamepad_methods.button(self, name){
  return lib.SDL_GetGamepadButton(self.handle, code_of(
    button_codes, lib.SDL_GetGamepadButtonFromString, name, "button"
  ))
}

local func clamp01(v){
  if(v < 0){
    return 0
  }
  if(v > 1){
    return 1
  }
  return v
}

// rumble(low: number, high: number, ms: number)
// Rumbles the low and high frequency motors (0 to 1) for ms milliseconds;
// a gamepad without rumble ignores it.
func gamepad_methods.rumble(self, low, high, ms){
  local func strength(v){
    return math.floor(clamp01(v) * 65535)
  }
  lib.SDL_RumbleGamepad(
    self.handle, strength(low), strength(high), math.floor(ms)
  )
}

// ------------------------------------------------------------ events

local event = ffi.new("SDL_Event", 1, C)
local as_window = ffi.cast(event, "SDL_WindowEvent", C)
local as_key = ffi.cast(event, "SDL_KeyboardEvent", C)
local as_text = ffi.cast(event, "SDL_TextInputEvent", C)
local as_motion = ffi.cast(event, "SDL_MouseMotionEvent", C)
local as_button = ffi.cast(event, "SDL_MouseButtonEvent", C)
local as_wheel = ffi.cast(event, "SDL_MouseWheelEvent", C)
local as_pad = ffi.cast(event, "SDL_GamepadDeviceEvent", C)
local as_pad_axis = ffi.cast(event, "SDL_GamepadAxisEvent", C)
local as_pad_button = ffi.cast(event, "SDL_GamepadButtonEvent", C)
local as_drop = ffi.cast(event, "SDL_DropEvent", C)

// window events with no fields beyond their window
local window_event_names = {}
window_event_names[K.SDL_EVENT_WINDOW_SHOWN] = "show"
window_event_names[K.SDL_EVENT_WINDOW_HIDDEN] = "hide"
window_event_names[K.SDL_EVENT_WINDOW_EXPOSED] = "expose"
window_event_names[K.SDL_EVENT_WINDOW_MINIMIZED] = "minimize"
window_event_names[K.SDL_EVENT_WINDOW_MAXIMIZED] = "maximize"
window_event_names[K.SDL_EVENT_WINDOW_RESTORED] = "restore"
window_event_names[K.SDL_EVENT_WINDOW_MOUSE_ENTER] = "mouse_enter"
window_event_names[K.SDL_EVENT_WINDOW_MOUSE_LEAVE] = "mouse_leave"
window_event_names[K.SDL_EVENT_WINDOW_FOCUS_GAINED] = "focus"
window_event_names[K.SDL_EVENT_WINDOW_FOCUS_LOST] = "blur"
window_event_names[K.SDL_EVENT_WINDOW_CLOSE_REQUESTED] = "close"
window_event_names[K.SDL_EVENT_WINDOW_OCCLUDED] = "occlude"
window_event_names[K.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED] = "display_scale"
window_event_names[K.SDL_EVENT_WINDOW_ENTER_FULLSCREEN] = "enter_fullscreen"
window_event_names[K.SDL_EVENT_WINDOW_LEAVE_FULLSCREEN] = "leave_fullscreen"

// the event in the buffer as a table, or null for one the package skips
local func translate(t){
  local name = window_event_names[t]
  if(name != null){
    local w = windows_by_id[as_window.windowID]
    if(t == K.SDL_EVENT_WINDOW_CLOSE_REQUESTED and w != null){
      w.is_open = false
    }
    return {type: name, window: w}
  }
  if(t == K.SDL_EVENT_KEY_DOWN or t == K.SDL_EVENT_KEY_UP){
    local e = {
      type: "key_up",
      window: windows_by_id[as_key.windowID],
      key: key_name(as_key.key),
      scancode: scancode_name(as_key.scancode),
      repeat: as_key.repeat,
      mods: mods_of(as_key.mod),
    }
    if(t == K.SDL_EVENT_KEY_DOWN){
      e.type = "key_down"
    }
    return e
  }
  if(t == K.SDL_EVENT_MOUSE_MOTION){
    return {
      type: "mouse_move",
      window: windows_by_id[as_motion.windowID],
      x: as_motion.x,
      y: as_motion.y,
      dx: as_motion.xrel,
      dy: as_motion.yrel,
    }
  }
  if(t == K.SDL_EVENT_MOUSE_BUTTON_DOWN or t == K.SDL_EVENT_MOUSE_BUTTON_UP){
    local e = {
      type: "mouse_up",
      window: windows_by_id[as_button.windowID],
      button: button_names[as_button.button - 1] or as_button.button,
      x: as_button.x,
      y: as_button.y,
      clicks: as_button.clicks,
    }
    if(t == K.SDL_EVENT_MOUSE_BUTTON_DOWN){
      e.type = "mouse_down"
    }
    return e
  }
  if(t == K.SDL_EVENT_MOUSE_WHEEL){
    local dx = as_wheel.x
    local dy = as_wheel.y
    if(as_wheel.direction == 1){
      dx = -dx
      dy = -dy
    }
    return {
      type: "wheel",
      window: windows_by_id[as_wheel.windowID],
      dx: dx,
      dy: dy,
      x: as_wheel.mouse_x,
      y: as_wheel.mouse_y,
    }
  }
  if(t == K.SDL_EVENT_TEXT_INPUT){
    return {
      type: "text", window: windows_by_id[as_text.windowID], text: as_text.text
    }
  }
  if(t == K.SDL_EVENT_WINDOW_RESIZED or
    t == K.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED){
    local e = {
      type: "resize",
      window: windows_by_id[as_window.windowID],
      width: as_window.data1,
      height: as_window.data2,
    }
    if(t == K.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED){
      e.type = "pixel_resize"
    }
    return e
  }
  if(t == K.SDL_EVENT_WINDOW_MOVED){
    return {
      type: "move", window: windows_by_id[as_window.windowID],
      x: as_window.data1, y: as_window.data2
    }
  }
  if(t == K.SDL_EVENT_QUIT){
    for(let local w in values(windows_by_id)){
      w.is_open = false
    }
    return {type: "quit"}
  }
  if(t == K.SDL_EVENT_GAMEPAD_ADDED){
    local g = gamepad_of(as_pad.which)
    if(g == null){
      return null
    }
    return {type: "gamepad_added", gamepad: g}
  }
  if(t == K.SDL_EVENT_GAMEPAD_REMOVED){
    local g = gamepads_by_id[as_pad.which]
    if(g == null){
      return null
    }
    gamepads_by_id[g.id] = null
    lib.SDL_CloseGamepad(g.handle)
    return {type: "gamepad_removed", gamepad: g}
  }
  if(t == K.SDL_EVENT_GAMEPAD_BUTTON_DOWN or t == K.SDL_EVENT_GAMEPAD_BUTTON_UP){
    local e = {
      type: "gamepad_up",
      gamepad: gamepads_by_id[as_pad_button.which],
      button: lib.SDL_GetGamepadStringForButton(as_pad_button.button),
    }
    if(t == K.SDL_EVENT_GAMEPAD_BUTTON_DOWN){
      e.type = "gamepad_down"
    }
    return e
  }
  if(t == K.SDL_EVENT_GAMEPAD_AXIS_MOTION){
    return {
      type: "gamepad_axis",
      gamepad: gamepads_by_id[as_pad_axis.which],
      axis: lib.SDL_GetGamepadStringForAxis(as_pad_axis.axis),
      value: axis_value(as_pad_axis.value),
    }
  }
  if(t == K.SDL_EVENT_DROP_FILE){
    return {
      type: "drop", window: windows_by_id[as_drop.windowID], path: as_drop.data
    }
  }
  return null
}

// poll()
// Takes the waiting events in from the system. [Window.events] and
// [Window.open] call it; a program without a window loop calls it to keep
// gamepads and the keyboard state current.
func window.poll(){
  for(lib.SDL_PollEvent(event)){
    local e = translate(event.type)
    if(e != null){
      append(pending, e)
    }
  }
}

// Something that happened, as [events] and [Window.events] hand it out.
// Its type says what, and which of the other fields it has:
//
//   "key_down", "key_up"                 window, key, scancode, repeat, mods
//   "text"                               window, text
//   "mouse_move"                         window, x, y, dx, dy
//   "mouse_down", "mouse_up"             window, button, x, y, clicks
//   "wheel"                              window, dx, dy, x, y
//   "resize", "pixel_resize"             window, width, height
//   "move"                               window, x, y
//   "drop"                               window, path
//   "close", "focus", "blur", "show", "hide", "expose", "minimize",
//   "maximize", "restore", "mouse_enter", "mouse_leave", "occlude",
//   "display_scale", "enter_fullscreen", "leave_fullscreen"     window
//   "gamepad_added", "gamepad_removed"   gamepad
//   "gamepad_down", "gamepad_up"         gamepad, button
//   "gamepad_axis"                       gamepad, axis, value
//   "quit"                               (the program was asked to quit)
//
// type Event = {type: string, window?: Window, gamepad?: Gamepad,
//   key?: string, scancode?: string, repeat?: bool,
//   mods?: {shift: bool, ctrl: bool, alt: bool, gui: bool}, text?: string,
//   x?: number, y?: number, dx?: number, dy?: number,
//   button?: string | int, clicks?: int, width?: int, height?: int,
//   path?: string, axis?: string, value?: number}
// [type]: what happened: one of the names above
// [window]: the window it belongs to; "quit" and the gamepad events have
//   none
// [key]: the key in the keyboard's layout, named as SDL names it, in lower
//   case with _ for spaces: "a", "1", "space", "return", "escape",
//   "left_shift", "f1", "up"
// [scancode]: the physical key, by its name on a US keyboard
// [repeat]: whether the key repeats because it is held
// [mods]: the modifier keys held
// [text]: typed text (a window's text_input turns these events on)
// [x]: where the mouse is in the window, across; for "move", where the
//   window is on the screen
// [y]: the same, down
// [dx]: how far the mouse moved across; for "wheel", how far it scrolled
// [dy]: the same, down
// [button]: a mouse button ("left", "middle", "right", "x1", "x2"; a
//   number for others), or a gamepad's button as [Gamepad.button] names it
// [clicks]: 1 for a click, 2 for a double click
// [width]: the new width, in points for "resize" and in pixels for
//   "pixel_resize"
// [height]: the new height, likewise
// [path]: the file dropped on the window
// [axis]: the gamepad's axis as [Gamepad.axis] names it
// [value]: where the axis is, -1 to 1

// events() -> {Event}
// Every event since the last call, of all windows, oldest first.
func window.events(){
  window.poll()
  local all = pending
  pending = {}
  return all
}

// wait(ms?: number)
// Sleeps until an event arrives, or ms milliseconds pass: for programs
// that draw only when something changes.
func window.wait(ms){
  if(lib.SDL_WaitEventTimeout(event, math.floor(ms or -1))){
    local e = translate(event.type)
    if(e != null){
      append(pending, e)
    }
  }
}

// ------------------------------------------------------------ input state

local keys_count = ffi.new("int", 1, C)
local keys = lib.SDL_GetKeyboardState(keys_count)

// key_down(name: string) -> bool
// Whether the key at name's place on a US keyboard is held, whatever the
// layout: "w" is the key above "s" on a French keyboard too.
func window.key_down(name){
  return keys[scancode_of(name)]
}

// mods() -> {shift: bool, ctrl: bool, alt: bool, gui: bool}
// The modifier keys held (gui: command on a Mac, the Windows key).
func window.mods(){
  return mods_of(lib.SDL_GetModState())
}

local mouse_x = ffi.new("float", 1, C)
local mouse_y = ffi.new("float", 1, C)

// mouse() -> Mouse
// Where the mouse is in the focused window and which buttons are held.
// type Mouse = {x: number, y: number, left: bool, middle: bool,
//   right: bool, x1: bool, x2: bool}
func window.mouse(){
  local b = lib.SDL_GetMouseState(mouse_x, mouse_y)
  return {
    x: mouse_x[0],
    y: mouse_y[0],
    left: (b & 1) != 0,
    middle: (b & 2) != 0,
    right: (b & 4) != 0,
    x1: (b & 8) != 0,
    x2: (b & 16) != 0,
  }
}

// mouse_down(button: string | int) -> bool
// Whether a mouse button ("left", "middle", "right", "x1", "x2" or 1-5)
// is held.
func window.mouse_down(button){
  local b = lib.SDL_GetMouseState(mouse_x, mouse_y)
  return (b & (1 << (button_number(button) - 1))) != 0
}

// gamepads() -> {Gamepad}
// The gamepads connected now.
func window.gamepads(){
  window.poll()
  local out = {}
  for(let local g in values(gamepads_by_id)){
    append(out, g)
  }
  return out
}

// cursor(visible: bool)
// Shows or hides the mouse cursor.
func window.cursor(visible){
  if(visible){
    check(lib.SDL_ShowCursor(), "cursor")
  } else {
    check(lib.SDL_HideCursor(), "cursor")
  }
}

// ------------------------------------------------------------ the rest

local message_kinds = {
  information: K.SDL_MESSAGEBOX_INFORMATION,
  warning: K.SDL_MESSAGEBOX_WARNING,
  error: K.SDL_MESSAGEBOX_ERROR,
}

// message(text: string, options?: {title?: string, kind?: string})
// Shows a message box and waits until it is dismissed.
// [kind]: "information" (default), "warning" or "error"
func window.message(text, options, parent){
  options = options or {}
  local kind = message_kinds[options.kind or "information"]
  if(kind == null){
    raise(concat("window: no message kind ", options.kind))
  }
  local handle = null
  if(parent != null){
    handle = parent.handle
  }
  check(
    lib.SDL_ShowSimpleMessageBox(kind, options.title or "", text, handle),
    "message",
  )
}

// open_url(url: string)
// Opens a URL in the system's browser (or a file in its application).
func window.open_url(url){
  check(lib.SDL_OpenURL(url), "open_url")
}

// screen() -> Screen
// The primary display: its size in points, refresh rate and scale.
// type Screen = {width: int, height: int, refresh_rate: number,
//   pixel_density: number, scale: number}
func window.screen(){
  local id = lib.SDL_GetPrimaryDisplay()
  local mode = lib.SDL_GetCurrentDisplayMode(id)
  if(mode == null){
    fail("screen")
  }
  return {
    width: mode.w,
    height: mode.h,
    refresh_rate: mode.refresh_rate,
    pixel_density: mode.pixel_density,
    scale: lib.SDL_GetDisplayContentScale(id),
  }
}

// version() -> string
// SDL's version, "3.4.20".
func window.version(){
  local v = lib.SDL_GetVersion()
  return concat(
    "", math.floor(v / 1000000) | 0, ".", (math.floor(v / 1000) | 0) % 1000,
    ".", v % 1000
  )
}

local module_get = {}
local module_set = {}

// clipboard(self) -> string
// The clipboard's text ("" when it holds none); settable.
func module_get.clipboard(self){
  local p = lib.SDL_GetClipboardText()
  if(p == null){
    return ""
  }
  local text = ffi.string(p)
  lib.SDL_free(p)
  return text
}
func module_set.clipboard(self, v){
  check(lib.SDL_SetClipboardText(v), "clipboard")
}

window.@meta = {__type: "window", __get: module_get, __set: module_set}

return window
