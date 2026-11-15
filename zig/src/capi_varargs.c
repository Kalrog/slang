// The variadic functions of slang.h (printf-style). They are C because
// Zig's LLVM backend cannot take C's variable arguments on every target
// (it refuses on 64-bit ARM Linux): C formats the text with vsnprintf and
// hands it to the Zig side (capi.zig), which owns the VM.
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct slang_State slang_State;

// capi.zig
void slang__pushformatted(slang_State *S, const char *text, size_t len);
int slang__errorformatted(slang_State *S, const char *kind, const char *text, size_t len);

// the text fmt and ap make, in *len bytes: small (when it fits) or a new
// buffer the caller frees
static char *format(char *small, size_t size, size_t *len, const char *fmt, va_list ap) {
  va_list copy;
  va_copy(copy, ap);
  int n = vsnprintf(small, size, fmt, copy);
  va_end(copy);
  if (n < 0) {
    *len = 0;
    small[0] = 0;
    return small;
  }
  *len = (size_t)n;
  if ((size_t)n < size) return small;
  char *big = malloc((size_t)n + 1);
  if (big == NULL) {
    *len = size - 1;
    return small;
  }
  va_copy(copy, ap);
  vsnprintf(big, (size_t)n + 1, fmt, copy);
  va_end(copy);
  return big;
}

void slang_pushfstring(slang_State *S, const char *fmt, ...) {
  char small[512];
  size_t len;
  va_list ap;
  va_start(ap, fmt);
  char *text = format(small, sizeof small, &len, fmt, ap);
  va_end(ap);
  slang__pushformatted(S, text, len);
  if (text != small) free(text);
}

int slang_error(slang_State *S, const char *fmt, ...) {
  char small[512];
  size_t len;
  va_list ap;
  va_start(ap, fmt);
  char *text = format(small, sizeof small, &len, fmt, ap);
  va_end(ap);
  int r = slang__errorformatted(S, NULL, text, len);
  if (text != small) free(text);
  return r;
}

int slang_errorkind(slang_State *S, const char *kind, const char *fmt, ...) {
  char small[512];
  size_t len;
  va_list ap;
  va_start(ap, fmt);
  char *text = format(small, sizeof small, &len, fmt, ap);
  va_end(ap);
  int r = slang__errorformatted(S, kind, text, len);
  if (text != small) free(text);
  return r;
}
