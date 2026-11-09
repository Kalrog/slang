// slang/codegen_reg: compiles AST nodes into function prototypes in the
// register instruction set (zig/src/vm/ops.zig), the way slang/codegen does
// it for the stack instruction set. slang/codegen's generate hands over to
// this one for the register ISA (plans/PLAN_REGISTER.md; once the stack ISA
// goes, this backend moves into codegen.slang).
//
//   local proto = codegen_reg.generate(ast_node, "main.slang")
//   local f = vm.load_proto(proto)
//
// An expression compiles to a descriptor (see `desc` below) that says where
// its value is or how to get it, and is placed in a register only where it
// is needed: a local is read in place, a constant becomes the k operand of
// the instruction that uses it, a field read is emitted once its
// destination is known. Registers hold the locals, in the order of their
// declaration, and above them the temporaries of the expression being
// compiled, allocated and freed as a stack; a statement ends with no
// temporaries left. A call's function and arguments are always the highest
// registers in use (the VM relies on it: see ops.zig).
local ast = require("slang/ast")
local str = require("slang/string")
local optimizer = require("slang/optimizer")

local codegen = {}

// opcodes (zig/src/vm/ops.zig: Op)
local OP_MOVE = 0
local OP_LOAD_K = 1
local OP_LOAD_INT = 2
local OP_LOAD_BOOL = 3
local OP_LOAD_NULL = 4
local OP_CLOSURE = 5
local OP_GET_UPVAL = 6
local OP_SET_UPVAL = 7
local OP_CLOSE = 8
local OP_ADD = 9
local OP_SUB = 10
local OP_MUL = 11
local OP_DIV = 12
local OP_MOD = 13
local OP_POW = 14
local OP_BAND = 15
local OP_BOR = 16
local OP_BXOR = 17
local OP_SHL = 18
local OP_SHR = 19
local OP_NEG = 20
local OP_NOT = 21
local OP_BNOT = 22
local OP_EQ = 23
local OP_LT = 24
local OP_LE = 25
local OP_GT = 26
local OP_GE = 27
local OP_TEST = 28
local OP_TEST_SET = 29
local OP_JUMP = 30
local OP_NEW_TABLE = 31
local OP_GET_FIELD = 32
local OP_GET_INDEX = 33
local OP_GET_UP_FIELD = 34
local OP_SET_FIELD = 35
local OP_SET_INDEX = 36
local OP_SET_UP_FIELD = 37
local OP_SELF = 38
local OP_SET_LIST = 39
local OP_INIT_FIELD = 40
local OP_GET_META = 41
local OP_SET_META = 42
local OP_TYPE = 43
local OP_CALL = 44
local OP_CALL_SPREAD = 45
local OP_RETURN = 46
local OP_RETURN_NULL = 47
local OP_TRY_BEGIN = 48
local OP_TRY_END = 49
local OP_THROW = 50
local OP_FOR_LOOP = 51
local OP_FORIN_PREP = 52
local OP_FORIN_NEXT = 53

// the flags of a for_loop, in the A of the jump word after it
local FOR_LEQ = 1
local FOR_NEGATE = 2
local FOR_SUB = 4
local FOR_STEP_K = 8
local FOR_LIMIT_K = 16

// instruction layout: |c:8|b:8|k:1|a:8|op:7|, bx = 17 bits, sbx = bx - 65535
local SBX_OFFSET = 65535
local MAX_BX = 131071
// a constant up to this index fits the k operand (C, or B of a store)
local MAX_RK = 255
// the most array items a table literal stores with one set_list
local LIST_FLUSH = 32

local func enc_abc(op, a, b, c, k){
  local kbit = 0
  if(k){
    kbit = 1
  }
  return c << 24 | b << 16 | kbit << 15 | a << 7 | op
}

local func enc_abx(op, a, bx){
  return bx << 15 | a << 7 | op
}

local func enc_asbx(op, a, sbx){
  return (sbx + SBX_OFFSET) << 15 | a << 7 | op
}

local arith_ops = {}
arith_ops["+"] = OP_ADD
arith_ops["-"] = OP_SUB
arith_ops["*"] = OP_MUL
arith_ops["/"] = OP_DIV
arith_ops["%"] = OP_MOD
arith_ops["^"] = OP_POW
arith_ops["&"] = OP_BAND
arith_ops["|"] = OP_BOR
arith_ops["~"] = OP_BXOR
arith_ops["<<"] = OP_SHL
arith_ops[">>"] = OP_SHR

// a comparison: its opcode (with the left operand in B), the opcode with
// the operands swapped, and whether its sense is inverted (!=)
local compare_ops = {}
compare_ops["<"] = {op: OP_LT, swapped: OP_GT, negate: false}
compare_ops["<="] = {op: OP_LE, swapped: OP_GE, negate: false}
compare_ops[">"] = {op: OP_GT, swapped: OP_LT, negate: false}
compare_ops[">="] = {op: OP_GE, swapped: OP_LE, negate: false}
compare_ops["=="] = {op: OP_EQ, swapped: OP_EQ, negate: false}
compare_ops["!="] = {op: OP_EQ, swapped: OP_EQ, negate: true}

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
    constants: {},
    constant_index: {},
    locals: {},
    // the live locals in the order of their registers (the last one holds
    // the highest register: the temporaries start above it)
    active: {},
    // every local's {name, register, first pc, end pc} (for debuggers)
    local_vars: {},
    upvalues: {},
    upvalue_list: {},
    children: {},
    scopes: {},
    nargs: nargs or 0,
    is_vararg: is_vararg == true,
    used_registers: 0,
    max_registers: 0,
    // temporaries below this register stay while statements are compiled
    // (a defer's cleanup, emitted where a return holds its value)
    temp_floor: 0,
    scope: 0,
  }
  a.@meta = asm_meta
  return a
}

func asm.get_local(self, name){
  return self.locals[name]
}

// the register above the live locals: where the temporaries start
func asm.local_top(self){
  local n = len(self.active)
  if(n == 0){
    return 0
  }
  return self.active[n - 1].register + 1
}

// the register the temporaries of a statement start at
func asm.statement_base(self){
  local top = self:local_top()
  if(self.temp_floor > top){
    return self.temp_floor
  }
  return top
}

// frees the temporaries (the end of a statement)
func asm.reset_temps(self){
  self.used_registers = self:statement_base()
}

// a new local in the next register: nothing but locals may be below it, so
// its register is the end of the locals (the register of a temporary that
// is still in use would be held until the local's scope ends)
func asm.create_local(self, name, above_temps){
  if(above_temps != true and self.used_registers != self:statement_base()){
    raise(error.new(error.kinds.error, concat(
      "codegen: local ", name, " declared while temporaries are in use")))
  }
  local register = self:allocate_register()
  local lv = {
    register: register, name: name, scope: self.scope,
    previous: self.locals[name], captured: false
  }
  lv.debug = {name, register, len(self.instructions), -1}
  append(self.local_vars, lv.debug)
  self.locals[name] = lv
  append(self.active, lv)
  return lv
}

// gives a hidden local its visible name (a for-in's element register)
func asm.rename_local(self, lv, name){
  self.locals[lv.name] = lv.previous
  lv.previous = self.locals[name]
  lv.name = name
  self.locals[name] = lv
  lv.debug[0] = name
  lv.debug[2] = len(self.instructions)
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
        upvalue_index: -1,
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
        local_register: -1,
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

// frees the innermost live local, which must be lv
func asm.free_local(self, lv){
  local n = len(self.active)
  if(n == 0 or self.active[n - 1] != lv){
    raise(error.new(error.kinds.error, "codegen: locals freed out of order"))
  }
  remove(self.active, n - 1)
  if(lv.debug != null and lv.debug[3] < 0){
    lv.debug[3] = len(self.instructions)
  }
  // a shadowed local (lv.previous) is visible again
  self.locals[lv.name] = lv.previous
  self.used_registers = lv.register
}

func asm.enter_scope(self, breakable){
  self.scope = self.scope + 1
  append(self.scopes, {
    breakable: breakable == true, break_jumps: {}, continue_jumps: {},
    label: null, break_target: null
  })
}

func asm.leave_scope(self){
  // a local a closure captured is closed when its scope ends: a block
  // closes its own at its end (visit_statements), and this covers the
  // scopes that end otherwise (an if's condition, a try expression's
  // clause, a loop's variables)
  self:close_open_upvalues()
  // the locals of the scope are the innermost ones
  for(len(self.active) > 0 and
    self.active[len(self.active) - 1].scope == self.scope){
    self:free_local(self.active[len(self.active) - 1])
  }
  local leaving = remove(self.scopes, len(self.scopes) - 1)
  for(let local jump in values(leaving.break_jumps)){
    self:patch_jump(jump, leaving.break_target)
  }
  self.scope = self.scope - 1
}

// emits close for the lowest captured local of the scopes deeper than
// depth: a break or continue leaves them without their block's end
func asm.close_upvalues_below(self, depth){
  local min_slot = self.max_registers
  local any_captured = false
  for(let local lv in values(self.active)){
    if(lv.scope > depth and lv.captured and lv.register < min_slot){
      any_captured = true
      min_slot = lv.register
    }
  }
  if(any_captured){
    self:emit_close(min_slot)
  }
}

// emits close for the lowest captured local of the current scope, unless
// the instruction before already closes them (the scope's block did) or
// the scope ends in a return or a throw (a frame closes its own)
func asm.close_open_upvalues(self){
  local min_slot = self.max_registers
  local any_captured = false
  for(let local lv in values(self.active)){
    if(lv.scope == self.scope and lv.captured and lv.register < min_slot){
      any_captured = true
      min_slot = lv.register
    }
  }
  if(not any_captured){
    return null
  }
  local n = len(self.instructions)
  if(n > 0){
    local last = self.instructions[n - 1]
    local op = last & 127
    if(op == OP_RETURN or op == OP_RETURN_NULL or op == OP_THROW){
      return null
    }
    if(op == OP_CLOSE and ((last >> 7) & 255) <= min_slot){
      return null
    }
  }
  self:emit_close(min_slot)
}

func asm.allocate_register(self){
  local register = self.used_registers
  self.used_registers = self.used_registers + 1
  if(self.used_registers > 255){
    // located at the code being generated, when it has a location yet
    local fields = null
    local n = len(self.locations)
    if(n > 0){
      local at = self.locations[n - 1]
      fields = {
        location: {origin: at[1], line: at[2], column: at[3]}, stack: "",
      }
    }
    local what = "Too many registers"
    if(self.name != null){
      what = concat(what, " in ", self.name)
    }
    raise(error.new(error.kinds.compile, what, fields))
  }
  if(self.used_registers > self.max_registers){
    self.max_registers = self.used_registers
  }
  return register
}

// frees register reg when it is a temporary (the last one allocated)
func asm.free_register(self, reg){
  if(reg < self:local_top()){
    return null
  }
  if(reg != self.used_registers - 1){
    raise(error.new(error.kinds.error, concat(
      "codegen: register ", reg, " freed out of order (", self.used_registers,
      " in use)")))
  }
  self.used_registers = reg
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
    raise(error.new(error.kinds.error, concat("Invalid constant: ", value)))
  }
  local index = self.constant_index[key]
  if(index != null){
    return index
  }
  index = len(self.constants)
  if(index > MAX_BX){
    raise(error.new(error.kinds.compile, "Too many constants"))
  }
  self.constant_index[key] = index
  local entry = {kind}
  entry[1] = value
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
  return len(self.instructions) - 1
}

func asm.emit_abc(self, op, a, b, c, k){
  return self:emit(enc_abc(op, a or 0, b or 0, c or 0, k == true))
}

func asm.emit_abx(self, op, a, bx){
  return self:emit(enc_abx(op, a or 0, bx or 0))
}

func asm.emit_asbx(self, op, a, sbx){
  return self:emit(enc_asbx(op, a or 0, sbx or 0))
}

func asm.next_instruction_index(self){
  return len(self.instructions)
}

// sets the A of the instruction at pc (a relocatable result)
func asm.set_a(self, pc, a){
  local ins = self.instructions[pc]
  self.instructions[pc] = (ins & ~(255 << 7)) | a << 7
}

func asm.emit_move(self, to, from){
  if(to != from){
    self:emit_abc(OP_MOVE, to, from, 0)
  }
}

func asm.emit_load_k(self, reg, index){
  self:emit_abx(OP_LOAD_K, reg, index)
}

func asm.emit_load_null(self, reg, count){
  self:emit_abc(OP_LOAD_NULL, reg, (count or 1) - 1, 0)
}

func asm.emit_load_bool(self, reg, value, skip){
  local b = 0
  if(value){
    b = 1
  }
  local c = 0
  if(skip){
    c = 1
  }
  self:emit_abc(OP_LOAD_BOOL, reg, b, c)
}

func asm.emit_close(self, min_slot){
  self:emit_abc(OP_CLOSE, min_slot, 0, 0)
}

func asm.emit_jump(self, target){
  local sbx = 0
  if(target != null){
    sbx = target - len(self.instructions) - 1
  }
  return self:emit_asbx(OP_JUMP, 0, sbx)
}

// jumps and try_begins keep their opcode and A (a for_loop's jump carries
// its flags there)
func asm.patch_jump(self, jump, target){
  if(target == null){
    target = len(self.instructions)
  }
  local ins = self.instructions[jump]
  self.instructions[jump] = (ins & 32767) | (target - jump - 1 + SBX_OFFSET) << 15
}

// try_begin(first) -> a handle for patch_try: an error raised before the
// matching try_end goes to the patched address with the error in register
// `first` and the upvalues of the registers from `first` up closed
func asm.emit_try_begin(self, first){
  return self:emit_asbx(OP_TRY_BEGIN, first, 0)
}

func asm.patch_try(self, handle){
  self:patch_jump(handle)
}

func asm.emit_call(self, fn, nargs){
  self:emit_abc(OP_CALL, fn, nargs, 0)
}

// call_spread(fn, fixed): the arguments are `fixed` values followed by one
// list whose elements become the remaining arguments
func asm.emit_call_spread(self, fn, fixed){
  self:emit_abc(OP_CALL_SPREAD, fn, fixed, 0)
}

// ------------------------------------------------------------ expressions
//
// A descriptor says where an expression's value is:
//   {kind: "k", index}                  a constant
//   {kind: "reg", reg}                  a register: a local, or a temporary
//   {kind: "upval", index}              an upvalue
//   {kind: "indexed", table, key}       table[key]: table a register, key a
//                                       "k" descriptor (a field) or a "reg"
//   {kind: "indexed_up", up, key}       upvalue[key], key a constant index
//   {kind: "reloc", pc}                 the instruction at pc computes it
//                                       into the register its A will name
// A temporary is any register from the function's local_top up; the
// descriptor functions free them in the order they were allocated, last
// first.

local func is_temp(a, e){
  return e.kind == "reg" and e.reg >= a:local_top()
}

local func free_desc(a, e){
  if(e.kind == "reg"){
    a:free_register(e.reg)
  } else if(e.kind == "indexed"){
    // (the key was allocated after the table)
    if(e.key.kind == "reg"){
      a:free_register(e.key.reg)
    }
    a:free_register(e.table)
  }
}

// frees the registers of two operands, the higher one first
local func free_two(a, e1, e2){
  local r1 = -1
  local r2 = -1
  if(e1.kind == "reg"){
    r1 = e1.reg
  }
  if(e2.kind == "reg"){
    r2 = e2.reg
  }
  if(r1 > r2){
    free_desc(a, e1)
    free_desc(a, e2)
  } else {
    free_desc(a, e2)
    free_desc(a, e1)
  }
}

// an upvalue or an indexed value becomes the instruction that reads it
local func discharge(a, e){
  if(e.kind == "upval"){
    return {kind: "reloc", pc: a:emit_abc(OP_GET_UPVAL, 0, e.index, 0)}
  }
  if(e.kind == "indexed"){
    free_desc(a, e)
    if(e.key.kind == "k"){
      return {kind: "reloc", pc: a:emit_abc(OP_GET_FIELD, 0, e.table, e.key.index)}
    }
    return {kind: "reloc", pc: a:emit_abc(OP_GET_INDEX, 0, e.table, e.key.reg)}
  }
  if(e.kind == "indexed_up"){
    return {kind: "reloc", pc: a:emit_abc(OP_GET_UP_FIELD, 0, e.up, e.key)}
  }
  return e
}

// puts the value in register reg (freeing the temporary it was in)
local func to_reg(a, e, reg){
  e = discharge(a, e)
  if(e.kind == "k"){
    a:emit_load_k(reg, e.index)
  } else if(e.kind == "reg"){
    if(e.reg != reg){
      a:emit_move(reg, e.reg)
      a:free_register(e.reg)
    }
  } else if(e.kind == "reloc"){
    a:set_a(e.pc, reg)
  } else if(e.kind == "void"){
    a:emit_load_null(reg)
  } else {
    raise(error.new(error.kinds.error, concat("codegen: cannot place a ", e.kind)))
  }
  return {kind: "reg", reg: reg}
}

// the value in some register: where it is, or a new temporary
local func to_any_reg(a, e){
  if(e.kind == "reg"){
    return e
  }
  e = discharge(a, e)
  return to_reg(a, e, a:allocate_register())
}

// the value in the next free register (a temporary at the top)
local func to_next_reg(a, e){
  e = discharge(a, e)
  free_desc(a, e)
  return to_reg(a, e, a:allocate_register())
}

// an operand that may be a constant: {c, k} for the C and k fields; the
// register it took, if any, is the caller's to free (through `desc`)
local func to_rk(a, e){
  if(e.kind == "k" and e.index <= MAX_RK){
    return {c: e.index, k: true, desc: e}
  }
  local r = to_any_reg(a, e)
  return {c: r.reg, k: false, desc: r}
}

local func const_desc(a, value){
  return {kind: "k", index: a:index_of_constant(value)}
}

// ------------------------------------------------------------ code generator

local gen = {}
local gen_meta = {__index: gen}
local visitors = {}

// visit(node) -> the descriptor of an expression, null for a statement
func gen.visit(self, node){
  self.asm:set_location(node.token)
  local f = visitors[node.type]
  if(f == null){
    raise(error.new(error.kinds.error,
      concat("codegen: unknown node type ", node.type)))
  }
  return f(self, node)
}

local func global_index(token, name){
  return ast.node("Index", {
    receiver: ast.node("Identifier", {value: "_ENV"}, token),
    index: ast.node("String", {value: name}, token),
    dotStyle: false,
  }, token)
}

// raises a compile error in the program at token: {kind: "compile",
// message, location, stack}, so that it is reported at the program's line
// rather than the compiler's
local func compile_error(g, token, ...message){
  local parts = {}
  for(let local m in values(message)){
    append(parts, string(m))
  }
  local text = str.join(parts, "")
  if(token == null or token.line == null){
    raise(error.new(error.kinds.compile, text))
  }
  raise({
    kind: "compile",
    message: text,
    location: {origin: g.asm.origin, line: token.line, column: token.column},
    stack: "",
  })
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
    g.record:use(name, token, lv.def, write, value, statement)
  } else {
    g.record:use(name, token, null, write, value, statement)
  }
}

// the descriptor of a name: a local, an upvalue, or the global _ENV[name]
local func name_desc(g, node, name){
  local lv = g.asm:get_local(name)
  if(lv != null){
    return {kind: "reg", reg: lv.register}
  }
  local up = g.asm:get_upvalue(name)
  if(up != null){
    return {kind: "upval", index: up.index}
  }
  return g:visit(global_index(node.token, name))
}

func visitors.Int(g, node){
  return const_desc(g.asm, node.value)
}

func visitors.Double(g, node){
  return const_desc(g.asm, node.value)
}

func visitors.String(g, node){
  return const_desc(g.asm, node.value)
}

func visitors.True(g, node){
  return const_desc(g.asm, true)
}

func visitors.False(g, node){
  return const_desc(g.asm, false)
}

func visitors.Null(g, node){
  return const_desc(g.asm, null)
}

func visitors.Identifier(g, node){
  record_use(g, node.value, node.token, false)
  return name_desc(g, node, node.value)
}

// the key of an index or a field: a constant (a "k" descriptor, when it
// fits the k operand) or a register
local func key_desc(g, node){
  local a = g.asm
  local e = g:visit(node)
  if(e.kind == "k" and e.index <= MAX_RK){
    return e
  }
  return to_any_reg(a, e)
}

func visitors.Index(g, node){
  if(g.record != null){
    g.record:field(node, false)
  }
  local a = g.asm
  local recv = g:visit(node.receiver)
  if(recv.kind == "upval" and node.index.type == "String"){
    local k = a:index_of_constant(node.index.value)
    if(k <= MAX_RK){
      return {kind: "indexed_up", up: recv.index, key: k}
    }
  }
  local t = to_any_reg(a, recv)
  local key = key_desc(g, node.index)
  return {kind: "indexed", table: t.reg, key: key}
}

func visitors.Meta(g, node){
  if(g.record != null){
    g.record:field(node, false)
  }
  local a = g.asm
  local r = to_any_reg(a, g:visit(node.receiver))
  free_desc(a, r)
  return {kind: "reloc", pc: a:emit_abc(OP_GET_META, 0, r.reg, 0)}
}

// ---- conditions

local visit_condition = null
local patch_all = null

patch_all = func(g, jumps){
  for(let local j in values(jumps)){
    g.asm:patch_jump(j)
  }
}

// a comparison that jumps when its truth is `sense`; with `counter`, that
// register is put in B (a for loop's counter): null when it is neither side
local func emit_compare(g, node, sense, counter){
  local a = g.asm
  local cmp = compare_ops[node.op]
  if(cmp.negate){
    sense = not sense
  }
  local left = g:visit(node.left)
  // (the left side is placed before the right side is compiled, so that
  // the registers it holds are below the right side's)
  if(left.kind != "k" and left.kind != "reg"){
    left = to_any_reg(a, left)
  }
  local right = g:visit(node.right)
  local op = cmp.op
  // the left operand goes in a register: a constant on the left alone
  // swaps sides (1 < x is x > 1), and so does a counter on the right
  local swap = false
  if(counter != null){
    if(left.kind == "reg" and left.reg == counter){
      swap = false
    } else if(right.kind == "reg" and right.reg == counter){
      swap = true
    } else {
      return null
    }
  } else if(left.kind == "k" and right.kind != "k"){
    swap = true
  }
  if(swap){
    local t = left
    left = right
    right = t
    op = cmp.swapped
  }
  local b = to_any_reg(a, left)
  local c = to_rk(a, right)
  free_two(a, b, c.desc)
  local k = 0
  if(sense){
    k = 1
  }
  a:set_location(node.token)
  a:emit_abc(op, k, b.reg, c.c, c.k)
  return a:emit_jump()
}

local pattern_declare = null
local pattern_check = null
local pattern_assign = null

// let PATTERN = value as a condition: the value goes to a hidden local (so
// that the pattern's own locals come after it), the pattern is checked,
// then its names are bound; the mismatches are the jumps when false
local func let_condition(g, node, sense){
  local a = g.asm
  local right = node.right
  local subject = null
  // a let inside a statement's expression had its locals declared at the
  // statement's start (predeclare_lets); one in a condition declares them
  // here, where no temporary is in use
  local pre = g.predeclared[node]
  if(pre != null and pre.asm == a and pre.scope == a.scope){
    if(pre.subject == null){
      record_use(g, right.value, right.token, false)
      subject = a:get_local(right.value).register
    } else {
      to_reg(a, g:visit(right), pre.subject)
      subject = pre.subject
    }
  } else if(right.type == "Identifier" and a:get_local(right.value) != null){
    record_use(g, right.value, right.token, false)
    subject = a:get_local(right.value).register
    pattern_declare(g, node.pattern)
  } else {
    local hidden = a:create_local(concat("(let value ", a:next_instruction_index(), ")"))
    to_reg(a, g:visit(right), hidden.register)
    a:reset_temps()
    subject = hidden.register
    pattern_declare(g, node.pattern)
  }
  local mismatch = {}
  pattern_check(g, node.pattern, subject, mismatch)
  pattern_assign(g, node.pattern, subject)
  if(not sense){
    return mismatch
  }
  local matched = a:emit_jump()
  patch_all(g, mismatch)
  return {matched}
}

// visit_condition(g, node, sense) -> the jumps to patch: code that jumps
// when the condition's truthiness is `sense` and falls through otherwise.
// and, or and not become jumps instead of values, comparisons compare and
// jump, anything else is tested in a register.
visit_condition = func(g, node, sense){
  local t = node.type
  if(t == "UnOp" and node.op == "not"){
    return visit_condition(g, node.operand, not sense)
  }
  if(t == "BinOp" and (node.op == "and" or node.op == "or")){
    // `and` jumping when false and `or` jumping when true jump on either
    // side; otherwise the left side decides alone when it goes the other
    // way, and that skips the right side
    local either = (node.op == "and") != sense
    if(either){
      local jumps = visit_condition(g, node.left, sense)
      for(let local j in values(visit_condition(g, node.right, sense))){
        append(jumps, j)
      }
      return jumps
    }
    local skip = visit_condition(g, node.left, not sense)
    local jumps = visit_condition(g, node.right, sense)
    patch_all(g, skip)
    return jumps
  }
  if(t == "BinOp" and compare_ops[node.op] != null){
    g.asm:set_location(node.token)
    return {emit_compare(g, node, sense, null)}
  }
  if(t == "Let"){
    g.asm:set_location(node.token)
    return let_condition(g, node, sense)
  }
  local a = g.asm
  local r = to_any_reg(a, g:visit(node))
  free_desc(a, r)
  a:emit_abc(OP_TEST, r.reg, 0, 0, sense)
  local jump = a:emit_jump()
  return {jump}
}

// a condition as a value: true or false in a new temporary
local func condition_value(g, node){
  local a = g.asm
  local when_false = visit_condition(g, node, false)
  local r = a:allocate_register()
  a:emit_load_bool(r, true, true)
  patch_all(g, when_false)
  a:emit_load_bool(r, false, false)
  return {kind: "reg", reg: r}
}

// a and b, a or b as values: the left side when it decides, else the right
local func logical_value(g, node){
  local a = g.asm
  local r = a:allocate_register()
  local left = discharge(a, g:visit(node.left))
  local k = node.op == "or"
  if(left.kind == "reg"){
    // test_set: the left value moves to r only when it is the result
    a:emit_abc(OP_TEST_SET, r, left.reg, 0, k)
    a:free_register(left.reg)
  } else {
    to_reg(a, left, r)
    a:emit_abc(OP_TEST, r, 0, 0, k)
  }
  local done = a:emit_jump()
  to_reg(a, g:visit(node.right), r)
  a:patch_jump(done)
  return {kind: "reg", reg: r}
}

func visitors.BinOp(g, node){
  local op = node.op
  if(op == "and" or op == "or"){
    return logical_value(g, node)
  }
  if(compare_ops[op] != null){
    return condition_value(g, node)
  }
  local code = arith_ops[op]
  if(code == null){
    compile_error(g, node.token, "Unknown operator: \"", op, "\"")
  }
  local a = g.asm
  local b = to_any_reg(a, g:visit(node.left))
  local c = to_rk(a, g:visit(node.right))
  free_two(a, b, c.desc)
  a:set_location(node.token)
  return {kind: "reloc", pc: a:emit_abc(code, 0, b.reg, c.c, c.k)}
}

func visitors.UnOp(g, node){
  local code
  if(node.op == "-"){
    code = OP_NEG
  } else if(node.op == "not"){
    code = OP_NOT
  } else if(node.op == "~"){
    code = OP_BNOT
  } else {
    compile_error(g, node.token, "Unknown operator: ", node.op)
  }
  local a = g.asm
  local b = to_any_reg(a, g:visit(node.operand))
  free_desc(a, b)
  a:set_location(node.token)
  return {kind: "reloc", pc: a:emit_abc(code, 0, b.reg, 0)}
}

func visitors.Let(g, node){
  return condition_value(g, node)
}

// ---- assignment

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

// table[key] = value for an Index target: the receiver and the key are
// evaluated, then the value
local func store_index(g, left, value_node){
  local a = g.asm
  local recv = g:visit(left.receiver)
  if(recv.kind == "upval" and left.index.type == "String"){
    local k = a:index_of_constant(left.index.value)
    if(k <= MAX_RK){
      local v = to_rk(a, g:visit(value_node))
      free_desc(a, v.desc)
      a:set_location(left.token)
      a:emit_abc(OP_SET_UP_FIELD, recv.index, k, v.c, v.k)
      return null
    }
  }
  local t = to_any_reg(a, recv)
  local key = key_desc(g, left.index)
  local v = to_rk(a, g:visit(value_node))
  free_desc(a, v.desc)
  if(key.kind == "reg"){
    a:free_register(key.reg)
  }
  a:free_register(t.reg)
  a:set_location(left.token)
  if(key.kind == "k"){
    a:emit_abc(OP_SET_FIELD, t.reg, key.index, v.c, v.k)
  } else {
    a:emit_abc(OP_SET_INDEX, t.reg, key.reg, v.c, v.k)
  }
}

// name = value for a name that is a local, an upvalue or a global
local func store_name(g, token, name, value_node){
  local a = g.asm
  local lv = a:get_local(name)
  if(lv != null){
    to_reg(a, g:visit(value_node), lv.register)
    return null
  }
  local up = a:get_upvalue(name)
  if(up != null){
    local v = to_any_reg(a, g:visit(value_node))
    free_desc(a, v)
    a:emit_abc(OP_SET_UPVAL, v.reg, up.index, 0)
    return null
  }
  store_index(g, global_index(token, name), value_node)
}

func visitors.Assignment(g, node){
  local left = node.left
  name_next(g, left, node.right)
  if(g.record != null){
    if(left.type == "Identifier"){
      record_use(g, left.value, left.token, true, node.right, node.token)
    } else if(left.type == "Index" or left.type == "Meta"){
      g.record:field(left, true, node.right, node.token)
    }
  }
  if(left.type == "Identifier"){
    store_name(g, left.token, left.value, node.right)
  } else if(left.type == "Index"){
    store_index(g, left, node.right)
  } else if(left.type == "Meta"){
    local a = g.asm
    local t = to_any_reg(a, g:visit(left.receiver))
    local m = to_any_reg(a, g:visit(node.right))
    free_two(a, t, m)
    a:set_location(left.token)
    a:emit_abc(OP_SET_META, t.reg, m.reg, 0)
  } else {
    compile_error(g, left.token, "Invalid assignment target: ",
      ast.to_string(left))
  }
}

// whether the name occurs anywhere in node (as an identifier, read or
// written, in nested functions too)
local mentions = null
mentions = func(node, name){
  // (type() of a node is its own: the type field tells a node)
  if(node == null){
    return false
  }
  local t = node.type
  if(t == null){
    return false
  }
  if(t == "Identifier"){
    return node.value == name
  }
  for(let local spec in values(ast.specs[t] or {})){
    local kind = spec[1]
    if(kind == "node" or kind == "node?"){
      if(mentions(node[spec[0]], name)){
        return true
      }
    } else if(kind == "list"){
      for(let local item in values(node[spec[0]] or {})){
        if(mentions(item, name)){
          return true
        }
      }
    }
  }
  return false
}

func visitors.Declaration(g, node){
  local left = node.left
  name_next(g, left, node.right)
  if(node.is_global){
    // `global name = value`: the global, never a local; where a local of
    // that name is visible the name would read the local afterwards, so it
    // is an error rather than a global no one sees
    if(left.type != "Identifier"){
      compile_error(g, left.token, "global declares a name, not ",
        ast.to_string(left))
    }
    local name = left.value
    if(g.asm:get_local(name) != null or g.asm:get_upvalue(name) != null){
      compile_error(g, left.token, "global ", name, ": a local ", name,
        " is visible here")
    }
    if(g.record != null){
      g.record:use(name, left.token, null, true, node.right, node.token, true)
    }
    if(node.right != null){
      store_index(g, global_index(left.token, name), node.right)
    }
    return null
  }
  if(left.type == "Identifier"){
    local name = left.value
    local existing = g.asm:get_local(name)
    if(node.is_local or existing != null){
      // a local of an enclosing scope may be shadowed, one of this scope not
      if(node.is_local and existing != null and existing.scope == g.asm.scope){
        compile_error(g, left.token, "Variable already declared: ", name)
      }
      if(node.is_local and node.right != null and not mentions(node.right, name)){
        // the value is computed into the register the local takes: it
        // was declared last, so that is the next free one
        local a = g.asm
        local e = to_next_reg(a, g:visit(node.right))
        a:free_register(e.reg)
        local lv = a:create_local(name)
        if(lv.register != e.reg){
          raise(error.new(error.kinds.error, "codegen: a declaration's register moved"))
        }
        record_local(g, name, left.token, "local", node.right, node.token)
        return null
      }
      if(node.is_local){
        // (declared before its value is compiled: `local func f(){ f() }`
        // and `local t = {f: func(){ t }}` refer to it)
        g.asm:create_local(name)
        record_local(g, name, left.token, "local", node.right, node.token)
      } else {
        record_use(g, name, left.token, true)
      }
      local lv = g.asm:get_local(name)
      if(node.right != null){
        to_reg(g.asm, g:visit(node.right), lv.register)
      } else if(node.is_local){
        g.asm:emit_load_null(lv.register)
      }
      return null
    }
    // `func name(){}` where name is a local of an enclosing function sets
    // it, as `name = func(){}` would
    if(g.asm:get_upvalue(name) != null){
      record_use(g, name, left.token, true, node.right, node.token)
      if(node.right != null){
        store_name(g, left.token, name, node.right)
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
    store_index(g, global_index(left.token, name), right)
  } else if(left.type == "Index"){
    if(g.record != null){
      g.record:field(left, true, node.right, node.token)
    }
    store_index(g, left, node.right)
  } else {
    compile_error(g, left.token, "Invalid assignment target: ",
      ast.to_string(left))
  }
}

// ---- blocks, defer, try

// defined with the blocks below
local emit_exits = null

// whether a return or break here leaves a try or a defer (whose cleanup
// runs before it: the value returned is copied first)
local func has_exits(g, stop){
  local scopes = g.asm.scopes
  for(local i = len(scopes) - 1; i >= stop; i = i - 1){
    if(scopes[i].handler or scopes[i].cleanup != null){
      return true
    }
  }
  return false
}

func visitors.Return(g, node){
  if(g.defer_floors != null and len(g.defer_floors) > 0){
    compile_error(g, node.token, "return is not allowed inside defer")
  }
  local a = g.asm
  local exits = has_exits(g, 0)
  if(node.value == null and not exits){
    a:emit_abc(OP_RETURN_NULL, 0, 0, 0)
    return null
  }
  local r = null
  if(node.value != null){
    if(g.record != null and node.value.type == "Function" and
      g.record_function != null){
      // (a function literal returned: its parameters are recorded with a
      // CallbackParam value, {returned_from: the Function node it is
      // returned from, index})
      g.callback_site = {returned_from: g.record_function}
    }
    local e = g:visit(node.value)
    if(exits){
      // the value waits in a temporary while the defers left run
      r = to_next_reg(a, e)
    } else {
      r = to_any_reg(a, e)
    }
  } else {
    r = {kind: "reg", reg: a:allocate_register()}
    a:emit_load_null(r.reg)
  }
  emit_exits(g, 0)
  a:set_location(node.token)
  a:emit_abc(OP_RETURN, r.reg, 0, 0)
  free_desc(a, r)
}

local RAISED = "<raised>"

local func copy_map(t){
  local out = {}
  for(let local e in entries(t)){
    out[e[0]] = e[1]
  }
  return out
}

local visit_statements = null

// the statement types whose children are statements of their own (each
// declared at its own start) or belong to another scope
local statement_scopes = {
  Function: true, Block: true, If: true, For: true, ForIn: true, Try: true,
  Defer: true,
}

// Declares the locals of the `let` expressions in a statement's
// expressions before the statement is compiled: a let's value and the
// names it binds are locals of the statement's scope, and a local can
// only be declared while no temporary is in use (so not in the middle of
// a call's arguments, where `f(let x = y)` meets its let). Each let is
// remembered with its registers (see let_condition).
local predeclare_lets = null
predeclare_lets = func(g, node){
  if(node == null){
    return null
  }
  local t = node.type
  if(t == null or statement_scopes[t]){
    return null
  }
  if(t == "Let"){
    local a = g.asm
    local right = node.right
    local pre = {asm: a, scope: a.scope, subject: null}
    if(right.type == "Identifier" and a:get_local(right.value) != null){
      // (the value stays where it is)
    } else {
      predeclare_lets(g, right)
      pre.subject = a:create_local(concat("(let value ", a:next_instruction_index(), ")")).register
    }
    pattern_declare(g, node.pattern)
    g.predeclared[node] = pre
    return null
  }
  if(t == "LetStat"){
    predeclare_lets(g, node.right)
    return null
  }
  for(let local spec in values(ast.specs[t] or {})){
    local kind = spec[1]
    if(kind == "node" or kind == "node?"){
      predeclare_lets(g, node[spec[0]])
    } else if(kind == "list"){
      for(let local item in values(node[spec[0]] or {})){
        predeclare_lets(g, item)
      }
    }
  }
}

// a statement: compiled with no temporaries in use before or after it
local func visit_statement(g, node){
  predeclare_lets(g, node)
  g:visit(node)
  g.asm:reset_temps()
}

// the body of an if, a loop, a function, a try or a defer, which opens the
// scope itself: a loop body shares it with the loop variables, so that a
// closure made in one iteration keeps that iteration's values
local func visit_body(g, node){
  if(node.type == "Block"){
    visit_statements(g, node.statements, 0)
  } else {
    visit_statement(g, node)
  }
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
  // (a return's value waits in a temporary below the cleanup's code)
  local saved_floor = g.asm.temp_floor
  g.asm.temp_floor = g.asm.used_registers
  g.asm:enter_scope(false)
  visit_body(g, cleanup.body)
  g.asm:leave_scope()
  g.asm.temp_floor = saved_floor
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
      g.asm:emit_abc(OP_TRY_END, 0, 0, 0)
    }
    if(sc.cleanup != null){
      emit_cleanup(g, sc.cleanup)
    }
  }
}

// the error path of a protected region whose try_begin named `first`: the
// raised value is in that register, which becomes the local RAISED
local func handler_local(g, first, above_temps){
  local lv = g.asm:create_local(RAISED, above_temps)
  if(lv.register != first){
    raise(error.new(error.kinds.error, concat(
      "codegen: the handler's register is ", lv.register, ", not ", first)))
  }
  return lv
}

// defer: the rest of the block (from index `from`) runs as a protected
// region; the cleanup is emitted at its normal end, in its error handler
// (then the error goes on), and at every return and break that leaves it
local func emit_defer(g, d, statements, from){
  local a = g.asm
  local cleanup = {body: d.body, locals: copy_map(a.locals)}
  local first = a.used_registers
  local begin = a:emit_try_begin(first)
  a:enter_scope(false)
  local sc = a.scopes[len(a.scopes) - 1]
  sc.handler = true
  sc.cleanup = cleanup
  visit_statements(g, statements, from)
  a:leave_scope()
  a:emit_abc(OP_TRY_END, 0, 0, 0)
  emit_cleanup(g, cleanup)
  local done = a:emit_jump()
  a:patch_try(begin)
  a:enter_scope(false)
  local lv = handler_local(g, first)
  emit_cleanup(g, cleanup)
  a:emit_abc(OP_THROW, lv.register, 0, 0)
  a:leave_scope()
  a:patch_jump(done)
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
    visit_statement(g, s)
  }
  // a return closes every upvalue of the frame itself, after its value:
  // closing here would give a closure made by the value (return func(){
  // ... }) upvalues of its own instead of those its siblings share
  if(final == null or final.type != "Return"){
    g.asm:close_open_upvalues()
  }
  if(final != null){
    visit_statement(g, final)
  }
}

// a block is a scope of its own: its locals end with it
func visitors.Block(g, node){
  g.asm:enter_scope(false)
  visit_statements(g, node.statements, 0)
  g.asm:leave_scope()
}

// a defer that is a block's only or last statement guards nothing; one
// reached any other way than through a block is a statement on its own
func visitors.Defer(g, node){
  visit_statements(g, {node}, 0)
}

// try { body } catch(p1) { b1 } catch(p2) { b2 } ...: the clauses become
// if(let p1 = raised) b1 else if(let p2 = raised) b2 else raise(raised)
func visitors.Try(g, node){
  local a = g.asm
  local first = a.used_registers
  local begin = a:emit_try_begin(first)
  a:enter_scope(false)
  a.scopes[len(a.scopes) - 1].handler = true
  visit_body(g, node.body)
  a:leave_scope()
  a:emit_abc(OP_TRY_END, 0, 0, 0)
  local done = a:emit_jump()
  a:patch_try(begin)
  a:enter_scope(false)
  handler_local(g, first)
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
  visit_body(g, chain)
  a:leave_scope()
  a:patch_jump(done)
}

// try { value } catch(p1) { v1 } ...: one value either way, in a temporary
// that is also where the error lands (the local RAISED of the catch
// clauses); the clauses are tried in order on it as Try's are, and when
// none matches it is raised again
func visitors.TryExpr(g, node){
  local a = g.asm
  local r = a:allocate_register()
  local begin = a:emit_try_begin(r)
  to_reg(a, g:visit(node.value), r)
  a:emit_abc(OP_TRY_END, 0, 0, 0)
  local done = a:emit_jump()
  a:patch_try(begin)
  a:free_register(r)
  a:enter_scope(false)
  handler_local(g, r, true)
  local raised = ast.node("Identifier", {value: RAISED}, node.token)
  local ends = {}
  local caught_all = false
  for(let local c in values(node.catches)){
    a:enter_scope(false)
    local skip = null
    if(c.pattern != null){
      skip = visit_condition(
        g, ast.node("Let", {pattern: c.pattern, right: raised}, c.token), false
      )
    }
    to_reg(a, g:visit(c.body), r)
    a:leave_scope()
    append(ends, a:emit_jump())
    if(skip == null){
      caught_all = true
      break
    }
    patch_all(g, skip)
  }
  if(not caught_all){
    a:emit_abc(OP_THROW, r, 0, 0)
  }
  a:leave_scope()
  patch_all(g, ends)
  a:patch_jump(done)
  // the register again, as the value
  local again = a:allocate_register()
  if(again != r){
    raise(error.new(error.kinds.error, "codegen: a try's value moved"))
  }
  return {kind: "reg", reg: r}
}

func visitors.Throw(g, node){
  local a = g.asm
  local v = to_any_reg(a, g:visit(node.value))
  free_desc(a, v)
  a:set_location(node.token)
  a:emit_abc(OP_THROW, v.reg, 0, 0)
}

// if(c){ a } else { b } as an expression: one value either way
func visitors.IfExpr(g, node){
  local a = g.asm
  local r = a:allocate_register()
  local else_jumps = visit_condition(g, node.condition, false)
  to_reg(a, g:visit(node.thenValue), r)
  local skip = a:emit_jump()
  patch_all(g, else_jumps)
  to_reg(a, g:visit(node.elseValue), r)
  a:patch_jump(skip)
  return {kind: "reg", reg: r}
}

// let PATTERN = expr as a statement: a mismatch raises {kind: "let",
// message, pattern, value} with the throw op (no global involved); printed
// uncaught, it shows the value too. The pattern's locals are declared in
// the current scope.
func visitors.LetStat(g, node){
  local a = g.asm
  local token = node.token
  local hidden = a:create_local(concat("(let value ", a:next_instruction_index(), ")"))
  to_reg(a, g:visit(node.right), hidden.register)
  a:reset_temps()
  pattern_declare(g, node.pattern)
  local mismatch = {}
  pattern_check(g, node.pattern, hidden.register, mismatch)
  pattern_assign(g, node.pattern, hidden.register)
  local done = a:emit_jump()
  patch_all(g, mismatch)
  local pattern_text = str.trim(ast.to_source(node.pattern))
  local func field(name, v){
    return ast.node(
      "Field", {key: ast.node("String", {value: name}, token), value: v}, token
    )
  }
  local value = ast.node("Identifier", {value: hidden.name}, token)
  local err = g:visit(ast.node("Table", {
    fields: {
      field("kind", ast.node("String", {value: "let"}, token)),
      field("message", ast.node(
        "String",
        {value: concat("let: the value does not match ", pattern_text)}, token
      )),
      field("pattern", ast.node("String", {value: pattern_text}, token)),
      field("value", value),
    },
  }, token))
  local e = to_any_reg(a, err)
  free_desc(a, e)
  a:emit_abc(OP_THROW, e.reg, 0, 0)
  a:patch_jump(done)
}

// the outer scope holds locals bound by the condition (let patterns); each
// branch gets its own scope so that then-branch locals do not leak into the
// else branch
func visitors.If(g, node){
  g.asm:enter_scope(false)
  local else_jumps = visit_condition(g, node.condition, false)
  g.asm:enter_scope(false)
  visit_body(g, node.thenBranch)
  g.asm:leave_scope()
  if(node.elseBranch != null){
    local skip = g.asm:emit_jump()
    patch_all(g, else_jumps)
    g.asm:enter_scope(false)
    visit_body(g, node.elseBranch)
    g.asm:leave_scope()
    g.asm:patch_jump(skip)
  } else {
    patch_all(g, else_jumps)
  }
  g.asm:leave_scope()
}

// ---- functions and calls

func visitors.Function(g, node){
  local parent = g.asm
  local params = node.params
  local n = len(params)
  for(local i = 0; i < n - 1; i = i + 1){
    if(str.starts_with(params[i].value, "...")){
      compile_error(g, params[i].token or node.token,
        "a rest parameter (...) must be the last parameter")
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
  local site = g.callback_site
  g.callback_site = null
  for(local i = 0; i < len(params); i = i + 1){
    local param = params[i]
    local name = param.value
    if(str.starts_with(name, "...")){
      name = str.substring(name, 3)
    }
    g.asm:create_local(name)
    local value = null
    if(site != null){
      value = {
        type: "CallbackParam", call: site.call, arg: site.arg,
        returned_from: site.returned_from, index: i
      }
    }
    record_local(g, name, param.token, "parameter", value)
  }
  local outer_function = g.record_function
  g.record_function = node
  visit_body(g, node.body)
  g.record_function = outer_function
  g.asm:leave_scope()
  g.asm:emit_abc(OP_RETURN_NULL, 0, 0, 0)
  g.asm = parent
  g.asm:set_location(node.token)
  return {kind: "reloc", pc: parent:emit_abx(OP_CLOSURE, 0, len(parent.children) - 1)}
}

local func has_spread(items){
  for(let local item in values(items)){
    if(item.type == "Spread"){
      return true
    }
  }
  return false
}

local emit_spread_list = null

// the arguments into the registers after fn (the receiver of a method call
// is there already: `extra`), then the call; the result is in fn
// (with a recorder, a function literal passed as an argument learns where:
// its parameters are recorded with a CallbackParam value, {call, arg,
// index}, for tools that read the callee's doc)
local func emit_call_args(g, args, extra, fn, token, call){
  local a = g.asm
  if(not has_spread(args)){
    for(local i = 0; i < len(args); i = i + 1){
      local arg = args[i]
      if(g.record != null and call != null and arg.type == "Function"){
        g.callback_site = {call: call, arg: i}
      }
      to_next_reg(a, g:visit(arg))
    }
    a:set_location(token)
    a:emit_call(fn, len(args) + extra)
  } else {
    local fixed = 0
    local rest = {}
    for(let local arg in values(args)){
      if(arg.type == "Spread" or len(rest) > 0){
        append(rest, arg)
      } else {
        to_next_reg(a, g:visit(arg))
        fixed = fixed + 1
      }
    }
    if(len(rest) == 1){
      // f(a, ...t): the list itself, no copy
      to_next_reg(a, g:visit(rest[0].value))
    } else {
      to_next_reg(a, emit_spread_list(g, rest, token))
    }
    a:set_location(token)
    a:emit_call_spread(fn, fixed + extra)
  }
  a.used_registers = fn + 1
  return {kind: "reg", reg: fn}
}

// one table: the items (fields or argument nodes, some of them Spread)
// joined with concat, consecutive plain items as one literal
emit_spread_list = func(g, items, token){
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
  local a = g.asm
  local fn = to_next_reg(a, g:visit(global_index(token, "concat")))
  for(let local seg in values(segments)){
    to_next_reg(a, g:visit(seg))
  }
  a:emit_call(fn.reg, len(segments))
  a.used_registers = fn.reg + 1
  return fn
}

func visitors.Call(g, node){
  // `while(c){ ... }` reads as a call of a global while with a block: a
  // loop written as in other languages, not a call anyone means
  local f = node.function
  local args = node.args
  if(f.type == "Identifier" and f.value == "while" and len(args) > 0 and
    args[len(args) - 1].type == "Function" and
    g.asm:get_local("while") == null and g.asm:get_upvalue("while") == null){
    compile_error(g, f.token,
      "slang has no while loop: `for(condition){ ... }` loops while the condition holds")
  }
  local a = g.asm
  local fn = to_next_reg(a, g:visit(node.function))
  return emit_call_args(g, node.args, 0, fn.reg, node.token, node)
}

// obj:name(args): self puts the method and the receiver in two registers
func visitors.Invoke(g, node){
  if(g.record != null){
    g.record:field(node, false)
  }
  local a = g.asm
  local recv = to_any_reg(a, g:visit(node.receiver))
  free_desc(a, recv)
  local base = a:allocate_register()
  a:allocate_register()
  local k = a:index_of_constant(node.name.value)
  a:set_location(node.token)
  if(k <= MAX_RK){
    a:emit_abc(OP_SELF, base, recv.reg, k, true)
  } else {
    local t = a:allocate_register()
    a:emit_load_k(t, k)
    a:emit_abc(OP_SELF, base, recv.reg, t, false)
    a:free_register(t)
  }
  return emit_call_args(g, node.args, 1, base, node.token, node)
}

func visitors.CallStat(g, node){
  local a = g.asm
  free_desc(a, discharge(a, g:visit(node.call)))
}

// ---- tables

local func at_most(x, limit){
  if(x > limit){
    return limit
  }
  return x
}

// a table literal's field: a constant key stores with init_field, a
// computed one with set_index
local func emit_field(g, t, key_node, value_node){
  local a = g.asm
  local key = key_desc(g, key_node)
  local v = to_rk(a, g:visit(value_node))
  free_desc(a, v.desc)
  if(key.kind == "k"){
    a:emit_abc(OP_INIT_FIELD, t, key.index, v.c, v.k)
  } else {
    a:free_register(key.reg)
    a:emit_abc(OP_SET_INDEX, t, key.reg, v.c, v.k)
  }
}

// {..., @meta: m}: the table is built from its other fields, then given
// its metatable
func visitors.Table(g, node){
  local a = g.asm
  local metas = {}
  local fields = {}
  for(let local f in values(node.fields)){
    if(f.type == "MetaField"){
      append(metas, f)
    } else {
      append(fields, f)
    }
  }
  if(len(metas) > 0){
    local t = to_any_reg(a, g:visit(ast.node("Table", {fields: fields}, node.token)))
    for(let local f in values(metas)){
      local m = to_any_reg(a, g:visit(f.value))
      free_desc(a, m)
      a:set_location(f.token)
      a:emit_abc(OP_SET_META, t.reg, m.reg, 0)
    }
    return t
  }
  if(has_spread(node.fields)){
    return emit_spread_list(g, node.fields, node.token)
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
  local t = a:allocate_register()
  a:emit_abc(OP_NEW_TABLE, t, at_most(len(array_fields), 255), at_most(len(map_fields), 255))
  // the list items, in the registers after the table, stored in batches
  local pending = 0
  local start = 0
  local func flush(){
    if(pending == 0){
      return null
    }
    if(start <= 255){
      a:emit_abc(OP_SET_LIST, t, pending, start, false)
    } else {
      a:emit_abc(OP_SET_LIST, t, pending, 0, true)
      a:emit(start)
    }
    start = start + pending
    pending = 0
    a.used_registers = t + 1
  }
  for(let local f in values(array_fields)){
    name_next(g, ast.node("Int", {value: start + pending}, f.token), f.value)
    to_next_reg(a, g:visit(f.value))
    pending = pending + 1
    if(pending == LIST_FLUSH){
      flush()
    }
  }
  flush()
  for(let local f in values(map_fields)){
    name_next(g, f.key, f.value)
    a:set_location(f.token)
    emit_field(g, t, f.key, f.value)
  }
  return {kind: "reg", reg: t}
}

// ---- loops

local emit_for_loop = null

func visitors.For(g, node){
  local a = g.asm
  a:enter_scope(true)
  local scope = a.scopes[len(a.scopes) - 1]
  scope.label = node.label
  if(node.init != null){
    visit_statement(g, node.init)
  }
  // a counting loop: `i = i + step` (or -) as the update and a comparison
  // of i with a limit as the condition, both in registers or constants,
  // become a for_loop (see emit_for_loop)
  local counter = null
  local update = node.update
  local cond = node.condition
  if(update != null and cond != null and update.type == "Assignment" and
    update.left.type == "Identifier" and update.right.type == "BinOp" and
    (update.right.op == "+" or update.right.op == "-") and
    update.right.left.type == "Identifier" and
    update.right.left.value == update.left.value and
    cond.type == "BinOp" and compare_ops[cond.op] != null and
    cond.op != "==" and cond.op != "!="){
    local name = update.left.value
    local lv = a:get_local(name)
    local on_left = cond.left.type == "Identifier" and cond.left.value == name
    local on_right = cond.right.type == "Identifier" and cond.right.value == name
    if(lv != null and (on_left or on_right)){
      counter = lv.register
    }
  }
  local loop_start = a:next_instruction_index()
  local exits = null
  if(counter != null){
    exits = {emit_compare(g, cond, false, counter)}
    // (the condition must be the comparison and its jump alone: the
    // for_loop jumps back to them when its operands are not numbers)
    if(a:next_instruction_index() != loop_start + 2){
      counter = null
    }
  } else {
    exits = visit_condition(g, cond, false)
  }
  visit_body(g, node.body)
  // continue goes to the update
  for(let local jump in values(scope.continue_jumps)){
    a:patch_jump(jump)
  }
  if(counter != null){
    emit_for_loop(g, update, counter, cond, loop_start)
  } else {
    if(update != null){
      visit_statement(g, update)
    }
    a:emit_jump(loop_start)
  }
  patch_all(g, exits)
  a:leave_scope()
}

// the operand of a for_loop: {x, k} for a constant or a register, or null
local func for_operand(g, node){
  local a = g.asm
  if(node.type == "Int" or node.type == "Double"){
    local k = a:index_of_constant(node.value)
    if(k <= MAX_RK){
      return {x: k, k: true}
    }
    return null
  }
  if(node.type == "Identifier"){
    local lv = a:get_local(node.value)
    if(lv != null){
      return {x: lv.register, k: false}
    }
  }
  return null
}

// the update and the jump back of a counting loop as one for_loop (the
// condition was compiled as one comparison and one jump at loop_start);
// when its operands do not fit, the update as itself
emit_for_loop = func(g, update, counter, cond, loop_start){
  local a = g.asm
  local step = for_operand(g, update.right.right)
  local cmp = compare_ops[cond.op]
  local limit_node = cond.right
  local op = cond.op
  if(cond.left.type != "Identifier" or a:get_local(cond.left.value) == null or
    a:get_local(cond.left.value).register != counter){
    // the counter on the right: the mirrored comparison
    limit_node = cond.left
    if(op == "<"){
      op = ">"
    } else if(op == "<="){
      op = ">="
    } else if(op == ">"){
      op = "<"
    } else {
      op = "<="
    }
  }
  local limit = for_operand(g, limit_node)
  if(step == null or limit == null){
    visit_statement(g, update)
    a:emit_jump(loop_start)
    return null
  }
  local flags = 0
  if(op == "<=" or op == ">"){
    flags = flags | FOR_LEQ
  }
  if(op == ">" or op == ">="){
    flags = flags | FOR_NEGATE
  }
  if(update.right.op == "-"){
    flags = flags | FOR_SUB
  }
  if(step.k){
    flags = flags | FOR_STEP_K
  }
  if(limit.k){
    flags = flags | FOR_LIMIT_K
  }
  a:set_location(update.token)
  a:emit_abc(OP_FOR_LOOP, counter, step.x, limit.x, false)
  // the jump to the body, after the condition's two words
  a:emit_asbx(OP_JUMP, flags, loop_start + 2 - a:next_instruction_index() - 1)
}

// (with a recorder, the names a for-in pattern binds are recorded with a
// LoopValue value, {iterator, part}: part is null for the value itself, the
// index or key of a part a table pattern takes apart)
local func loop_values(g, node){
  if(g.record == null){
    return null
  }
  local out = {}
  local p = node.pattern
  if(p.type == "VarPattern"){
    out[p.name.token.start] = {type: "LoopValue", iterator: node.itterator}
  } else if(p.type == "TablePattern"){
    local i = 0
    for(let local f in values(p.fields)){
      if(f.type == "FieldPattern" and f.value.type == "VarPattern"){
        local part = i
        if(f.key != null and f.key.type == "String"){
          part = f.key.value
        } else {
          i = i + 1
        }
        out[f.value.name.token.start] = {
          type: "LoopValue", iterator: node.itterator, part: part
        }
      }
    }
  }
  return out
}

// for(let PATTERN in f(x)): the iterator, its position and the element in
// three registers (forin_prep, forin_next); an element is matched against
// the pattern in place, a plain `let local name` naming the element's
// register itself
func visitors.ForIn(g, node){
  local a = g.asm
  a:enter_scope(true)
  local scope = a.scopes[len(a.scopes) - 1]
  scope.label = node.label
  // the iterator returns stop when it is done (null is an element): the
  // global, read once into a hidden local, compared by identity
  local stop_lv = a:create_local("(for stop)")
  to_reg(a, g:visit(global_index(node.token, "stop")), stop_lv.register)
  a:reset_temps()
  g.loop_values = loop_values(g, node)
  local it_lv = a:create_local("(for iterator)")
  local position_lv = a:create_local("(for position)")
  local element_lv = a:create_local("(for element)")
  local pattern = node.pattern
  local plain = pattern.type == "VarPattern" and pattern.isLocal
  local it = node.itterator
  if(it.type == "Call" and len(it.args) == 1 and it.args[0].type != "Spread"){
    to_reg(a, g:visit(it.function), it_lv.register)
    to_reg(a, g:visit(it.args[0]), position_lv.register)
    a:reset_temps()
    a:set_location(it.token)
    a:emit_abc(OP_FORIN_PREP, it_lv.register, 0, 0)
  } else {
    to_reg(a, g:visit(it), it_lv.register)
    a:reset_temps()
  }
  if(plain){
    // (after the iterator, which may read a variable of the same name)
    a:rename_local(element_lv, pattern.name.value)
    local value = null
    if(g.loop_values != null and pattern.name.token != null){
      value = g.loop_values[pattern.name.token.start]
    }
    record_local(g, pattern.name.value, pattern.name.token, "local", value)
  }
  local loop_start = a:next_instruction_index()
  // a table walked in the loop: its next element, then to the pattern
  // (or to the end); an iterator function: on to its call
  a:emit_abc(OP_FORIN_NEXT, it_lv.register, 0, 0)
  local walked_end = a:emit_jump()
  local walked_value = a:emit_jump()
  // the call, in a temporary above the loop's locals
  local t = a:allocate_register()
  a:emit_move(t, it_lv.register)
  a:set_location(it.token)
  a:emit_call(t, 0)
  a:emit_move(element_lv.register, t)
  a:free_register(t)
  a:emit_abc(OP_EQ, 1, element_lv.register, stop_lv.register, false)
  local stop_jump = a:emit_jump()
  a:patch_jump(walked_value)
  local mismatch = {}
  if(plain){
    pattern_check(g, pattern, element_lv.register, mismatch)
  } else {
    pattern_declare(g, pattern)
    pattern_check(g, pattern, element_lv.register, mismatch)
    pattern_assign(g, pattern, element_lv.register)
  }
  g.loop_values = null
  visit_body(g, node.body)
  // continue fetches the next value
  for(let local jump in values(scope.continue_jumps)){
    a:patch_jump(jump, loop_start)
  }
  a:emit_jump(loop_start)
  // an element the pattern does not take: let? goes on with the next one,
  // let raises (as the let statement does)
  if(len(mismatch) > 0){
    patch_all(g, mismatch)
    if(node.skip){
      a:emit_jump(loop_start)
    } else {
      local token = node.token
      local pattern_text = str.trim(ast.to_source(pattern))
      local func field(name, text){
        return ast.node("Field", {
          key: ast.node("String", {value: name}, token),
          value: ast.node("String", {value: text}, token),
        }, token)
      }
      local err = to_any_reg(a, g:visit(ast.node("Table", {
        fields: {
          field("kind", "for"),
          field("message", concat(
            "for: an element does not match ", pattern_text,
            " (write let? to skip such elements; a name? takes null)",
          )),
          field("pattern", pattern_text),
        },
      }, token)))
      free_desc(a, err)
      a:emit_abc(OP_THROW, err.reg, 0, 0)
    }
  }
  a:patch_jump(stop_jump)
  a:patch_jump(walked_end)
  a:leave_scope()
}

// ---- patterns
//
// A pattern is matched against a value in a register in two steps: the
// check jumps to the mismatch list when the value does not fit, then the
// assignment binds the names. The locals a pattern binds are declared
// before either step (pattern_declare), so that no temporary is below them.

pattern_declare = func(g, p){
  local t = p.type
  if(t == "VarPattern"){
    if(p.isLocal){
      g.asm:create_local(p.name.value)
      local value = null
      if(g.loop_values != null and p.name.token != null){
        value = g.loop_values[p.name.token.start]
      }
      record_local(g, p.name.value, p.name.token, "local", value)
    }
  } else if(t == "TablePattern"){
    for(let local f in values(p.fields)){
      pattern_declare(g, f.value)
    }
  } else if(t == "FieldPattern"){
    pattern_declare(g, p.value)
  } else if(t == "MatcherPattern"){
    if(p.sub != null){
      pattern_declare(g, p.sub)
    }
  }
}

// a table pattern's fields with their keys: positional ones count from 0
// and after the last integer key
local func table_pattern_fields(node){
  local fields = {}
  local last_number = -1
  for(let local f in values(node.fields)){
    if(f.key == null){
      last_number = last_number + 1
      append(fields, ast.node(
        "FieldPattern",
        {key: ast.node("Int", {value: last_number}, f.token), value: f.value},
        f.token,
      ))
    } else {
      if(f.key.type == "Int"){
        last_number = f.key.value
      }
      append(fields, f)
    }
  }
  return fields
}

// reg[key] into a new temporary
local func emit_field_read(g, reg, key_node){
  local a = g.asm
  local t = a:allocate_register()
  local key = key_desc(g, key_node)
  if(key.kind == "k"){
    a:emit_abc(OP_GET_FIELD, t, reg, key.index)
  } else {
    a:free_register(key.reg)
    a:emit_abc(OP_GET_INDEX, t, reg, key.reg)
  }
  return t
}

// __match(matcher, value) into a new temporary (null: no match)
local func emit_match_call(g, node, reg){
  local a = g.asm
  local fn = to_next_reg(a, g:visit(global_index(node.token, "__match")))
  to_next_reg(a, g:visit(node.matcher))
  local v = a:allocate_register()
  a:emit_move(v, reg)
  a:set_location(node.token)
  a:emit_call(fn.reg, 2)
  a.used_registers = fn.reg + 1
  return fn.reg
}

// a jump to the mismatches when the type of reg is not name
local func check_type(g, reg, name, mismatch){
  local a = g.asm
  local t = a:allocate_register()
  a:emit_abc(OP_TYPE, t, reg, 0)
  local k = to_rk(a, const_desc(a, name))
  free_desc(a, k.desc)
  a:free_register(t)
  a:emit_abc(OP_EQ, 0, t, k.c, k.k)
  append(mismatch, a:emit_jump())
}

pattern_check = func(g, p, reg, mismatch){
  local a = g.asm
  local t = p.type
  a:set_location(p.token)
  if(t == "ConstPattern"){
    local k = to_rk(a, g:visit(p.value))
    free_desc(a, k.desc)
    a:emit_abc(OP_EQ, 0, reg, k.c, k.k)
    append(mismatch, a:emit_jump())
  } else if(t == "VarPattern"){
    // anything but null matches (false too: for-in goes on past it)
    if(not p.canBeNull){
      local k = to_rk(a, const_desc(a, null))
      free_desc(a, k.desc)
      a:emit_abc(OP_EQ, 1, reg, k.c, k.k)
      append(mismatch, a:emit_jump())
    }
  } else if(t == "TablePattern"){
    check_type(g, reg, p.type_check or "table", mismatch)
    for(let local f in values(table_pattern_fields(p))){
      pattern_check(g, f, reg, mismatch)
    }
  } else if(t == "FieldPattern"){
    local v = emit_field_read(g, reg, p.key)
    pattern_check(g, p.value, v, mismatch)
    a:free_register(v)
  } else if(t == "MatcherPattern"){
    // 'matcher [as PATTERN]: __match(matcher, value) decides (null: no
    // match) and its result is what the sub-pattern matches; the check
    // and the assignment each call it, so a matcher must be pure. 'Type as
    // PATTERN checks the type and matches the sub-pattern against the
    // value itself.
    if(p.matcher == null){
      check_type(g, reg, p.type_name, mismatch)
      if(p.sub != null){
        pattern_check(g, p.sub, reg, mismatch)
      }
    } else {
      local r = emit_match_call(g, p, reg)
      local k = to_rk(a, const_desc(a, null))
      free_desc(a, k.desc)
      a:emit_abc(OP_EQ, 1, r, k.c, k.k)
      append(mismatch, a:emit_jump())
      if(p.sub != null){
        pattern_check(g, p.sub, r, mismatch)
      }
      a:free_register(r)
    }
  } else {
    compile_error(g, p.token, "not a pattern: ", t)
  }
}

pattern_assign = func(g, p, reg){
  local a = g.asm
  local t = p.type
  if(t == "VarPattern"){
    local name = p.name.value
    if(p.isLocal){
      a:emit_move(a:get_local(name).register, reg)
    } else if(a:get_local(name) != null){
      // an existing name is assigned like `name = value`: a local first,
      // then an upvalue, else a global
      record_use(g, name, p.name.token, true)
      a:emit_move(a:get_local(name).register, reg)
    } else if(a:get_upvalue(name) != null){
      record_use(g, name, p.name.token, true)
      a:emit_abc(OP_SET_UPVAL, reg, a:get_upvalue(name).index, 0)
    } else {
      record_use(g, name, p.name.token, true)
      local env = g:visit(ast.node("Identifier", {value: "_ENV"}, p.token))
      local k = a:index_of_constant(name)
      if(env.kind == "upval" and k <= MAX_RK){
        a:emit_abc(OP_SET_UP_FIELD, env.index, k, reg, false)
      } else {
        local e = to_any_reg(a, env)
        local key = to_any_reg(a, {kind: "k", index: k})
        free_two(a, e, key)
        a:emit_abc(OP_SET_INDEX, e.reg, key.reg, reg, false)
      }
    }
  } else if(t == "TablePattern"){
    for(let local f in values(table_pattern_fields(p))){
      pattern_assign(g, f, reg)
    }
  } else if(t == "FieldPattern"){
    local v = emit_field_read(g, reg, p.key)
    pattern_assign(g, p.value, v)
    a:free_register(v)
  } else if(t == "MatcherPattern"){
    if(p.sub == null){
      return null
    }
    if(p.matcher == null){
      pattern_assign(g, p.sub, reg)
    } else {
      local r = emit_match_call(g, p, reg)
      pattern_assign(g, p.sub, r)
      a:free_register(r)
    }
  }
}

// the pattern nodes are compiled through pattern_check and pattern_assign
local func pattern_outside(g, node){
  compile_error(g, node.token, "a pattern outside of let or for")
}
visitors.ConstPattern = pattern_outside
visitors.VarPattern = pattern_outside
visitors.TablePattern = pattern_outside
visitors.FieldPattern = pattern_outside
visitors.MatcherPattern = pattern_outside

// ---- break, continue, quote

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
    compile_error(g, node.token,
      word, " ", node.label, ": no enclosing loop is labeled ", node.label)
  }
  compile_error(g, node.token, word, " outside of a loop")
}

// a break or continue: the defers and trys between here and the loop are
// left, upvalues of the blocks left are closed, then the jump
local func leave_to_loop(g, node, word){
  local target = loop_target(g, node, word)
  local floors = g.defer_floors
  if(floors != null and len(floors) > 0 and target < floors[len(floors) - 1]){
    compile_error(g, node.token, word, " is not allowed to leave a defer")
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
  return g:visit(ast.quote(node.ast))
}

func visitors.Unquote(g, node){
  compile_error(g, node.token, "an unquote outside of a quote is resolved while parsing; this one was not")
}

func visitors.Spread(g, node){
  compile_error(g, node.token, "a spread (...) belongs in a call or a table")
}

// ------------------------------------------------------------ assembly

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
  // locals still alive at the end live to it
  for(let local v in values(self.local_vars)){
    if(v[3] < 0){
      v[3] = len(self.instructions)
    }
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
    locals: self.local_vars,
    isa: "register",
  }
}

// generate(node: table, origin?: string, options?: {record?: table}) -> Prototype
// Compiles an AST node (a chunk, usually) into the prototype of a function
// in the register ISA that runs it; see slang/codegen's generate for the
// options.
func codegen.generate(node, origin, options){
  local g = {predeclared: {}}
  g.@meta = gen_meta
  if(options != null){
    g.record = options.record
  }
  if(g.record == null){
    node = optimizer.optimize(node, {constants: true})
  }
  local parent = asm.new(null, origin or "string")
  parent:create_local("_ENV")
  g.asm = asm.new(parent)
  visit_body(g, node)
  g.asm:emit_abc(OP_RETURN_NULL, 0, 0, 0)
  return g.asm:assemble()
}

return codegen
