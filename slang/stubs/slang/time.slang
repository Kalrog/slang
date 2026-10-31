// slang/time: wall-clock time as seconds since the Unix epoch, in UTC,
// built into the VM.
//
//   local time = require("slang/time")
//   local t = time.now()
//   time.iso(t)                          // "2026-10-31T17:30:52.123Z"
//   time.utc(t).year                     // 2026
//   time.from_utc({year: 2026, month: 1, day: 1})   // 1767225600
//   time.parse_http_date("Sun, 06 Nov 1994 08:49:37 GMT")   // 784111777
//
// A time is a number of seconds: an int, or a double with a fraction of a
// second. There are no local time zones. Functions taking a time raise an
// error when it is out of range (beyond the year 9999).

// The calendar fields of a time, in UTC. Months and days count from 1.
// type Fields = {year: int, month: int, day: int, hour: int, minute: int,
//   second: int, ms: int, weekday: int, yday: int}
// [ms]: milliseconds, 0 to 999
// [weekday]: 0 (Sunday) to 6
// [yday]: the day of the year, from 1
local m = {}

// now() -> float
// The current time in seconds, with millisecond precision.
func m.now(){}

// ------------------------------------------------------------ calendar

// utc(t: int | float) -> Fields
// The UTC calendar fields of time t.
func m.utc(t){}

// from_utc(fields: Fields) -> int | float
// The time of the fields year, month, day, hour, minute, second and ms (an
// int, or a double when there is a fraction of a second); weekday and
// yday are ignored. year is required; month and day default to 1, the
// rest to 0. Fields normalize, so {year: 2026, month: 13, day: 1} is
// January 2027 and adding 30 to day moves 30 days on.
func m.from_utc(fields){}

// ------------------------------------------------------------ formats

// http_date(t: int | float) -> string
// t as an HTTP date, "Sun, 06 Nov 1994 08:49:37 GMT".
func m.http_date(t){}

// parse_http_date(s: string) -> int?
// The time of an HTTP date, or null. Accepts the three forms RFC 9110
// requires (RFC 1123, RFC 850 and asctime).
func m.parse_http_date(s){}

// iso(t: int | float) -> string
// t as ISO 8601, "1994-11-06T08:49:37Z", with ".123" before the Z when t
// has milliseconds.
func m.iso(t){}

// parse_iso(s: string) -> int | float | null
// The time of an ISO 8601 date (a double when it has a fraction), or null.
// Accepts RFC 3339 and the common forms: a date alone, "T" or a space
// before the time, seconds and fraction optional, and "Z", "+hh:mm",
// "+hhmm", "+hh" or nothing (UTC) for the zone.
func m.parse_iso(s){}

return m
