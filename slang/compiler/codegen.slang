// slang/codegen: compiles AST nodes into function prototypes. A prototype is a
// table that slang/vm's load_proto turns into a function:
//   {code, locations, constants, upvalues, children, max_stack, nargs, is_vararg}
local ast = require("slang/ast")
local str = require("slang/string")

local codegen = {}

// opcodes (must match the VM)
local OP_LOAD_CONSTANT = 0
local OP_LOAD_BOOL = 1
local OP_LOAD_CLOSURE = 2
local OP_ADD = 3
local OP_SUB = 4
local OP_MUL = 5
local OP_DIV = 6
local OP_MOD = 7
local OP_NEG = 8
local OP_NOT = 9
local OP_EQ = 10
local OP_LT = 11
local OP_LEQ = 12
local OP_MOVE = 13
local OP_PUSH = 14
local OP_POP = 15
local OP_RETURN = 16
local OP_NEW_TABLE = 17
local OP_SET_TABLE = 18
local OP_GET_TABLE = 19
local OP_SET_UPVALUE = 20
local OP_GET_UPVALUE = 21
local OP_CLOSE_UPVALUES = 22
local OP_TEST = 23
local OP_JUMP = 24
local OP_CALL = 25
local OP_TYPE = 26
local OP_POW = 27
local OP_BAND = 28
local OP_BOR = 29
local OP_BXOR = 30
local OP_SHL = 31
local OP_SHR = 32
local OP_BNOT = 33
local OP_CALL_SPREAD = 34
local OP_TRY_BEGIN = 35
local OP_TRY_END = 36
local OP_THROW = 37

// instruction layout: |b:9|c:9|a:8|op:6|, bx = 18 bits, sbx = bx - 0x1FFFF, ax = 26 bits
local SBX_OFFSET = 131071

local func enc_abc(op, a, b, c){
  return b << 23 | c << 14 | a << 6 | op
}

local func enc_abx(op, a, bx){
  return bx << 14 | a << 6 | op
}

local func enc_asbx(op, a, sbx){
  return (sbx + SBX_OFFSET) << 14 | a << 6 | op
}

local func enc_ax(op, ax){
  return ax << 6 | op
}

local binops = {}
binops["+"] = OP_ADD
binops["-"] = OP_SUB
binops["*"] = OP_MUL
binops["/"] = OP_DIV
binops["%"] = OP_MOD
binops["<"] = OP_LT
binops["<="] = OP_LEQ
binops["=="] = OP_EQ
binops["^"] = OP_POW
binops["&"] = OP_BAND
binops["|"] = OP_BOR
binops["~"] = OP_BXOR
binops["<<"] = OP_SHL
binops[">>"] = OP_SHR

// ------------------------------------------------------------ function assembler

local asm = {}
local asm_meta = {__index: asm}

func asm.new(parent, origin, nargs, is_vararg){
  local a = {
    parent: parent,
    // the function's name, when its definition gives it one (see name_of)
    name: null,
    origin: origin or parent.origin,
    instructions: {},
    locations: {},
    patterns: {},
    constants: {},
    constant_index: {},
    locals: {},
    upvalues: {},
    upvalue_list: {},
    children: {},
    scopes: {},
    nargs: nargs or 0,
    is_vararg: is_vararg == true,
    used_registers: 0,
    max_registers: 0,
    scope: 0,
  }
  a.meta = asm_meta
  return a
}

func asm.get_local(self, name){
  return self.locals[name]
}

func asm.create_local(self, name){
  local register = self:allocate_register()
  local lv = {
    register: register, name: name, scope: self.scope,
    previous: self.locals[name], captured: false,
  }
  self.locals[name] = lv
  return lv
}

func asm.get_upvalue(self, name){
  local known = self.upvalues[name]
  if(known != null){
    return known
  }
  if(self.parent != null){
    local lv = self.parent:get_local(name)
    if(lv != null){
      lv.captured = true
      local def = {
        name: name,
        index: len(self.upvalue_list),
        local_register: lv.register,
        upvalue_index: - 1,
        lv: lv,
      }
      self.upvalues[name] = def
      append(self.upvalue_list, def)
      return def
    }
    local up = self.parent:get_upvalue(name)
    if(up != null){
      local def = {
        name: name,
        index: len(self.upvalue_list),
        local_register: - 1,
        upvalue_index: up.index,
        lv: up.lv,
      }
      self.upvalues[name] = def
      append(self.upvalue_list, def)
      return def
    }
  }
  return null
}

func asm.free_local(self, lv){
  if(lv.previous != null){
    self.locals[lv.name] = lv.previous
  } else {
    self.locals[lv.name] = null
    self:free_register()
  }
}

func asm.enter_scope(self, breakable){
  self.scope = self.scope + 1
  append(self.scopes, {
    breakable: breakable == true, break_jumps: {}, continue_jumps: {},
    label: null, break_target: null,
  })
}

func asm.leave_scope(self){
  local to_free = {}
  for(let local name in keys(self.locals)){
    local lv = self.locals[name]
    if(lv.scope == self.scope){
      append(to_free, lv)
    }
  }
  for(let local lv in values(to_free)){
    self:free_local(lv)
  }
  local leaving = remove(self.scopes, len(self.scopes) - 1)
  // a loop may say where a break lands (a for-in: on the pop of its iterator)
  for(let local jump in values(leaving.break_jumps)){
    self:patch_jump(jump, leaving.break_target)
  }
  self.scope = self.scope - 1
}

// emits closeUpvalues for the lowest captured local of the scopes deeper
// than depth: a break or continue leaves them without their block's end
func asm.close_upvalues_below(self, depth){
  local min_slot = self.max_registers
  local any_captured = false
  for(let local name in keys(self.locals)){
    local current = self.locals[name]
    for(current != null and current.scope > depth){
      if(current.captured and current.register < min_slot){
        any_captured = true
        min_slot = current.register
      }
      current = current.previous
    }
  }
  if(any_captured){
    self:emit_close_upvalues(min_slot)
  }
}

// emits closeUpvalues for the lowest captured local of the current scope
func asm.close_open_upvalues(self){
  local min_slot = self.max_registers
  local any_captured = false
  for(let local name in keys(self.locals)){
    local current = self.locals[name]
    for(current != null and current.scope == self.scope){
      if(current.captured){
        any_captured = true
        if(current.register < min_slot){
          min_slot = current.register
        }
      }
      current = current.previous
    }
  }
  if(any_captured){
    self:emit_close_upvalues(min_slot)
  }
}

func asm.allocate_register(self){
  local register = self.used_registers
  self.used_registers = self.used_registers + 1
  if(self.used_registers > 255){
    error("Too many registers")
  }
  if(self.used_registers > self.max_registers){
    self.max_registers = self.used_registers
  }
  return register
}

func asm.free_register(self){
  if(self.used_registers == 0){
    error("No registers to free")
  }
  self.used_registers = self.used_registers - 1
  return self.used_registers
}

func asm.index_of_constant(self, value){
  local key
  local kind
  local t = type(value)
  if(value == null){
    key = "n"
    kind = "null"
  } else if(t == "string"){
    key = concat("s:", value)
    kind = "string"
  } else if(t == "int"){
    key = concat("i:", value)
    kind = "int"
  } else if(t == "double"){
    key = concat("d:", value)
    kind = "double"
  } else if(t == "bool"){
    key = concat("b:", value)
    kind = "bool"
  } else {
    error("Invalid constant: ", value)
  }
  local index = self.constant_index[key]
  if(index != null){
    return index
  }
  index = len(self.constants)
  self.constant_index[key] = index
  local entry = {kind}
  list_push(entry, value)
  append(self.constants, entry)
  return index
}

func asm.set_location(self, token){
  if(token == null){
    return null
  }
  local n = len(self.instructions)
  local last = self.locations[len(self.locations) - 1]
  if(last != null and last[0] == n){
    return null
  }
  append(self.locations, {n, self.origin, token.line, token.column})
}

func asm.emit(self, instruction){
  append(self.instructions, instruction)
}

func asm.emit_abc(self, op, a, b, c){
  self:emit(enc_abc(op, a or 0, b or 0, c or 0))
}

func asm.emit_abx(self, op, a, bx){
  self:emit(enc_abx(op, a or 0, bx or 0))
}

func asm.emit_asbx(self, op, a, sbx){
  self:emit(enc_asbx(op, a or 0, sbx or 0))
}

func asm.emit_ax(self, op, ax){
  self:emit(enc_ax(op, ax or 0))
}

func asm.emit_load_constant(self, value){
  self:emit_abx(OP_LOAD_CONSTANT, 0, self:index_of_constant(value))
}

func asm.emit_binop(self, op){
  local code = binops[op]
  if(code == null){
    error("Unknown operator: \"", op, "\"")
  }
  self:emit(code)
}

func asm.emit_unop(self, op){
  if(op == "-"){
    self:emit(OP_NEG)
  } else if(op == "not"){
    self:emit(OP_NOT)
  } else if(op == "~"){
    self:emit(OP_BNOT)
  } else {
    error("Unknown operator: ", op)
  }
}

func asm.emit_return(self){
  self:emit(OP_RETURN)
}

func asm.emit_move(self, from){
  self:emit_asbx(OP_MOVE, 0, from)
}

func asm.emit_push(self, index){
  self:emit_asbx(OP_PUSH, 0, index)
}

func asm.emit_new_table(self, n_list, n_hash){
  self:emit_abc(OP_NEW_TABLE, 0, n_list, n_hash)
}

func asm.emit_set_table(self){
  self:emit(OP_SET_TABLE)
}

func asm.emit_get_table(self){
  self:emit(OP_GET_TABLE)
}

func asm.emit_load_bool(self, value, jump){
  local b = 0
  if(value){
    b = 1
  }
  local c = 0
  if(jump){
    c = 1
  }
  self:emit_abc(OP_LOAD_BOOL, 0, b, c)
}

func asm.emit_test(self, c){
  local v = 0
  if(c){
    v = 1
  }
  self:emit_abc(OP_TEST, 0, 0, v)
}

func asm.emit_jump(self, target){
  local sbx = 0
  if(target != null){
    sbx = target - len(self.instructions) - 1
  }
  self:emit_asbx(OP_JUMP, 0, sbx)
  return len(self.instructions) - 1
}

func asm.patch_jump(self, jump, target){
  if(target == null){
    target = len(self.instructions)
  }
  local opcode = self.instructions[jump] & 63
  self.instructions[jump] = enc_asbx(opcode, 0, target - jump - 1)
}

// try_begin(first) -> a handle for patch_try: an error raised before the
// matching try_end goes to the patched address, with upvalues of registers
// from `first` up closed
func asm.emit_try_begin(self, first){
  self:emit_asbx(OP_TRY_BEGIN, first, 0)
  return {index: len(self.instructions) - 1, first: first}
}

func asm.patch_try(self, handle){
  self.instructions[handle.index] = enc_asbx(
    OP_TRY_BEGIN, handle.first, len(self.instructions) - handle.index - 1
  )
}

func asm.emit_try_end(self){
  self:emit_abc(OP_TRY_END, 0, 0, 0)
}

func asm.emit_throw(self){
  self:emit_abc(OP_THROW, 0, 0, 0)
}

func asm.emit_break(self){
  local target = null
  for(local i = len(self.scopes) - 1; i >= 0; i = i - 1){
    if(self.scopes[i].breakable){
      target = self.scopes[i]
      break
    }
  }
  if(target == null){
    error("Cannot break outside of a loop")
  }
  append(target.break_jumps, self:emit_jump())
}

func asm.emit_pop(self, keep, n){
  self:emit_abx(OP_POP, keep or 0, n or 1)
}

func asm.next_instruction_index(self){
  return len(self.instructions)
}

func asm.emit_set_upvalue(self, index){
  self:emit_ax(OP_SET_UPVALUE, index)
}

func asm.emit_get_upvalue(self, index){
  self:emit_ax(OP_GET_UPVALUE, index)
}

func asm.emit_close_upvalues(self, min_slot){
  self:emit_ax(OP_CLOSE_UPVALUES, min_slot)
}

func asm.emit_load_closure(self, index){
  self:emit_ax(OP_LOAD_CLOSURE, index)
}

func asm.emit_call(self, nargs){
  self:emit_abx(OP_CALL, 0, nargs)
}

// call_spread(fixed): the arguments are `fixed` values followed by one list
// whose elements become the remaining arguments
func asm.emit_call_spread(self, fixed){
  self:emit_abx(OP_CALL_SPREAD, 0, fixed)
}

func asm.emit_type(self){
  self:emit(OP_TYPE)
}

func asm.start_pattern(self){
  local p = pattern_new(self)
  append(self.patterns, p)
  return p
}

func asm.current_pattern(self){
  return self.patterns[len(self.patterns) - 1]
}

func asm.end_pattern(self){
  remove(self.patterns, len(self.patterns) - 1)
}

func asm.assemble(self){
  local children = {}
  for(let local c in values(self.children)){
    append(children, c:assemble())
  }
  local upvalues = {}
  for(let local u in values(self.upvalue_list)){
    local index = u.upvalue_index
    if(u.local_register >= 0){
      index = u.local_register
    }
    append(upvalues, {u.name, index, u.local_register >= 0})
  }
  return {
    code: self.instructions,
    locations: self.locations,
    constants: self.constants,
    upvalues: upvalues,
    children: children,
    max_stack: self.max_registers,
    nargs: self.nargs,
    is_vararg: self.is_vararg,
    name: self.name,
  }
}

// ------------------------------------------------------------ pattern assembler

local pat = {}
local pat_meta = {__index: pat}

func pattern_new(parent){
  local p = {
    step: "check", missmatch_jumps: {}, stack_increase: 0, parent: parent,
  }
  p.meta = pat_meta
  return p
}

func pat.complete_check_step(self){
  if(self.step != "check"){
    error("Cannot complete check step after completing the assign step")
  }
  self.step = "assign"
}

func pat.close_missmatch_jumps(self){
  for(let local jump in values(self.missmatch_jumps)){
    self.parent:patch_jump(jump)
  }
}

func pat.increase_stack_height(self){
  self.stack_increase = self.stack_increase + 1
}

func pat.decrease_stack_height(self){
  self.stack_increase = self.stack_increase - 1
}

func pat.test_missmatch(self, missmatch_if){
  self.parent:emit_test(not missmatch_if)
  local match_jump = self.parent:emit_jump()
  if(self.stack_increase > 0){
    self.parent:emit_pop(0, self.stack_increase)
  }
  append(self.missmatch_jumps, self.parent:emit_jump())
  self.parent:patch_jump(match_jump)
}

// ------------------------------------------------------------ code generator

local gen = {}
local gen_meta = {__index: gen}
local visitors = {}

func gen.visit(self, node){
  self.asm:set_location(node.token)
  local f = visitors[node.type]
  if(f == null){
    error("codegen: unknown node type ", node.type)
  }
  f(self, node)
}

local func global_index(token, name){
  return ast.node(
    "Index",
    {
      receiver: ast.node("Identifier", {value: "_ENV"}, token),
      index: ast.node("String", {value: name}, token),
      dotStyle: false,
    }, token
  )
}

local func position(token){
  if(token == null){
    return "?"
  }
  return concat("", token.line, ":", token.column)
}

// With a recorder (generate's options.record, see slang/symbols), the
// names codegen resolves are reported: every local it declares
// (define), every name it reads or assigns with what that resolved to
// (use: a local's definition, or null for a global), and every field
// written or read by name (field).
local func record_local(g, name, token, kind, value, statement){
  if(g.record != null){
    local lv = g.asm:get_local(name)
    lv.def = g.record:define(name, token, kind, value, statement)
  }
}

local func record_use(g, name, token, write, value, statement){
  if(g.record == null){
    return null
  }
  local lv = g.asm:get_local(name)
  if(lv == null){
    local up = g.asm:get_upvalue(name)
    if(up != null){
      lv = up.lv
    }
  }
  if(lv != null){
    g.record:use(name, token, lv.def, write)
  } else {
    g.record:use(name, token, null, write, value, statement)
  }
}

func visitors.Int(g, node){
  g.asm:emit_load_constant(node.value)
}

func visitors.Double(g, node){
  g.asm:emit_load_constant(node.value)
}

func visitors.String(g, node){
  g.asm:emit_load_constant(node.value)
}

func visitors.True(g, node){
  g.asm:emit_load_bool(true, false)
}

func visitors.False(g, node){
  g.asm:emit_load_bool(false, false)
}

func visitors.Null(g, node){
  g.asm:emit_load_constant(null)
}

local func visit_logical_and(g, node){
  g:visit(node.left)
  g.asm:emit_push(- 1)
  g.asm:emit_test(false)
  local done = g.asm:emit_jump()
  g.asm:emit_pop()
  g:visit(node.right)
  g.asm:patch_jump(done)
}

local func visit_logical_or(g, node){
  g:visit(node.left)
  g.asm:emit_push(- 1)
  g.asm:emit_test(true)
  local done = g.asm:emit_jump()
  g.asm:emit_pop()
  g:visit(node.right)
  g.asm:patch_jump(done)
}

func visitors.BinOp(g, node){
  local op = node.op
  if(op == "and"){
    visit_logical_and(g, node)
    return null
  }
  if(op == "or"){
    visit_logical_or(g, node)
    return null
  }
  g:visit(node.left)
  g:visit(node.right)
  if(op == ">"){
    g.asm:emit_binop("<=")
    g.asm:emit_unop("not")
  } else if(op == ">="){
    g.asm:emit_binop("<")
    g.asm:emit_unop("not")
  } else if(op == "!="){
    g.asm:emit_binop("==")
    g.asm:emit_unop("not")
  } else {
    g.asm:emit_binop(op)
  }
}

func visitors.UnOp(g, node){
  g:visit(node.operand)
  g.asm:emit_unop(node.op)
}

// the name a definition gives a function: f, m.f, field (for profiles and
// tracebacks); null for anything else
local func name_of(target){
  if(target.type == "Identifier"){
    return target.value
  }
  if(target.type == "String"){
    return target.value
  }
  if(target.type == "Index" and target.dotStyle and
    target.index.type == "String"){
    local receiver = name_of(target.receiver)
    if(receiver == null){
      return target.index.value
    }
    return concat(receiver, ".", target.index.value)
  }
  return null
}

// the name the next function compiled gets (set by the definition it is the
// value of, taken by visitors.Function)
local func name_next(g, target, value){
  if(value != null and value.type == "Function" and g.function_name == null){
    g.function_name = name_of(target)
  }
}

func visitors.Assignment(g, node){
  local left = node.left
  name_next(g, left, node.right)
  if(g.record != null){
    if(left.type == "Identifier"){
      record_use(g, left.value, left.token, true, node.right, node.token)
    } else if(left.type == "Index"){
      g.record:field(left, true, node.right, node.token)
    }
  }
  if(left.type == "Identifier"){
    local lv = g.asm:get_local(left.value)
    if(lv != null){
      g:visit(node.right)
      g.asm:emit_move(lv.register)
      return null
    }
    local up = g.asm:get_upvalue(left.value)
    if(up != null){
      g:visit(node.right)
      g.asm:emit_set_upvalue(up.index)
      return null
    }
    g:visit(ast.node(
      "Assignment",
      {left: global_index(left.token, left.value), right: node.right},
      left.token
    ))
  } else if(left.type == "Index"){
    g:visit(left.receiver)
    g:visit(left.index)
    g:visit(node.right)
    g.asm:emit_set_table()
  } else {
    error("Invalid assignment target: ", ast.to_string(left))
  }
}

func visitors.Declaration(g, node){
  local left = node.left
  name_next(g, left, node.right)
  if(left.type == "Identifier"){
    local name = left.value
    local existing = g.asm:get_local(name)
    if(node.is_local or existing != null){
      if(node.is_local and existing != null){
        error("Variable already declared: ", name, " ", position(left.token))
      }
      if(existing == null){
        g.asm:create_local(name)
        record_local(g, name, left.token, "local", node.right, node.token)
      } else {
        record_use(g, name, left.token, true)
      }
      local lv = g.asm:get_local(name)
      if(node.right != null){
        g:visit(node.right)
        g.asm:emit_move(lv.register)
      }
      return null
    }
    local right = node.right
    if(right == null){
      right = ast.node("Null", {}, left.token)
    }
    if(g.record != null){
      g.record:use(name, left.token, null, true, node.right, node.token)
    }
    g:visit(ast.node(
      "Assignment", {left: global_index(left.token, name), right: right},
      left.token
    ))
  } else if(left.type == "Index"){
    if(g.record != null){
      g.record:field(left, true, node.right, node.token)
    }
    g:visit(left.receiver)
    g:visit(left.index)
    g:visit(node.right)
    g.asm:emit_set_table()
  } else {
    error("Invalid assignment target: ", ast.to_string(left))
  }
}

// defined with the blocks below
local emit_exits = null

func visitors.Return(g, node){
  if(g.defer_floors != null and len(g.defer_floors) > 0){
    error("return is not allowed inside defer ", position(node.token))
  }
  if(node.value != null){
    g:visit(node.value)
  } else {
    g.asm:emit_load_constant(null)
  }
  // the value waits on the stack while the defers left run
  emit_exits(g, 0)
  g.asm:emit_return()
}

// ------------------------------------------------------------ blocks, defer, try

local RAISED = "<raised>"

local func copy_map(t){
  local out = {}
  for(let local e in entries(t)){
    out[e[0]] = e[1]
  }
  return out
}

// emits a defer's cleanup code, compiled with the names visible at the
// defer (a return in a nested block may shadow one of them)
local func emit_cleanup(g, cleanup){
  local saved = g.asm.locals
  g.asm.locals = copy_map(cleanup.locals)
  // a return or a break may not leave the cleanup: remember where it starts
  local floors = g.defer_floors or {}
  g.defer_floors = floors
  append(floors, len(g.asm.scopes))
  g.asm:enter_scope(false)
  g:visit(cleanup.body)
  g.asm:leave_scope()
  remove(floors, len(floors) - 1)
  g.asm.locals = saved
}

// leaving scopes from the innermost up to (not including) scope index
// `stop`: each try or defer region left pops its handler, each defer runs
// its cleanup
emit_exits = func(g, stop){
  local scopes = g.asm.scopes
  for(local i = len(scopes) - 1; i >= stop; i = i - 1){
    local sc = scopes[i]
    if(sc.handler){
      g.asm:emit_try_end()
    }
    if(sc.cleanup != null){
      emit_cleanup(g, sc.cleanup)
    }
  }
}

// the error path of a protected region: the raised value is on the stack;
// it becomes the local RAISED for the handler's code
local func handler_local(g){
  local lv = g.asm:create_local(RAISED)
  g.asm:emit_move(lv.register)
  return lv
}

local visit_statements = null

// defer: the rest of the block (from index `from`) runs as a protected
// region; the cleanup is emitted at its normal end, in its error handler
// (then the error goes on), and at every return and break that leaves it
local func emit_defer(g, d, statements, from){
  local cleanup = {body: d.body, locals: copy_map(g.asm.locals)}
  local first = g.asm.used_registers
  local begin = g.asm:emit_try_begin(first)
  g.asm:enter_scope(false)
  local sc = g.asm.scopes[len(g.asm.scopes) - 1]
  sc.handler = true
  sc.cleanup = cleanup
  visit_statements(g, statements, from)
  g.asm:leave_scope()
  g.asm:emit_try_end()
  emit_cleanup(g, cleanup)
  local done = g.asm:emit_jump()
  g.asm:patch_try(begin)
  g.asm:enter_scope(false)
  local lv = handler_local(g)
  emit_cleanup(g, cleanup)
  g.asm:emit_push(lv.register)
  g.asm:emit_throw()
  g.asm:leave_scope()
  g.asm:patch_jump(done)
}

visit_statements = func(g, statements, from){
  local n = len(statements)
  local final = null
  if(n > from){
    local last = statements[n - 1]
    if(last.type == "Return" or last.type == "Break" or last.type == "Continue"){
      final = last
      n = n - 1
    }
  }
  for(local i = from; i < n; i = i + 1){
    local s = statements[i]
    if(s.type == "Defer"){
      emit_defer(g, s, statements, i + 1)
      final = null
      break
    }
    g:visit(s)
  }
  g.asm:close_open_upvalues()
  if(final != null){
    g:visit(final)
  }
}

func visitors.Block(g, node){
  visit_statements(g, node.statements, 0)
}

// a defer that is a block's only or last statement guards nothing; one
// reached any other way than through a block is a statement on its own
func visitors.Defer(g, node){
  visit_statements(g, {node}, 0)
}

// try { body } catch(p1) { b1 } catch(p2) { b2 } ...: the clauses become
// if(let p1 = raised) b1 else if(let p2 = raised) b2 else raise(raised)
func visitors.Try(g, node){
  local first = g.asm.used_registers
  local begin = g.asm:emit_try_begin(first)
  g.asm:enter_scope(false)
  g.asm.scopes[len(g.asm.scopes) - 1].handler = true
  g:visit(node.body)
  g.asm:leave_scope()
  g.asm:emit_try_end()
  local done = g.asm:emit_jump()
  g.asm:patch_try(begin)
  g.asm:enter_scope(false)
  handler_local(g)
  local raised = ast.node("Identifier", {value: RAISED}, node.token)
  local chain = ast.node("Throw", {value: raised}, node.token)
  for(local i = len(node.catches) - 1; i >= 0; i = i - 1){
    local c = node.catches[i]
    if(c.pattern == null){
      chain = c.body
    } else {
      local test = ast.node("Let", {pattern: c.pattern, right: raised}, c.token)
      chain = ast.node(
        "If", {condition: test, thenBranch: c.body, elseBranch: chain}, c.token
      )
    }
  }
  g:visit(chain)
  g.asm:leave_scope()
  g.asm:patch_jump(done)
}

func visitors.Throw(g, node){
  g:visit(node.value)
  g.asm:emit_throw()
}

// if(c){ a } else { b } as an expression: one value either way
func visitors.IfExpr(g, node){
  g:visit(node.condition)
  g.asm:emit_test(false)
  local else_jump = g.asm:emit_jump()
  g:visit(node.thenValue)
  local skip = g.asm:emit_jump()
  g.asm:patch_jump(else_jump)
  g:visit(node.elseValue)
  g.asm:patch_jump(skip)
}

func visitors.Identifier(g, node){
  record_use(g, node.value, node.token, false)
  local lv = g.asm:get_local(node.value)
  if(lv != null){
    g.asm:emit_push(lv.register)
    return null
  }
  local up = g.asm:get_upvalue(node.value)
  if(up != null){
    g.asm:emit_get_upvalue(up.index)
    return null
  }
  g:visit(global_index(node.token, node.value))
}

func visitors.Field(g, node){
  if(node.key != null){
    name_next(g, node.key, node.value)
  }
  g.asm:emit_push(- 1)
  g:visit(node.key)
  g:visit(node.value)
  g.asm:emit_set_table()
}

local func has_spread(items){
  for(let local item in values(items)){
    if(item.type == "Spread"){
      return true
    }
  }
  return false
}

// leaves one table on the stack: the items (fields or argument nodes, some
// of them Spread) joined with concat, consecutive plain items as one literal
local func emit_spread_list(g, items, token){
  local segments = {}
  local plain = {}
  local func flush(){
    if(len(plain) > 0){
      append(segments, ast.node("Table", {fields: plain}, token))
      plain = {}
    }
  }
  for(let local item in values(items)){
    if(item.type == "Spread"){
      flush()
      append(segments, item.value)
    } else if(item.type == "Field"){
      append(plain, item)
    } else {
      append(plain, ast.node("Field", {value: item}, item.token))
    }
  }
  flush()
  // concat is looked up as a global whatever locals are in scope
  g:visit(global_index(token, "concat"))
  for(let local seg in values(segments)){
    g:visit(seg)
  }
  g.asm:emit_call(len(segments))
}

// pushes the arguments and emits the call; `extra` arguments (the receiver
// of a method call) are already on the stack
local func emit_call_args(g, args, extra, token){
  if(not has_spread(args)){
    for(let local a in values(args)){
      g:visit(a)
    }
    g.asm:emit_call(len(args) + extra)
    return null
  }
  local fixed = 0
  local rest = {}
  for(let local a in values(args)){
    if(a.type == "Spread" or len(rest) > 0){
      append(rest, a)
    } else {
      g:visit(a)
      fixed = fixed + 1
    }
  }
  if(len(rest) == 1){
    // f(a, ...t): the list itself, no copy
    g:visit(rest[0].value)
  } else {
    emit_spread_list(g, rest, token)
  }
  g.asm:emit_call_spread(fixed + extra)
}

func visitors.Table(g, node){
  if(has_spread(node.fields)){
    emit_spread_list(g, node.fields, node.token)
    return null
  }
  local array_fields = {}
  local map_fields = {}
  for(let local f in values(node.fields)){
    if(f.key == null){
      append(array_fields, f)
    } else {
      append(map_fields, f)
    }
  }
  g.asm:emit_new_table(len(array_fields), len(map_fields))
  local i = 0
  for(let local f in values(array_fields)){
    g:visit(ast.node(
      "Field", {key: ast.node("Int", {value: i}, f.token), value: f.value},
      f.token
    ))
    i = i + 1
  }
  for(let local f in values(map_fields)){
    g:visit(f)
  }
}

func visitors.Index(g, node){
  if(g.record != null){
    g.record:field(node, false)
  }
  g:visit(node.receiver)
  g:visit(node.index)
  g.asm:emit_get_table()
}

// the outer scope holds locals bound by the condition (let patterns); each
// branch gets its own scope so that then-branch locals do not leak into the
// else branch
// let PATTERN = expr: the value is kept in a hidden local so that the
// error can carry it; the pattern's locals are declared in the current
// scope. A mismatch raises {kind: "let", message, pattern, value} with the
// throw op (no global involved); printed uncaught, it shows the value too.
func visitors.LetStat(g, node){
  local token = node.token
  local hidden = concat("let value ", g.asm:next_instruction_index())
  g.asm:create_local(hidden)
  local lv = g.asm:get_local(hidden)
  g:visit(node.right)
  g.asm:emit_move(lv.register)
  local value = ast.node("Identifier", {value: hidden}, token)
  g:visit(ast.node("Let", {pattern: node.pattern, right: value}, token))
  g.asm:emit_test(false)
  local fail_jump = g.asm:emit_jump()
  local done = g.asm:emit_jump()
  g.asm:patch_jump(fail_jump)
  local pattern_text = ast.to_string(node.pattern)
  local func field(name, v){
    return ast.node(
      "Field", {key: ast.node("String", {value: name}, token), value: v}, token
    )
  }
  g:visit(ast.node(
    "Table",
    {
      fields: {
        field("kind", ast.node("String", {value: "let"}, token)),
        field("message", ast.node(
          "String",
          {value: concat("let: the value does not match ", pattern_text)}, token
        )),
        field("pattern", ast.node("String", {value: pattern_text}, token)),
        field("value", value),
      },
    }, token
  ))
  g.asm:emit_throw()
  g.asm:patch_jump(done)
}

func visitors.If(g, node){
  g.asm:enter_scope(false)
  g:visit(node.condition)
  g.asm:emit_test(false)
  local else_jump = g.asm:emit_jump()
  g.asm:enter_scope(false)
  g:visit(node.thenBranch)
  g.asm:leave_scope()
  if(node.elseBranch != null){
    local skip = g.asm:emit_jump()
    g.asm:patch_jump(else_jump)
    g.asm:enter_scope(false)
    g:visit(node.elseBranch)
    g.asm:leave_scope()
    g.asm:patch_jump(skip)
  } else {
    g.asm:patch_jump(else_jump)
  }
  g.asm:leave_scope()
}

func visitors.Function(g, node){
  local parent = g.asm
  local params = node.params
  local n = len(params)
  for(local i = 0; i < n - 1; i = i + 1){
    if(str.starts_with(params[i].value, "...")){
      error(
        "Vararg must be the last parameter but was found in ",
        position(node.token)
      )
    }
  }
  local is_vararg = n > 0 and str.starts_with(params[n - 1].value, "...")
  g.asm = asm.new(parent, null, n, is_vararg)
  // an anonymous function is named after the one it is defined in
  // (seq_list/func); the line tells two of them apart
  g.asm.name = g.function_name
  if(g.asm.name == null and parent.name != null){
    g.asm.name = concat(parent.name, "/func")
  }
  g.function_name = null
  append(parent.children, g.asm)
  g.asm:enter_scope(false)
  for(let local param in values(params)){
    local name = param.value
    if(str.starts_with(name, "...")){
      name = str.substring(name, 3)
    }
    g.asm:create_local(name)
    record_local(g, name, param.token, "parameter")
  }
  g:visit(node.body)
  g.asm:leave_scope()
  g.asm:emit_load_constant(null)
  g.asm:emit_return()
  g.asm = parent
  g.asm:emit_load_closure(len(parent.children) - 1)
}

func visitors.Call(g, node){
  g:visit(node.function)
  emit_call_args(g, node.args, 0, node.token)
}

func visitors.Invoke(g, node){
  if(g.record != null){
    g.record:field(node, false)
  }
  g:visit(node.receiver)
  g.asm:emit_push(- 1)
  g.asm:emit_load_constant(node.name.value)
  g.asm:emit_get_table()
  g.asm:emit_push(- 2)
  emit_call_args(g, node.args, 1, node.token)
  g.asm:emit_move(- 1)
}

func visitors.CallStat(g, node){
  g:visit(node.call)
  g.asm:emit_pop()
}

func visitors.For(g, node){
  g.asm:enter_scope(true)
  local scope = g.asm.scopes[len(g.asm.scopes) - 1]
  scope.label = node.label
  if(node.init != null){
    g:visit(node.init)
  }
  local loop_start = g.asm:next_instruction_index()
  g:visit(node.condition)
  g.asm:emit_test(false)
  local loop_end = g.asm:emit_jump()
  g:visit(node.body)
  // continue goes to the update
  for(let local jump in values(scope.continue_jumps)){
    g.asm:patch_jump(jump)
  }
  if(node.update != null){
    g:visit(node.update)
  }
  g.asm:emit_jump(loop_start)
  g.asm:patch_jump(loop_end)
  g.asm:leave_scope()
}

func visitors.ForIn(g, node){
  g.asm:enter_scope(true)
  local scope = g.asm.scopes[len(g.asm.scopes) - 1]
  scope.label = node.label
  g:visit(node.itterator)
  local loop_start = g.asm:next_instruction_index()
  local p = g.asm:start_pattern()
  g.asm:emit_push(- 1)
  g.asm:emit_call(0)
  p:increase_stack_height()
  g.asm:emit_push(- 1)
  p:increase_stack_height()
  g:visit(node.pattern)
  p:complete_check_step()
  g:visit(node.pattern)
  g.asm:end_pattern()
  g:visit(node.body)
  // continue fetches the next value
  for(let local jump in values(scope.continue_jumps)){
    g.asm:patch_jump(jump, loop_start)
  }
  g.asm:emit_jump(loop_start)
  p:close_missmatch_jumps()
  // a break lands here too: the iterator is still on the stack
  scope.break_target = g.asm:next_instruction_index()
  g.asm:emit_pop()
  g.asm:leave_scope()
}

func visitors.Let(g, node){
  local p = g.asm:start_pattern()
  g:visit(node.right)
  p:increase_stack_height()
  g.asm:emit_push(- 1)
  p:increase_stack_height()
  g:visit(node.pattern)
  p:complete_check_step()
  g:visit(node.pattern)
  g.asm:end_pattern()
  g.asm:emit_load_bool(true, true)
  p:close_missmatch_jumps()
  g.asm:emit_load_bool(false, false)
}

// Every pattern consumes the value on top of the stack, in the check step
// and in the assign step.
func visitors.ConstPattern(g, node){
  local p = g.asm:current_pattern()
  if(p.step == "check"){
    g:visit(node.value)
    g.asm:emit_binop("==")
    p:decrease_stack_height()
    p:test_missmatch(false)
  } else {
    g.asm:emit_pop()
  }
}

func visitors.FieldPattern(g, node){
  local p = g.asm:current_pattern()
  if(p.step == "check"){
    g.asm:emit_push(- 1)
    g:visit(node.key)
    g.asm:emit_get_table()
    p:increase_stack_height()
    g:visit(node.value)
  } else {
    g.asm:emit_push(- 1)
    g:visit(node.key)
    g.asm:emit_get_table()
    g:visit(node.value)
  }
}

// 'matcher [as PATTERN]: __match(matcher, value) decides (null: no match)
// and its result is what the sub-pattern matches. The pattern machinery
// makes two passes, a check and a bind, each consuming a copy of the value,
// so a matcher with a sub-pattern runs twice on a successful match: keep
// matchers pure. 'Type as PATTERN checks the type and matches the
// sub-pattern against the value itself.
local func emit_match_call(g, node){
  // stack: value -> value, result
  g:visit(global_index(node.token, "__match"))
  g:visit(node.matcher)
  g.asm:emit_push(- 3)
  g.asm:emit_call(2)
}

func visitors.MatcherPattern(g, node){
  local p = g.asm:current_pattern()
  if(node.matcher == null){
    if(p.step == "check"){
      g.asm:emit_push(- 1)
      g.asm:emit_type()
      g.asm:emit_load_constant(node.type_name)
      g.asm:emit_binop("==")
      p:test_missmatch(false)
    }
    g:visit(node.sub)
    return null
  }
  if(p.step == "check"){
    emit_match_call(g, node)
    // the value is consumed; the result replaces it (a negative move
    // counts from the top after the pop)
    g.asm:emit_move(- 1)
    g.asm:emit_push(- 1)
    g.asm:emit_load_constant(null)
    g.asm:emit_binop("==")
    p:test_missmatch(true)
    if(node.sub != null){
      g:visit(node.sub)
    } else {
      g.asm:emit_pop()
      p:decrease_stack_height()
    }
  } else if(node.sub != null){
    emit_match_call(g, node)
    g.asm:emit_move(- 1)
    g:visit(node.sub)
  } else {
    g.asm:emit_pop()
  }
}

func visitors.TablePattern(g, node){
  local p = g.asm:current_pattern()
  local fields = {}
  local last_number = - 1
  for(let local f in values(node.fields)){
    if(f.key == null){
      last_number = last_number + 1
      append(fields, ast.node(
        "FieldPattern",
        {key: ast.node("Int", {value: last_number}, f.token), value: f.value},
        f.token
      ))
    } else {
      if(f.key.type == "Int"){
        last_number = f.key.value
      }
      append(fields, f)
    }
  }
  if(p.step == "check"){
    g.asm:emit_push(- 1)
    g.asm:emit_type()
    g.asm:emit_load_constant(node.type_check or "table")
    g.asm:emit_binop("==")
    p:test_missmatch(false)
  }
  for(let local f in values(fields)){
    g:visit(f)
  }
  g.asm:emit_pop()
  p:decrease_stack_height()
}

func visitors.VarPattern(g, node){
  local p = g.asm:current_pattern()
  if(p.step == "check"){
    if(node.canBeNull){
      g.asm:emit_pop()
      p:decrease_stack_height()
      return null
    }
    p:decrease_stack_height()
    p:test_missmatch(false)
  } else {
    if(node.isLocal){
      g.asm:create_local(node.name.value)
      record_local(g, node.name.value, node.name.token, "local")
      g.asm:emit_move(g.asm:get_local(node.name.value).register)
    } else if(g.asm:get_local(node.name.value) != null){
      // an existing name is assigned like `name = value`: a local first,
      // then an upvalue, else a global
      record_use(g, node.name.value, node.name.token, true)
      g.asm:emit_move(g.asm:get_local(node.name.value).register)
    } else if(g.asm:get_upvalue(node.name.value) != null){
      record_use(g, node.name.value, node.name.token, true)
      g.asm:emit_set_upvalue(g.asm:get_upvalue(node.name.value).index)
    } else {
      record_use(g, node.name.value, node.name.token, true)
      g:visit(ast.node("Identifier", {value: "_ENV"}, node.token))
      g.asm:emit_load_constant(node.name.value)
      g.asm:emit_push(- 3)
      g.asm:emit_set_table()
      g.asm:emit_pop()
    }
  }
}

// the scope index of the loop a break or continue goes to: the innermost,
// or the one with the label
local func loop_target(g, node, word){
  local scopes = g.asm.scopes
  for(local i = len(scopes) - 1; i >= 0; i = i - 1){
    if(scopes[i].breakable and
      (node.label == null or scopes[i].label == node.label)){
      return i
    }
  }
  if(node.label != null){
    error(
      concat(
        word, " ", node.label, ": no enclosing loop is labeled ", node.label,
        " "
      ),
      position(node.token)
    )
  }
  if(word == "break"){
    error("Cannot break outside of a loop")
  }
  error(concat("continue outside of a loop "), position(node.token))
}

// a break or continue: the defers and trys between here and the loop are
// left, upvalues of the blocks left are closed, then the jump
local func leave_to_loop(g, node, word){
  local target = loop_target(g, node, word)
  local floors = g.defer_floors
  if(floors != null and len(floors) > 0 and target < floors[len(floors) - 1]){
    error(
      concat(word, " is not allowed to leave a defer "),
      position(node.token)
    )
  }
  emit_exits(g, target + 1)
  // the loop's own scope too: a loop body's locals live there, and an
  // iteration's end closes them (so each iteration's closures keep theirs)
  g.asm:close_upvalues_below(target)
  local jump = g.asm:emit_jump()
  local scope = g.asm.scopes[target]
  if(word == "break"){
    append(scope.break_jumps, jump)
  } else {
    append(scope.continue_jumps, jump)
  }
}

func visitors.Break(g, node){
  leave_to_loop(g, node, "break")
}

func visitors.Continue(g, node){
  leave_to_loop(g, node, "continue")
}

func visitors.Quote(g, node){
  g:visit(ast.quote(node.ast))
}

func visitors.Unquote(g, node){
  error("Unquote was not resolved in parsing step: ", position(node.token))
}

// generate(node, origin, {record}) -> prototype table; record receives the
// names as they are resolved (see record_local above)
func codegen.generate(node, origin, options){
  local g = {}
  g.meta = gen_meta
  if(options != null){
    g.record = options.record
  }
  local parent = asm.new(null, origin or "string")
  parent:create_local("_ENV")
  g.asm = asm.new(parent)
  g:visit(node)
  g.asm:emit_load_constant(null)
  g.asm:emit_return()
  return g.asm:assemble()
}

return codegen
