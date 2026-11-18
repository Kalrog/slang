// Functions of Emscripten itself that packages call through slang/ffi in
// the graphics VM (website/web/build.sh): symbols.slang gives each one
// declared here with EM_API an entry in the table slang/ffi looks names up
// in.
#include <emscripten/html5.h>
#define EM_API

// the size of a canvas's drawing buffer (the gpu package's canvas)
EM_API int emscripten_get_canvas_element_size(const char *target, int *width, int *height);
EM_API int emscripten_set_canvas_element_size(const char *target, int width, int height);
