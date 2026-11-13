# bench/compare/slang/strings.slang in Python
import time
def main():
    t0 = time.perf_counter()
    total = 0
    for _ in range(5):
        parts = []
        for i in range(100000):
            parts.append("item" + str(i))
        back = ",".join(parts).split(",")
        for s in back:
            total += len(s)
    print(f"strings: {total} in {(time.perf_counter() - t0) * 1000:.3f} ms")
main()
