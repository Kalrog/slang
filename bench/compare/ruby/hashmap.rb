# bench/compare/slang/hashmap.slang in Ruby
def now = Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000
t0 = now
seed = 42
counts = {}
keys = Array.new(50_000) { |i| "k#{i}" }
1_000_000.times do
  seed = seed * 16807 % 2147483647
  k = keys[seed % 50_000]
  c = counts[k]
  if c.nil?
    counts[k] = 1
  else
    counts[k] = c + 1
  end
end
distinct = 0
most = 0
keys.each do |k|
  c = counts[k]
  next if c.nil?
  distinct += 1
  most = c if c > most
end
puts format("hashmap: %d in %.3f ms", distinct * 1000 + most, now - t0)
