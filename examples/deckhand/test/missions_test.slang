// every mission can be won, and its main hazard catches the careless
local t = require("slang/test")
local missions = require("game/missions")
local autopilot = require("game/autopilot")

local by_name = {}
for(let local m in values(missions)){
  by_name[m.name] = m
}

local solutions = require("game/solutions")

// what goes wrong without the trick: {steps, how it ends}
local failures = {
  doorman: {{{go: "dossier"}}, "stuck"},
  timing: {
    {
      {go: "port1"}, {jack: "port1"}, {type: "door1.open(3)"}, {unjack: true},
      {go: "dossier"}
    },
    "stuck",
  },
  eyes: {{{go: "dossier"}}, "caught"},
  tripwire: {
    {
      {go: "port1"}, {jack: "port1"}, {type: "laser1.off(3); door1.open(3)"},
      {unjack: true}, {go: "dossier"}
    },
    "stuck",
  },
  pulse: {
    {
      {go: "port1"}, {jack: "port1"}, {type: "cam1.off(2); cam2.off(2)"},
      {unjack: true}, {go: "dossier"}
    },
    "caught",
  },
  // the glass does not hide you
  relay: {
    {
      {go: "port1"}, {jack: "port1"}, {type: "door1.open()"}, {unjack: true},
      {go: "port2"}, {jack: "port2"},
      {type: "laser1.off(7); wait(4); door2.open(3)"}, {unjack: true},
      {go: "dossier"}
    },
    "caught",
  },
}

local func describe(r){
  return concat(
    "state ", r.world.state, ", reason ", string(r.world.reason), ", pilot ",
    string(r.pilot.failed), ", at ", r.world.player.x, ",", r.world.player.z,
    ", t ", r.world.time
  )
}

t.group("missions"){
  t.test("every mission has a solution and a failure here"){
    for(let local m in values(missions)){
      assert(solutions[m.name] != null, concat("no solution for ", m.name))
      assert(failures[m.name] != null, concat("no failure for ", m.name))
    }
  }
  for(let local m in values(missions)){
    t.test(concat(m.name, " can be won")){
      local r = autopilot.play(m, solutions[m.name], 60)
      assert(r.world.state == "complete", describe(r))
    }
    t.test(concat(m.name, " punishes the obvious")){
      local f = failures[m.name]
      local r = autopilot.play(m, f[0], 30)
      if(f[1] == "caught"){
        assert(r.world.state == "caught", describe(r))
      } else {
        assert(
          r.world.state == "playing" and r.pilot.failed != null,
          describe(r),
        )
      }
    }
  }
}
