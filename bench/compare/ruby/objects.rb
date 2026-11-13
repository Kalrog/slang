# bench/compare/slang/objects.slang in Ruby
def now = Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000
class Point
  attr_reader :x, :y
  def initialize(x, y)
    @x = x
    @y = y
  end
  def add(o) = Point.new(@x + o.x, @y + o.y)
  def len2 = @x * @x + @y * @y
end
t0 = now
acc = Point.new(0, 0)
sum = 0
i = 0
while i < 1_000_000
  p = Point.new(i, i + 1)
  acc = acc.add(p)
  sum += p.len2 % 1000 if i % 3 == 0
  i += 1
end
puts format("objects: %d in %.3f ms", acc.x + acc.y + sum, now - t0)
