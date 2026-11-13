# bench/compare/slang/hashmap.slang in Python
import time
def main():
    t0 = time.perf_counter()
    seed = 42
    counts = {}
    keys = ["k" + str(i) for i in range(50000)]
    for _ in range(1000000):
        seed = seed * 16807 % 2147483647
        k = keys[seed % 50000]
        c = counts.get(k)
        if c is None:
            counts[k] = 1
        else:
            counts[k] = c + 1
    distinct = 0
    most = 0
    for k in keys:
        c = counts.get(k)
        if c is not None:
            distinct += 1
            if c > most:
                most = c
    print(f"hashmap: {distinct * 1000 + most} in {(time.perf_counter() - t0) * 1000:.3f} ms")
main()
