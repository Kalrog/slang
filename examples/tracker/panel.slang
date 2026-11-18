// The panel at the right: the strip that is selected (a track, a bus or
// the master): its instrument and inserts as tabs, the unit's patch and
// parameters as sliders, the strip's gain, pan, mute and sends. All of it
// is the mouse's: drag a slider, click what has few settings to step
// through them, right click for a parameter's default, the wheel scrolls
// the parameters.
local rl = require("raylib")
local math = require("slang/math")
local param = require("studio/param")
local units = require("studio/units")
local gfx = require("gfx")

local panel = {}

local CW = gfx.CW
local CH = gfx.CH
local C = gfx.colors

panel.COLS = 26 // its width in characters
local NAME = 10 // characters of a parameter's name
local BAR = 7 // of its slider
local TOP = 6 // lines above the parameters

local func strip_color(A){
  if(A.ref.kind == "track"){
    return gfx.hue(A.ref.index)
  }
  return {150, 160, 185}
}

// the lines of the strip's own section, from the bottom: gain, pan, mute
// and a send per bus for a track
local func strip_lines(A){
  if(A.ref.kind == "track"){
    return 3 + len(A.song.buses)
  }
  return 3
}

// rows(A, h) -> how many parameters the panel shows at a height of h
local func rows(A, h){
  return to_int(h / CH) - TOP - strip_lines(A) - 2
}

// shown(A) -> the unit the tabs have chosen ({entry, handle}), or null;
// the slot is put right when the strip has no such unit
func panel.shown(A){
  local entry = A.P:entry(A.ref)
  if(entry == null){
    A.ref = {kind: "master"}
    entry = A.P:entry(A.ref)
  }
  if(A.slot >= len(entry.inserts)){
    A.slot = len(entry.inserts) - 1
  }
  if(A.slot < 0 and A.ref.kind != "track"){
    A.slot = if(len(entry.inserts) > 0){ 0 } else { -1 }
  }
  return A.P:unit(A.ref, A.slot)
}

// the parameters a unit shows: all but those it writes itself come first
local func listed(handle){
  return handle.info.list
}

// a value as the panel has room for it: without its unit when that is
// too long
local func short(d, value){
  local text = param.text(d, value)
  if(len(text) > 7 and d.unit != null){
    text = require("slang/string").substring(
      text, 0, len(text) - len(d.unit) - 1
    )
  }
  return gfx.fit(text, 7)
}

// a slider's value from the mouse: where in the bar it is
local func slider_t(mx, x){
  return math.clamp((mx - x) / (BAR * CW - 1), 0.0, 1.0)
}

// whether a parameter is stepped through (clicked), not slid
local func stepped(d){
  return d.labels != null or d.kind == "switch"
}

local func menu_items(A){
  if(A.menu.kind == "instrument" or A.menu.kind == "track"){
    return units.names.instruments
  }
  // (an effect for a strip, or the one a new bus starts with)
  return units.names.effects
}

// ------------------------------------------------------------ drawing

func panel.draw(A, x, y, w, h){
  gfx.rect(x, y, w, h, C.panel)
  gfx.rect(x, y, 1, h, C.line)
  local left = x + 4
  local hue = strip_color(A)
  local entry = A.P:entry(A.ref)
  local strip = A.P:strip(A.ref)
  // the strip's name
  gfx.rect(x + 1, y, w - 1, CH, gfx.shade(hue, 0.5))
  gfx.text(gfx.fit(entry.name, panel.COLS - 8), left, y, C.title)
  if(A.ref.kind == "bus" and A.menu == null){
    gfx.right("remove bus", x + w - 4, y, C.bad)
  } else {
    gfx.right(A.ref.kind, x + w - 4, y, gfx.shade(hue, 1.0))
  }
  if(A.menu != null){
    // a list to pick from
    local what = "its instrument:"
    if(A.menu.kind == "effect"){
      what = "an effect to add:"
    } else if(A.menu.kind == "track"){
      what = "a new track of:"
    } else if(A.menu.kind == "bus"){
      what = "a new bus with:"
    }
    gfx.text(what, left, y + CH * 2, C.dim)
    local items = menu_items(A)
    for(local i = 0; i < len(items); i = i + 1){
      local iy = y + CH * (4 + i)
      if(A.hover_y >= iy and A.hover_y < iy + CH and A.hover_x >= x){
        gfx.rect(x + 1, iy, w - 1, CH, C.cursor_row)
      }
      gfx.text(items[i], left + CW, iy, C.text)
    }
    gfx.text("escape: leave it", left, y + CH * (5 + len(items)), C.faint)
    return null
  }
  local u = panel.shown(A)
  // the tabs: the instrument, the inserts, and one to add an insert
  local tx = left
  local ty = y + CH + 2
  A.tabs = {}
  local func tab(label, slot, color){
    local tw = len(label) * CW + 6
    local on = slot == A.slot
    gfx.rect(tx, ty, tw, CH, if(on){ gfx.shade(color, 0.6) } else { C.line })
    gfx.text(label, tx + 3, ty, if(on){ C.title } else { C.dim })
    append(A.tabs, {x: tx, w: tw, slot: slot})
    tx = tx + tw + 2
  }
  if(A.ref.kind == "track"){
    tab(gfx.fit(entry.unit, 5), -1, hue)
  }
  for(local i = 0; i < len(entry.inserts); i = i + 1){
    tab(gfx.fit(entry.inserts[i].unit, 4), i, {150, 160, 185})
  }
  if(len(entry.inserts) < 4){
    tab("+", -2, C.good)
  }
  local line = y + CH * 3
  if(u == null){
    gfx.text("no inserts: + adds one", left, line, C.faint)
  } else {
    // the unit and its patch
    gfx.text("UNIT", left, line, C.dim)
    gfx.text(u.entry.unit, left + 6 * CW, line, C.text)
    if(A.slot >= 0){
      gfx.right("remove", x + w - 4, line, C.bad)
    } else {
      gfx.right("change", x + w - 4, line, C.dim)
    }
    line = line + CH
    local patches = u.handle.patches
    if(len(patches) > 0){
      gfx.text("PATCH", left, line, C.dim)
      gfx.text(gfx.fit(u.entry.patch or "-", 14), left + 6 * CW, line, C.warn)
      gfx.right("< >", x + w - 4, line, C.dim)
    } else {
      gfx.text("PATCH", left, line, C.faint)
      gfx.text("-", left + 6 * CW, line, C.faint)
    }
    line = line + CH
    // what belongs to the slot: a track's lane and columns, a
    // compressor's sidechain
    if(A.slot < 0){
      gfx.text("LANE", left, line, C.dim)
      gfx.text(gfx.fit(entry.lane or "-", 10), left + 6 * CW, line, C.fx)
      gfx.text("COLS", left + 17 * CW, line, C.dim)
      gfx.text(string(entry.columns), left + 22 * CW, line, C.text)
    } else if(u.entry.unit == "compressor"){
      gfx.text("HEARS", left, line, C.dim)
      gfx.text(
        gfx.fit(u.entry.sidechain or "itself", 14), left + 6 * CW, line, C.text
      )
    }
    line = line + CH
    // the parameters
    local list = listed(u.handle)
    local n = rows(A, h)
    A.param_scroll = math.clamp(A.param_scroll, 0, math.max(0, len(list) - n))
    gfx.rect(x + 1, line + 5, w - 1, 1, C.line)
    line = line + CH
    for(local i = 0; i < n; i = i + 1){
      local d = list[A.param_scroll + i]
      if(d == null){
        break
      }
      local py = line + i * CH
      local value = u.handle:get(d.name)
      if(d.kind == "meter"){
        value = u.handle:effective(d.name)
      }
      local hot = A.drag != null and A.drag.kind == "param" and
        A.drag.name == d.name
      gfx.text(
        gfx.fit(d.name, NAME),
        left,
        py,
        if(hot){ C.title } else { C.text },
      )
      local bx = left + (NAME + 1) * CW
      local color = if(d.kind == "meter"){ C.dim } else { hue }
      if(stepped(d)){
        color = gfx.shade(hue, 0.6)
      }
      if(d.bipolar){
        gfx.center(
          bx, py + 3, BAR * CW, 6, param.t_of(d, value) * 2 - 1, color, C.line
        )
      } else {
        gfx.bar(bx, py + 3, BAR * CW, 6, param.t_of(d, value), color, C.line)
      }
      gfx.text(short(d, value), bx + (BAR + 1) * CW - 4, py, C.dim)
    }
    if(len(list) > n){
      // where in the list it is
      local track_h = n * CH
      local knob = math.max(6, to_int(track_h * n / len(list)))
      local at = to_int((track_h - knob) * A.param_scroll / (len(list) - n))
      gfx.rect(x + w - 2, line + at, 2, knob, C.dim)
    }
  }
  // the strip itself, at the bottom
  local sy = y + h - strip_lines(A) * CH
  gfx.rect(x + 1, sy - 6, w - 1, 1, C.line)
  local bx = left + (NAME + 1) * CW
  gfx.text("GAIN", left, sy, C.text)
  gfx.bar(bx, sy + 3, BAR * CW, 6, entry.gain / 2, hue, C.line)
  gfx.text(
    gfx.fit(string(math.round(entry.gain * 100) / 100), 7),
    bx + (BAR + 1) * CW - 4,
    sy,
    C.dim,
  )
  gfx.text("PAN", left, sy + CH, C.text)
  gfx.center(bx, sy + CH + 3, BAR * CW, 6, entry.pan, hue, C.line)
  gfx.text(
    gfx.fit(string(math.round(entry.pan * 100) / 100), 7),
    bx + (BAR + 1) * CW - 4,
    sy + CH,
    C.dim,
  )
  gfx.text("MUTE", left, sy + CH * 2, C.text)
  gfx.text(
    if(entry.mute){ "on" } else { "off" },
    bx,
    sy + CH * 2,
    if(entry.mute){ C.bad } else { C.dim },
  )
  // the strip's level, beside its mute
  local pk = strip.peak
  gfx.bar(
    bx + 4 * CW, sy + CH * 2 + 2, 6 * CW, 3, math.sqrt(pk.left), C.good, C.line
  )
  gfx.bar(
    bx + 4 * CW, sy + CH * 2 + 7, 6 * CW, 3, math.sqrt(pk.right), C.good, C.line
  )
  if(A.ref.kind == "track"){
    for(local b = 0; b < len(A.song.buses); b = b + 1){
      local by = sy + CH * (3 + b)
      local name = A.song.buses[b].name
      gfx.text(concat("> ", gfx.fit(name, NAME - 2)), left, by, C.text)
      local amount = entry.sends[name] or 0.0
      gfx.bar(bx, by + 3, BAR * CW, 6, amount, {150, 160, 185}, C.line)
      gfx.text(
        gfx.fit(string(math.round(amount * 100) / 100), 7),
        bx + (BAR + 1) * CW - 4,
        by,
        C.dim,
      )
    }
  }
}

// ------------------------------------------------------------ the mouse

// the lane of a track: the next parameter of its instrument (d: 1 or -1),
// none after the last
local func step_lane(A, entry, handle, d){
  local list = handle.info.list
  local at = -1
  for(local i = 0; i < len(list); i = i + 1){
    if(list[i].name == entry.lane){
      at = i
    }
  }
  for(true){
    at = at + d
    if(at < -1){
      at = len(list) - 1
    }
    if(at >= len(list)){
      at = -1
    }
    if(at < 0 or (list[at].kind != "meter" and not stepped(list[at]))){
      break
    }
  }
  entry.lane = if(at < 0){ null } else { list[at].name }
  A.song.dirty = true
}

local func step_patch(A, u, d){
  local patches = u.handle.patches
  if(len(patches) == 0){
    return null
  }
  local at = -1
  for(local i = 0; i < len(patches); i = i + 1){
    if(patches[i] == u.entry.patch){
      at = i
    }
  }
  at = ((at + d) % len(patches) + len(patches)) % len(patches)
  A.P:set_patch(A.ref, A.slot, patches[at])
  A.say(concat(u.entry.unit, ": ", patches[at]))
}

// mouse(A, x, y, w, h, mx, my) -> whether the panel took the mouse
func panel.mouse(A, x, y, w, h, mx, my){
  local left = x + 4
  local bx = left + (NAME + 1) * CW
  local pressed = rl.mouse.pressed(rl.MOUSE_BUTTON_LEFT)
  local right = rl.mouse.pressed(rl.MOUSE_BUTTON_RIGHT)
  local down = rl.mouse.down(rl.MOUSE_BUTTON_LEFT)
  local wheel = rl.mouse.wheel
  // a slider held: it follows the mouse wherever it goes
  if(A.drag != null){
    if(not down){
      A.drag = null
      return true
    }
    local t = slider_t(mx, bx)
    local g = A.drag
    if(g.kind == "param"){
      local u = A.P:unit(A.ref, A.slot)
      if(u != null){
        local d = u.handle.info.list[u.handle.info.index[g.name]]
        local v = param.from_t(d, t)
        if(d.step != null){
          v = param.value(d, v)
        }
        A.P:set_param(A.ref, A.slot, g.name, v)
      }
    } else if(g.kind == "gain"){
      A.P:set_strip(A.ref, "gain", t * 2)
    } else if(g.kind == "pan"){
      local pan = t * 2 - 1
      // the middle holds on a little
      if(math.abs(pan) < 0.06){
        pan = 0.0
      }
      A.P:set_strip(A.ref, "pan", pan)
    } else if(g.kind == "send"){
      A.P:set_send(A.ref.index, g.bus, t)
    }
    return true
  }
  if(not gfx.inside(mx, my, x, y, w, h)){
    return false
  }
  if(A.menu != null){
    if(pressed){
      local items = menu_items(A)
      local i = to_int((my - y) / CH) - 4
      if(i >= 0 and i < len(items)){
        local kind = A.menu.kind
        A.menu = null
        if(kind == "instrument"){
          A.P:set_unit(A.ref.index, items[i])
          A.say(concat(A.song.tracks[A.ref.index].name, " plays ", items[i]))
        } else if(kind == "track"){
          local t = A.P:add_track(items[i])
          if(t == null){
            A.say("no more tracks")
          } else {
            A.cursor.t = t
            A.cursor.f = 0
            A.ref = {kind: "track", index: t}
            A.slot = -1
          }
        } else if(kind == "bus"){
          local b = A.P:add_bus(items[i])
          if(b == null){
            A.say("four buses are the most")
          } else {
            A.ref = {kind: "bus", index: b}
            A.slot = 0
            A.param_scroll = 0
            A.say(concat(
              "a bus: ", A.song.buses[b].name,
              ". Tracks send to it at the bottom of their panel"
            ))
          }
        } else {
          A.slot = A.P:add_insert(A.ref, items[i])
          A.param_scroll = 0
        }
      } else {
        A.menu = null
      }
    }
    return true
  }
  local entry = A.P:entry(A.ref)
  local u = panel.shown(A)
  local line = to_int((my - y) / CH)
  // a bus's title: its "remove bus"
  if(line == 0){
    if(pressed and A.ref.kind == "bus" and mx > x + w - 11 * CW){
      local name = entry.name
      A.P:remove_bus(A.ref.index)
      A.ref = {kind: "master"}
      A.slot = 0
      A.param_scroll = 0
      A.say(concat("removed the bus ", name))
    }
    return true
  }
  // the tabs
  if(pressed and my >= y + CH + 2 and my < y + CH * 2 + 2){
    for(let local tb in values(A.tabs or {})){
      if(mx >= tb.x and mx < tb.x + tb.w){
        if(tb.slot == -2){
          A.menu = {kind: "effect"}
        } else {
          A.slot = tb.slot
          A.param_scroll = 0
        }
      }
    }
    return true
  }
  local sy = y + h - strip_lines(A) * CH
  if(my >= sy){
    // the strip's own
    local k = to_int((my - sy) / CH)
    if(pressed){
      if(k == 0){
        A.drag = {kind: "gain"}
      } else if(k == 1){
        A.drag = {kind: "pan"}
      } else if(k == 2){
        A.P:set_strip(A.ref, "mute", not entry.mute)
      } else if(A.ref.kind == "track" and A.song.buses[k - 3] != null){
        A.drag = {kind: "send", bus: A.song.buses[k - 3].name}
      }
    } else if(right){
      if(k == 0){
        A.P:set_strip(A.ref, "gain", 1.0)
      } else if(k == 1){
        A.P:set_strip(A.ref, "pan", 0.0)
      } else if(A.ref.kind == "track" and A.song.buses[k - 3] != null){
        A.P:set_send(A.ref.index, A.song.buses[k - 3].name, 0.0)
      }
    }
    return true
  }
  if(u == null){
    return true
  }
  if(line == 3 and pressed){
    if(A.slot >= 0){
      A.P:remove_insert(A.ref, A.slot)
      A.slot = A.slot - 1
      A.param_scroll = 0
    } else {
      A.menu = {kind: "instrument"}
    }
    return true
  }
  if(line == 4){
    if(pressed){
      local d = 1
      if(mx > x + w - 4 * CW and mx <= x + w - 2 * CW){
        d = -1
      }
      step_patch(A, u, d)
    } else if(wheel != 0){
      step_patch(A, u, if(wheel > 0){ -1 } else { 1 })
    }
    return true
  }
  if(line == 5){
    if(A.slot < 0){
      if(mx < left + 17 * CW){
        if(pressed){
          step_lane(A, entry, u.handle, 1)
        } else if(right){
          entry.lane = null
          A.song.dirty = true
        } else if(wheel != 0){
          step_lane(A, entry, u.handle, if(wheel > 0){ -1 } else { 1 })
        }
      } else if(pressed){
        entry.columns = entry.columns % 4 + 1
        A.song.dirty = true
      }
    } else if(u.entry.unit == "compressor" and pressed){
      // itself, then each track in turn
      local names = {}
      for(let local tr in values(A.song.tracks)){
        if(not(A.ref.kind == "track" and tr.name == entry.name)){
          append(names, tr.name)
        }
      }
      local at = -1
      for(local i = 0; i < len(names); i = i + 1){
        if(names[i] == u.entry.sidechain){
          at = i
        }
      }
      at = at + 1
      A.P:set_sidechain(A.ref, A.slot, names[at])
    }
    return true
  }
  // the parameters
  local list = listed(u.handle)
  local n = rows(A, h)
  local first = y + CH * (TOP + 1)
  if(my >= first and my < first + n * CH){
    if(wheel != 0){
      A.param_scroll = math.clamp(
        A.param_scroll - to_int(wheel * 3),
        0,
        math.max(0, len(list) - n),
      )
      return true
    }
    local d = list[A.param_scroll + to_int((my - first) / CH)]
    if(d == null or d.kind == "meter"){
      return true
    }
    if(right){
      A.P:set_param(A.ref, A.slot, d.name, d.default)
    } else if(pressed){
      if(stepped(d)){
        local v = u.handle:get(d.name) + 1
        if(v > d.max){
          v = d.min
        }
        A.P:set_param(A.ref, A.slot, d.name, v)
      } else {
        A.drag = {kind: "param", name: d.name}
      }
    }
  }
  return true
}

return panel
