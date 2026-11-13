# bench/compare/slang/strings.slang in Ruby
def now = Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000
t0 = now
total = 0
5.times do
  parts = []
  100_000.times { |i| parts << "item#{i}" }
  parts.join(",").split(",").each { |s| total += s.length }
end
puts format("strings: %d in %.3f ms", total, now - t0)
