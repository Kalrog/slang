// The engine: the database of clauses and the machine that proves goals.
//
// The machine is explicit (no recursion in slang for recursion in Prolog),
// so a Prolog recursion a million calls deep is a long list, not a deep
// slang stack, and answers come one at a time on demand. Its state:
//
//   goals    what is left to prove: a linked list of frames, the first
//            frame first. Frames are shared between the lists that
//            continue the same way, so saving "the rest" is free.
//   choices  a stack of choice points: places to come back to on failure,
//            each with the goals to go on with and the trail height when
//            it was made.
//   trail    every variable bound so far, in order. Failing back to a
//            choice point unbinds the variables bound since it was made.
//
// The loop: take the first frame and run it. A user predicate's call picks
// the first clause whose head unifies, pushes a choice point when other
// clauses could match too, and puts the clause's body in front of the
// remaining goals. When there are no goals left, that is an answer; asking
// for the next answer is failing on purpose. When a goal fails, the most
// recent choice point is taken back up.
//
// Cut: every goal frame carries a barrier, the height of the choice stack
// when the predicate call it belongs to started. `!` pops the choice
// points above it: the alternatives of the goals before it in the clause
// and the other clauses of the call. call/1 makes a new barrier, so a cut
// inside it only cuts inside it.
local ast = require("ast")
local terms = require("terms")
local compile = require("compile")

local M = {}

local deref = terms.deref

local func is_compound(t, name, arity) => type(t) == "Compound"
  and t.name == name and len(t.arguments) == arity

local TRUE = ast.atom("true")
local FAIL = ast.atom("fail")

// ------------------------------------------------------------------- database

local Database = {}
Database.__index = Database

// database(ops) -> an empty Database:
//   predicates: "name/arity" -> {name, arity, clauses, dynamic}
//   builtins: "name/arity" -> func(query, args) -> bool (see builtins.slang)
//   flags: unknown ("error" or "fail": what calling an unknown predicate
//     does), occurs_check ("false" or "true")
//   ops: the operator table, shared with the reader and the writer
//   output: func(text), where write/1 and friends send their text
//   globals: nb_setval/2's values
//   generation: counts changes to the clauses (the logical update view)
//   inferences: predicate calls so far, for statistics/2
func M.database(ops){
  local db = {
    predicates: {}, builtins: {}, ops: ops,
    flags: {unknown: "error", occurs_check: "false"},
    output: func(text){ print(text) },
    globals: {}, generation: 0, inferences: 0, next_clause_id: 0,
  }
  db.@meta = Database
  return db
}

// is_builtin(key) -> whether "name/arity" is built in: control constructs
// and built-ins can't be changed by assert/retract
func Database.is_builtin(self, key) => M.CONTROL[key] != null
  or self.builtins[key] != null

// predicate(key, name, arity) -> the predicate, made when it does not
// exist yet
func Database.predicate(self, key, name, arity){
  local p = self.predicates[key]
  if(p == null){
    p = {key: key, name: name, arity: arity, clauses: {}, dynamic: false}
    self.predicates[key] = p
  }
  return p
}

// add_clause(term, at_front?) stores a clause (assertz, or asserta with
// at_front). The clauses of a predicate are an array that a running call
// may still be walking: appending is safe (the call ignores clauses newer
// than itself, see generation), anything else makes a new array.
func Database.add_clause(self, term, at_front){
  local c = compile.clause(term)
  if(self:is_builtin(c.key)){
    terms.permission_error("modify", "static_procedure", terms.indicator(
      deref(c.head)))
  }
  local head = c.head
  local p = self:predicate(c.key, head.name, len(terms.arguments(head)))
  self.generation = self.generation + 1
  self.next_clause_id = self.next_clause_id + 1
  c.id = self.next_clause_id
  c.added = self.generation
  if(at_front){
    local clauses = {c}
    for(let local old in values(p.clauses)){
      append(clauses, old)
    }
    p.clauses = clauses
  } else {
    append(p.clauses, c)
  }
}

// erase(key, id) removes the clause id of the predicate key
func Database.erase(self, key, id){
  local p = self.predicates[key]
  if(p == null){
    return
  }
  local clauses = {}
  for(let local c in values(p.clauses)){
    if(c.id != id){
      append(clauses, c)
    }
  }
  p.clauses = clauses
  self.generation = self.generation + 1
}

// ---------------------------------------------------------------------- frames

// A goal frame: prove term; barrier is where a ! in it cuts back to
local func goal_frame(term, barrier, next) => {
  kind: "goal", term: term, barrier: barrier, next: next,
}

// A cut frame: pop the choice points above height (the end of the
// condition of an if-then-else: commit to its first solution)
local func cut_frame(height, next) => {kind: "cut", height: height, next: next}

// The end of catch/3's goal: from here on, its catcher no longer applies
local func exit_catch_frame(choice, next) => {
  kind: "exit_catch", choice: choice, next: next,
}

// ----------------------------------------------------------------------- query

local Query = {}
Query.__index = Query

// query(db, goal) -> a Query for goal; next() finds the answers one by one
func M.query(db, goal){
  local q = {
    db: db, goals: goal_frame(goal, 0, null), choices: {}, trail: {},
    started: false, finished: false,
    // the variables that existed before the query (see bind)
    var_mark: ast.newest_var_id(),
  }
  q.@meta = Query
  return q
}

// next() -> true when there is another answer (the bindings of its
// variables are in place until the next call), false when there are no
// more. An uncaught Prolog exception is raised as a slang error of kind
// "prolog" (its ball field holds the term).
func Query.next(self){
  if(self.finished){
    return false
  }
  if(self.started and not self:backtrack()){
    self.finished = true
    return false
  }
  self.started = true
  if(not self:run()){
    self.finished = true
    return false
  }
  return true
}

// has_choices() -> whether more answers may come (a choice point is left)
func Query.has_choices(self) => len(self.choices) > 0

// close() undoes every binding the query made: for queries run inside
// another (findall/3), whose bindings must not outlive them
func Query.close(self){
  self:undo_to(0)
  self.choices = {}
  self.finished = true
}

// the main loop: run goals until none are left (true) or nothing is left
// to try (false)
func Query.run(self){
  for(true){
    local frame = self.goals
    if(frame == null){
      return true
    }
    self.goals = frame.next
    local ok = false
    try {
      ok = self:step(frame)
    } catch(local e) {
      // halt/0 stops everything; Prolog errors (and slang errors, which
      // become system_error terms) go to the nearest catch/3
      if(error.is(e, "halt")){
        raise(e)
      }
      self:throw(M.ball_of(e))
      ok = true
    }
    if(not ok and not self:backtrack()){
      return false
    }
  }
}

// ball_of(e) -> the Prolog term a slang error stands for
func M.ball_of(e){
  if(error.is(e, "prolog")){
    return e.ball
  }
  return ast.compound("error", {
    ast.compound("system_error", {ast.atom(error.message(e))}), ast.var(),
  })
}

// step(frame) -> false when the frame's goal failed
func Query.step(self, frame){
  if(frame.kind == "cut"){
    self:cut_to(frame.height)
    return true
  }
  if(frame.kind == "exit_catch"){
    self:exit_catch(frame.choice)
    return true
  }
  local goal = terms.callable(frame.term)
  local key = terms.key(goal)
  local control = M.CONTROL[key]
  if(control != null){
    return control(self, goal, frame)
  }
  local builtin = self.db.builtins[key]
  if(builtin != null){
    return builtin(self, terms.arguments(goal))
  }
  return self:call_predicate(goal, key)
}

// ---------------------------------------------------------- calling clauses

// first_key(goal) -> the index key of a goal's first argument
local func first_key(goal){
  if(type(goal) != "Compound"){
    return null
  }
  return compile.index_key(goal.arguments[0])
}

// next_candidate(clauses, i, key, generation) -> the index of the first
// clause from i on that the call could use: one that existed when the
// call started (the logical update view: clauses added while a call runs
// are not seen by it) and whose first argument fits; -1 if there is none
local func next_candidate(clauses, i, key, generation){
  local n = len(clauses)
  for(i < n){
    local c = clauses[i]
    if(c.added <= generation and (key == null or c.first == null
      or c.first == key)){
      return i
    }
    i = i + 1
  }
  return -1
}

func Query.call_predicate(self, goal, key){
  self.db.inferences = self.db.inferences + 1
  local p = self.db.predicates[key]
  if(p == null){
    if(self.db.flags.unknown == "fail"){
      return false
    }
    terms.existence_error("procedure", terms.indicator(goal))
  }
  return self:try_clauses(goal, p.clauses, 0, self.db.generation, self.goals)
}

// try_clauses(...) -> whether a clause from index start on could be
// entered. When another one could match after it, a choice point
// remembers where to go on.
func Query.try_clauses(self, goal, clauses, start, generation, rest){
  local key = first_key(goal)
  local i = next_candidate(clauses, start, key, generation)
  if(i < 0){
    return false
  }
  // a ! in the clause's body cuts back to here: the clause's own choice
  // point (pushed next) and everything after it
  local barrier = len(self.choices)
  local j = next_candidate(clauses, i + 1, key, generation)
  if(j >= 0){
    self:push_choice({
      kind: "clauses", goal: goal, clauses: clauses, index: j,
      generation: generation, goals: rest,
    })
  }
  return self:enter_clause(goal, clauses[i], barrier, rest)
}

// enter_clause(...) -> whether the clause's head unifies with goal; when
// it does, its body goes in front of rest
func Query.enter_clause(self, goal, clause, barrier, rest){
  // frame holds this use's value of each slot of the clause
  local frame = {}
  local head_args = terms.arguments(clause.head)
  local goal_args = terms.arguments(goal)
  for(local i = 0; i < len(head_args); i = i + 1){
    if(not self:unify_head(head_args[i], goal_args[i], frame)){
      return false
    }
  }
  if(clause.is_fact){
    self.goals = rest
  } else {
    self.goals = goal_frame(
      compile.instantiate(clause.body, frame), barrier, rest,
    )
  }
  return true
}

// unify_head(pattern, term, frame) -> whether the head argument pattern
// (with slots) unifies with term. Unifying against the stored head
// directly, instead of copying it first, saves most of the copying: the
// first time a slot is met it simply becomes the goal's term.
func Query.unify_head(self, pattern, term, frame){
  local kind = type(pattern)
  if(kind == "Slot"){
    local seen = frame[pattern.index]
    if(seen == null){
      frame[pattern.index] = term
      return true
    }
    return self:unify(seen, term)
  }
  if(kind != "Compound"){
    return self:unify(pattern, term)
  }
  local t = deref(term)
  if(type(t) == "Var"){
    self:bind(t, compile.instantiate(pattern, frame))
    return true
  }
  if(type(t) != "Compound" or t.name != pattern.name
    or len(t.arguments) != len(pattern.arguments)){
    return false
  }
  for(local i = 0; i < len(pattern.arguments); i = i + 1){
    if(not self:unify_head(pattern.arguments[i], t.arguments[i], frame)){
      return false
    }
  }
  return true
}

// ----------------------------------------------------------------- unification

// bind(v, t) binds the unbound variable v to t. The binding goes on the
// trail only when something may have to undo it: when v is older than the
// newest choice point (backtracking there throws away the variables made
// after it, bound or not), or older than the query itself (close() undoes
// those). Without this rule a long deterministic loop would fill the trail
// with bindings nothing will ever undo.
func Query.bind(self, v, t){
  v.ref = t
  local n = len(self.choices)
  local mark = self.var_mark
  if(n > 0){
    mark = self.choices[n - 1].var_mark
  }
  if(v.id <= mark){
    append(self.trail, v)
  }
}

// undo_to(mark) unbinds everything bound since the trail was mark long.
// An entry is a variable to unbind, or {undo} for other undoable changes.
func Query.undo_to(self, mark){
  local trail = self.trail
  for(len(trail) > mark){
    local entry = remove(trail, len(trail) - 1)
    if(type(entry) == "Var"){
      entry.ref = null
    } else {
      entry.undo()
    }
  }
}

// occurs(v, t) -> whether the variable v occurs in t
local func occurs(v, t){
  for(let local x in values(terms.vars_of(t))){
    if(same(x, v)){
      return true
    }
  }
  return false
}

// unify(a, b, occurs_check?) -> whether a and b could be made equal; the
// bindings that made them so are on the trail. On failure some bindings
// may have been made: the caller fails back to a choice point, which
// undoes them (or undoes them itself, as \= does).
func Query.unify(self, a, b, occurs_check){
  occurs_check = occurs_check or self.db.flags.occurs_check == "true"
  // pairs still to unify, as a stack: x0, y0, x1, y1, ...
  local stack = {a, b}
  for(len(stack) > 0){
    local y = deref(remove(stack, len(stack) - 1))
    local x = deref(remove(stack, len(stack) - 1))
    if(same(x, y)){
      continue
    }
    if(type(x) == "Var" and type(y) == "Var"){
      // the newer variable points at the older one, so that answers show
      // the query's own variables rather than clause-internal ones
      if(x.id < y.id){
        self:bind(y, x)
      } else {
        self:bind(x, y)
      }
    } else if(type(x) == "Var"){
      if(occurs_check and occurs(x, y)){
        return false
      }
      self:bind(x, y)
    } else if(type(y) == "Var"){
      if(occurs_check and occurs(y, x)){
        return false
      }
      self:bind(y, x)
    } else if(type(x) != type(y)){
      // 1 = 1.0 fails too: an Integer is never a Float
      return false
    } else if(type(x) == "Compound"){
      if(x.name != y.name or len(x.arguments) != len(y.arguments)){
        return false
      }
      for(local i = len(x.arguments) - 1; i >= 0; i = i - 1){
        append(stack, x.arguments[i])
        append(stack, y.arguments[i])
      }
    } else if(type(x) == "Atom"){
      if(x.name != y.name){
        return false
      }
    } else if(x.value != y.value){
      return false
    }
  }
  return true
}

// ------------------------------------------------------------- backtracking

// push_choice(cp) records a place to come back to: with the trail
// height and the newest variable at this point
func Query.push_choice(self, cp){
  cp.trail_mark = len(self.trail)
  cp.var_mark = ast.newest_var_id()
  append(self.choices, cp)
}

// cut_to(height) pops the choice points above height
func Query.cut_to(self, height){
  for(len(self.choices) > height){
    remove(self.choices, len(self.choices) - 1)
  }
}

// backtrack() -> false when no choice point is left; else the state is
// the one of the most recent choice point, going on with its alternative
func Query.backtrack(self){
  for(len(self.choices) > 0){
    local cp = remove(self.choices, len(self.choices) - 1)
    self:undo_to(cp.trail_mark)
    if(cp.kind == "alternative"){
      self.goals = cp.goals
      return true
    }
    if(cp.kind == "clauses"){
      if(self:try_clauses(cp.goal, cp.clauses, cp.index, cp.generation,
        cp.goals)){
        return true
      }
    }
    // a "catch" choice point has no alternative: backtracking just leaves
    // the catch/3 it belongs to
  }
  return false
}

// push_goal(term) puts term in front of the goals, as call/1 would (a cut
// in it is local): how built-ins continue with more Prolog
func Query.push_goal(self, term){
  self.goals = goal_frame(term, len(self.choices), self.goals)
}

// push_alternatives(goals) -> false when there are none; else proves the
// first of goals now and the others on backtracking: how built-ins with
// several answers (between/3 style) give them
func Query.push_alternatives(self, goals){
  local n = len(goals)
  if(n == 0){
    return false
  }
  local t = goals[n - 1]
  for(local i = n - 2; i >= 0; i = i - 1){
    t = ast.compound(";", {goals[i], t})
  }
  self:push_goal(t)
  return true
}

// solutions(goal, each) runs goal as a query of its own and calls each()
// for every answer, while its bindings are in place, until each() returns
// false. All its bindings are undone afterwards. (findall/3, forall/2)
func Query.solutions(self, goal, each){
  local sub = M.query(self.db, goal)
  try {
    for(sub:next()){
      if(each() == false){
        break
      }
    }
  } catch(local e) {
    sub:close()
    raise(e)
  }
  sub:close()
}

// --------------------------------------------------------------- exceptions

// throw(ball) unwinds to the most recent catch/3 whose catcher unifies
// with ball and goes on with its recovery goal; with none, the query ends
// and ball is raised to whoever asked for its answers
func Query.throw(self, ball){
  // the ball is copied first: undoing bindings must not change it
  ball = terms.copy(ball)
  for(len(self.choices) > 0){
    local cp = remove(self.choices, len(self.choices) - 1)
    self:undo_to(cp.trail_mark)
    if(cp.kind == "catch" and cp.active){
      local mark = len(self.trail)
      if(self:unify(cp.catcher, ball)){
        self.goals = goal_frame(cp.recovery, cp.barrier, cp.goals)
        return
      }
      self:undo_to(mark)
    }
  }
  self.goals = null
  self.finished = true
  terms.throw(ball)
}

// exit_catch(cp): the goal of a catch/3 succeeded. When it left no choice
// points, the catch is over and its choice point goes. Otherwise it stays
// (backtracking into the goal needs it) but stops catching until then.
func Query.exit_catch(self, cp){
  local n = len(self.choices)
  if(n > 0 and same(self.choices[n - 1], cp)){
    remove(self.choices, n - 1)
    return
  }
  cp.active = false
  append(self.trail, {undo: func(){ cp.active = true }})
}

// ------------------------------------------------------------------ portray

// portray_hook(db) -> the program's portray/1 as a writer option (see
// writer.format), or null when the program has none. portray(T) is run as
// a query of its own with its output collected: when it succeeds, what it
// wrote is how T is shown. Its bindings are undone, and an error in it
// counts as failing.
func M.portray_hook(db){
  local p = db.predicates["portray/1"]
  if(p == null or len(p.clauses) == 0){
    return null
  }
  return func(t){
    local written = {}
    local saved = db.output
    db.output = func(text){ append(written, text) }
    local q = M.query(db, ast.compound("portray", {t}))
    local ok = false
    try {
      ok = q:next()
    } catch(local e) {
      if(error.is(e, "halt")){
        db.output = saved
        raise(e)
      }
    }
    q:close()
    db.output = saved
    if(not ok){
      return null
    }
    local text = ""
    for(let local w in values(written)){
      text = concat(text, w)
    }
    return text
  }
}

// --------------------------------------------------------------- control

// The control constructs: they need the frame (its cut barrier), so the
// engine runs them itself. "name/arity" -> func(query, goal, frame) -> bool
M.CONTROL = {}
local CONTROL = M.CONTROL

CONTROL["true/0"] = func(q, goal, frame) => true
CONTROL["fail/0"] = func(q, goal, frame) => false
CONTROL["false/0"] = func(q, goal, frame) => false

// A, B: prove A, then B; both cut like the clause they are in
CONTROL[",/2"] = func(q, goal, frame){
  local args = goal.arguments
  q.goals = goal_frame(args[0], frame.barrier,
    goal_frame(args[1], frame.barrier, q.goals))
  return true
}

CONTROL["!/0"] = func(q, goal, frame){
  q:cut_to(frame.barrier)
  return true
}

// (C -> T ; E): a choice point for E, then C (whose cut is its own), then
// a cut frame that drops E and C's other solutions, then T
local func if_then_else(q, c, t, e, frame){
  local height = len(q.choices)
  q:push_choice({kind: "alternative", goals: goal_frame(e, frame.barrier, q.goals)})
  q.goals = goal_frame(c, height + 1,
    cut_frame(height, goal_frame(t, frame.barrier, q.goals)))
  return true
}

// A ; B: a choice point for B, then A. A cut inside either cuts the
// clause they are in.
CONTROL[";/2"] = func(q, goal, frame){
  local left = deref(goal.arguments[0])
  local right = goal.arguments[1]
  if(is_compound(left, "->", 2)){
    return if_then_else(q, left.arguments[0], left.arguments[1], right, frame)
  }
  q:push_choice({
    kind: "alternative", goals: goal_frame(right, frame.barrier, q.goals),
  })
  q.goals = goal_frame(left, frame.barrier, q.goals)
  return true
}

CONTROL["->/2"] = func(q, goal, frame) => if_then_else(
  q, goal.arguments[0], goal.arguments[1], FAIL, frame,
)

// \+ G: true when G has no solution; it is (G -> fail ; true)
CONTROL["\\+/1"] = func(q, goal, frame) => if_then_else(
  q, goal.arguments[0], FAIL, TRUE, frame,
)

// call(G, A1, ...): G with the extra arguments added; a cut inside only
// cuts inside the call
local func call_n(q, goal, frame){
  local args = goal.arguments
  local g = terms.callable(args[0])
  local extra = {}
  for(local i = 1; i < len(args); i = i + 1){
    append(extra, args[i])
  }
  if(len(extra) > 0){
    g = compile.add_args(g, extra)
  }
  q:push_goal(g)
  return true
}
for(local n = 1; n <= 8; n = n + 1){
  CONTROL[concat("call/", n)] = call_n
}

// catch(G, Catcher, Recovery): a choice point marks where a throw/1 from
// inside G comes back to
CONTROL["catch/3"] = func(q, goal, frame){
  local args = goal.arguments
  local cp = {
    kind: "catch", catcher: args[1], recovery: args[2], goals: q.goals,
    barrier: frame.barrier, active: true,
  }
  q:push_choice(cp)
  q.goals = goal_frame(args[0], len(q.choices), exit_catch_frame(cp, q.goals))
  return true
}

CONTROL["throw/1"] = func(q, goal, frame){
  local ball = deref(goal.arguments[0])
  if(type(ball) == "Var"){
    terms.instantiation_error()
  }
  terms.throw(ball)
}

return M
