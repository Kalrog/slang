// slang/time: wall-clock time as seconds since the Unix epoch, in UTC,
// built into the VM. Months and days count from 1, weekday from 0 (Sunday),
// yday from 1. There are no local time zones. Functions taking a time raise
// an error when it is out of range (beyond the year 9999).
local m = {}

// now() -> the current time in seconds, a double with millisecond precision
func m.now(){}

// ------------------------------------------------------------ calendar

// utc(t) -> the UTC fields of time t: {year, month, day, hour, minute,
// second, ms, weekday, yday}, all ints
func m.utc(t){}

// from_utc(fields) -> the time of {year, month, day, hour, minute, second,
// ms}: an int, or a double when there is a fraction of a second. year is
// required; month and day default to 1, the rest to 0. Fields normalize,
// so {year: 2026, month: 13, day: 1} is January 2027 and adding 30 to day
// moves 30 days on.
func m.from_utc(fields){}

// ------------------------------------------------------------ formats

// http_date(t) -> t as an HTTP date, "Sun, 06 Nov 1994 08:49:37 GMT"
func m.http_date(t){}

// parse_http_date(s) -> the time of an HTTP date as an int, or null. Accepts
// the three forms RFC 9110 requires (RFC 1123, RFC 850 and asctime).
func m.parse_http_date(s){}

// iso(t) -> t as ISO 8601, "1994-11-06T08:49:37Z", with ".123" before the Z
// when t has milliseconds
func m.iso(t){}

// parse_iso(s) -> the time of an ISO 8601 date, an int or a double when it
// has a fraction, or null. Accepts RFC 3339 and the common forms: a date
// alone, "T" or a space before the time, seconds and fraction optional, and
// "Z", "+hh:mm", "+hhmm", "+hh" or nothing (UTC) for the zone.
func m.parse_iso(s){}

return m
