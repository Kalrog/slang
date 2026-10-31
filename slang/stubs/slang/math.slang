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

// random(lo?: int | float, hi?: int | float) -> float
// A random double from lo (0 by default) up to hi (1 by default).
func m.random(lo, hi){}

// ------------------------------------------------------------ functions

// sqrt(x: int | float) -> float
// The square root of x.
func m.sqrt(x){}

// exp(x: int | float) -> float
// e to the power x.
func m.exp(x){}

// log(x: int | float) -> float
// The natural logarithm of x.
func m.log(x){}

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

return m
