# bench/compare/slang/dijkstra.slang in Ruby
def now = Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000
N = 5000
$seed = 7
def rand_mod(m)
  $seed = $seed * 16807 % 2147483647
  $seed % m
end
ADJ = Array.new(N) { [] }
N.times do |i|
  4.times do
    j = rand_mod(N)
    w = rand_mod(100) + 1
    ADJ[i] << [j, w]
    ADJ[j] << [i, w]
  end
end
def shortest(src)
  dist = Array.new(N, 1_000_000_000)
  dist[src] = 0
  hd = [0]
  hn = [src]
  size = 1
  while size > 0
    d = hd[0]
    u = hn[0]
    size -= 1
    ld = hd[size]
    ln = hn[size]
    i = 0
    loop do
      c = i * 2 + 1
      break if c >= size
      c += 1 if c + 1 < size && hd[c + 1] < hd[c]
      break if hd[c] >= ld
      hd[i] = hd[c]
      hn[i] = hn[c]
      i = c
    end
    hd[i] = ld
    hn[i] = ln
    next unless d <= dist[u]
    ADJ[u].each do |v, w|
      nd = d + w
      next unless nd < dist[v]
      dist[v] = nd
      i = size
      size += 1
      while i > 0
        p = (i - 1) / 2
        break if hd[p] <= nd
        hd[i] = hd[p]
        hn[i] = hn[p]
        i = p
      end
      hd[i] = nd
      hn[i] = v
    end
  end
  dist.sum
end
t0 = now
check = 0
20.times { |s| check += shortest(s) }
puts format("dijkstra: %d in %.3f ms", check, now - t0)
