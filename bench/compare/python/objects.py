# bench/compare/slang/objects.slang in Python
import time
class Point:
    __slots__ = ("x", "y")
    def __init__(self, x, y):
        self.x = x
        self.y = y
    def add(self, o):
        return Point(self.x + o.x, self.y + o.y)
    def len2(self):
        return self.x * self.x + self.y * self.y
def main():
    t0 = time.perf_counter()
    acc = Point(0, 0)
    s = 0
    for i in range(1000000):
        p = Point(i, i + 1)
        acc = acc.add(p)
        if i % 3 == 0:
            s += p.len2() % 1000
    print(f"objects: {acc.x + acc.y + s} in {(time.perf_counter() - t0) * 1000:.3f} ms")
main()
