// The sawtooth of bench/audio.slang in C: the floor for kernels
// (PLAN_PERF.md part 3). bench/run_all.sh builds and runs it when cc exists.
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

int main(void) {
  const int n = 1000000;
  float *out = malloc(n * sizeof(float));
  double phase = 0.0;
  const double inc = 440.0 / 48000.0;
  struct timespec t0, t1;
  clock_gettime(CLOCK_MONOTONIC, &t0);
  for (int i = 0; i < n; i++) {
    out[i] = (float)(phase * 2.0 - 1.0);
    phase += inc;
    if (phase >= 1.0) phase -= 1.0;
  }
  clock_gettime(CLOCK_MONOTONIC, &t1);
  double ns = ((t1.tv_sec - t0.tv_sec) * 1e9 + (t1.tv_nsec - t0.tv_nsec)) / n;
  // the sum keeps the loop from being optimised away
  double sum = 0;
  for (int i = 0; i < n; i++) sum += out[i];
  printf("sawtooth, C: %.1f ns per sample (sum %.3f)\n", ns, sum);
  free(out);
  return 0;
}
