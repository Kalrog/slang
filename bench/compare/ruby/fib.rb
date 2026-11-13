# bench/compare/slang/fib.slang in Ruby
def fib(n)
  return n if n < 2
  fib(n - 1) + fib(n - 2)
end
def now = Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000
t0 = now
r = fib(30)
puts format("fib: %d in %.3f ms", r, now - t0)
