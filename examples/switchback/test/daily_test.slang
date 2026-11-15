local t = require("slang/test")
local async = require("slang/async")
local json = require("slang/json")
local web = require("slang/web")
local day = require("server/day")
local store = require("server/store")
local app_lib = require("server/app")

// The daily run's server (server/): the day and its valley, one counted
// run a player a day, the day's times as a graph, names, and the API the
// page uses.

local A = "0123456789abcdef0123456789abcdef"
local B = "fedcba9876543210fedcba9876543210"

local func player(i){
  local s = string(100000 + i)
  return concat(s, s, s, s, s, "00")
}

local func math_close(a, b){
  return a - b < 0.000001 and b - a < 0.000001
}

local func run(d, p, time, extra){
  local r = {day: d, player: p, time: time, penalty: 0, recoveries: 0, splits: {time / 2, time}}
  for(let local e in entries(extra or {})){
    r[e[0]] = e[1]
  }
  return r
}

t.group("daily: the day"){
  t.test("day 1 is the 15th of November 2026, a day from midnight UTC"){
    assert(day.number(day.EPOCH) == 1)
    assert(day.number(day.EPOCH + 86399999) == 1)
    assert(day.number(day.EPOCH + 86400000) == 2)
    assert(day.date(1) == "2026-11-15" and day.date(17) == "2026-12-01", day.date(17))
  }

  t.test("each day has its own valley, the same everywhere"){
    local seen = {}
    for(local d = 1; d <= 400; d = d + 1){
      local s = day.seed(d)
      assert(s >= 1 and s <= 99999, s)
      assert(s == day.seed(d))
      seen[s] = true
    }
    local distinct = 0
    for(let local _ in keys(seen)){
      distinct = distinct + 1
    }
    assert(distinct > 390, distinct)
  }
}

t.group("daily: the store"){
  t.test("the first run of a player's day counts, later ones do not"){
    local s = store.open(":memory:")
    assert(store.add(s, run(1, A, 700)).ok)
    local again = store.add(s, run(1, A, 500))
    assert(not again.ok and again.reason == "counted")
    assert(store.run(s, 1, A).time == 700)
    // (another day is another run)
    assert(store.add(s, run(2, A, 500)).ok)
  }

  t.test("runs that cannot be are refused"){
    local s = store.open(":memory:")
    assert(store.add(s, run(1, "nothex", 700)).reason == "bad player")
    assert(store.add(s, run(1, A, 5)).reason == "bad time")
    assert(store.add(s, run(1, A, 700, {splits: {400, 300}})).reason == "bad splits")
    assert(store.add(s, run(1, A, 700, {penalty: 800})).reason == "bad penalty")
    assert(store.add(s, run(1, A, 700, {recoveries: -1})).reason == "bad recoveries")
    assert(store.run(s, 1, A) == null)
  }

  t.test("the day's times as bars, the median, the player's place"){
    local s = store.open(":memory:")
    for(local i = 0; i < 40; i = i + 1){
      assert(store.add(s, run(3, player(i), 600 + i * 10)).ok)
    }
    local r = store.results(s, 3, player(10))
    assert(r.count == 40 and r.best == 600 and r.median == 795, r.median)
    local total = 0
    for(let local c in values(r.bins.counts)){
      total = total + c
    }
    assert(total == 40, total)
    assert(len(r.bins.counts) >= 10 and len(r.bins.counts) <= 30, len(r.bins.counts))
    assert(r.bins.from <= 600 and r.bins.width > 0)
    assert(r.you.rank == 11 and r.you.time == 700, r.you.rank)
    assert(math_close(r.you.ahead_of, 29 / 39))
    // one run: a graph of bars all the same, the run in its middle
    local one = store.open(":memory:")
    store.add(one, run(1, A, 700))
    local lone = store.results(one, 1, A)
    assert(len(lone.bins.counts) == 12 and lone.bins.counts[5] + lone.bins.counts[6] == 1, lone.bins.from)
    // a day without runs
    local empty = store.results(s, 4, A)
    assert(empty.count == 0 and empty.you == null and len(empty.bins.counts) == 0)
  }

  t.test("names: set, shown with the fastest runs, removed"){
    local s = store.open(":memory:")
    store.add(s, run(1, A, 700, {name: "  Ann  "}))
    store.add(s, run(1, B, 650))
    assert(store.set_name(s, B, "Bo"))
    local top = store.results(s, 1, A).top
    assert(len(top) == 2 and top[0].name == "Bo" and top[1].name == "Ann" and top[1].you)
    assert(not store.set_name(s, A, "a name much too long for the list"))
    assert(not store.set_name(s, A, "tab\there"))
    assert(store.set_name(s, B, ""))
    assert(len(store.results(s, 1, A).top) == 1)
  }
}

t.group("daily: the API"){
  t.test("today, a run, the day's results, a name"){
    local s = store.open(":memory:")
    // (the 3rd day, at noon)
    local now = day.EPOCH + 2 * 86400000 + 43200000
    local client = web.test(app_lib.app({store: s, now: func(){ return now }}))
    async.main(func(){
      local res = async.await(client:get("/api/today"))
      local today = json.decode(res.body)
      assert(today.day == 3 and today.seed == day.seed(3) and today.date == "2026-11-17", res.body)

      res = async.await(client:post("/api/runs", {json: run(3, A, 640, {name: "Ann"})}))
      local posted = json.decode(res.body)
      assert(res.status == 200 and posted.ok and posted.results.count == 1, res.body)
      assert(posted.results.you.rank == 1 and posted.results.top[0].name == "Ann")

      // the second run of the day is not counted, but the results come
      res = async.await(client:post("/api/runs", {json: run(3, A, 600)}))
      posted = json.decode(res.body)
      assert(res.status == 200 and not posted.ok and posted.reason == "counted")
      assert(posted.results.you.time == 640)

      // yesterday's run is taken (it began before midnight), not older
      res = async.await(client:post("/api/runs", {json: run(2, B, 900)}))
      assert(res.status == 200, res.body)
      res = async.await(client:post("/api/runs", {json: run(1, B, 900)}))
      assert(res.status == 400, res.body)
      res = async.await(client:post("/api/runs", {json: run(3, B, 1)}))
      assert(res.status == 400 and json.decode(res.body).reason == "bad time")

      res = async.await(client:get(concat("/api/today?player=", A)))
      assert(json.decode(res.body).run.time == 640, res.body)
      res = async.await(client:get(concat("/api/days/3?player=", B)))
      assert(json.decode(res.body).count == 1 and json.decode(res.body).you == null)
      res = async.await(client:get("/api/days/4"))
      assert(res.status == 404)

      res = async.await(client:post("/api/name", {json: {player: A, name: "Anna 2"}}))
      assert(json.decode(res.body).ok)
      res = async.await(client:get("/api/days/3"))
      assert(json.decode(res.body).top[0].name == "Anna 2", res.body)
    })
  }
}
