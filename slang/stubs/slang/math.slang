// slang/math: numeric functions, built into the VM. Unless noted they take
// an int or a double and return a double.
local m = {}

// pi: the constant 3.14159...
m.pi = 3.141592653589793

// e: the constant 2.71828...
m.e = 2.718281828459045

// ------------------------------------------------------------ rounding

// round(x) -> x rounded to the nearest whole number, halves away from zero
func m.round(x){}

// floor(x) -> the largest whole number not above x
func m.floor(x){}

// ceil(x) -> the smallest whole number not below x
func m.ceil(x){}

// abs(x) -> the absolute value of x, an int for an int
func m.abs(x){}

// min(...xs) -> the smallest of the numbers, as given (an int stays an int);
// the double infinity without arguments. Raises an error for a non-number.
func m.min(...xs){}

// max(...xs) -> the largest of the numbers, as given (an int stays an int);
// the double minus infinity without arguments. Raises an error for a
// non-number.
func m.max(...xs){}

// random([lo], [hi]) -> a random double from lo (0 by default) up to hi (1
// by default)
func m.random(lo, hi){}

// ------------------------------------------------------------ functions

// sqrt(x) -> the square root of x
func m.sqrt(x){}

// exp(x) -> e to the power x
func m.exp(x){}

// log(x) -> the natural logarithm of x
func m.log(x){}

// sin(x) -> the sine of x radians
func m.sin(x){}

// cos(x) -> the cosine of x radians
func m.cos(x){}

// tan(x) -> the tangent of x radians
func m.tan(x){}

// asin(x) -> the arc sine of x, in radians
func m.asin(x){}

// acos(x) -> the arc cosine of x, in radians
func m.acos(x){}

// atan(x) -> the arc tangent of x, in radians
func m.atan(x){}

// atan2(y, x) -> the angle of the point (x, y) from the x axis, in radians
func m.atan2(y, x){}

return m
