.text
.globl _saw
.p2align 2
_saw: //saw(out: [*]f32, n: i64, phase: f64, inc: f64) f64
//register locations:
// x0: out
// x1: n
// d0: phase
// d1: inc
// d0: return
// x2: i
// d2: 1.0
// d3: 2.0
// x3: 4
  mov x2, #0
  cmp x1, x2
  b.le AFTER_LOOP
  fmov d2, #1.0
  fmov d3, #2.0
START_OF_LOOP:
  fadd d0, d0, d1
  fcmp d0, d2
  b.le ELSE
  fsub d0, d0, d2
ELSE:
  fmul d4, d0, d3
  fsub d4, d4, d2
  fcvt s4, d4
  add x4, x0, x2
  str s4, [x0], #4
  add x2, x2, #1
  cmp x2, x1
  b.lt START_OF_LOOP
AFTER_LOOP:
  ret