// Drawing Inkblast with raylib, and its sounds (made from samples computed
// here, as in breakout). Everything drawn comes from the client's view:
// the newest state from the server, players between the two newest.
local rl = require("raylib")
local math = require("slang/math")
local rules = require("game/rules")
local str = require("slang/string")

local render = {}

render.CELL = 48
render.TOP = 72
render.WIDTH = rules.W * render.CELL
render.HEIGHT = rules.H * render.CELL + render.TOP

local CELL = render.CELL
local TOP = render.TOP

local colors = {
  background: {22, 21, 30},
  floor: {44, 42, 56},
  floor_line: {50, 48, 63},
  pillar: {84, 80, 104},
  pillar_top: {108, 104, 132},
  crate: {150, 104, 68},
  crate_edge: {112, 76, 48},
  text: {222, 220, 232},
  dim: {130, 128, 148},
  players: {{242, 98, 98}, {64, 202, 190}, {246, 192, 64}, {164, 122, 242}},
}
render.colors = colors

local func mix(a, b, f){
  return {
    to_int(a[0] + (b[0] - a[0]) * f), to_int(a[1] + (b[1] - a[1]) * f),
    to_int(a[2] + (b[2] - a[2]) * f), 255,
  }
}

local func with_alpha(c, a){
  return {c[0], c[1], c[2], to_int(math.clamp(a, 0, 1) * 255)}
}

// the ink of each player, mixed into the floor once
local inks = {}
for(let local c in values(colors.players)){
  append(inks, mix(colors.floor, c, 0.42))
}

// ------------------------------------------------------------ sound

local sounds = null

local func samples_of(n, f){
  local out = {}
  for(local i = 0; i < n; i = i + 1){
    append(out, f(i / n, i))
  }
  return out
}

local func make(rate, seconds, f){
  return rl.sound({samples: samples_of(to_int(rate * seconds), f), sample_rate: rate})
}

func render.init_sound(){
  rl.init_audio_device()
  if(not rl.is_audio_device_ready()){
    return
  }
  local rate = 22050
  local phase = 0
  local low = 0
  sounds = {
    // noise through a falling low-pass: a thud with a crackle
    boom: make(rate, 0.5, func(t, i){
      local cut = 0.35 * (1 - t) + 0.02
      low = low + (math.random() * 2 - 1 - low) * cut
      return low * (1 - t) * (1 - t) * 0.9
    }),
    drop: make(rate, 0.06, func(t, i){
      phase = phase + (300 - 120 * t) / rate
      return math.sin(phase * 6.2832) * (1 - t) * 0.35
    }),
    pickup: make(rate, 0.16, func(t, i){
      phase = phase + (600 + 700 * t) / rate
      return (if(phase % 1 < 0.5){ 1 } else { -1 }) * (1 - t) * 0.15
    }),
    ko: make(rate, 0.4, func(t, i){
      phase = phase + (500 - 380 * t) / rate
      return (if(phase % 1 < 0.5){ 1 } else { -1 }) * (1 - t) * 0.2
    }),
  }
}

func render.play(name){
  if(sounds != null and sounds[name] != null){
    rl.play_sound(sounds[name])
  }
}

func render.close_sound(){
  if(sounds != null){
    rl.close_audio_device()
  }
}

// ------------------------------------------------------------ the arena

local func cell_rect(x, y, inset){
  return {x * CELL + inset, TOP + y * CELL + inset, CELL - 2 * inset, CELL - 2 * inset}
}

local func draw_cells(state, time){
  for(local y = 0; y < rules.H; y = y + 1){
    for(local x = 0; x < rules.W; x = x + 1){
      local i = rules.index(x, y)
      local c = state.cells[i]
      local px = x * CELL
      local py = TOP + y * CELL
      if(c == rules.PILLAR){
        rl.draw_rectangle(px, py, CELL, CELL, colors.pillar)
        rl.draw_rectangle(px + 3, py + 3, CELL - 6, CELL - 12, colors.pillar_top)
      } else {
        local owner = state.paint[i]
        local floor = if(owner > 0){ inks[owner - 1] } else { colors.floor }
        rl.draw_rectangle(px, py, CELL, CELL, floor)
        rl.draw_rectangle_lines(px, py, CELL, CELL, colors.floor_line)
        if(c == rules.CRATE){
          rl.draw_rectangle_rounded(cell_rect(x, y, 4), 0.18, 4, colors.crate_edge)
          rl.draw_rectangle_rounded(cell_rect(x, y, 7), 0.18, 4, colors.crate)
          rl.draw_line_ex({px + 10, py + 10}, {px + CELL - 10, py + CELL - 10}, 3, colors.crate_edge)
          rl.draw_line_ex({px + CELL - 10, py + 10}, {px + 10, py + CELL - 10}, 3, colors.crate_edge)
        } else if(c == rules.POT){
          local bob = math.sin(time * 4 + x) * 2
          rl.draw_circle(px + CELL / 2, py + CELL / 2 + 4 + bob, 12, {60, 58, 76, 255})
          rl.draw_circle(px + CELL / 2, py + CELL / 2 + 2 + bob, 9, mix(colors.players[to_int(time * 2) % 4], {255, 255, 255}, 0.2))
          rl.draw_rectangle(px + CELL / 2 - 5, py + CELL / 2 - 12 + bob, 10, 6, {60, 58, 76, 255})
        } else if(c == rules.LENS){
          local bob = math.sin(time * 4 + y) * 2
          rl.draw_circle_lines(px + CELL / 2, py + CELL / 2 + bob, 11, colors.text)
          rl.draw_circle(px + CELL / 2, py + CELL / 2 + bob, 8, {150, 200, 255, 140})
          rl.draw_line_ex({px + CELL / 2 + 8, py + CELL / 2 + 8 + bob}, {px + CELL / 2 + 15, py + CELL / 2 + 15 + bob}, 3, colors.text)
        }
      }
    }
  }
}

local func draw_charges(state, time){
  for(let local ch in values(state.charges)){
    local cx = ch[0] * CELL + CELL / 2
    local cy = TOP + ch[1] * CELL + CELL / 2
    local left = ch[3]
    // quicker and bigger as it burns down
    local pulse = math.sin(time * (8 + 20 * (1 - left / 2200))) * 0.5 + 0.5
    local color = colors.players[ch[2]]
    rl.draw_circle(cx, cy + 3, 15, {12, 12, 18, 120})
    rl.draw_circle(cx, cy, 14 + pulse * 2, mix({30, 28, 40}, color, 0.25 + pulse * 0.25))
    rl.draw_ring({cx, cy}, 10, 14 + pulse * 2, -90, -90 + 360 * left / 2200, 24, color)
    rl.draw_circle(cx + 6, cy - 12, 3 + pulse * 2, {255, 230, 140, 255})
  }
}

local func draw_blasts(state){
  for(let local b in values(state.blasts)){
    local color = colors.players[b[0]]
    for(let local i in values(b[1])){
      local x = i % rules.W
      local y = to_int((i - x) / rules.W)
      rl.draw_rectangle_rounded(cell_rect(x, y, 2), 0.3, 4, with_alpha(color, 0.85))
      rl.draw_rectangle_rounded(cell_rect(x, y, 12), 0.5, 4, {255, 248, 230, 230})
    }
  }
}

local func draw_player(c, p, time){
  local slot = p[0]
  local flags = p[4]
  if((flags & 1) == 0){
    return
  }
  // a player who just came back blinks while blasts cannot touch them
  if((flags & 2) != 0 and to_int(time * 10) % 2 == 0){
    return
  }
  local at = c:position_of(slot)
  local cx = at[0] * CELL + CELL / 2
  local cy = TOP + at[1] * CELL + CELL / 2
  local color = colors.players[slot]
  local dir = p[3]
  local dx = rules.DX[dir]
  local dy = rules.DY[dir]
  rl.draw_ellipse(cx, cy + 15, 15, 6, {10, 10, 16, 110})
  rl.draw_circle(cx, cy, 17, mix(color, {0, 0, 0}, 0.3))
  rl.draw_circle(cx, cy - 2, 16, color)
  // eyes look where it goes: side by side, or one above the other
  // when it looks left or right
  for(let local side in values({-1, 1})){
    local ex = cx + side * 6
    local ey = cy - 4 + dy * 5
    if(dx != 0){
      ex = cx + dx * 7
      ey = cy - 4 + side * 4
    }
    rl.draw_circle(ex, ey, 4, {250, 250, 255, 255})
    rl.draw_circle(ex + dx * 1.5, ey + dy * 1.5, 2, {20, 20, 30, 255})
  }
  if(slot == c.slot){
    rl.draw_triangle({cx, cy - 25}, {cx - 6, cy - 33}, {cx + 6, cy - 33}, colors.text)
  }
}

// ------------------------------------------------------------ the HUD

local func clock_text(ms){
  local s = to_int(math.ceil(ms / 1000))
  local m = to_int((s - s % 60) / 60)
  local rest = s % 60
  return concat(string(m), ":", if(rest < 10){ "0" } else { "" }, string(rest))
}

local func name_of(c, slot){
  local r = c.roster[slot]
  if(r == null){
    return concat("Player ", string(slot + 1))
  }
  return r.name
}

local func draw_hud(c, state){
  rl.draw_rectangle(0, 0, render.WIDTH, TOP, colors.background)
  local card = 150
  local order = {0, 2, 1, 3}
  for(local n = 0; n < 4; n = n + 1){
    local slot = order[n]
    local p = state.by_slot[slot]
    local x = if(n < 2){ 12 + n * (card + 8) } else { render.WIDTH - 12 - (4 - n) * (card + 8) + 8 }
    local color = colors.players[slot]
    if(p == null){
      rl.draw_rectangle_rounded({x, 10, card, 52}, 0.2, 4, {34, 33, 44, 255})
    } else {
      rl.draw_rectangle_rounded({x, 10, card, 52}, 0.2, 4, mix(colors.background, color, if(slot == c.slot){ 0.35 } else { 0.18 }))
      rl.draw_rectangle_rounded({x + 8, 20, 10, 32}, 0.5, 4, color)
      local name = name_of(c, slot)
      if(c.roster[slot] != null and c.roster[slot].bot){
        name = concat(name, " (bot)")
      }
      // (a long name is cut to fit the card)
      for(len(name) > 1 and rl.measure_text(name, 16) > card - 34){
        name = str.substring(name, 0, len(name) - 1)
      }
      rl.draw_text(name, x + 26, 16, 16, colors.text)
      rl.draw_text(string(p[6]), x + 26, 36, 22, color)
      local kos = concat("KO ", string(p[5]))
      rl.draw_text(kos, x + card - 10 - rl.measure_text(kos, 14), 42, 14, colors.dim)
    }
  }
  local t = clock_text(state.left)
  local size = 34
  local tcolor = if(state.left < 10000){ colors.players[0] } else { colors.text }
  rl.draw_text(t, render.WIDTH / 2 - rl.measure_text(t, size) / 2, 12, size, tcolor)
  local rtt = concat(string(to_int(c.net.rtt)), " ms")
  rl.draw_text(rtt, render.WIDTH / 2 - rl.measure_text(rtt, 12) / 2, 50, 12, colors.dim)
}

local func centered(s, y, size, color){
  rl.draw_text(s, render.WIDTH / 2 - rl.measure_text(s, size) / 2, y, size, color)
}

local func draw_feed(feed, time){
  local y = render.HEIGHT - 26
  for(local i = len(feed) - 1; i >= 0 and i >= len(feed) - 4; i = i - 1){
    local e = feed[i]
    local age = time - e.at
    if(age < 4){
      local w = rl.measure_text(e.text, 16)
      rl.draw_rectangle_rounded({render.WIDTH - w - 24, y - 4, w + 16, 24}, 0.4, 4, {16, 16, 24, to_int(200 * (1 - age / 4))})
      rl.draw_text(e.text, render.WIDTH - w - 16, y, 16, with_alpha(e.color, 1 - age / 4))
      y = y - 28
    }
  }
}

// draw(client, feed, time): one frame
func render.draw(c, feed, time){
  rl.begin_drawing()
  rl.clear_background(colors.background)
  local state = c.state
  if(state == null){
    centered(c.status, render.HEIGHT / 2 - 12, 24, colors.dim)
    rl.end_drawing()
    return
  }
  draw_cells(state, time)
  draw_charges(state, time)
  draw_blasts(state)
  for(let local p in values(state.players)){
    draw_player(c, p, time)
  }
  draw_hud(c, state)
  draw_feed(feed, time)
  if(state.phase == "over"){
    rl.draw_rectangle(0, TOP, render.WIDTH, render.HEIGHT - TOP, {10, 10, 16, 170})
    local p = state.by_slot[state.winner]
    if(p != null){
      local color = colors.players[state.winner]
      centered(concat(name_of(c, state.winner), " wins"), render.HEIGHT / 2 - 40, 48, color)
      centered(concat(string(p[6]), " tiles of ink"), render.HEIGHT / 2 + 16, 24, colors.text)
    }
    centered("next round soon", render.HEIGHT / 2 + 52, 18, colors.dim)
  } else if(c.slot != null){
    local me = state.by_slot[c.slot]
    if(me != null and (me[4] & 1) == 0){
      centered("knocked out", render.HEIGHT / 2 - 16, 32, colors.text)
    }
  }
  rl.end_drawing()
}

// the line in the feed for a piece of news, or null
func render.feed_line(c, e){
  if(e[0] == "ko"){
    local victim = name_of(c, e[1])
    if(e[1] == e[2]){
      return {text: concat(victim, " inked themselves"), color: colors.players[e[1]]}
    }
    return {text: concat(name_of(c, e[2]), " inked ", victim), color: colors.players[e[2]]}
  }
  if(e[0] == "pickup" and e[2] == "pot"){
    return {text: concat(name_of(c, e[1]), " spilled a pot"), color: colors.players[e[1]]}
  }
  return null
}

return render
