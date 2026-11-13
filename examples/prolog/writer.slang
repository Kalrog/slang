// Terms back to text: write/1, writeq/1, print/1, write_canonical/1 and the
// answers of the toplevel.
//
// Writing with operators is the reader run backwards. An operator term of
// priority P written where at most max is allowed gets parentheses when
// P > max, and its operands are written at the priorities its type allows
// (the same x/y rule as reading). Spaces go only where the text would
// otherwise read back differently: around alphanumeric operators (X is Y),
// between two symbol characters (1- -1), and after a prefix operator that
// is followed by a number or a "(" (- 1 is not -1, - (a,b) is not -(a,b)).
local ast = require("ast")
local terms = require("terms")
local str = require("slang/string")

local M = {}

local deref = terms.deref

local func is_letter(b) => b != null and ((b >= 'a' and b <= 'z')
  or (b >= 'A' and b <= 'Z'))

local func first_byte(text) => str.byte_at(text, 0)

local func last_byte(text) => str.byte_at(text, len(text) - 1)

// format(t, options?) -> string. Options:
//   quoted: atoms and strings in quotes where needed (writeq, print)
//   ignore_ops: functional notation for everything (write_canonical)
//   ops: the operator table (Operators; without it nothing is an operator)
//   var_names: {[id]: name} for variables to print by name
//   spaced: ", " between arguments and list elements (the toplevel)
//   budget: how many subterms to print at most before "..." (cyclic terms
//     made without the occurs check would print forever)
//   portray: func(t) -> text or null, asked first for every subterm that
//     is not a variable: a text replaces the term (print/1 and the
//     toplevel pass the program's portray/1 hook here)
//   priority: the highest priority the whole term may have without
//     parentheses (1200; the toplevel writes values as the right side of
//     X = ..., which is 699)
func M.format(t, options){
  options = options or {}
  local ops = options.ops
  local quoted = options.quoted == true
  local comma = ","
  if(options.spaced){
    comma = ", "
  }
  local budget = options.budget or 1000000
  local var_names = options.var_names or {}

  local func atom_text(name){
    if(quoted){
      return ast.atom_text(name)
    }
    return name
  }

  local func op_def(class, name){
    if(ops == null or options.ignore_ops){
      return null
    }
    return ops[class][name]
  }

  local func is_operator(name) => ops != null and not options.ignore_ops
    and ops:priority(name) > 0

  // w(t, max, operand) writes t where a term of priority <= max fits;
  // operand says t is the operand of an operator (where an operator atom
  // needs parentheses)
  local w = null

  local func write_args(args){
    local parts = {}
    for(let local a in values(args)){
      append(parts, w(a, 999, false))
    }
    return str.join(parts, comma)
  }

  local func write_list(t){
    local parts = {}
    for(terms.is_list_cell(t) and budget > 0){
      append(parts, w(t.arguments[0], 999, false))
      t = deref(t.arguments[1])
    }
    local out = concat("[", str.join(parts, comma))
    if(budget <= 0){
      return concat(out, "|...]")
    }
    if(not terms.is_nil(t)){
      out = concat(out, "|", w(t, 999, false))
    }
    return concat(out, "]")
  }

  // the text of an operator term, or null when t is not one
  local func write_operator(t, max){
    local args = t.arguments
    local n = len(args)
    local name = t.name
    local text = null
    local priority = 0
    if(n == 2 and op_def("infix", name) != null){
      local def = op_def("infix", name)
      priority = def.priority
      local left_max = priority - 1
      local right_max = priority - 1
      if(def.type == "yfx"){
        left_max = priority
      } else if(def.type == "xfy"){
        right_max = priority
      }
      local left = w(args[0], left_max, true)
      local right = w(args[1], right_max, true)
      local op = atom_text(name)
      if(name == ","){
        op = comma
      } else if(is_letter(first_byte(op))){
        op = concat(" ", op, " ")
      } else {
        // keep symbol characters of the operator and the operands apart
        if(ast.is_symbol_char(last_byte(left))){
          op = concat(" ", op)
        }
        if(ast.is_symbol_char(first_byte(right))){
          op = concat(op, " ")
        }
      }
      text = concat(left, op, right)
    } else if(n == 1 and op_def("prefix", name) != null){
      local def = op_def("prefix", name)
      priority = def.priority
      local operand_max = priority
      if(def.type == "fx"){
        operand_max = priority - 1
      }
      local operand = w(args[0], operand_max, true)
      local op = atom_text(name)
      local b = first_byte(operand)
      local operand_type = type(deref(args[0]))
      if(is_letter(last_byte(op)) or b == '(' or ast.is_symbol_char(b)
        or operand_type == "Integer" or operand_type == "Float"){
        op = concat(op, " ")
      }
      text = concat(op, operand)
    } else if(n == 1 and op_def("postfix", name) != null){
      local def = op_def("postfix", name)
      priority = def.priority
      local operand_max = priority - 1
      if(def.type == "yf"){
        operand_max = priority
      }
      local operand = w(args[0], operand_max, true)
      local op = atom_text(name)
      if(is_letter(first_byte(op)) or ast.is_symbol_char(last_byte(operand))){
        op = concat(" ", op)
      }
      text = concat(operand, op)
    } else {
      return null
    }
    if(priority > max){
      return concat("(", text, ")")
    }
    return text
  }

  w = func(t, max, operand){
    budget = budget - 1
    if(budget < 0){
      return "..."
    }
    t = deref(t)
    local kind = type(t)
    if(kind == "Var"){
      return var_names[t.id] or concat("_G", t.id)
    }
    if(options.portray != null){
      local shown = options.portray(t)
      if(shown != null){
        return shown
      }
    }
    if(kind == "Integer" or kind == "Float"){
      return concat("", t.value)
    }
    if(kind == "String"){
      if(quoted){
        return ast.quote(t.value, "\"")
      }
      return t.value
    }
    if(kind == "Atom"){
      local text = atom_text(t.name)
      if(operand and is_operator(t.name)){
        return concat("(", text, ")")
      }
      return text
    }
    if(kind == "Slot"){
      return concat("_S", t.index)
    }
    // a compound
    if(terms.is_list_cell(t)){
      return write_list(t)
    }
    if(t.name == "{}" and len(t.arguments) == 1 and not options.ignore_ops){
      return concat("{", w(t.arguments[0], 1200, false), "}")
    }
    local text = write_operator(t, max)
    if(text != null){
      return text
    }
    return concat(atom_text(t.name), "(", write_args(t.arguments), ")")
  }

  return w(t, options.priority or 1200, false)
}

// --------------------------------------------------------------------- tests

group("writer"){
  local grammar = require("grammar")

  // read text, then write it back with options
  local func roundtrip(text, options){
    local r = grammar.read_program(concat(text, " ."))
    assert(r[0] == "ok", concat("cannot read ", text, ": ", r[1]))
    local ops = grammar.operators()
    local t = terms.from_source(r[1][0], terms.new_names())
    local o = options or {}
    o.ops = ops
    o.var_names = {}
    for(let local v in values(terms.vars_of(t))){
      o.var_names[v.id] = v.name
    }
    return M.format(t, o)
  }
  local func same(text, options){
    local got = roundtrip(text, options)
    assert(got == text, concat(text, " was written as ", got))
  }
  local func check(text, expected, options){
    local got = roundtrip(text, options)
    assert(got == expected, concat(text, " was written as ", got, ", not ",
      expected))
  }

  test("operators"){
    same("1+2*3")
    same("(1+2)*3")
    same("1-2-3")
    same("1-(2-3)")
    same("a:-b,c;d")
    same("X is Y+1")
    same("a mod b")
    same("\\+a")
    same("- 1")
    same("-1")
    same("1- -1")
    check("- (-1)", "- -1")
    same("-a")
    same("- -a")
    same("\\+ (a,b)")
    same("f((a,b))")
    same("f((a:-b))")
    same("[a,b|T]")
    same("{a,b}")
    same("(a=b)=c")
    same("2^3^4")
    same("(2^3)^4")
    check("X = (-)", "X=(-)")
    check("f(-)", "f(-)")
    check("[-]", "[-]")
  }
  test("quoting"){
    same("'hello world'", {quoted: true})
    check("'hello world'", "hello world")
    same("[]", {quoted: true})
    same("'don\\'t'", {quoted: true})
    same("\"text\"", {quoted: true})
    check("\"text\"", "text")
  }
  test("canonical and spaced"){
    check("1+2*3", "+(1,*(2,3))", {ignore_ops: true})
    check("[1,2]", "[1,2]", {ignore_ops: true})
    check("[1,2,3]", "[1, 2, 3]", {spaced: true})
    check("(a,b)", "a, b", {spaced: true})
  }
}

return M
