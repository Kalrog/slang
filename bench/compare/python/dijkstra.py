# bench/compare/slang/dijkstra.slang in Python (hand-written heap, not heapq)
import time
N = 5000
seed = 7
def rand(m):
    global seed
    seed = seed * 16807 % 2147483647
    return seed % m
adj = [[] for _ in range(N)]
for i in range(N):
    for _ in range(4):
        j = rand(N)
        w = rand(100) + 1
        adj[i].append((j, w))
        adj[j].append((i, w))
def shortest(src):
    dist = [1000000000] * N
    dist[src] = 0
    hd = [0]
    hn = [src]
    size = 1
    while size > 0:
        d = hd[0]
        u = hn[0]
        size -= 1
        ld = hd[size]
        ln = hn[size]
        i = 0
        while True:
            c = i * 2 + 1
            if c >= size:
                break
            if c + 1 < size and hd[c + 1] < hd[c]:
                c += 1
            if hd[c] >= ld:
                break
            hd[i] = hd[c]
            hn[i] = hn[c]
            i = c
        hd[i] = ld
        hn[i] = ln
        if d <= dist[u]:
            for v, w in adj[u]:
                nd = d + w
                if nd < dist[v]:
                    dist[v] = nd
                    i = size
                    size += 1
                    if i == len(hd):
                        hd.append(nd)
                        hn.append(v)
                    while i > 0:
                        p = (i - 1) // 2
                        if hd[p] <= nd:
                            break
                        hd[i] = hd[p]
                        hn[i] = hn[p]
                        i = p
                    hd[i] = nd
                    hn[i] = v
    return sum(dist)
t0 = time.perf_counter()
check = 0
for s in range(20):
    check += shortest(s)
print(f"dijkstra: {check} in {(time.perf_counter() - t0) * 1000:.3f} ms")
