double saw(float *out, long n, double phase, double inc) {
  for (long i = 0; i < n; i++) {
    phase += inc;
    if (phase >= 1.0) phase -= 1.0;
    out[i] = (float)(phase * 2 - 1);
  }
  return phase;
}
