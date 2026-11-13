// bench/compare/slang/sieve.slang in JavaScript (a plain array, not a typed one)
const n = 2000000;
const t0 = performance.now();
const flags = [];
for (let i = 0; i <= n; i++) flags.push(true);
let count = 0;
for (let i = 2; i <= n; i++) {
  if (flags[i]) {
    count++;
    for (let j = i * i; j <= n; j += i) flags[j] = false;
  }
}
console.log(`sieve: ${count} in ${(performance.now() - t0).toFixed(3)} ms`);
