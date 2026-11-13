// bench/compare/slang/fib.slang in JavaScript
function fib(n) {
  if (n < 2) return n;
  return fib(n - 1) + fib(n - 2);
}
const t0 = performance.now();
const r = fib(30);
console.log(`fib: ${r} in ${(performance.now() - t0).toFixed(3)} ms`);
