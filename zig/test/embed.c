/* A C program embedding slang through the slang library (zig build test
 * links it against libslang and runs it): a VM, code run in it, a value
 * read back, a C function called from slang. */
#include <stdio.h>
#include <string.h>
#include "slang.h"

static int twice(slang_State *S) {
    slang_pushint(S, slang_checkint(S, 1) * 2);
    return 1;
}

int main(void) {
    slang_State *S = slang_new();
    if (S == NULL) {
        fprintf(stderr, "embed: slang_new failed\n");
        return 1;
    }
    slang_pushcfunction(S, twice, "twice");
    slang_setglobal(S, "twice");
    if (slang_dostring(S, "local t = {1, 2, 3}\nreturn concat(\"sum \", string(twice(t[0] + t[1] + t[2])))", "embed") != SLANG_OK) {
        fprintf(stderr, "embed: %s\n", slang_tostring(S, -1));
        return 1;
    }
    const char *got = slang_tostring(S, -1);
    if (got == NULL || strcmp(got, "sum 12") != 0) {
        fprintf(stderr, "embed: got %s\n", got ? got : "(null)");
        return 1;
    }
    /* an error comes back as a status and a message */
    if (slang_dostring(S, "raise(\"no\")", "embed") == SLANG_OK) {
        fprintf(stderr, "embed: an error was not reported\n");
        return 1;
    }
    slang_close(S);
    return 0;
}
