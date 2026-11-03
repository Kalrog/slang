// game/editor: the deck's input line. Text with a cursor, several lines
// (Shift+Enter), and a history (Up and Down). Pure: main.slang turns keys
// into calls, test/editor_test.slang checks it.
local str = require("slang/string")

local editor = {}

local Editor = {}
// the metatable of every editor (not Editor.@meta: that would be Editor's own)
local editor_meta = {__index: Editor}

// new() -> an empty editor
func editor.new(){
  return {
    text: "", cursor: 0, history: {}, browsing: null, draft: "",
    @meta: editor_meta
  }
}

// insert(s): text at the cursor
func Editor.insert(self, s){
  self.text = concat(
    str.substring(self.text, 0, self.cursor),
    s,
    str.substring(self.text, self.cursor),
  )
  self.cursor = self.cursor + len(s)
}

// backspace(): deletes before the cursor
func Editor.backspace(self){
  if(self.cursor > 0){
    self.text = concat(
      str.substring(self.text, 0, self.cursor - 1),
      str.substring(self.text, self.cursor),
    )
    self.cursor = self.cursor - 1
  }
}

// delete(): deletes after the cursor
func Editor.delete(self){
  if(self.cursor < len(self.text)){
    self.text = concat(
      str.substring(self.text, 0, self.cursor),
      str.substring(self.text, self.cursor + 1),
    )
  }
}

func Editor.left(self){
  if(self.cursor > 0){
    self.cursor = self.cursor - 1
  }
}

func Editor.right(self){
  if(self.cursor < len(self.text)){
    self.cursor = self.cursor + 1
  }
}

// home(), end_(): to the start or end of the cursor's line
func Editor.home(self){
  for(self.cursor > 0 and str.byte_at(self.text, self.cursor - 1) != 10){
    self.cursor = self.cursor - 1
  }
}

func Editor.end_(self){
  for(self.cursor < len(self.text) and str.byte_at(self.text, self.cursor) != 10){
    self.cursor = self.cursor + 1
  }
}

// set(text): replaces the text, cursor at the end
func Editor.set(self, text){
  self.text = text
  self.cursor = len(text)
}

// up(), down(): through the history; the text being written is kept as a
// draft below the newest entry
func Editor.up(self){
  local n = len(self.history)
  if(n == 0){
    return
  }
  if(self.browsing == null){
    self.draft = self.text
    self.browsing = n
  }
  if(self.browsing > 0){
    self.browsing = self.browsing - 1
    self:set(self.history[self.browsing])
  }
}

func Editor.down(self){
  if(self.browsing == null){
    return
  }
  self.browsing = self.browsing + 1
  if(self.browsing >= len(self.history)){
    self.browsing = null
    self:set(self.draft)
  } else {
    self:set(self.history[self.browsing])
  }
}

// take() -> the text, which goes into the history; the editor is emptied
func Editor.take(self){
  local text = self.text
  local n = len(self.history)
  if(str.trim(text) != "" and (n == 0 or self.history[n - 1] != text)){
    append(self.history, text)
  }
  self.browsing = null
  self.draft = ""
  self:set("")
  return text
}

// lines() -> the text as lines, and {line, column} of the cursor
func Editor.lines(self){
  local lines = str.split(self.text, "\n")
  local line = 0
  local column = 0
  for(local i = 0; i < self.cursor; i = i + 1){
    if(str.byte_at(self.text, i) == 10){
      line = line + 1
      column = 0
    } else {
      column = column + 1
    }
  }
  return {lines: lines, line: line, column: column}
}

return editor
