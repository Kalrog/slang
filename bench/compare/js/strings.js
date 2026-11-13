// bench/compare/slang/strings.slang in JavaScript
const t0 = performance.now();
let total = 0;
for (let round = 0; round < 5; round++) {
  const parts = [];
  for (let i = 0; i < 100000; i++) parts.push("item" + i);
  const back = parts.join(",").split(",");
  for (const s of back) total += s.length;
}
console.log(`strings: ${total} in ${(performance.now() - t0).toFixed(3)} ms`);
