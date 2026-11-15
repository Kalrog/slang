// server/day: which day of the daily run it is, and its valley. Day 1
// is 15 November 2026; a day starts at midnight UTC, so that everyone
// drives the same valley at the same time.
//
//   local day = require("server/day")
//   local today = day.today()          // {day: 3, date: "2026-11-17", seed: 48213}
local time = require("slang/time")
local str = require("slang/string")
local math = require("slang/math")

local m = {}

m.EPOCH = time.from_utc({year: 2026, month: 11, day: 15})
local DAY = 86400000

// number(ms?: float) -> int: the day at that time (now by default)
func m.number(ms){
  ms = ms or time.now()
  return to_int(math.floor((ms - m.EPOCH) / DAY)) + 1
}

// seed(day: int) -> int: the day's valley, 1 to 99999, the days' seeds
// scattered (one day's valley says nothing of the next's)
func m.seed(day){
  // (each product stays well inside 64 bits)
  local x = (day * 2654435761 + 40503) % 4294967296
  x = x ~ (x >> 15)
  x = (x * 69069 + 1013904223) % 4294967296
  x = x ~ (x >> 13)
  return x % 99999 + 1
}

// date(day: int) -> string: its date, "2026-11-17"
func m.date(day){
  local t = time.utc(m.EPOCH + (day - 1) * DAY)
  return str.format("%04d-%02d-%02d", t.year, t.month, t.day)
}

// info(day: int) -> {day, date, seed}
func m.info(day){
  return {day: day, date: m.date(day), seed: m.seed(day)}
}

// today() -> {day, date, seed}
func m.today(){
  return m.info(m.number())
}

return m
