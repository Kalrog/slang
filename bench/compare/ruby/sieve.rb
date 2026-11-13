# bench/compare/slang/sieve.slang in Ruby
def now = Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000
n = 2_000_000
t0 = now
flags = []
i = 0
while i <= n
  flags << true
  i += 1
end
count = 0
i = 2
while i <= n
  if flags[i]
    count += 1
    j = i * i
    while j <= n
      flags[j] = false
      j += i
    end
  end
  i += 1
end
puts format("sieve: %d in %.3f ms", count, now - t0)
