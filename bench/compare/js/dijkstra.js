// bench/compare/slang/dijkstra.slang in JavaScript
const n = 5000;
let seed = 7;
function rand(m) { seed = seed * 16807 % 2147483647; return seed % m; }
const adj = [];
for (let i = 0; i < n; i++) adj.push([]);
for (let i = 0; i < n; i++) {
  for (let k = 0; k < 4; k++) {
    const j = rand(n);
    const w = rand(100) + 1;
    adj[i].push([j, w]);
    adj[j].push([i, w]);
  }
}
function shortest(src) {
  const dist = [];
  for (let i = 0; i < n; i++) dist.push(1000000000);
  dist[src] = 0;
  const hd = [0], hn = [src];
  let size = 1;
  while (size > 0) {
    const d = hd[0], u = hn[0];
    size--;
    const ld = hd[size], ln = hn[size];
    let i = 0;
    for (;;) {
      let c = i * 2 + 1;
      if (c >= size) break;
      if (c + 1 < size && hd[c + 1] < hd[c]) c++;
      if (hd[c] >= ld) break;
      hd[i] = hd[c]; hn[i] = hn[c];
      i = c;
    }
    hd[i] = ld; hn[i] = ln;
    if (d <= dist[u]) {
      for (const e of adj[u]) {
        const v = e[0], nd = d + e[1];
        if (nd < dist[v]) {
          dist[v] = nd;
          i = size++;
          if (i === hd.length) { hd.push(nd); hn.push(v); }
          while (i > 0) {
            const p = (i - 1) >> 1;
            if (hd[p] <= nd) break;
            hd[i] = hd[p]; hn[i] = hn[p];
            i = p;
          }
          hd[i] = nd; hn[i] = v;
        }
      }
    }
  }
  let total = 0;
  for (const d of dist) total += d;
  return total;
}
const t0 = performance.now();
let check = 0;
for (let s = 0; s < 20; s++) check += shortest(s);
console.log(`dijkstra: ${check} in ${(performance.now() - t0).toFixed(3)} ms`);
