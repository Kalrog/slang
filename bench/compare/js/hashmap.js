// bench/compare/slang/hashmap.slang in JavaScript (a Map, the idiomatic string-keyed table)
const t0 = performance.now();
let seed = 42;
const counts = new Map();
const keys = [];
for (let i = 0; i < 50000; i++) keys.push("k" + i);
for (let i = 0; i < 1000000; i++) {
  seed = seed * 16807 % 2147483647;
  const k = keys[seed % 50000];
  const c = counts.get(k);
  if (c === undefined) counts.set(k, 1); else counts.set(k, c + 1);
}
let distinct = 0, most = 0;
for (const k of keys) {
  const c = counts.get(k);
  if (c !== undefined) { distinct++; if (c > most) most = c; }
}
console.log(`hashmap: ${distinct * 1000 + most} in ${(performance.now() - t0).toFixed(3)} ms`);
