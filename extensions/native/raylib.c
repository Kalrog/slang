/*
 * raylib: a native extension exposing the parts of raylib (https://www.raylib.com)
 * that a small 2D game needs: a window, a frame loop, rectangles, circles,
 * lines, text and the keyboard. Built by `zig build` against the system
 * raylib (see zig/build.zig); examples/breakout uses it.
 *
 * Colors are tables {r, g, b} or {r, g, b, a} with components 0..255.
 * Coordinates and sizes accept ints or doubles.
 */
#include <raylib.h>
#include "slang.h"

/* The color at stack index idx; records an argument error if it is not a
 * color table. */
static Color check_color(slang_State *S, int idx) {
    Color c = {0, 0, 0, 255};
    if (!slang_istable(S, idx)) {
        slang_argerror(S, idx, "color table {r, g, b, a} expected");
        return c;
    }
    unsigned char *parts[4] = {&c.r, &c.g, &c.b, &c.a};
    for (int i = 0; i < 4; i++) {
        slang_rawgeti(S, idx, i);
        if (!slang_isnull(S, -1)) {
            double v = slang_todouble(S, -1);
            if (v < 0) v = 0;
            if (v > 255) v = 255;
            *parts[i] = (unsigned char)v;
        }
        slang_pop(S, 1);
    }
    return c;
}

static int number(slang_State *S, int idx) {
    return (int)slang_checknumber(S, idx);
}

/* ---- window and frame loop ---- */

static int l_init_window(slang_State *S) {
    int w = number(S, 1);
    int h = number(S, 2);
    const char *title = slang_optstring(S, 3, "slang");
    if (slang_failed(S)) return SLANG_ERROR;
    InitWindow(w, h, title);
    return 0;
}

static int l_close_window(slang_State *S) {
    (void)S;
    CloseWindow();
    return 0;
}

static int l_window_should_close(slang_State *S) {
    slang_pushbool(S, WindowShouldClose());
    return 1;
}

static int l_set_target_fps(slang_State *S) {
    int fps = number(S, 1);
    if (slang_failed(S)) return SLANG_ERROR;
    SetTargetFPS(fps);
    return 0;
}

static int l_get_frame_time(slang_State *S) {
    slang_pushdouble(S, GetFrameTime());
    return 1;
}

static int l_get_time(slang_State *S) {
    slang_pushdouble(S, GetTime());
    return 1;
}

static int l_get_screen_width(slang_State *S) {
    slang_pushint(S, GetScreenWidth());
    return 1;
}

static int l_get_screen_height(slang_State *S) {
    slang_pushint(S, GetScreenHeight());
    return 1;
}

static int l_begin_drawing(slang_State *S) {
    (void)S;
    BeginDrawing();
    return 0;
}

static int l_end_drawing(slang_State *S) {
    (void)S;
    EndDrawing();
    return 0;
}

static int l_clear_background(slang_State *S) {
    Color c = check_color(S, 1);
    if (slang_failed(S)) return SLANG_ERROR;
    ClearBackground(c);
    return 0;
}

/* ---- shapes and text ---- */

static int l_draw_rectangle(slang_State *S) {
    int x = number(S, 1), y = number(S, 2), w = number(S, 3), h = number(S, 4);
    Color c = check_color(S, 5);
    if (slang_failed(S)) return SLANG_ERROR;
    DrawRectangle(x, y, w, h, c);
    return 0;
}

static int l_draw_rectangle_lines(slang_State *S) {
    int x = number(S, 1), y = number(S, 2), w = number(S, 3), h = number(S, 4);
    Color c = check_color(S, 5);
    if (slang_failed(S)) return SLANG_ERROR;
    DrawRectangleLines(x, y, w, h, c);
    return 0;
}

static int l_draw_circle(slang_State *S) {
    int x = number(S, 1), y = number(S, 2);
    double r = slang_checknumber(S, 3);
    Color c = check_color(S, 4);
    if (slang_failed(S)) return SLANG_ERROR;
    DrawCircle(x, y, (float)r, c);
    return 0;
}

static int l_draw_line(slang_State *S) {
    int x1 = number(S, 1), y1 = number(S, 2), x2 = number(S, 3), y2 = number(S, 4);
    Color c = check_color(S, 5);
    if (slang_failed(S)) return SLANG_ERROR;
    DrawLine(x1, y1, x2, y2, c);
    return 0;
}

static int l_draw_text(slang_State *S) {
    const char *text = slang_checkstring(S, 1);
    int x = number(S, 2), y = number(S, 3), size = number(S, 4);
    Color c = check_color(S, 5);
    if (slang_failed(S)) return SLANG_ERROR;
    DrawText(text, x, y, size, c);
    return 0;
}

static int l_measure_text(slang_State *S) {
    const char *text = slang_checkstring(S, 1);
    int size = number(S, 2);
    if (slang_failed(S)) return SLANG_ERROR;
    slang_pushint(S, MeasureText(text, size));
    return 1;
}

static int l_draw_fps(slang_State *S) {
    int x = number(S, 1), y = number(S, 2);
    if (slang_failed(S)) return SLANG_ERROR;
    DrawFPS(x, y);
    return 0;
}

/* ---- input ---- */

static int l_is_key_down(slang_State *S) {
    int key = (int)slang_checkint(S, 1);
    if (slang_failed(S)) return SLANG_ERROR;
    slang_pushbool(S, IsKeyDown(key));
    return 1;
}

static int l_is_key_pressed(slang_State *S) {
    int key = (int)slang_checkint(S, 1);
    if (slang_failed(S)) return SLANG_ERROR;
    slang_pushbool(S, IsKeyPressed(key));
    return 1;
}

static const slang_Reg funcs[] = {
    {"init_window", l_init_window},
    {"close_window", l_close_window},
    {"window_should_close", l_window_should_close},
    {"set_target_fps", l_set_target_fps},
    {"get_frame_time", l_get_frame_time},
    {"get_time", l_get_time},
    {"get_screen_width", l_get_screen_width},
    {"get_screen_height", l_get_screen_height},
    {"begin_drawing", l_begin_drawing},
    {"end_drawing", l_end_drawing},
    {"clear_background", l_clear_background},
    {"draw_rectangle", l_draw_rectangle},
    {"draw_rectangle_lines", l_draw_rectangle_lines},
    {"draw_circle", l_draw_circle},
    {"draw_line", l_draw_line},
    {"draw_text", l_draw_text},
    {"measure_text", l_measure_text},
    {"draw_fps", l_draw_fps},
    {"is_key_down", l_is_key_down},
    {"is_key_pressed", l_is_key_pressed},
    {NULL, NULL},
};

static const struct {
    const char *name;
    int value;
} keys[] = {
    {"KEY_LEFT", KEY_LEFT},   {"KEY_RIGHT", KEY_RIGHT}, {"KEY_UP", KEY_UP},
    {"KEY_DOWN", KEY_DOWN},   {"KEY_SPACE", KEY_SPACE}, {"KEY_ENTER", KEY_ENTER},
    {"KEY_ESCAPE", KEY_ESCAPE}, {"KEY_A", KEY_A},       {"KEY_D", KEY_D},
    {"KEY_W", KEY_W},         {"KEY_S", KEY_S},         {"KEY_R", KEY_R},
    {"KEY_P", KEY_P},         {"KEY_Q", KEY_Q},
    {NULL, 0},
};

SLANG_EXTENSION(raylib) {
    slang_newmodule(S, funcs);
    for (int i = 0; keys[i].name; i++) {
        slang_pushint(S, keys[i].value);
        slang_setfield(S, -2, keys[i].name);
    }
    slang_pushstring(S, RAYLIB_VERSION);
    slang_setfield(S, -2, "version");
    return 1;
}
