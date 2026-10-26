extension "dsl/dialogue"
local t = require("slang/test")
local dlg = require("engine/dialogue")

test_flags = {}

dialogue test_elder {
  say "Welcome."
  choice {
    "Who are you?" => {
      say "The elder."
      test_flags.asked = true
    }
    "Bye" => { }
  }
  if(test_flags.asked){
    say "Farewell, curious one."
  }
}

t.group("dialogue DSL"){
  t.test("say and choice drive a coroutine"){
    test_flags = {}
    dlg.start("test_elder")
    assert(dlg.active(), "open")
    assert(dlg.current().text == "Welcome.", "first line")
    dlg.confirm()
    local c = dlg.current()
    assert(c.options != null and len(c.options) == 2 and c.options[1] == "Bye", "options")
    dlg.move(1)
    assert(c.selected == 1, "moved")
    dlg.move(1)
    assert(c.selected == 0, "wraps")
    dlg.confirm()
    assert(dlg.current().text == "The elder.", "chosen branch")
    dlg.confirm()
    assert(dlg.current().text == "Farewell, curious one.", "ordinary slang in between")
    dlg.confirm()
    assert(not dlg.active(), "closed at the end")
    assert(test_flags.asked == true, "side effects happened")
  }
  t.test("the other branch"){
    test_flags = {}
    dlg.start("test_elder")
    dlg.confirm()
    dlg.move(1)
    dlg.confirm()
    assert(not dlg.active(), "Bye ends the dialogue")
  }
}
