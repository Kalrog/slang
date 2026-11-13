// Arithmetic: what `X is Expr` and the comparisons =:=, <, ... evaluate.
//
// Expressions are ordinary terms (1 + 2 is the compound +(1, 2)) that are
// only evaluated when asked to. Evaluating needs every variable bound: an
// unbound one is an instantiation error, not a failure, because there is
// no way to solve `X is Y + 1` for Y by evaluating.
//
// Values are slang ints and doubles. Integers are 64 bits: an operation
// whose result does not fit is an evaluation error rather than silently
// wrapping around (there are no big integers here).
local ast = require("ast")
local terms = require("terms")
local math = require("slang/math")

local M = {}

local deref = terms.deref

local func is_int(v) => type(v) == "int"

// the largest magnitude an int holds, as a double
local LIMIT = 9223372036854775807.0

local func check_int(v){
  if(is_int(v)){
    return v
  }
  terms.type_error("integer", ast.float(v))
}

// a result of an integer operation, computed both exactly (wrapping) and
// as a double: when the double is out of range, the exact one wrapped
local func int_result(exact, approx){
  if(approx >= LIMIT or approx < -LIMIT){
    terms.evaluation_error("int_overflow")
  }
  return exact
}

local func add(a, b){
  if(is_int(a) and is_int(b)){
    return int_result(a + b, to_float(a) + to_float(b))
  }
  return a + b
}

local func sub(a, b){
  if(is_int(a) and is_int(b)){
    return int_result(a - b, to_float(a) - to_float(b))
  }
  return a - b
}

local func mul(a, b){
  if(is_int(a) and is_int(b)){
    return int_result(a * b, to_float(a) * to_float(b))
  }
  return a * b
}

local func nonzero(b){
  if(b == 0){
    terms.evaluation_error("zero_divisor")
  }
}

local func iabs(x){
  if(x < 0){
    return -x
  }
  return x
}

// int_div(a, b) -> a / b rounded toward zero, exactly. slang's / divides
// as doubles, which are exact only up to 2^53, so the quotient it gives is
// an estimate that is corrected until the remainder is right.
local func int_div(a, b){
  nonzero(b)
  local q = to_int(a / b)
  for(true){
    local r = a - q * b
    local same_signs = (a < 0) == (b < 0)
    if(r != 0 and (r < 0) != (a < 0)){
      // went one too far
      if(same_signs){
        q = q - 1
      } else {
        q = q + 1
      }
    } else if(iabs(r) >= iabs(b)){
      // not far enough
      if(same_signs){
        q = q + 1
      } else {
        q = q - 1
      }
    } else {
      return q
    }
  }
}

// rem: the remainder of //, with the sign of a
local func rem(a, b) => a - int_div(a, b) * b

// mod: the remainder of floored division, with the sign of b
local func mod(a, b){
  local r = rem(a, b)
  if(r != 0 and (r < 0) != (b < 0)){
    return r + b
  }
  return r
}

// floored division (div/2)
local func floor_div(a, b) => int_div(sub(a, mod(a, b)), b)

// a / b: an integer when both are integers and it divides exactly (as
// SWI-Prolog does), else a float
local func divide(a, b){
  nonzero(b)
  if(is_int(a) and is_int(b) and rem(a, b) == 0){
    return int_div(a, b)
  }
  return to_float(a) / to_float(b)
}

// integer power by repeated squaring, checking every step for overflow
local func int_pow(base, exp){
  if(exp < 0){
    if(base == 1){
      return 1
    }
    if(base == -1){
      if(rem(exp, 2) == 0){
        return 1
      }
      return -1
    }
    nonzero(base)
    terms.type_error("float", ast.integer(base))
  }
  local result = 1
  for(exp > 0){
    if(rem(exp, 2) == 1){
      result = mul(result, base)
    }
    exp = int_div(exp, 2)
    if(exp > 0){
      base = mul(base, base)
    }
  }
  return result
}

local func power(a, b){
  if(is_int(a) and is_int(b)){
    return int_pow(a, b)
  }
  return to_float(a) ^ to_float(b)
}

local func gcd(a, b){
  a = math.abs(check_int(a))
  b = math.abs(check_int(b))
  for(b != 0){
    local t = rem(a, b)
    a = b
    b = t
  }
  return a
}

local func to_integer(x){
  if(is_int(x)){
    return x
  }
  if(x != x or x == math.inf or x == -math.inf or x >= LIMIT or x < -LIMIT){
    terms.evaluation_error("undefined")
  }
  return to_int(x)
}

local func sign_of(x){
  if(x > 0){
    return 1
  }
  if(x < 0){
    return -1
  }
  return 0
}

// the evaluable functors: "name/arity" -> func(values...) -> value
local FUNCTIONS = {
  ["+/2"]: add,
  ["-/2"]: sub,
  ["*/2"]: mul,
  ["//2"]: divide,
  ["///2"]: func(a, b) => int_div(check_int(a), check_int(b)),
  ["mod/2"]: func(a, b){
    nonzero(check_int(b))
    return mod(check_int(a), b)
  },
  ["rem/2"]: func(a, b){
    nonzero(check_int(b))
    return rem(check_int(a), b)
  },
  ["div/2"]: func(a, b){
    nonzero(check_int(b))
    return floor_div(check_int(a), b)
  },
  ["-/1"]: func(a) => sub(0, a),
  ["+/1"]: func(a) => a,
  ["abs/1"]: func(a){
    if(a < 0){
      return sub(0, a)
    }
    return a
  },
  ["sign/1"]: func(a){
    if(is_int(a)){
      return sign_of(a)
    }
    return to_float(sign_of(a))
  },
  ["min/2"]: func(a, b){
    if(b < a){
      return b
    }
    return a
  },
  ["max/2"]: func(a, b){
    if(b > a){
      return b
    }
    return a
  },
  ["**/2"]: power,
  ["^/2"]: func(a, b){
    if(is_int(a) and is_int(b)){
      return int_pow(a, b)
    }
    return to_float(a) ^ to_float(b)
  },
  ["sqrt/1"]: func(a){
    if(a < 0){
      terms.evaluation_error("undefined")
    }
    return math.sqrt(to_float(a))
  },
  ["sin/1"]: func(a) => math.sin(to_float(a)),
  ["cos/1"]: func(a) => math.cos(to_float(a)),
  ["tan/1"]: func(a) => math.tan(to_float(a)),
  ["asin/1"]: func(a) => math.asin(to_float(a)),
  ["acos/1"]: func(a) => math.acos(to_float(a)),
  ["atan/1"]: func(a) => math.atan(to_float(a)),
  ["atan/2"]: func(a, b) => math.atan2(to_float(a), to_float(b)),
  ["atan2/2"]: func(a, b) => math.atan2(to_float(a), to_float(b)),
  ["exp/1"]: func(a) => math.exp(to_float(a)),
  ["log/1"]: func(a){
    if(a <= 0){
      terms.evaluation_error("undefined")
    }
    return math.log(to_float(a))
  },
  ["log/2"]: func(base, a) => math.log(to_float(a)) / math.log(to_float(base)),
  ["log2/1"]: func(a) => math.log2(to_float(a)),
  ["float/1"]: func(a) => to_float(a),
  ["integer/1"]: func(a){
    if(is_int(a)){
      return a
    }
    return to_integer(math.round(a))
  },
  ["float_integer_part/1"]: func(a) => to_float(math.trunc(to_float(a))),
  ["float_fractional_part/1"]: func(a) => to_float(a) - math.trunc(to_float(a)),
  ["truncate/1"]: func(a) => to_integer(math.trunc(to_float(a))),
  ["round/1"]: func(a) => to_integer(math.round(to_float(a))),
  ["ceiling/1"]: func(a) => to_integer(math.ceil(to_float(a))),
  ["floor/1"]: func(a) => to_integer(math.floor(to_float(a))),
  [">>/2"]: func(a, b) => check_int(a) >> check_int(b),
  ["<</2"]: func(a, b) => check_int(a) << check_int(b),
  ["/\\/2"]: func(a, b) => check_int(a) & check_int(b),
  ["\\//2"]: func(a, b) => check_int(a) | check_int(b),
  ["xor/2"]: func(a, b) => check_int(a) ~ check_int(b),
  ["\\/1"]: func(a) => ~check_int(a),
  ["gcd/2"]: gcd,
  ["msb/1"]: func(a){
    a = check_int(a)
    local n = -1
    for(a > 0){
      a = a >> 1
      n = n + 1
    }
    return n
  },
  ["random/1"]: func(a) => math.random_int(0, check_int(a) - 1),
  ["random_float/0"]: func() => math.random(),
  ["pi/0"]: func() => math.pi,
  ["e/0"]: func() => math.e,
  ["inf/0"]: func() => math.inf,
  ["infinite/0"]: func() => math.inf,
  ["nan/0"]: func() => math.nan,
  ["epsilon/0"]: func() => 2.220446049250313e-16,
  ["max_tagged_integer/0"]: func() => math.max_int,
}

// eval(t) -> the value of the arithmetic expression t (a slang int or
// double)
func M.eval(t){
  t = deref(t)
  local kind = type(t)
  if(kind == "Integer" or kind == "Float"){
    return t.value
  }
  if(kind == "Var"){
    terms.instantiation_error()
  }
  if(kind == "String" and len(t.value) == 1){
    // "a" evaluates to its character code
    return require("slang/utf8").code_at(t.value, 0)
  }
  // [X] evaluates as X ("a" in code-list form)
  if(terms.is_list_cell(t) and terms.is_nil(deref(t.arguments[1]))){
    return M.eval(t.arguments[0])
  }
  if(not terms.is_callable(t)){
    terms.type_error("evaluable", t)
  }
  local f = FUNCTIONS[terms.key(t)]
  if(f == null){
    terms.type_error("evaluable", terms.indicator(t))
  }
  local args = {}
  for(let local a in values(terms.arguments(t))){
    append(args, M.eval(a))
  }
  local n = len(args)
  if(n == 0){
    return f()
  }
  if(n == 1){
    return f(args[0])
  }
  return f(args[0], args[1])
}

// compare(a, b) -> -1, 0 or 1: the values of two expressions compared
// (=:=, <, ... are this)
func M.compare(a, b){
  local x = M.eval(a)
  local y = M.eval(b)
  if(x < y){
    return -1
  }
  if(x > y){
    return 1
  }
  return 0
}

return M
