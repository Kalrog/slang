extension "extensions/lambda_shorthand"

local double = |x| 2 * x
local thrice = func(x) => 3 * x

print(double(4), " ", thrice(4), "\n")
