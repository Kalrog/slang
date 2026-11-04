// mix(int, sint): the Lisp interpreter specialized to the Lisp's own
// self-interpreter is a Lisp interpreter written in slang, generated.
// Jones's optimality test for a specializer: is it as good as the
// hand-written one?
local mix = require("mix")
local lisp = require("lisp")
local time = require("slang/time")
local sint = require("sint")     // sint.lisp, through the dialect

local func say(...parts){ print(...parts, "\n") }
local func show(title, spec){
  say("\n== ", title)
  say(spec:source())
}

local int = mix.load(lisp.interpreter)
local options = {limit: 5000}

// ------------------------------------------------- mix(int, p): compiling
local fib = lisp.read("""
  (define (main n) (fib n))
  (define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
""")
local append = lisp.read("""
  (define (main xs ys) (app xs ys))
  (define (app xs ys) (if (null? xs) ys (cons (car xs) (app (cdr xs) ys))))
""")
say("interpreted: fib(20) = ", int.run(fib, 20))
say("interpreted: (app '(1 2) '(3)) = ", lisp.show(int.run(append, lisp.read("(1 2)")[0], lisp.read("(3)")[0])))

local spec = mix.specialize(lisp.interpreter, "run", {program: fib}, options)
show("mix(int, fib): the Lisp program, compiled", spec)
local fib_slang = spec:load()
say("compiled: fib(20) = ", fib_slang(20))

spec = mix.specialize(lisp.interpreter, "run", {program: append}, options)
show("mix(int, append)", spec)

// a program and its input both static: mix computes the answer
spec = mix.specialize(lisp.interpreter, "run", {program: fib, a: 10}, options)
show("mix(int, fib, 10): nothing left to run", spec)

// --------------------------------------- mix(int, sint): an interpreter
say("\nsint.lisp has ", len(lisp.to_list(sint)), " definitions")
say("doubly interpreted: int(sint, fib, 15) = ", int.run(sint, fib, 15))

spec = mix.specialize(lisp.interpreter, "run", {program: sint}, options)
show(concat("mix(int, sint): a Lisp interpreter in slang, generated (", len(spec.functions), " functions)"), spec)
local sint_slang = spec:load()
say("generated interpreter: fib(15) = ", sint_slang(fib, 15))
say("generated interpreter: (app '(1 2) '(3)) = ", lisp.show(sint_slang(append, lisp.read("(1 2)")[0], lisp.read("(3)")[0])))

// ---------------------------------------------------- the optimality test
local func timed(f){
  local t0 = time.clock()
  f()
  return to_int(time.clock() - t0)
}
local n = 18
say("\nfib(", n, "):")
say("  compiled by mix(int, fib)           ", timed(func(){ fib_slang(n) }), " ms")
say("  int, the hand-written interpreter   ", timed(func(){ int.run(fib, n) }), " ms")
say("  mix(int, sint), the generated one   ", timed(func(){ sint_slang(fib, n) }), " ms")
say("  int running sint running fib        ", timed(func(){ int.run(sint, fib, n) }), " ms")
