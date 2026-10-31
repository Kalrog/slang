// the deck's input line
local t = require("slang/test")
local editor = require("game/editor")

t.group("editor"){
  t.test("typing, moving and deleting"){
    local e = editor.new()
    e:insert("door1.open()")
    e:left()
    e:insert("3")
    assert(e.text == "door1.open(3)")
    e:backspace()
    e:backspace()
    assert(e.text == "door1.open)")
    e:home()
    e:delete()
    assert(e.text == "oor1.open)" and e.cursor == 0)
    e:end_()
    assert(e.cursor == len(e.text))
  }
  t.test("lines and the cursor's place in them"){
    local e = editor.new()
    e:insert("cam1.off(2)\nwait(1)")
    local v = e:lines()
    assert(len(v.lines) == 2 and v.line == 1 and v.column == 7)
    e:home()
    assert(e:lines().column == 0 and e:lines().line == 1)
  }
  t.test("history: up recalls, down returns to the draft"){
    local e = editor.new()
    e:insert("a")
    assert(e:take() == "a")
    e:insert("b")
    e:take()
    e:insert("dra")
    e:up()
    assert(e.text == "b")
    e:up()
    assert(e.text == "a")
    e:up()
    assert(e.text == "a")
    e:down()
    e:down()
    assert(e.text == "dra")
  }
  t.test("blank and repeated entries stay out of the history"){
    local e = editor.new()
    e:take()
    e:insert("x")
    e:take()
    e:insert("x")
    e:take()
    assert(len(e.history) == 1)
  }
}
