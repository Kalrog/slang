# bench/compare/slang/fib.slang in Python
import time
def fib(n):
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)
t0 = time.perf_counter()
r = fib(30)
print(f"fib: {r} in {(time.perf_counter() - t0) * 1000:.3f} ms")
