// Inkblast: a party game for up to four on one arena, over the network.
// Set charges, blast crates, and paint the floor in your colour: when the
// 90 seconds are up, the most floor wins. A blast knocks out whoever it
// catches for a few seconds. Bots fill the slots nobody plays.
//
//   bin/slang run examples/inkblast/main.slang               host a game and play
//   bin/slang run examples/inkblast/main.slang join 10.0.0.7  join a game
//   bin/slang run examples/inkblast/main.slang server         serve without a window
//
// Options: --port n (7777), --name text, --bots easy|normal|hard (how
// well the bots play, normal by default), --no-bots, --round seconds (90),
// and on a client --lag ms and --loss 0.1 to play over a worse network
// than there is
// (slang/net's simulate). Arrows or WASD move, space sets a charge,
// escape quits.
//
// The game uses slang/net: the server runs the rules (game/rules) and sends
// the state every tick; clients send what the player does and draw. The
// host plays through the network too, over loopback.
//
// For tests and screenshots, from the environment:
//   INKBLAST_FRAMES=n          quit after n frames
//   INKBLAST_AUTOPLAY=1        a bot plays for you
//   INKBLAST_SHOT=n:file.png   save a screenshot at frame n
local rl = require("raylib")
local os = require("slang/os")
local str = require("slang/string")
local uv = require("uv")
local server = require("game/server")
local client = require("game/client")
local render = require("game/render")
local bots = require("game/bots")

local func usage(){
  print("usage: main.slang [join <address> | server] [--port n] [--name text] [--bots easy|normal|hard] [--no-bots] [--round s] [--lag ms] [--loss p]\n")
  os.exit(2)
}

local func options(list){
  local o = {mode: "host", port: 7777, name: os.getenv("USER") or "Player", bots: true, lag: 0, loss: 0}
  local i = 0
  local func value(){
    i = i + 1
    if(i >= len(list)){
      usage()
    }
    return list[i]
  }
  for(; i < len(list); i = i + 1){
    local a = list[i]
    if(a == "join"){
      o.mode = "join"
      o.address = value()
    } else if(a == "server"){
      o.mode = "server"
    } else if(a == "host"){
      o.mode = "host"
    } else if(a == "--port"){
      o.port = to_int(value())
    } else if(a == "--name"){
      o.name = value()
    } else if(a == "--round"){
      o.round = to_int(value()) * 1000
    } else if(a == "--bots"){
      o.level = value()
      if(bots.LEVELS[o.level] == null){
        usage()
      }
    } else if(a == "--no-bots"){
      o.bots = false
    } else if(a == "--lag"){
      o.lag = to_int(value())
    } else if(a == "--loss"){
      o.loss = str.to_number(value())
    } else {
      usage()
    }
  }
  return o
}

local o = options(args())

if(o.mode == "server"){
  local s = server.start({port: o.port, bots: o.bots, level: o.level, round: o.round})
  print("inkblast: serving on port ", s.port, "\n")
  s:run()
  return
}

local host = null
local address = o.address
if(o.mode == "host"){
  host = server.start({port: o.port, bots: o.bots, level: o.level, round: o.round})
  address = "127.0.0.1"
  print("inkblast: hosting on port ", host.port, " (others join with: join <this machine's address>)\n")
}
local simulate = null
if(o.lag > 0 or o.loss > 0){
  simulate = {latency: o.lag / 2, jitter: o.lag / 4, loss: o.loss}
}
local c = client.connect(address, o.port, {name: o.name, simulate: simulate})

local autoplay = os.getenv("INKBLAST_AUTOPLAY") != null
local frame_limit = os.getenv("INKBLAST_FRAMES")
local shots = {}
if(os.getenv("INKBLAST_SHOT") != null){
  for(let local part in values(str.split(os.getenv("INKBLAST_SHOT"), ","))){
    local pieces = str.split(part, ":")
    shots[to_int(pieces[0])] = pieces[1]
  }
}

rl.set_config_flags(rl.FLAG_MSAA_4X_HINT)
rl.init_window(render.WIDTH, render.HEIGHT, "Inkblast")
rl.set_target_fps(60)
render.init_sound()

// the direction held: the newest key pressed wins while it is down
local KEYS = {
  {rl.KEY_UP, rl.KEY_W}, {rl.KEY_RIGHT, rl.KEY_D}, {rl.KEY_DOWN, rl.KEY_S}, {rl.KEY_LEFT, rl.KEY_A},
}
local held = {}
local func steering(){
  for(local d = 1; d <= 4; d = d + 1){
    local down = rl.is_key_down(KEYS[d - 1][0]) or rl.is_key_down(KEYS[d - 1][1])
    local i = -1
    for(local j = 0; j < len(held); j = j + 1){
      if(held[j] == d){
        i = j
      }
    }
    if(down and i < 0){
      append(held, d)
    } else if(not down and i >= 0){
      remove(held, i)
    }
  }
  if(len(held) == 0){
    return 0
  }
  return held[len(held) - 1]
}

// autoplay: a bot plans for you (on the host's world)
local mind = bots.mind("hard")
local func autopilot(){
  local s = c.state
  if(s == null or c.slot == null or host == null){
    return
  }
  local plan = bots.think(host.world, c.slot, mind)
  c:steer(plan.dir)
  if(plan.drop){
    c:drop()
  }
}

local feed = {}
local frames = 0
local start = uv.hrtime()
for(; not rl.window_should_close(); frames = frames + 1){
  if(frame_limit != null and frames >= to_int(frame_limit)){
    break
  }
  local dt = rl.get_frame_time() * 1000
  if(host != null){
    host:update(dt)
  }
  if(autoplay){
    autopilot()
  } else {
    c:steer(steering())
    if(rl.is_key_pressed(rl.KEY_SPACE)){
      c:drop()
    }
  }
  c:update()
  local time = (uv.hrtime() - start) / 1e9
  for(let local e in values(c:take_news())){
    if(e[0] == "boom"){
      render.play("boom")
    } else if(e[0] == "drop"){
      render.play("drop")
    } else if(e[0] == "pickup"){
      render.play("pickup")
    } else if(e[0] == "ko"){
      render.play("ko")
    }
    local line = render.feed_line(c, e)
    if(line != null){
      line.at = time
      append(feed, line)
      if(len(feed) > 8){
        remove(feed, 0)
      }
    }
  }
  render.draw(c, feed, time)
  if(shots[frames] != null){
    rl.take_screenshot(shots[frames])
  }
}
c:close()
if(host != null){
  // (the goodbye reaches the server before it closes)
  host:update(0)
  host:close()
}
render.close_sound()
rl.close_window()
print("inkblast: ", frames, " frames, ", c.status, "\n")
