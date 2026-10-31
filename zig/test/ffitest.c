/*
 * ffitest: a C library for zig/test/ffi_test.slang to call through slang/ffi.
 * Built by `zig build` into lib/libffitest.<ext>; plain C, no slang.h.
 */
#define _DEFAULT_SOURCE
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct { float x, y; } Vec2;
typedef struct { double a; int8_t b; int64_t c; } Mixed;
typedef struct { Vec2 pos; uint8_t tag[4]; char name[8]; } Item;
typedef struct { int32_t v[10]; } Big;
typedef struct Node { int value; struct Node *next; } Node;

int8_t ft_i8(int8_t x) { return x; }
uint8_t ft_u8(uint8_t x) { return x; }
int16_t ft_i16(int16_t x) { return x; }
uint16_t ft_u16(uint16_t x) { return x; }
int32_t ft_i32(int32_t x) { return x; }
uint32_t ft_u32(uint32_t x) { return x; }
int64_t ft_i64(int64_t x) { return x; }
uint64_t ft_u64(uint64_t x) { return x; }
float ft_f32(float x) { return x; }
double ft_f64(double x) { return x; }
bool ft_not(bool b) { return !b; }
double ft_mix_args(int8_t a, double b, uint16_t c, float d, int64_t e) { return a + b + c + d + e; }

const char *ft_greet(const char *name) {
    static char buf[64];
    snprintf(buf, sizeof buf, "hi %s", name ? name : "nobody");
    return buf;
}

Vec2 ft_vec_add(Vec2 a, Vec2 b) { return (Vec2){a.x + b.x, a.y + b.y}; }
Mixed ft_mixed(double a, int8_t b, int64_t c) { return (Mixed){a, b, c}; }
double ft_mixed_sum(Mixed m) { return m.a + m.b + (double)m.c; }

Item ft_item(Vec2 pos, const char *name) {
    Item it = {pos, {1, 2, 3, 4}, {0}};
    strncpy(it.name, name, sizeof it.name - 1);
    return it;
}
int ft_item_tags(Item it) { return it.tag[0] + it.tag[1] + it.tag[2] + it.tag[3] + (int)strlen(it.name); }

Big ft_big(int start) {
    Big b;
    for (int i = 0; i < 10; i++) b.v[i] = start + i;
    return b;
}
int64_t ft_big_sum(Big b) {
    int64_t s = 0;
    for (int i = 0; i < 10; i++) s += b.v[i];
    return s;
}

float ft_sum_vecs(const Vec2 *vs, int count) {
    float s = 0;
    for (int i = 0; i < count; i++) s += vs[i].x + vs[i].y;
    return s;
}
void ft_scale(Vec2 *v, float k) { v->x *= k; v->y *= k; }
void ft_fill(int *out, int count) { for (int i = 0; i < count; i++) out[i] = i * i; }

int ft_count_nodes(const Node *n) {
    int c = 0;
    for (; n; n = n->next) c += n->value;
    return c;
}

int ft_sum_ints(int count, ...) {
    va_list ap;
    va_start(ap, count);
    int s = 0;
    for (int i = 0; i < count; i++) s += va_arg(ap, int);
    va_end(ap);
    return s;
}

static int counter = 0;
int ft_next(void) { return ++counter; }
const void *ft_null(void) { return NULL; }

/* callbacks */
typedef int (*IntFn)(int);
int ft_apply(IntFn f, int x) { return f(x); }
uint8_t ft_apply_u8(uint8_t (*f)(uint8_t), uint8_t x) { return f(x); }
int8_t ft_apply_i8(int8_t (*f)(int8_t), int8_t x) { return f(x); }
double ft_apply_f64(double (*f)(double, float), double x) { return f(x, 0.5f); }
Vec2 ft_map_vec(Vec2 (*f)(Vec2, const char *), Vec2 v) { return f(v, "scaled"); }
const char *ft_name_of(const char *(*f)(int), int i) { return f(i); }

typedef struct { IntFn on_value; int base; } Handler;
static Handler saved;
void ft_set_handler(Handler h) { saved = h; }
int ft_fire(int x) { return saved.on_value ? saved.on_value(saved.base + x) : -1; }

/* n threads at once call f(i) for their i; the sum of the results */
struct ft_job { IntFn f; int x; int r; };
static void *ft_run_job(void *p) {
    struct ft_job *j = p;
    for (int k = 0; k < 100; k++) j->r = j->f(j->x);
    return NULL;
}
int ft_threads(IntFn f, int n) {
    pthread_t t[16];
    struct ft_job jobs[16];
    if (n > 16) n = 16;
    for (int i = 0; i < n; i++) {
        jobs[i] = (struct ft_job){ f, i, 0 };
        pthread_create(&t[i], NULL, ft_run_job, &jobs[i]);
    }
    int s = 0;
    for (int i = 0; i < n; i++) {
        pthread_join(t[i], NULL);
        s += jobs[i].r;
    }
    return s;
}
