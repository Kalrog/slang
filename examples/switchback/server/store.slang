// server/store: the daily runs, in SQLite. A player is a random id the
// browser keeps (no account); their first finished run of a day is the
// one that counts, and a name, if they gave one, is shown with it.
//
//   local store = require("server/store")
//   local s = store.open("daily.db")              // or ":memory:"
//   store.add(s, {day: 3, player: id, time: 812.4, penalty: 10,
//     recoveries: 1, splits: {120.5, 340.1, 812.4}})   // {ok: true}
//   store.set_name(s, id, "Ann")
//   store.results(s, 3, id)       // the day's times as a graph, and yours
local sqlite = require("slang/sqlite")
local json = require("slang/json")
local math = require("slang/math")
local str = require("slang/string")
local time = require("slang/time")

local m = {}

// a run to the summit takes longer than this, and less than that (s)
m.MIN_TIME = 60
m.MAX_TIME = 6 * 3600
m.NAME_LENGTH = 20
// about this many bars in the graph
m.BINS = 24
// and at least this many
m.MIN_BINS = 12
// the named runs listed with the graph
m.TOP = 10

// open(path: string) -> Store
func m.open(path){
  local db = sqlite.open(path)
  db:exec("""create table if not exists runs(
    day integer not null, player text not null, time real not null,
    penalty real not null, recoveries integer not null, splits text not null,
    created real not null, primary key(day, player))""")
  db:exec("create index if not exists runs_by_time on runs(day, time)")
  db:exec("create table if not exists players(player text primary key, name text not null)")
  return {db: db}
}

func m.close(s){
  s.db:close()
}

local func is_number(v){
  return type(v) == "int" or type(v) == "double"
}

// player ids: 32 hex digits (lower case)
func m.valid_player(p){
  if(type(p) != "string" or len(p) != 32){
    return false
  }
  for(local i = 0; i < 32; i = i + 1){
    local b = str.byte_at(p, i)
    if(not ((b >= 48 and b <= 57) or (b >= 97 and b <= 102))){
      return false
    }
  }
  return true
}

// the name as it is kept, or null when it cannot be one: trimmed, 1 to
// NAME_LENGTH characters, no control characters
func m.clean_name(name){
  if(type(name) != "string"){
    return null
  }
  name = str.trim(name)
  if(len(name) == 0 or len(name) > m.NAME_LENGTH * 4){
    return null
  }
  local chars = 0
  for(local i = 0; i < len(name); i = i + 1){
    local b = str.byte_at(name, i)
    if(b < 32 or b == 127){
      return null
    }
    // (counting characters: the bytes that start one)
    if(b < 128 or b >= 192){
      chars = chars + 1
    }
  }
  if(chars > m.NAME_LENGTH){
    return null
  }
  return name
}

// why a run cannot be taken, or null
local func problem(run){
  if(type(run) != "table"){
    return "not a run"
  }
  if(not m.valid_player(run.player)){
    return "bad player"
  }
  if(type(run.day) != "int"){
    return "bad day"
  }
  if(not is_number(run.time) or run.time < m.MIN_TIME or run.time > m.MAX_TIME){
    return "bad time"
  }
  if(not is_number(run.penalty) or run.penalty < 0 or run.penalty > run.time){
    return "bad penalty"
  }
  if(type(run.recoveries) != "int" or run.recoveries < 0){
    return "bad recoveries"
  }
  if(type(run.splits) != "table" or len(run.splits) > 64){
    return "bad splits"
  }
  local last = 0
  for(let local t in values(run.splits)){
    if(not is_number(t) or t < last or t > run.time + 0.001){
      return "bad splits"
    }
    last = t
  }
  return null
}

// add(store, run: {day, player, time, penalty, recoveries, splits,
//   name?}) -> {ok: bool, reason?: string}
// The player's run of the day, unless they have one: reason "counted"
// then, or what is wrong with it. A name with it is the player's name
// from now on.
func m.add(s, run){
  local wrong = problem(run)
  if(wrong != null){
    return {ok: false, reason: wrong}
  }
  local r = s.db:run(
    "insert or ignore into runs(day, player, time, penalty, recoveries, splits, created) values (?, ?, ?, ?, ?, ?, ?)",
    {run.day, run.player, run.time * 1.0, run.penalty * 1.0, run.recoveries, json.encode(run.splits), time.now()},
  )
  if(run.name != null){
    m.set_name(s, run.player, run.name)
  }
  if(r.changes == 0){
    return {ok: false, reason: "counted"}
  }
  return {ok: true}
}

// set_name(store, player, name?) -> bool: the player's name ("" or null
// removes it); false for a name that cannot be one
func m.set_name(s, player, name){
  if(not m.valid_player(player)){
    return false
  }
  if(name == null or (type(name) == "string" and str.trim(name) == "")){
    s.db:run("delete from players where player = ?", {player})
    return true
  }
  local clean = m.clean_name(name)
  if(clean == null){
    return false
  }
  s.db:run(
    "insert into players(player, name) values (?, ?) on conflict(player) do update set name = excluded.name",
    {player, clean},
  )
  return true
}

// run(store, day, player) -> the player's counted run of the day, or null:
// {time, penalty, recoveries, splits}
func m.run(s, day, player){
  if(not m.valid_player(player)){
    return null
  }
  local row = s.db:one("select time, penalty, recoveries, splits from runs where day = ? and player = ?", {day, player})
  if(row == null){
    return null
  }
  row.splits = try { json.decode(row.splits) } catch { {} }
  return row
}

// a step for the bars that reads well (seconds)
local STEPS = {1, 2, 5, 10, 15, 20, 30, 60, 90, 120, 180, 300, 600, 900, 1800, 3600}

local func nice(width){
  for(let local step in values(STEPS)){
    if(step >= width){
      return step
    }
  }
  return STEPS[len(STEPS) - 1]
}

// results(store, day, player?) -> Results
// type Results = {day: int, count: int, median?: float, best?: float,
//   bins: {from: float, width: float, counts: {int}},
//   you?: {time: float, rank: int, ahead_of: float},
//   top: {{name: string, time: float, you: bool}}}
// [bins]: the times as bars: bar k counts the times from from + k * width
//   (the last bar also the slower ones)
// [you]: the player's counted run: rank 1 is the fastest; ahead_of, the
//   share of the others that were slower (0 to 1)
// [top]: the fastest runs of players with a name
func m.results(s, day, player){
  local rows = s.db:all("select time from runs where day = ? order by time", {day})
  local times = {}
  for(let local row in values(rows)){
    append(times, row.time)
  }
  local count = len(times)
  local out = {day: day, count: count, bins: {from: 0, width: 60, counts: {}}, top: {}}
  if(count > 0){
    out.best = times[0]
    out.median = if(count % 2 == 1){ times[to_int(count / 2)] } else {
      (times[count / 2 - 1] + times[count / 2]) / 2
    }
    // the bars reach from the best to the slowest twentieth (the slower
    // ones go into the last)
    local high = times[math.min(count - 1, to_int(count * 0.95))]
    local width = nice(math.max(5, (high - times[0]) / m.BINS))
    local from = math.floor(times[0] / width) * width
    local n = math.max(1, to_int(math.floor((high - from) / width)) + 1)
    // (few times: still a graph's width of bars, the times in its middle)
    if(n < m.MIN_BINS){
      local before = math.min(to_int(from / width), to_int((m.MIN_BINS - n) / 2))
      from = from - before * width
      n = m.MIN_BINS
    }
    local counts = {}
    for(local k = 0; k < n; k = k + 1){
      append(counts, 0)
    }
    for(let local t in values(times)){
      local k = math.min(n - 1, to_int(math.floor((t - from) / width)))
      counts[k] = counts[k] + 1
    }
    out.bins = {from: from, width: width, counts: counts}
  }
  local mine = if(player != null){ m.run(s, day, player) } else { null }
  if(mine != null){
    local faster = s.db:one("select count(*) as n from runs where day = ? and time < ?", {day, mine.time}).n
    local slower = s.db:one("select count(*) as n from runs where day = ? and time > ?", {day, mine.time}).n
    out.you = {
      time: mine.time,
      rank: faster + 1,
      ahead_of: if(count > 1){ slower / (count - 1) } else { 1.0 },
    }
  }
  for(let local row in values(s.db:all(
    "select players.player as player, players.name as name, runs.time as time from runs join players on players.player = runs.player where runs.day = ? order by runs.time limit ?",
    {day, m.TOP},
  ))){
    append(out.top, {name: row.name, time: row.time, you: row.player == player})
  }
  return out
}

return m
