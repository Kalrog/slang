// cvec3: the vector benchmark's C library (bench/vectors), called through
// slang/ffi: 3D vectors of doubles by value, through pointers, and a batch.
// Built by `zig build bench-libs` into build/bench (not installed).

typedef struct { double x, y, z; } Vec3;

Vec3 v3_add(Vec3 a, Vec3 b) { return (Vec3){a.x + b.x, a.y + b.y, a.z + b.z}; }

void v3_add_into(Vec3 *o, const Vec3 *a, const Vec3 *b) {
  o->x = a->x + b->x;
  o->y = a->y + b->y;
  o->z = a->z + b->z;
}

void v3_axpy(Vec3 *p, const Vec3 *v, double dt) {
  p->x += v->x * dt;
  p->y += v->y * dt;
  p->z += v->z * dt;
}

double v3_dot(Vec3 a, Vec3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }

void v3_step(Vec3 *p, const Vec3 *v, int n, double dt) {
  for (int i = 0; i < n; i++) {
    p[i].x += v[i].x * dt;
    p[i].y += v[i].y * dt;
    p[i].z += v[i].z * dt;
  }
}
