# bench/compare/slang/sieve.slang in Python
import time
def main():
    n = 2000000
    t0 = time.perf_counter()
    flags = []
    i = 0
    while i <= n:
        flags.append(True)
        i += 1
    count = 0
    for i in range(2, n + 1):
        if flags[i]:
            count += 1
            for j in range(i * i, n + 1, i):
                flags[j] = False
    print(f"sieve: {count} in {(time.perf_counter() - t0) * 1000:.3f} ms")
main()
