// Delve: a small roguelike. Seven floors of a dungeon made anew for every
// game, the Amulet of Yendor at the bottom, and monsters that differ by
// what they do: bats flutter, oozes split, archers keep their distance,
// ghosts walk through walls. Field of view, pathfinding and the rules
// live in game/ with no window; this file draws them with raylib
// (packages/raylib) and reads the keyboard.
//
//   make delve            (or: slang run examples/delve/main.slang)
//
// Move with the arrow keys, hjkl and yubn (or the numpad); walk into a
// monster to attack, into a door to open it. . or 5 waits, g picks up,
// > descends, i opens the pack (then a number uses an item), ? shows the
// help, r starts over, escape quits.
//
// DELVE_SEED=n makes the same dungeon every run, DELVE_AUTOPLAY=1 lets the
// autoplayer play, DELVE_FRAMES=n quits after n frames and
// DELVE_SCREENSHOT=file saves the last frame (the smoke test uses them).
local rl = require("raylib")
local os = require("slang/os")
local str = require("slang/string")
local world = require("game/world")
local map = require("game/map")
local bot = require("game/bot")
local kinds = require("game/kinds")

local CELL_W = 18
local CELL_H = 22
local FONT = 20
local TOP = 34                 // the status bar
local LOG_LINES = 4
local LOG_H = LOG_LINES * 20 + 10
local WIDTH = map.W * CELL_W
local HEIGHT = TOP + map.H * CELL_H + LOG_H

local colors = {
  background: {14, 12, 20},
  bar: {26, 22, 38},
  wall: {150, 138, 190},
  wall_dim: {62, 56, 82},
  floor: {120, 114, 150},
  floor_dim: {44, 42, 58},
  door: {190, 140, 70},
  door_dim: {95, 70, 35},
  stairs: {255, 255, 255},
  stairs_dim: {140, 140, 150},
  player: {255, 255, 255},
  text: {210, 205, 220},
  dim: {120, 115, 135},
  hp_good: {90, 200, 110},
  hp_hurt: {230, 190, 70},
  hp_bad: {230, 80, 80},
  bolt: {170, 210, 255},
  gold: {250, 210, 60},
  title: {255, 230, 140},
}

// ------------------------------------------------------------ sound

// A tone computed here: a square wave sliding from one pitch to another,
// fading out, handed to raylib as samples (as examples/breakout does).
local sounds = null

local func tone(from, to, seconds, volume){
  local rate = 22050
  local n = to_int(rate * seconds)
  local samples = {}
  local phase = 0.0
  for(local i = 0; i < n; i = i + 1){
    local t = i / n
    phase = phase + (from + (to - from) * t) / rate
    local square = phase % 1 < 0.5 and 1 or -1
    append(samples, square * volume * (1 - t))
  }
  return rl.sound({samples: samples, sample_rate: rate})
}

local func make_sounds(){
  rl.audio.open()
  if(not rl.audio.ready){ return }
  sounds = {
    hit: tone(240, 180, 0.06, 0.2),
    hurt: tone(150, 80, 0.12, 0.25),
    kill: tone(300, 620, 0.1, 0.2),
    pickup: tone(660, 990, 0.08, 0.18),
    stairs: tone(330, 140, 0.35, 0.2),
    zap: tone(1400, 200, 0.2, 0.22),
    dead: tone(220, 40, 1.0, 0.3),
    won: tone(440, 1760, 0.9, 0.25),
  }
}

local func play(name){
  if(sounds != null and sounds[name] != null){ sounds[name]:play() }
}

// ------------------------------------------------------------ state

local seed = os.getenv("DELVE_SEED")
local autoplay = os.getenv("DELVE_AUTOPLAY") != null
local w = null
local b = null
local overlay = null           // null, "pack", "help"
local aiming = null            // the pack index of the wand being aimed
local bolt_until = 0           // the bolt of a wand stays drawn until then
local frames = 0

local func new_game(){
  w = world.new({seed: seed != null and to_int(str.to_number(seed)) or null})
  b = bot.new(w)
  overlay = null
  aiming = null
}

// runs a player action and plays what it caused
local func act(action){
  local passed = w:act(action)
  if(w.event != null){ play(w.event) }
  if(w.bolt != null){ bolt_until = rl.time + 0.18 }
  if(w.state == "dead"){ play("dead") }
  if(w.state == "won"){ play("won") }
  return passed
}

// ------------------------------------------------------------ input

local dirs = {
  {rl.KEY_LEFT, -1, 0}, {rl.KEY_RIGHT, 1, 0}, {rl.KEY_UP, 0, -1}, {rl.KEY_DOWN, 0, 1},
  {rl.KEY_KP_4, -1, 0}, {rl.KEY_KP_6, 1, 0}, {rl.KEY_KP_8, 0, -1}, {rl.KEY_KP_2, 0, 1},
  {rl.KEY_KP_7, -1, -1}, {rl.KEY_KP_9, 1, -1}, {rl.KEY_KP_1, -1, 1}, {rl.KEY_KP_3, 1, 1},
}
local char_dirs = {
  h: {-1, 0}, l: {1, 0}, k: {0, -1}, j: {0, 1},
  y: {-1, -1}, u: {1, -1}, b: {-1, 1}, n: {1, 1},
}

// the direction asked for this frame, or null
local func direction_pressed(chars){
  for(let local d in values(dirs)){
    if(rl.key.pressed(d[0]) or rl.key.pressed_repeat(d[0])){ return {d[1], d[2]} }
  }
  for(let local c in values(chars)){
    if(char_dirs[c] != null){ return char_dirs[c] }
  }
  return null
}

local func handle_input(){
  local chars = {}
  for(local c = rl.key.next_char(); c != 0; c = rl.key.next_char()){
    append(chars, str.from_bytes({c}))
  }
  local escape = rl.key.pressed(rl.KEY_ESCAPE)
  for(let local c in values(chars)){
    if(c == "r" and w.state != "playing"){ new_game(); return }
    if(c == "?"){ overlay = overlay == "help" and null or "help"; return }
    if(c == "i"){ overlay = overlay == "pack" and null or "pack"; aiming = null; return }
  }
  if(escape and (overlay != null or aiming != null)){
    overlay = null
    aiming = null
    return
  }
  if(w.state != "playing"){ return }
  if(aiming != null){
    local d = direction_pressed(chars)
    if(d != null){
      local i = aiming
      aiming = null
      act({kind: "use", index: i, dir: d})
    }
    return
  }
  if(overlay == "pack"){
    for(let local c in values(chars)){
      local n = str.parse_int(c)
      if(n != null and n >= 1 and n <= len(w.player.pack)){
        local it = w.player.pack[n - 1]
        overlay = null
        if(kinds.items[it.kind].use == "zap"){
          aiming = n - 1
        } else {
          act({kind: "use", index: n - 1})
        }
        return
      }
    }
    return
  }
  if(overlay != null){ return }
  if(autoplay){
    if(frames % 5 == 0){ b:step() }   // twelve moves a second, to watch
    return
  }
  local d = direction_pressed(chars)
  if(d != null){
    act({kind: "move", dx: d[0], dy: d[1]})
    return
  }
  for(let local c in values(chars)){
    if(c == "." or c == "5"){ act({kind: "wait"}) }
    else if(c == "g" or c == ","){ act({kind: "pickup"}) }
    else if(c == ">"){ act({kind: "descend"}) }
    else if(str.parse_int(c) != null and str.parse_int(c) >= 1){
      local n = str.parse_int(c)
      if(n <= len(w.player.pack)){
        local it = w.player.pack[n - 1]
        if(kinds.items[it.kind].use == "zap"){ aiming = n - 1 } else { act({kind: "use", index: n - 1}) }
      }
    }
  }
  if(rl.key.pressed(rl.KEY_KP_5)){ act({kind: "wait"}) }
}

// ------------------------------------------------------------ drawing

local func glyph(ch, x, y, color){
  local px = x * CELL_W + to_int((CELL_W - rl.text.measure(ch, FONT)) / 2)
  rl.draw.text(ch, px, TOP + y * CELL_H + 1, FONT, color)
}

local func draw_map(){
  local m = w.map
  for(local y = 0; y < m.h; y = y + 1){
    for(local x = 0; x < m.w; x = x + 1){
      if(not w.seen:get(x, y)){ continue }
      local lit = w.visible:get(x, y)
      local t = m.tiles:get(x, y)
      if(t == map.WALL or t == map.ROCK){
        glyph("#", x, y, lit and colors.wall or colors.wall_dim)
      } else if(t == map.FLOOR){
        glyph(".", x, y, lit and colors.floor or colors.floor_dim)
      } else if(t == map.DOOR){
        glyph("+", x, y, lit and colors.door or colors.door_dim)
      } else if(t == map.OPEN_DOOR){
        glyph("'", x, y, lit and colors.door or colors.door_dim)
      } else if(t == map.STAIRS){
        glyph(">", x, y, lit and colors.stairs or colors.stairs_dim)
      }
    }
  }
  for(let local it in values(w.items)){
    if(w.seen:get(it.x, it.y)){
      local c = it.color
      if(not w.visible:get(it.x, it.y)){ c = {to_int(c[0] / 2), to_int(c[1] / 2), to_int(c[2] / 2)} }
      glyph(it.glyph, it.x, it.y, c)
    }
  }
  if(w.bolt != null and rl.time < bolt_until){
    for(let local c in values(w.bolt)){ glyph("*", c[0], c[1], colors.bolt) }
  }
  for(let local mo in values(w.monsters)){
    if(w.visible:get(mo.x, mo.y)){
      glyph(mo.glyph, mo.x, mo.y, mo.color)
      if(mo.hp < mo.max_hp){
        // a sliver of health under a wounded monster
        local px = mo.x * CELL_W + 2
        local py = TOP + (mo.y + 1) * CELL_H - 3
        rl.draw.rectangle(px, py, CELL_W - 4, 2, colors.wall_dim)
        rl.draw.rectangle(px, py, to_int((CELL_W - 4) * mo.hp / mo.max_hp), 2, colors.hp_bad)
      }
    }
  }
  glyph("@", w.player.x, w.player.y, colors.player)
}

local func draw_status(){
  local p = w.player
  rl.draw.rectangle(0, 0, WIDTH, TOP, colors.bar)
  local x = 12
  local func item(text, color){
    rl.draw.text(text, x, 8, FONT, color or colors.text)
    x = x + rl.text.measure(text, FONT) + 28
  }
  item(concat("Floor ", string(w.depth)))
  local hp = concat("HP ", string(p.hp), "/", string(p.max_hp))
  local f = p.hp / p.max_hp
  local hp_color = f > 0.6 and colors.hp_good or (f > 0.3 and colors.hp_hurt or colors.hp_bad)
  rl.draw.text(hp, x, 8, FONT, hp_color)
  x = x + rl.text.measure(hp, FONT) + 10
  rl.draw.rectangle(x, 11, 120, 12, colors.wall_dim)
  rl.draw.rectangle(x, 11, to_int(120 * f), 12, hp_color)
  x = x + 148
  item(concat("Gold ", string(p.gold)), colors.gold)
  item(concat(p.weapon.name, " ", string(p.weapon.weapon[0]), "-", string(p.weapon.weapon[1])))
  item(p.armor and concat(p.armor.name, " ", string(p.armor.armor)) or "no armor", p.armor and colors.text or colors.dim)
  item(concat("Pack ", string(len(p.pack)), "/", string(world.PACK)), colors.dim)
  local turn = concat("Turn ", string(w.turn))
  rl.draw.text(turn, WIDTH - 12 - rl.text.measure(turn, FONT), 8, FONT, colors.dim)
}

local func draw_log(){
  local y0 = TOP + map.H * CELL_H
  rl.draw.rectangle(0, y0, WIDTH, LOG_H, colors.bar)
  local n = len(w.messages)
  for(local i = 0; i < LOG_LINES and i < n; i = i + 1){
    local m = w.messages[n - 1 - i]
    local color = i == 0 and colors.text or colors.dim
    if(m.turn < w.turn - 1 and i == 0){ color = colors.dim }
    rl.draw.text(m.text, 12, y0 + 6 + (LOG_LINES - 1 - i) * 20, FONT, color)
  }
  if(aiming != null){
    rl.draw.text("Zap in which direction? (escape cancels)", 12, y0 + 6 + (LOG_LINES - 1) * 20, FONT, colors.bolt)
  }
}

local func panel(lines, title){
  local wmax = rl.text.measure(title, FONT)
  for(let local l in values(lines)){
    local tw = rl.text.measure(l[0], FONT)
    if(tw > wmax){ wmax = tw }
  }
  local pw = wmax + 48
  local ph = (len(lines) + 2) * 22 + 24
  local px = to_int((WIDTH - pw) / 2)
  local py = to_int((HEIGHT - ph) / 2)
  rl.draw.rectangle(px, py, pw, ph, {20, 18, 30, 240})
  rl.draw.rectangle_lines(px, py, pw, ph, colors.wall)
  rl.draw.text(title, px + 24, py + 12, FONT, colors.title)
  for(local i = 0; i < len(lines); i = i + 1){
    rl.draw.text(lines[i][0], px + 24, py + 12 + (i + 2) * 22, FONT, lines[i][1] or colors.text)
  }
}

local func draw_overlay(){
  if(overlay == "pack"){
    local lines = {}
    local p = w.player
    for(local i = 0; i < len(p.pack); i = i + 1){
      local it = p.pack[i]
      local text = concat(string(i + 1), ") ", it.name)
      if(it.charges != null){ text = concat(text, " (", string(it.charges), " charges)") }
      append(lines, {text, it.color})
    }
    if(len(lines) == 0){ append(lines, {"Your pack is empty.", colors.dim}) }
    append(lines, {"", null})
    append(lines, {"A number uses an item, i or escape closes the pack.", colors.dim})
    panel(lines, "Your pack")
  } else if(overlay == "help"){
    local lines = {
      {"Arrows, hjkl / yubn or the numpad move; walk into a monster to attack it.", null},
      {".  or 5     wait a turn", null},
      {"g           pick up what lies here", null},
      {">           descend the stairs", null},
      {"i           the pack; a number uses an item", null},
      {"r           a new game, once this one is over", null},
      {"", null},
      {"Monsters:", colors.title},
    }
    for(let local k in values({"rat", "bat", "goblin", "archer", "ooze", "zombie", "ghost", "troll"})){
      local mk = kinds.monsters[k]
      append(lines, {concat(mk.glyph, "  ", mk.name, "   ", mk.note or ""), mk.color})
    }
    append(lines, {"", null})
    append(lines, {"Find the Amulet of Yendor on floor 7. Escape closes this.", colors.dim})
    panel(lines, "Delve")
  } else if(w.state == "dead"){
    panel({
      {concat("Killed by a ", w.killer, " on floor ", string(w.depth), " after ", string(w.turn), " turns."), null},
      {concat(string(w.player.kills), " monsters slain, ", string(w.player.gold), " gold found."), colors.gold},
      {"", null},
      {"r starts a new game, escape quits.", colors.dim},
    }, "You died")
  } else if(w.state == "won"){
    panel({
      {concat("You bring the Amulet of Yendor up from floor ", string(w.depth), " in ", string(w.turn), " turns."), null},
      {concat(string(w.player.kills), " monsters slain, ", string(w.player.gold), " gold found."), colors.gold},
      {"", null},
      {"r starts a new game, escape quits.", colors.dim},
    }, "You have won")
  }
}

local func draw(){
  rl.drawing{
    rl.draw.clear(colors.background)
    draw_map()
    draw_status()
    draw_log()
    draw_overlay()
  }
}

// ------------------------------------------------------------ main

rl.window.open({width: WIDTH, height: HEIGHT, title: "Delve", fps: 60})
rl.window.exit_key = 0
make_sounds()
new_game()

local frame_limit = os.getenv("DELVE_FRAMES")
local screenshot = os.getenv("DELVE_SCREENSHOT")
for(; not rl.window.should_close; frames = frames + 1){
  if(frame_limit != null and frames >= to_int(str.to_number(frame_limit))){ break }
  if(rl.key.pressed(rl.KEY_ESCAPE) and overlay == null and aiming == null){ break }
  handle_input()
  draw()
  if(screenshot != null and frame_limit != null and frames == to_int(str.to_number(frame_limit)) - 1){
    rl.window.screenshot(screenshot)
  }
}
if(sounds != null){ rl.audio.close() }
rl.window.close()
print("delve: ", frames, " frames, floor ", w.depth, ", turn ", w.turn, ", ", w.state, "\n")
