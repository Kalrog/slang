// The notation of patterns: a string of steps, as in Limut.
//
//   x-o-        four steps: a kick, a hat, a snare, a hat (a drum player)
//   0123        four steps of scale degrees (a tonal player)
//   0.2.        a dot is a rest
//   0_2_        an underscore holds the step before for one more step
//   -1 0#  3b   a minus before a digit: below the root; # and b: sharp, flat
//   0= 0! 0^ 0v longer by half, shorter by a third, louder by half, quieter by a third
//   0g 1g       other letters after a digit are flags the piece reads (e.g. glide)
//   0[12]3      a subsequence fits its steps into one step
//   0(357)      a chord plays its steps together
//   0<12>       a supersequence takes its next step each time the pattern repeats
//   ${expr}     a slang value in a backtick literal: a number, a name, a pattern
//
// Whitespace and double quotes mean nothing, so steps can be grouped by
// eye. `parse(text)` gives the tree of steps; `parser(expr)` is the peg
// parser the grammar extension (notation.slang) embeds, with expr the
// parser of a slang expression for splices (null: no splices).
local peg = require("slang/peg")
local str = require("slang/string")

local mini = {}

// the step kinds: note (a degree), hit (a letter), rest, hold, sub,
// chord, super, splice
mini.kinds = {"note", "hit", "rest", "hold", "sub", "chord", "super", "splice"}

local ignored = peg.pattern(" \t\r\n\"")
local func lex(p){
  return peg.seq(ignored:star(), p):pick(1)
}

// the modifiers after a step
local func apply_mod(step, m){
  if(m == "#"){
    step.acc = (step.acc or 0) + 1
  } else if(m == "b"){
    step.acc = (step.acc or 0) - 1
  } else if(m == "="){
    step.dur = (step.dur or 1.0) * 1.5
  } else if(m == "!"){
    step.dur = (step.dur or 1.0) * (2.0 / 3.0)
  } else if(m == "^"){
    step.vel = (step.vel or 1.0) * 1.5
  } else if(m == "v"){
    step.vel = (step.vel or 1.0) * (2.0 / 3.0)
  } else {
    step.flags = concat(step.flags or "", m)
  }
  return step
}

// parser(expr?: peg.Parser) -> peg.Parser: the steps of a pattern, a list
// of step tables; with expr, `${ }` splices hold the expression's value
func mini.parser(expr){
  local items = peg.settable()
  local digit = peg.pattern("0-9"):token("number")
  local sign = peg.char("-"):token("number")
  local note_mods = peg.choice(
    peg.pattern("#b=!^v"):token("operator"),
    peg.pattern("a-uw-z"):token("type"),
  )
  local hit_mods = peg.pattern("=!^v"):token("operator")
  local note = peg.seq(sign:optional(), digit, note_mods:star()):map(func(v){
    local d = str.to_number(v[1].value)
    if(v[0] != null){
      d = -d
    }
    local step = {t: "note", v: d}
    for(let local m in values(v[2])){
      apply_mod(step, m.value)
    }
    return step
  })
  local hit = peg.seq(
    peg.pattern("a-zA-Z*+~/\\|@&%?,;:'-"):token("string"),
    hit_mods:star(),
  ):map(func(v){
    local step = {t: "hit", v: v[0].value}
    for(let local m in values(v[1])){
      apply_mod(step, m.value)
    }
    return step
  })
  local rest = peg.char("."):token("comment"):map(func(v){ return {t: "rest"} })
  local hold = peg.char("_"):token("comment"):map(func(v){ return {t: "hold"} })
  local func group(open, close, kind){
    return peg.seq(
      peg.char(open):token(
        "punctuation",
      ),
      items,
      lex(peg.char(close, concat("\"", close, "\" expected"))):token(
        "punctuation",
      ),
    ):map(func(v){
      return {t: kind, items: v[1]}
    })
  }
  local alternatives = {
    group("[", "]", "sub"),
    group("(", ")", "chord"),
    group("<", ">", "super"),
    note,
    hit,
    rest,
    hold,
  }
  if(expr != null){
    append(alternatives, peg.seq(
      peg.string("${"):token(
        "punctuation",
      ),
      expr,
      peg.char("}", "\"}\" expected to close the ${ splice"):token(
        "punctuation",
      ),
    ):map(func(v){
      return {t: "splice", v: v[1]}
    }))
  }
  local step = lex(peg.choice_list(alternatives))
  items:set(step:star())
  return peg.seq(items, ignored:star()):pick(0)
}

local plain = null

// parse(text: string) -> {step}: the steps of text; raises a syntax error
func mini.parse(text){
  if(plain == null){
    plain = peg.seq(
      mini.parser(null),
      peg.end_of_input("a step expected"),
    ):pick(0)
  }
  local r = peg.parse(plain, text)
  if(r[0] == "ok"){
    return r[1]
  }
  raise(error.new(error.kinds.syntax, concat("pattern `", text, "`: ", r[1])))
}

return mini
