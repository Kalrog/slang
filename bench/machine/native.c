// The machine's own speed, without slang (bench/machine/run.slang runs it):
// loops in C, built by bench/machine/build.sh with zig cc at -O2 for each
// platform, so both machines run the same source through the same
// compiler. Each line: "name: <ns> ns per <unit>", the best of five rounds.
//
//   sawtooth       float arithmetic, a dependency chain (the audio kernels'
//                  floor)
//   int mix        integer multiply, shift, xor (hashing)
//   switch vm      a tiny bytecode interpreter dispatching with switch: how
//                  the CPU predicts one indirect branch for every opcode
//   threaded vm    the same program with computed goto (one indirect
//                  branch per handler, as slang's VM aims for)
//   pointer chase  dependent loads in random order over 64 MB: memory
//                  latency
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#ifdef _WIN32
#include <windows.h>
static double now_ns(void) {
  static LARGE_INTEGER f;
  LARGE_INTEGER c;
  if (f.QuadPart == 0) QueryPerformanceFrequency(&f);
  QueryPerformanceCounter(&c);
  return (double)c.QuadPart * 1e9 / (double)f.QuadPart;
}
#else
#include <time.h>
static double now_ns(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1e9 + t.tv_nsec;
}
#endif

// keeps results alive, so the loops are not optimised away
static volatile double sink;

static double sawtooth(int n) {
  float *out = malloc(n * sizeof(float));
  double phase = 0.0;
  const double inc = 440.0 / 48000.0;
  double t0 = now_ns();
  for (int i = 0; i < n; i++) {
    out[i] = (float)(phase * 2.0 - 1.0);
    phase += inc;
    if (phase >= 1.0) phase -= 1.0;
  }
  double t = (now_ns() - t0) / n;
  double sum = 0;
  for (int i = 0; i < n; i++) sum += out[i];
  sink = sum;
  free(out);
  return t;
}

static double int_mix(int n) {
  uint64_t x = 88172645463325252ull, acc = 0;
  double t0 = now_ns();
  for (int i = 0; i < n; i++) {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    acc += x * 0x9E3779B97F4A7C15ull;
  }
  double t = (now_ns() - t0) / n;
  sink = (double)acc;
  return t;
}

// the program: r0 counts down from n; each turn does a few arithmetic ops
// and a conditional jump back, as interpreted code does
enum { ADD, SUB, MUL, XOR, DEC, JNZ, HALT };
typedef struct { uint8_t op, a, b, c; } Ins;
static const Ins program[] = {
  {ADD, 1, 1, 2}, {XOR, 3, 1, 2}, {MUL, 2, 2, 4}, {SUB, 3, 3, 1}, {ADD, 1, 3, 4},
  {DEC, 0, 0, 0}, {JNZ, 0, 0, 0}, {HALT, 0, 0, 0},
};
#define PER_TURN 7

static double switch_vm(int turns) {
  int64_t r[8] = {turns, 1, 2, 3, 1, 0, 0, 0};
  const Ins *pc = program;
  double t0 = now_ns();
  for (;;) {
    Ins i = *pc++;
    switch (i.op) {
      case ADD: r[i.a] = r[i.b] + r[i.c]; break;
      case SUB: r[i.a] = r[i.b] - r[i.c]; break;
      case MUL: r[i.a] = r[i.b] * (r[i.c] | 1); break;
      case XOR: r[i.a] = r[i.b] ^ r[i.c]; break;
      case DEC: r[i.a] -= 1; break;
      case JNZ: if (r[i.a] != 0) pc = program; break;
      case HALT: goto done;
    }
  }
done:;
  double t = (now_ns() - t0) / ((double)turns * PER_TURN);
  sink = (double)(r[1] + r[3]);
  return t;
}

static double threaded_vm(int turns) {
  static void *labels[] = {&&l_add, &&l_sub, &&l_mul, &&l_xor, &&l_dec, &&l_jnz, &&l_halt};
  int64_t r[8] = {turns, 1, 2, 3, 1, 0, 0, 0};
  const Ins *pc = program;
  Ins i;
  double t0 = now_ns();
#define NEXT i = *pc++; goto *labels[i.op]
  NEXT;
l_add: r[i.a] = r[i.b] + r[i.c]; NEXT;
l_sub: r[i.a] = r[i.b] - r[i.c]; NEXT;
l_mul: r[i.a] = r[i.b] * (r[i.c] | 1); NEXT;
l_xor: r[i.a] = r[i.b] ^ r[i.c]; NEXT;
l_dec: r[i.a] -= 1; NEXT;
l_jnz: if (r[i.a] != 0) pc = program; NEXT;
l_halt:;
#undef NEXT
  double t = (now_ns() - t0) / ((double)turns * PER_TURN);
  sink = (double)(r[1] + r[3]);
  return t;
}

static double pointer_chase(int loads) {
  const size_t n = (64u << 20) / sizeof(uint32_t);
  uint32_t *next = malloc(n * sizeof(uint32_t));
  // one cycle through every slot in a random order (Sattolo's shuffle)
  for (size_t i = 0; i < n; i++) next[i] = (uint32_t)i;
  uint64_t s = 12345;
  for (size_t i = n - 1; i > 0; i--) {
    s = s * 6364136223846793005ull + 1442695040888963407ull;
    size_t j = (size_t)((s >> 33) % i);
    uint32_t tmp = next[i];
    next[i] = next[j];
    next[j] = tmp;
  }
  uint32_t p = 0;
  double t0 = now_ns();
  for (int i = 0; i < loads; i++) p = next[p];
  double t = (now_ns() - t0) / loads;
  sink = p;
  free(next);
  return t;
}

static void best(const char *name, const char *unit, double (*f)(int), int n) {
  double b = 1e300;
  for (int r = 0; r < 5; r++) {
    double t = f(n);
    if (t < b) b = t;
  }
  printf("%s: %.3f ns per %s\n", name, b, unit);
}

int main(void) {
  best("sawtooth", "sample", sawtooth, 4000000);
  best("int mix", "round", int_mix, 50000000);
  best("switch vm", "instruction", switch_vm, 10000000);
  best("threaded vm", "instruction", threaded_vm, 10000000);
  best("pointer chase", "load", pointer_chase, 4000000);
  return 0;
}
