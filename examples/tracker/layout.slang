// The keyboard layout: which key types which letter. raylib (GLFW) names
// keys by their place on a US keyboard, so KEY_K is the key where a US
// keyboard has its K, whatever the layout types there. A shortcut should
// follow the layout: command+K is the key that types k. On macOS the
// layout is asked (Carbon's UCKeyTranslate, through slang/ffi); elsewhere,
// or when that fails, the US place is assumed.
//
//   local layout = require("layout")
//   rl.is_key_pressed(layout.key("k"))     // the key that types k
local str = require("slang/string")
local time = require("slang/time")

local layout = {}

// the printable keys as GLFW names them (a letter's code is its capital)
// with their macOS virtual key codes, from GLFW's cocoa key table: the
// letter keys of a US keyboard, then its punctuation and digit keys, where
// other layouts put letters too (Bone has k, g and q on / ; and [)
local KEYS = {
  {65, 0x00},
  {66, 0x0B},
  {67, 0x08},
  {68, 0x02},
  {69, 0x0E},
  {70, 0x03},
  {71, 0x05},
  {72, 0x04},
  {73, 0x22},
  {74, 0x26},
  {75, 0x28},
  {76, 0x25},
  {77, 0x2E},
  {78, 0x2D},
  {79, 0x1F},
  {80, 0x23},
  {81, 0x0C},
  {82, 0x0F},
  {83, 0x01},
  {84, 0x11},
  {85, 0x20},
  {86, 0x09},
  {87, 0x0D},
  {88, 0x07},
  {89, 0x10},
  {90, 0x06},
  {39, 0x27},
  {44, 0x2B},
  {45, 0x1B},
  {46, 0x2F},
  {47, 0x2C},
  {59, 0x29},
  {61, 0x18},
  {91, 0x21},
  {92, 0x2A},
  {93, 0x1E},
  {96, 0x32},
  {161, 0x0A},
  {48, 0x1D},
  {49, 0x12},
  {50, 0x13},
  {51, 0x14},
  {52, 0x15},
  {53, 0x17},
  {54, 0x16},
  {55, 0x1A},
  {56, 0x1C},
  {57, 0x19},
}

local carbon = null
local tried = false

// the Carbon functions through slang/ffi (raises where there is no Carbon)
local func open_carbon(){
  local ffi = require("slang/ffi")
  local C = ffi.cdef("""
      typedef void *TISInputSourceRef;
      typedef void *CFStringRef;
      typedef void *CFDataRef;
      typedef void *CFAllocatorRef;
      typedef unsigned short UniChar;
      typedef unsigned long UniCharCount;
      typedef unsigned int UInt32;
      typedef unsigned short UInt16;
      typedef unsigned char UInt8;
      typedef int OSStatus;
      TISInputSourceRef TISCopyCurrentKeyboardLayoutInputSource(void);
      void *TISGetInputSourceProperty(TISInputSourceRef source, CFStringRef key);
      CFStringRef CFStringCreateWithCString(CFAllocatorRef alloc, const char *s, UInt32 encoding);
      void *CFDataGetBytePtr(CFDataRef data);
      UInt8 LMGetKbdType(void);
      OSStatus UCKeyTranslate(const void *layout, UInt16 key, UInt16 action,
        UInt32 modifiers, UInt32 keyboard, UInt32 options, UInt32 *dead,
        UniCharCount max, UniCharCount *length, UniChar *chars);
      void CFRelease(void *ref);
    """)
  local lib = ffi.load("/System/Library/Frameworks/Carbon.framework/Carbon", C)
  return {ffi: ffi, C: C, lib: lib}
}

// the Carbon functions, loaded once (null where there is no Carbon)
local func load_carbon(){
  if(not tried){
    tried = true
    carbon = try { open_carbon() } catch { null }
  }
  return carbon
}

// the letters the layout types on the printable keys: {[letter]: key code}
local func read_layout(c){
  local ffi = c.ffi
  local lib = c.lib
  local source = lib.TISCopyCurrentKeyboardLayoutInputSource()
  // the property key by its content: the dictionary compares strings
  local name = lib.CFStringCreateWithCString(
    null, "TISPropertyUnicodeKeyLayoutData", 0x08000100
  )
  local data = lib.TISGetInputSourceProperty(source, name)
  local out = null
  if(data != null){
    local bytes = lib.CFDataGetBytePtr(data)
    local kind = lib.LMGetKbdType()
    local dead = ffi.new("UInt32", 1, c.C)
    local length = ffi.new("UniCharCount", 1, c.C)
    local chars = ffi.new("UniChar", 4, c.C)
    out = {}
    for(let local k in values(KEYS)){
      dead[0] = 0
      // key down, no modifiers, no dead keys (option bit 0)
      local status = lib.UCKeyTranslate(
        bytes, k[1], 0, 0, kind, 1, dead, 4, length, chars
      )
      if(status == 0 and length[0] >= 1 and chars[0] >= 97 and chars[0] <= 122){
        local letter = str.from_bytes({chars[0]})
        if(out[letter] == null){
          out[letter] = k[0]
        }
      }
    }
  }
  lib.CFRelease(name)
  lib.CFRelease(source)
  return out
}

// read() -> the map, or null when the layout cannot be read (not macOS)
local func read(){
  local c = load_carbon()
  if(c == null){
    return null
  }
  return try { read_layout(c) } catch { null }
}

local keys = null
local taken = {}
local read_at = -1.0e9

// key(letter: string) -> the key code (rl.KEY_*) of the key that types
// the letter (a to z) in the current layout, read again every two seconds
// so a layout switched while the program runs is followed. A letter the
// layout puts on no letter key keeps its US place, unless another letter
// has that key: then 0, a key nobody presses, so no shortcut fires twice.
func layout.key(letter){
  local now = time.clock()
  if(now - read_at > 2000){
    read_at = now
    keys = read()
    taken = {}
    if(keys != null){
      for(let local e in entries(keys)){
        taken[e[1]] = e[0]
      }
    }
  }
  local us = str.byte_at(str.upper(letter), 0)
  if(keys == null){
    return us
  }
  if(keys[letter] != null){
    return keys[letter]
  }
  if(taken[us] != null){
    return 0
  }
  return us
}

// keys() -> the map the layout gave, or null (for tests and curiosity)
func layout.keys(){
  layout.key("a")
  return keys
}

return layout
