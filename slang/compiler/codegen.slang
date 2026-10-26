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

// instruction layout: |b:9|c:9|a:8|op:6|, bx = 18 bits, sbx = bx - 0x1FFFF, ax = 26 bits
local SBX_OFFSET = 131071
local SHIFT_A = 64
local SHIFT_C = 16384
local SHIFT_B = 8388608

local func enc_abc(op, a, b, c){
  return b * SHIFT_B + c * SHIFT_C + a * SHIFT_A + op
}

local func enc_abx(op, a, bx){
  return bx * SHIFT_C + a * SHIFT_A + op
}

local func enc_asbx(op, a, sbx){
  return (sbx + SBX_OFFSET) * SHIFT_C + a * SHIFT_A + op
}

local func enc_ax(op, ax){
  return ax * SHIFT_A + op
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

// ------------------------------------------------------------ function assembler

local asm = {}
local asm_meta = {__index: asm}

func asm.new(parent, origin, nargs, is_vararg){
  local a = {
    parent: parent,
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
  local lv = {register: register, name: name, scope: self.scope, previous: self.locals[name], captured: false}
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
      local def = {name: name, index: len(self.upvalue_list), local_register: lv.register, upvalue_index: -1}
      self.upvalues[name] = def
      append(self.upvalue_list, def)
      return def
    }
    local up = self.parent:get_upvalue(name)
    if(up != null){
      local def = {name: name, index: len(self.upvalue_list), local_register: -1, upvalue_index: up.index}
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
  append(self.scopes, {breakable: breakable == true, break_jumps: {}})
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
  for(let local jump in values(leaving.break_jumps)){
    self:patch_jump(jump)
  }
  self.scope = self.scope - 1
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
  local opcode = self.instructions[jump] % 64
  self.instructions[jump] = enc_asbx(opcode, 0, target - jump - 1)
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
  }
}

// ------------------------------------------------------------ pattern assembler

local pat = {}
local pat_meta = {__index: pat}

func pattern_new(parent){
  local p = {step: "check", missmatch_jumps: {}, stack_increase: 0, parent: parent}
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
  return ast.node("Index", {
    receiver: ast.node("Identifier", {value: "_ENV"}, token),
    index: ast.node("String", {value: name}, token),
    dotStyle: false,
  }, token)
}

local func position(token){
  if(token == null){
    return "?"
  }
  return concat("", token.line, ":", token.column)
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
  g.asm:emit_push(-1)
  g.asm:emit_test(false)
  local done = g.asm:emit_jump()
  g.asm:emit_pop()
  g:visit(node.right)
  g.asm:patch_jump(done)
}

local func visit_logical_or(g, node){
  g:visit(node.left)
  g.asm:emit_push(-1)
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

func visitors.Assignment(g, node){
  local left = node.left
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
    g:visit(ast.node("Assignment", {left: global_index(left.token, left.value), right: node.right}, left.token))
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
  if(left.type == "Identifier"){
    local name = left.value
    local existing = g.asm:get_local(name)
    if(node.is_local or existing != null){
      if(node.is_local and existing != null){
        error("Variable already declared: ", name, " ", position(left.token))
      }
      if(existing == null){
        g.asm:create_local(name)
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
    g:visit(ast.node("Assignment", {left: global_index(left.token, name), right: right}, left.token))
  } else if(left.type == "Index"){
    g:visit(left.receiver)
    g:visit(left.index)
    g:visit(node.right)
    g.asm:emit_set_table()
  } else {
    error("Invalid assignment target: ", ast.to_string(left))
  }
}

func visitors.Return(g, node){
  if(node.value != null){
    g:visit(node.value)
  } else {
    g.asm:emit_load_constant(null)
  }
  g.asm:emit_return()
}

func visitors.Block(g, node){
  local statements = node.statements
  local n = len(statements)
  local final = null
  if(n > 0){
    local last = statements[n - 1]
    if(last.type == "Return" or last.type == "Break"){
      final = last
      n = n - 1
    }
  }
  for(local i = 0; i < n; i = i + 1){
    g:visit(statements[i])
  }
  g.asm:close_open_upvalues()
  if(final != null){
    g:visit(final)
  }
}

func visitors.Identifier(g, node){
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
  g.asm:emit_push(-1)
  g:visit(node.key)
  g:visit(node.value)
  g.asm:emit_set_table()
}

func visitors.Table(g, node){
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
    g:visit(ast.node("Field", {key: ast.node("Int", {value: i}, f.token), value: f.value}, f.token))
    i = i + 1
  }
  for(let local f in values(map_fields)){
    g:visit(f)
  }
}

func visitors.Index(g, node){
  g:visit(node.receiver)
  g:visit(node.index)
  g.asm:emit_get_table()
}

// the outer scope holds locals bound by the condition (let patterns); each
// branch gets its own scope so that then-branch locals do not leak into the
// else branch
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
      error("Vararg must be the last parameter but was found in ", position(node.token))
    }
  }
  local is_vararg = n > 0 and str.starts_with(params[n - 1].value, "...")
  g.asm = asm.new(parent, null, n, is_vararg)
  append(parent.children, g.asm)
  g.asm:enter_scope(false)
  for(let local param in values(params)){
    local name = param.value
    if(str.starts_with(name, "...")){
      name = str.substring(name, 3)
    }
    g.asm:create_local(name)
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
  for(let local a in values(node.args)){
    g:visit(a)
  }
  g.asm:emit_call(len(node.args))
}

func visitors.Invoke(g, node){
  g:visit(node.receiver)
  g.asm:emit_push(-1)
  g.asm:emit_load_constant(node.name.value)
  g.asm:emit_get_table()
  g.asm:emit_push(-2)
  for(let local a in values(node.args)){
    g:visit(a)
  }
  g.asm:emit_call(len(node.args) + 1)
  g.asm:emit_move(-1)
}

func visitors.CallStat(g, node){
  g:visit(node.call)
  g.asm:emit_pop()
}

func visitors.For(g, node){
  g.asm:enter_scope(true)
  if(node.init != null){
    g:visit(node.init)
  }
  local loop_start = g.asm:next_instruction_index()
  g:visit(node.condition)
  g.asm:emit_test(false)
  local loop_end = g.asm:emit_jump()
  g:visit(node.body)
  if(node.update != null){
    g:visit(node.update)
  }
  g.asm:emit_jump(loop_start)
  g.asm:patch_jump(loop_end)
  g.asm:leave_scope()
}

func visitors.ForIn(g, node){
  g.asm:enter_scope(true)
  g:visit(node.itterator)
  local loop_start = g.asm:next_instruction_index()
  local p = g.asm:start_pattern()
  g.asm:emit_push(-1)
  g.asm:emit_call(0)
  p:increase_stack_height()
  g.asm:emit_push(-1)
  p:increase_stack_height()
  g:visit(node.pattern)
  p:complete_check_step()
  g:visit(node.pattern)
  g.asm:end_pattern()
  g:visit(node.body)
  g.asm:emit_jump(loop_start)
  p:close_missmatch_jumps()
  g.asm:emit_pop()
  g.asm:leave_scope()
}

func visitors.Let(g, node){
  local p = g.asm:start_pattern()
  g:visit(node.right)
  p:increase_stack_height()
  g.asm:emit_push(-1)
  p:increase_stack_height()
  g:visit(node.pattern)
  p:complete_check_step()
  g:visit(node.pattern)
  g.asm:end_pattern()
  g.asm:emit_load_bool(true, true)
  p:close_missmatch_jumps()
  g.asm:emit_load_bool(false, false)
}

func visitors.ConstPattern(g, node){
  local p = g.asm:current_pattern()
  if(p.step == "check"){
    g:visit(node.value)
    g.asm:emit_binop("==")
    p:decrease_stack_height()
    p:test_missmatch(false)
  }
}

func visitors.FieldPattern(g, node){
  local p = g.asm:current_pattern()
  if(p.step == "check"){
    g.asm:emit_push(-1)
    g:visit(node.key)
    g.asm:emit_get_table()
    p:increase_stack_height()
    g:visit(node.value)
  } else {
    local vt = node.value.type
    if(vt == "TablePattern" or vt == "VarPattern"){
      g.asm:emit_push(-1)
      g:visit(node.key)
      g.asm:emit_get_table()
      g:visit(node.value)
    }
  }
}

func visitors.TablePattern(g, node){
  local p = g.asm:current_pattern()
  local fields = {}
  local last_number = -1
  for(let local f in values(node.fields)){
    if(f.key == null){
      last_number = last_number + 1
      append(fields, ast.node("FieldPattern", {key: ast.node("Int", {value: last_number}, f.token), value: f.value}, f.token))
    } else {
      if(f.key.type == "Int"){
        last_number = f.key.value
      }
      append(fields, f)
    }
  }
  if(p.step == "check"){
    g.asm:emit_push(-1)
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
      g.asm:emit_move(g.asm:get_local(node.name.value).register)
    } else {
      g:visit(ast.node("Identifier", {value: "_ENV"}, node.token))
      g.asm:emit_load_constant(node.name.value)
      g.asm:emit_push(-3)
      g.asm:emit_set_table()
      g.asm:emit_pop()
    }
  }
}

func visitors.Break(g, node){
  g.asm:emit_break()
}

func visitors.Quote(g, node){
  g:visit(ast.quote(node.ast))
}

func visitors.Unquote(g, node){
  error("Unquote was not resolved in parsing step: ", position(node.token))
}

// generate(node, origin) -> prototype table
func codegen.generate(node, origin){
  local g = {}
  g.meta = gen_meta
  local parent = asm.new(null, origin or "string")
  parent:create_local("_ENV")
  g.asm = asm.new(parent)
  g:visit(node)
  g.asm:emit_load_constant(null)
  g.asm:emit_return()
  return g.asm:assemble()
}

return codegen
