// the grammar compiled by pegc against the interpreted combinators:
//   bin/slang run examples/futamura/peg_bench.slang [generated.slang] [inline limit] [nocache]
// parses the compiler's sources both ways, checks the ASTs are the same
// and times them
local compiler = require("slang/compiler")
local peg = require("slang/peg")
local ast = require("slang/ast")
local os = require("slang/os")
local time = require("slang/time")
local pegc = require("pegc")

local func say(...parts){ print(...parts, "\n") }

local g = compiler.grammar()
// the grammar itself stays on the combinators here: they are the baseline
g.state.opts.pegc = "off"
g:parse_source("local x = 1", "warm")
local t0 = time.clock()
local c = pegc.compile(g, {inline: to_int(args()[1] or "30"), far_cache: args()[2] != "nocache"})
say("generated ", c.functions, " functions, ", len(c.statics), " statics, ", len(c.source), " bytes of source in ", to_int(time.clock() - t0), " ms")
// with a path as argument, the generated source is written there
if(args()[0] != null and args()[0] != ""){ os.write_file(args()[0], c.source) }
t0 = time.clock()
local parsers = c:load()
say("compiled the generated source in ", to_int(time.clock() - t0), " ms")

local str = require("slang/string")
local statement = g.sealed.statement
local final = g.sealed.final_statement

// the top-level loop of a unit: statement after statement (a final
// statement last), optional semicolons between them
local func parse_all(source, stmt, last){
  local ctx = peg.context(source)
  local statements = {}
  local pos = peg.space_end(source, 0)
  for(pos < len(source)){
    ctx.rule_memo = {}
    local q = stmt(ctx, pos)
    if(q < 0){ q = last(ctx, pos) }
    if(q < 0){ error("parse failed at ", pos, ": ", ctx.far_msg, " at ", ctx.far_pos) }
    append(statements, ctx.value)
    pos = peg.space_end(source, q)
    if(str.byte_at(source, pos) == ';'){ pos = peg.space_end(source, pos + 1) }
  }
  return statements
}
local func interpreted(ctx, pos){ return statement:parse_on(ctx, pos) }
local func interpreted_final(ctx, pos){ return final:parse_on(ctx, pos) }
local gen_statement = parsers.rules.statement
local gen_final = parsers.rules.final_statement

// the lossless tree, as a string: the parser kinds and spans, the rule
// names and owners, so that two trees compare
local func dump(t, out){
  local p = t.p
  append(out, concat(p.kind or "?", p.rule_name and concat(":", p.rule_name) or "", t.owner and concat("@", t.owner) or "", " ", t.start, "-", t.stop, t.at != null and concat(" at", t.at) or "", t.raw and " raw" or "", t.woven and " woven" or ""))
  if(t.kids != null){
    append(out, "(")
    for(let local k in values(t.kids)){ dump(k, out) }
    append(out, ")")
  }
  return out
}
local func parse_tree_all(source, parse){
  local ctx = peg.context(source, {tree: true})
  local trees = {}
  local pos = peg.space_end(source, 0)
  for(pos < len(source)){
    ctx.rule_memo = {}
    local q = parse(ctx, pos)
    if(q < 0){ error("tree parse failed at ", pos, ": ", ctx.far_msg, " at ", ctx.far_pos) }
    append(trees, {tree: ctx.tree, value: ctx.value})
    pos = peg.space_end(source, q)
    if(str.byte_at(source, pos) == ';'){ pos = peg.space_end(source, pos + 1) }
  }
  return trees
}
local func tree_text(trees){
  local out = {}
  for(let local e in values(trees)){ dump(e.tree, out) append(out, "\n") }
  return str.join(out, "")
}
local func interpreted_tree(ctx, pos){
  local q = peg.parse_tree(statement, ctx, pos)
  if(q < 0){ q = peg.parse_tree(final, ctx, pos) }
  return q
}
local func generated_tree(ctx, pos){
  local q = parsers.trees.statement(ctx, pos)
  if(q < 0){ q = parsers.trees.final_statement(ctx, pos) }
  return q
}

local files = {"slang/compiler/codegen.slang", "slang/compiler/grammar.slang", "slang/compiler/peg.slang", "slang/compiler/compiler.slang"}
local total = {0, 0, 0, 0}
for(let local f in values(files)){
  local src = os.read_file(f)
  local a = parse_all(src, interpreted, interpreted_final)
  local b = parse_all(src, gen_statement, gen_final)
  local same = ast.to_source(ast.node("Block", {statements: a})) == ast.to_source(ast.node("Block", {statements: b}))
  // the best of five runs each, since the machine is never quiet
  local func best(f){
    local ms = null
    for(local i = 0; i < 5; i = i + 1){
      local t = time.clock()
      f()
      local d = time.clock() - t
      if(ms == null or d < ms){ ms = d }
    }
    return ms
  }
  local ms1 = best(func(){ parse_all(src, interpreted, interpreted_final) })
  local ms2 = best(func(){ parse_all(src, gen_statement, gen_final) })
  total[0] = total[0] + ms1
  total[1] = total[1] + ms2
  say(f, ": ", len(src), " bytes: interpreted ", to_int(ms1), " ms, generated ", to_int(ms2), " ms, same AST: ", same)
  // the tree parse (the language server's)
  local ta = parse_tree_all(src, interpreted_tree)
  local tb = parse_tree_all(src, generated_tree)
  local same_tree = tree_text(ta) == tree_text(tb)
  local tms1 = best(func(){ parse_tree_all(src, interpreted_tree) })
  local tms2 = best(func(){ parse_tree_all(src, generated_tree) })
  total[2] = total[2] + tms1
  total[3] = total[3] + tms2
  say("    with the tree: interpreted ", to_int(tms1), " ms, generated ", to_int(tms2), " ms, same tree: ", same_tree)
}
say("total: interpreted ", to_int(total[0]), " ms, generated ", to_int(total[1]), " ms, speedup ", to_int(total[0] / total[1] * 100) / 100)
say("total with the tree: interpreted ", to_int(total[2]), " ms, generated ", to_int(total[3]), " ms, speedup ", to_int(total[2] / total[3] * 100) / 100)
