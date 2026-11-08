// The text editor over the picture: lines of code in the pixel font,
// highlighted by the compiler's tokens, with a cursor, a selection, the
// clipboard and undo.
//
//   local E = editor.new(text)
//   E:update()                      // raylib's typed characters and keys
//   E:draw(x, y, cols, rows, tokens)
//   E:text()
//
// Keys: arrows (shift selects), home, end, page up and down, tab (two
// spaces), enter (keeps the indent), backspace, delete; with the command
// key (control elsewhere): A selects all, C X V copy, cut, paste, Z
// undoes. Clicks and the wheel are the caller's: click(line, col),
// scroll_by(n).
local rl = require("raylib")
local layout = require("layout")
local str = require("slang/string")
local tbl = require("slang/table")

local editor = {}
local methods = {}
local meta = {__index: methods}

editor.CW = 8 // a character cell, at the font's size of 10
editor.CH = 12
editor.FONT_SIZE = 10

// the colors of the tokens' categories
editor.colors = {
  keyword: {200, 140, 255},
  string: {160, 230, 120},
  number: {255, 190, 90},
  comment: {120, 130, 150},
  operator: {255, 130, 170},
  punctuation: {170, 180, 200},
  type: {120, 220, 240},
  ["function.declaration"]: {120, 200, 255},
  macro: {255, 200, 120},
  text: {235, 238, 245},
  cursor: {255, 230, 120},
  selection: {80, 100, 160, 180},
  back: {10, 12, 20, 200},
  gutter: {90, 100, 120},
  error: {255, 90, 90},
}

// new(text: string) -> Editor
func editor.new(text){
  local E = {
    lines: {""}, cx: 0, cy: 0, sel: null, scroll: 0, undo: {}, dirty: false,
    changed: true, rows: 30, line_clip: null, @meta: meta
  }
  E:set_text(text or "")
  E.dirty = false
  return E
}

func methods.set_text(self, text){
  self.lines = str.lines(text)
  if(len(self.lines) == 0 or str.ends_with(text, "\n")){
    append(self.lines, "")
  }
  self.cx = 0
  self.cy = 0
  self.sel = null
  self.scroll = 0
  self.changed = true
  self.dirty = true
}

// text() -> string: the lines joined
func methods.text(self){
  return str.join(self.lines, "\n")
}

local func clamp(v, lo, hi){
  if(v < lo){
    return lo
  }
  if(v > hi){
    return hi
  }
  return v
}

func methods.snapshot(self){
  append(self.undo, {lines: tbl.slice(self.lines), cx: self.cx, cy: self.cy})
  if(len(self.undo) > 200){
    self.undo = tbl.slice(self.undo, 1)
  }
}

func methods.restore(self){
  if(len(self.undo) == 0){
    return
  }
  local u = self.undo[len(self.undo) - 1]
  self.undo = tbl.slice(self.undo, 0, len(self.undo) - 1)
  self.lines = u.lines
  self.cx = u.cx
  self.cy = u.cy
  self.sel = null
  self:touched()
}

func methods.touched(self){
  self.changed = true
  self.dirty = true
  self.cy = clamp(self.cy, 0, len(self.lines) - 1)
  self.cx = clamp(self.cx, 0, len(self.lines[self.cy]))
  self:show_cursor()
}

func methods.show_cursor(self){
  if(self.cy < self.scroll){
    self.scroll = self.cy
  }
  if(self.cy >= self.scroll + self.rows){
    self.scroll = self.cy - self.rows + 1
  }
}

// the selection as {from: {x, y}, to: {x, y}} in order, or null
func methods.selection(self){
  if(self.sel == null){
    return null
  }
  local a = self.sel
  local b = {x: self.cx, y: self.cy}
  if(a.y == b.y and a.x == b.x){
    return null
  }
  if(a.y > b.y or (a.y == b.y and a.x > b.x)){
    return {from: b, to: a}
  }
  return {from: a, to: b}
}

func methods.selection_text(self){
  local s = self:selection()
  if(s == null){
    return ""
  }
  local parts = {}
  for(local y = s.from.y; y <= s.to.y; y = y + 1){
    local line = self.lines[y]
    local x0 = 0
    local x1 = len(line)
    if(y == s.from.y){
      x0 = s.from.x
    }
    if(y == s.to.y){
      x1 = s.to.x
    }
    append(parts, str.substring(line, x0, x1))
  }
  return str.join(parts, "\n")
}

func methods.delete_selection(self){
  local s = self:selection()
  if(s == null){
    self.sel = null
    return false
  }
  local first = str.substring(self.lines[s.from.y], 0, s.from.x)
  local last = str.substring(
    self.lines[s.to.y], s.to.x, len(self.lines[s.to.y])
  )
  local lines = tbl.slice(self.lines, 0, s.from.y)
  append(lines, concat(first, last))
  for(local y = s.to.y + 1; y < len(self.lines); y = y + 1){
    append(lines, self.lines[y])
  }
  self.lines = lines
  self.cx = s.from.x
  self.cy = s.from.y
  self.sel = null
  self:touched()
  return true
}

// insert(s: string): s at the cursor (replacing the selection)
func methods.insert(self, s){
  self:snapshot()
  self:delete_selection()
  local parts = str.split(s, "\n")
  local line = self.lines[self.cy]
  local before = str.substring(line, 0, self.cx)
  local after = str.substring(line, self.cx, len(line))
  if(len(parts) == 1){
    self.lines[self.cy] = concat(before, s, after)
    self.cx = self.cx + len(s)
  } else {
    local lines = tbl.slice(self.lines, 0, self.cy)
    append(lines, concat(before, parts[0]))
    for(local i = 1; i < len(parts) - 1; i = i + 1){
      append(lines, parts[i])
    }
    local last = parts[len(parts) - 1]
    append(lines, concat(last, after))
    for(local y = self.cy + 1; y < len(self.lines); y = y + 1){
      append(lines, self.lines[y])
    }
    self.lines = lines
    self.cy = self.cy + len(parts) - 1
    self.cx = len(last)
  }
  self:touched()
}

local func indent_of(line){
  local n = 0
  for(n < len(line) and str.byte_at(line, n) == 32){
    n = n + 1
  }
  return str.substring(line, 0, n)
}

func methods.newline(self){
  local line = self.lines[self.cy]
  local indent = indent_of(line)
  local before = str.trim_end(str.substring(line, 0, self.cx))
  if(str.ends_with(before, "{") or str.ends_with(before, "(")){
    indent = concat(indent, "  ")
  }
  self:insert(concat("\n", indent))
}

func methods.backspace(self){
  if(self:selection() != null){
    self:snapshot()
    self:delete_selection()
    return
  }
  self.sel = null
  if(self.cx > 0){
    self:snapshot()
    local line = self.lines[self.cy]
    local n = 1
    local before = str.substring(line, 0, self.cx)
    if(len(before) >= 2 and str.trim(before) == "" and self.cx % 2 == 0){
      n = 2
    }
    self.lines[self.cy] = concat(
      str.substring(line, 0, self.cx - n),
      str.substring(line, self.cx, len(line)),
    )
    self.cx = self.cx - n
    self:touched()
  } else if(self.cy > 0){
    self:snapshot()
    local prev = self.lines[self.cy - 1]
    self.cx = len(prev)
    self.lines[self.cy - 1] = concat(prev, self.lines[self.cy])
    remove(self.lines, self.cy)
    self.cy = self.cy - 1
    self:touched()
  }
}

func methods.delete_forward(self){
  if(self:selection() != null){
    self:snapshot()
    self:delete_selection()
    return
  }
  self.sel = null
  local line = self.lines[self.cy]
  if(self.cx < len(line)){
    self:snapshot()
    self.lines[self.cy] = concat(
      str.substring(line, 0, self.cx),
      str.substring(line, self.cx + 1, len(line)),
    )
    self:touched()
  } else if(self.cy < len(self.lines) - 1){
    self:snapshot()
    self.lines[self.cy] = concat(line, self.lines[self.cy + 1])
    remove(self.lines, self.cy + 1)
    self:touched()
  }
}

// move(dx, dy, select: bool): the cursor by characters and lines
func methods.move(self, dx, dy, select){
  if(select){
    if(self.sel == null){
      self.sel = {x: self.cx, y: self.cy}
    }
  } else {
    self.sel = null
  }
  if(dy != 0){
    self.cy = clamp(self.cy + dy, 0, len(self.lines) - 1)
    self.cx = clamp(self.cx, 0, len(self.lines[self.cy]))
  } else if(dx < 0){
    if(self.cx > 0){
      self.cx = self.cx - 1
    } else if(self.cy > 0){
      self.cy = self.cy - 1
      self.cx = len(self.lines[self.cy])
    }
  } else if(dx > 0){
    if(self.cx < len(self.lines[self.cy])){
      self.cx = self.cx + 1
    } else if(self.cy < len(self.lines) - 1){
      self.cy = self.cy + 1
      self.cx = 0
    }
  }
  self:show_cursor()
}

func methods.select_all(self){
  self.sel = {x: 0, y: 0}
  self.cy = len(self.lines) - 1
  self.cx = len(self.lines[self.cy])
}

// ---- the clipboard and comments

// copy_text() -> what a copy takes: the selection, or without one the
// cursor's whole line (with its newline), which paste then puts above the
// line it lands on, as editors do
func methods.copy_text(self){
  local s = self:selection_text()
  if(s != ""){
    self.line_clip = null
    return s
  }
  s = concat(self.lines[self.cy], "\n")
  self.line_clip = s
  return s
}

// cut_text() -> the same, taken out of the text
func methods.cut_text(self){
  local s = self:copy_text()
  self:snapshot()
  if(self.line_clip == null){
    self:delete_selection()
  } else {
    self.sel = null
    if(len(self.lines) > 1){
      remove(self.lines, self.cy)
    } else {
      self.lines[0] = ""
    }
    self.cx = 0
    self:touched()
  }
  return s
}

// paste(s): s at the cursor; a whole line copied here goes in above the
// cursor's line
func methods.paste(self, s){
  s = str.replace(s, "\r\n", "\n")
  if(s == self.line_clip and self:selection() == null){
    self.cx = 0
    self:insert(s)
    self:touched()
    return
  }
  self:insert(s)
}

// the lines a line command works on: the selection's (a selection ending
// at the start of a line leaves that line out), or the cursor's
local func line_range(self){
  local s = self:selection()
  if(s == null){
    return {from: self.cy, to: self.cy}
  }
  local to = s.to.y
  if(s.to.x == 0 and to > s.from.y){
    to = to - 1
  }
  return {from: s.from.y, to: to}
}

// toggle_comment(): the selected lines (or the cursor's) commented out
// with `// ` at their common indent, or, when every one of them is a
// comment already, uncommented; blank lines are left alone
func methods.toggle_comment(self){
  local r = line_range(self)
  local all = true
  local any = false
  local indent = null
  for(local y = r.from; y <= r.to; y = y + 1){
    local line = self.lines[y]
    if(str.trim(line) == ""){
      continue
    }
    any = true
    local n = len(indent_of(line))
    if(indent == null or n < indent){
      indent = n
    }
    if(not str.starts_with(str.trim_start(line), "//")){
      all = false
    }
  }
  if(not any){
    return
  }
  self:snapshot()
  for(local y = r.from; y <= r.to; y = y + 1){
    local line = self.lines[y]
    if(str.trim(line) == ""){
      continue
    }
    local delta = 0
    if(all){
      local lead = len(indent_of(line))
      local rest = str.substring(line, lead + 2, len(line))
      delta = -2
      if(str.starts_with(rest, " ")){
        rest = str.substring(rest, 1, len(rest))
        delta = -3
      }
      self.lines[y] = concat(str.substring(line, 0, lead), rest)
    } else {
      self.lines[y] = concat(
        str.substring(line, 0, indent), "// ", str.substring(line, indent, len(line))
      )
      delta = 3
    }
    // the cursor and the selection's ends keep their place in the text
    if(y == self.cy and self.cx > 0){
      self.cx = clamp(self.cx + delta, 0, len(self.lines[y]))
    }
    if(self.sel != null and y == self.sel.y and self.sel.x > 0){
      self.sel.x = clamp(self.sel.x + delta, 0, len(self.lines[y]))
    }
  }
  self:touched()
}

// click(line, col, select): the cursor to a position
func methods.click(self, line, col, select){
  if(select){
    if(self.sel == null){
      self.sel = {x: self.cx, y: self.cy}
    }
  } else {
    self.sel = null
  }
  self.cy = clamp(line, 0, len(self.lines) - 1)
  self.cx = clamp(col, 0, len(self.lines[self.cy]))
}

func methods.scroll_by(self, n){
  self.scroll = clamp(
    self.scroll + n, 0, clamp(len(self.lines) - self.rows, 0, len(self.lines))
  )
}

local func down(k){
  return rl.key.pressed(k) or rl.key.pressed_repeat(k)
}

// update(): the typed characters and keys of this frame; the command (or
// control) key shortcuts the caller does not take, their letters as the
// keyboard layout places them
func methods.update(self){
  local shift = rl.key.down(rl.KEY_LEFT_SHIFT) or
    rl.key.down(rl.KEY_RIGHT_SHIFT)
  local cmd = rl.key.down(rl.KEY_LEFT_SUPER) or
    rl.key.down(rl.KEY_RIGHT_SUPER) or rl.key.down(rl.KEY_LEFT_CONTROL) or
    rl.key.down(rl.KEY_RIGHT_CONTROL)
  if(cmd){
    if(rl.key.pressed(layout.key("a"))){
      self:select_all()
    } else if(rl.key.pressed(layout.key("c"))){
      rl.clipboard.text = self:copy_text()
    } else if(rl.key.pressed(layout.key("x"))){
      rl.clipboard.text = self:cut_text()
    } else if(rl.key.pressed(layout.key("v"))){
      local s = rl.clipboard.text
      if(s != null and s != ""){
        self:paste(s)
      }
    } else if(rl.key.pressed(layout.key("z"))){
      self:restore()
    } else if(rl.key.pressed(layout.key("k"))){
      // a letter, not the slash: shortcuts are command and a letter only,
      // and the letter as the keyboard layout places it (layout.slang)
      self:toggle_comment()
    }
    for(rl.key.next_char() != 0){ }
    return
  }
  for(local c = rl.key.next_char(); c != 0; c = rl.key.next_char()){
    if(c >= 32 and c < 127){
      self:insert(str.from_bytes({c}))
    } else if(c >= 127){
      self:insert(require("slang/utf8").char(c))
    }
  }
  if(down(rl.KEY_ENTER) or down(rl.KEY_KP_ENTER)){
    self:newline()
  }
  if(down(rl.KEY_TAB)){
    self:insert("  ")
  }
  if(down(rl.KEY_BACKSPACE)){
    self:backspace()
  }
  if(down(rl.KEY_DELETE)){
    self:delete_forward()
  }
  if(down(rl.KEY_LEFT)){
    self:move(-1, 0, shift)
  }
  if(down(rl.KEY_RIGHT)){
    self:move(1, 0, shift)
  }
  if(down(rl.KEY_UP)){
    self:move(0, -1, shift)
  }
  if(down(rl.KEY_DOWN)){
    self:move(0, 1, shift)
  }
  if(down(rl.KEY_HOME)){
    self:move(0, 0, shift)
    self.cx = 0
  }
  if(down(rl.KEY_END)){
    self:move(0, 0, shift)
    self.cx = len(self.lines[self.cy])
  }
  if(down(rl.KEY_PAGE_UP)){
    self:move(0, -self.rows, shift)
  }
  if(down(rl.KEY_PAGE_DOWN)){
    self:move(0, self.rows, shift)
  }
}

// ----------------------------------------------------------------- drawing

local font = null
local offsets = {}

// the font: raylib's own, a pixel font, each glyph centered in its cell
local func load_font(){
  font = rl.font.default
  for(local c = 32; c < 127; c = c + 1){
    local rec = font:glyph_atlas_rec(c)
    offsets[c] = to_int((editor.CW - rec.width) / 2)
  }
}

// glyph(c: int, x, y, color): one character at the font's size
func editor.glyph(c, x, y, color){
  if(font == null){
    load_font()
  }
  local off = offsets[c] or 0
  font:draw_text_codepoint(c, {x + off, y + 1}, editor.FONT_SIZE, color)
}

// text(s, x, y, color): a line of text, a cell per byte
func editor.text(s, x, y, color){
  for(local i = 0; i < len(s); i = i + 1){
    local c = str.byte_at(s, i)
    if(c != 32){
      editor.glyph(c, x + i * editor.CW, y, color)
    }
  }
}

func editor.width(s){
  return len(s) * editor.CW
}

// draw(x, y, cols, rows, tokens, error_line?): the editor's lines, with
// tokens from compiler.highlight ({line, column, length, category},
// 1-based), the error line underlined
func methods.draw(self, x, y, cols, rows, tokens, error_line){
  if(font == null){
    load_font()
  }
  self.rows = rows
  self:show_cursor()
  local C = editor.colors
  local CW = editor.CW
  local CH = editor.CH
  // a color per byte of the visible lines
  local spans = {}
  if(tokens != null){
    for(let local t in values(tokens)){
      local line = t.line - 1
      if(line >= self.scroll and line < self.scroll + rows){
        local color = C[t.category]
        if(color == null){
          local dot = str.index_of(t.category, ".")
          if(dot > 0){
            color = C[str.substring(t.category, 0, dot)]
          }
        }
        if(color != null){
          local s = spans[line]
          if(s == null){
            s = {}
            spans[line] = s
          }
          append(s, {
            from: t.column - 1, to: t.column - 1 + t.length, color: color
          })
        }
      }
    }
  }
  local sel = self:selection()
  local gutter = 3
  for(local r = 0; r < rows; r = r + 1){
    local ly = self.scroll + r
    if(ly >= len(self.lines)){
      break
    }
    local line = self.lines[ly]
    local py = y + r * CH
    local w = (len(line) + gutter + 1) * CW
    rl.draw.rectangle(x, py, w, CH, C.back)
    if(error_line != null and error_line - 1 == ly){
      rl.draw.rectangle(x, py + CH - 2, w, 2, C.error)
    }
    // the selection
    if(sel != null and ly >= sel.from.y and ly <= sel.to.y){
      local x0 = 0
      local x1 = len(line)
      if(ly == sel.from.y){
        x0 = sel.from.x
      }
      if(ly == sel.to.y){
        x1 = sel.to.x
      }
      if(x1 >= x0){
        rl.draw.rectangle(x + (gutter + x0) * CW, py, (x1 - x0) * CW + 2, CH, C.selection)
      }
    }
    // the line number
    local num = string(ly + 1)
    editor.text(num, x + (gutter - 1 - len(num)) * CW, py, C.gutter)
    local s = spans[ly]
    for(local i = 0; i < len(line) and i < cols - gutter; i = i + 1){
      local c = str.byte_at(line, i)
      if(c == 32){
        continue
      }
      local color = C.text
      if(s != null){
        for(let local sp in values(s)){
          if(i >= sp.from and i < sp.to){
            color = sp.color
          }
        }
      }
      editor.glyph(c, x + (gutter + i) * CW, py, color)
    }
    if(ly == self.cy){
      local blink = (to_int(rl.time * 2) % 2) == 0
      if(blink){
        rl.draw.rectangle(x + (gutter + self.cx) * CW, py, 2, CH, C.cursor)
      }
    }
  }
}

// position(x, y, ox, oy) -> {line, col}: the text position under a point
func methods.position(self, x, y, ox, oy){
  local line = self.scroll + to_int((y - oy) / editor.CH)
  local col = to_int((x - ox) / editor.CW + 0.5) - 3
  if(col < 0){
    col = 0
  }
  return {line: line, col: col}
}

return editor
