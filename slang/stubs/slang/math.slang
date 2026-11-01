// slang/math: numeric functions and constants, built into the VM.
//
//   local math = require("slang/math")
//   math.sqrt(2)                // 1.4142135623730951
//   math.floor(2.7)             // 2.0, a double
//   to_int(math.floor(2.7))     // 2
//   math.max(3, 7, 5)           // 7, still an int
//
// Unless noted the functions take an int or a double and return a double;
// use to_int for an int. Angles are in radians.
local m = {}

// The constant pi, 3.14159...
m.pi = 3.141592653589793

// The constant e, 2.71828...
m.e = 2.718281828459045
// Positive infinity, a double.
m.inf = 1 / 0.0
// A NaN, a double; use [is_nan] to test for one (NaN == NaN is false).
m.nan = 0 / 0.0
// The largest int, 2^63 - 1.
m.max_int = 9223372036854775807
// The smallest int, -2^63.
m.min_int = -9223372036854775807 - 1

// ------------------------------------------------------------ rounding

// round(x: int | float) -> float
// x rounded to the nearest whole number, halves away from zero.
func m.round(x){}

// floor(x: int | float) -> float
// The largest whole number not above x.
func m.floor(x){}

// ceil(x: int | float) -> float
// The smallest whole number not below x.
func m.ceil(x){}

// abs(x: int | float) -> int | float
// The absolute value of x; an int for an int.
func m.abs(x){}

// min(...xs: int | float) -> int | float
// The smallest of the numbers, as given (an int stays an int); the double
// infinity without arguments. Raises an error for a non-number.
func m.min(...xs){}

// max(...xs: int | float) -> int | float
// The largest of the numbers, as given (an int stays an int); the double
// minus infinity without arguments. Raises an error for a non-number.
func m.max(...xs){}

// trunc(x: int | float) -> float
// x without its fraction, toward zero.
func m.trunc(x){}

// sign(x: int | float) -> int | float
// -1, 0 or 1 as x is negative, zero or positive; an int for an int.
func m.sign(x){}

// clamp(x: int | float, lo: int | float, hi: int | float) -> int | float
// x limited to lo..hi; an int when all three are ints.
func m.clamp(x, lo, hi){}

// lerp(a: int | float, b: int | float, t: int | float) -> float
// The value t of the way from a to b: a + (b - a) * t.
func m.lerp(a, b, t){}

// is_nan(x) -> bool
// Whether x is a NaN.
func m.is_nan(x){}

// is_inf(x) -> bool
// Whether x is an infinity (either sign).
func m.is_inf(x){}

// ------------------------------------------------------------ random

// random(lo?: int | float, hi?: int | float) -> float
// A random double from lo (0 by default) up to hi (1 by default).
func m.random(lo, hi){}

// random_int(lo: int, hi: int) -> int
// A random int from lo up to and including hi.
func m.random_int(lo, hi){}

// seed(n: int)
// Starts the random numbers over from n, so a program repeats the same
// ones; without it they differ every run.
func m.seed(n){}

// ------------------------------------------------------------ functions

// sqrt(x: int | float) -> float
// The square root of x.
func m.sqrt(x){}

// exp(x: int | float) -> float
// e to the power x.
func m.exp(x){}

// log(x: int | float, base?: int | float) -> float
// The natural logarithm of x, or the logarithm in base.
func m.log(x, base){}

// log2(x: int | float) -> float
// The base-2 logarithm of x.
func m.log2(x){}

// log10(x: int | float) -> float
// The base-10 logarithm of x.
func m.log10(x){}

// hypot(x: int | float, y: int | float) -> float
// sqrt(x*x + y*y), without overflow on the way.
func m.hypot(x, y){}

// sin(x: int | float) -> float
// The sine of x radians.
func m.sin(x){}

// cos(x: int | float) -> float
// The cosine of x radians.
func m.cos(x){}

// tan(x: int | float) -> float
// The tangent of x radians.
func m.tan(x){}

// asin(x: int | float) -> float
// The arc sine of x, in radians.
func m.asin(x){}

// acos(x: int | float) -> float
// The arc cosine of x, in radians.
func m.acos(x){}

// atan(x: int | float) -> float
// The arc tangent of x, in radians.
func m.atan(x){}

// atan2(y: int | float, x: int | float) -> float
// The angle of the point (x, y) from the x axis, in radians.
func m.atan2(y, x){}

// sinh(x: int | float) -> float
// The hyperbolic sine of x.
func m.sinh(x){}

// cosh(x: int | float) -> float
// The hyperbolic cosine of x.
func m.cosh(x){}

// tanh(x: int | float) -> float
// The hyperbolic tangent of x.
func m.tanh(x){}

return m
