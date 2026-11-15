// The browser's half of slang/web's messages (zig/src/stdlib/weblib.zig):
// a program and its page talk in text. Built by emcc into the graphics VM
// (website/web/build.sh).
#include <emscripten.h>
#include <stddef.h>

// send(text): the page's Module.onProgramMessage(text), when it has one
EM_JS(void, slang_web_send, (const char *text, size_t len), {
  var s = UTF8ToString(text, len);
  if (Module.onProgramMessage) Module.onProgramMessage(s);
});

// receive(): the oldest text in Module.programInbox, in memory the VM
// frees, or 0
EM_JS(char *, slang_web_receive, (void), {
  var inbox = Module.programInbox;
  if (!inbox || !inbox.length) return 0;
  return stringToNewUTF8(String(inbox.shift()));
});
