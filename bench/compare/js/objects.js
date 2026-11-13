// bench/compare/slang/objects.slang in JavaScript
class Point {
  constructor(x, y) { this.x = x; this.y = y; }
  add(o) { return new Point(this.x + o.x, this.y + o.y); }
  len2() { return this.x * this.x + this.y * this.y; }
}
const t0 = performance.now();
let acc = new Point(0, 0);
let sum = 0;
for (let i = 0; i < 1000000; i++) {
  const p = new Point(i, i + 1);
  acc = acc.add(p);
  if (i % 3 === 0) sum += p.len2() % 1000;
}
console.log(`objects: ${acc.x + acc.y + sum} in ${(performance.now() - t0).toFixed(3)} ms`);
