// slang/time: UTC calendar fields, HTTP dates, ISO 8601
local t = require("slang/test")
local time = require("slang/time")

// 1994-11-06 08:49:37 UTC, the example date of RFC 9110
local example = 784111777

t.group("time"){
  t.test("now is seconds since the epoch"){
    local now = time.now()
    assert(type(now) == "double")
    assert(now > 1767225600, "after 2026-01-01")
    assert(time.utc(now).year >= 2026)
  }
  t.test("utc breaks a moment into fields"){
    local u = time.utc(example)
    assert(u.year == 1994 and u.month == 11 and u.day == 6)
    assert(u.hour == 8 and u.minute == 49 and u.second == 37 and u.ms == 0)
    assert(u.weekday == 0, "a Sunday")
    assert(u.yday == 310)
    local e = time.utc(0)
    assert(e.year == 1970 and e.month == 1 and e.day == 1 and e.weekday == 4 and e.yday == 1)
    local before = time.utc(-1)
    assert(before.year == 1969 and before.month == 12 and before.day == 31 and before.second == 59)
    assert(time.utc(1.25).ms == 250)
    assert(time.utc(951782400).month == 2 and time.utc(951782400).day == 29, "2000 is a leap year")
  }
  t.test("from_utc is the inverse of utc"){
    assert(time.from_utc({year: 1994, month: 11, day: 6, hour: 8, minute: 49, second: 37}) == example)
    assert(time.from_utc({year: 1970}) == 0, "fields default to the start")
    assert(time.from_utc({year: 1970, ms: 500}) == 0.5)
    for(local s = -5000000000; s < 5000000000; s = s + 123456789){
      local u = time.utc(s)
      assert(time.from_utc(u) == s, concat("round trip of ", string(s)))
    }
  }
  t.test("from_utc normalizes out-of-range fields"){
    assert(time.iso(time.from_utc({year: 2026, month: 13, day: 1})) == "2027-01-01T00:00:00Z")
    assert(time.iso(time.from_utc({year: 2026, month: 1, day: 0})) == "2025-12-31T00:00:00Z")
    assert(time.iso(time.from_utc({year: 2026, month: 2, day: 28 + 30})) == "2026-03-30T00:00:00Z")
    assert(time.iso(time.from_utc({year: 2026, month: 0})) == "2025-12-01T00:00:00Z")
    assert(time.iso(time.from_utc({year: 2026, month: 1, day: 1, hour: -1})) == "2025-12-31T23:00:00Z")
    local r = pcall(time.from_utc, {month: 1})
    assert(r[0] == "err" and r[1].message == "from_utc: year is required")
  }
  t.test("http_date formats RFC 1123"){
    assert(time.http_date(example) == "Sun, 06 Nov 1994 08:49:37 GMT")
    assert(time.http_date(example + 0.9) == "Sun, 06 Nov 1994 08:49:37 GMT", "whole seconds")
    assert(time.http_date(0) == "Thu, 01 Jan 1970 00:00:00 GMT")
  }
  t.test("parse_http_date reads the three forms of RFC 9110"){
    assert(time.parse_http_date("Sun, 06 Nov 1994 08:49:37 GMT") == example)
    assert(time.parse_http_date("Sunday, 06-Nov-94 08:49:37 GMT") == example)
    assert(time.parse_http_date("Sun Nov  6 08:49:37 1994") == example)
    assert(time.parse_http_date(time.http_date(1793275200)) == 1793275200)
    local bad = {"", "Sun, 06 Nov 1994 08:49:37", "Sun, 06 Nov 1994 08:49:37 UTC",
                 "Sun, 31 Nov 1994 08:49:37 GMT", "Sun, 06 Nox 1994 08:49:37 GMT",
                 "Sun, 06 Nov 1994 24:00:00 GMT", "Sun, 6 Nov 1994 08:49:37 GMT", "1994-11-06"}
    for(let local s in values(bad)){
      assert(time.parse_http_date(s) == null, s)
    }
  }
  t.test("iso formats RFC 3339 in UTC"){
    assert(time.iso(example) == "1994-11-06T08:49:37Z")
    assert(time.iso(example + 0.25) == "1994-11-06T08:49:37.250Z")
    assert(time.iso(-0.5) == "1969-12-31T23:59:59.500Z")
    local r = pcall(time.iso, 99999999999999)
    assert(r[0] == "err")
  }
  t.test("parse_iso reads RFC 3339 and the common ISO 8601 forms"){
    assert(time.parse_iso("1994-11-06T08:49:37Z") == example)
    assert(time.parse_iso("1994-11-06t08:49:37z") == example)
    assert(time.parse_iso("1994-11-06 08:49:37") == example, "SQLite's datetime()")
    assert(time.parse_iso("1994-11-06T09:49:37+01:00") == example)
    assert(time.parse_iso("1994-11-06T03:19:37-0530") == example)
    assert(time.parse_iso("1994-11-06T10:49:37+02") == example)
    assert(time.parse_iso("1994-11-06T08:49Z") == example - 37)
    assert(time.parse_iso("1994-11-06") == example - 31777)
    assert(time.parse_iso("1994-11-06T08:49:37.5Z") == example + 0.5)
    assert(time.parse_iso("1994-11-06T08:49:37,25Z") == example + 0.25)
    assert(time.parse_iso(time.iso(1793275200.125)) == 1793275200.125)
    assert(type(time.parse_iso("1994-11-06")) == "int", "an int without a fraction")
    local bad = {"", "1994-11", "1994-13-01", "1994-02-29", "1994-11-06T", "1994-11-06T25:00",
                 "1994-11-06T08:49:37.Z", "1994-11-06T08:49:37+1", "1994-11-06T08:49:37 Z",
                 "94-11-06", "1994-11-06T08:49:37Zjunk"}
    for(let local s in values(bad)){
      assert(time.parse_iso(s) == null, s)
    }
  }
}
