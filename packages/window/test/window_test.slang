// Windows without looking at them: hidden windows, their properties,
// events, input state and names (run with `slang test test` in
// packages/window)
local t = require("slang/test")
local window = require("window")

t.group("window: windows"){
  t.test("a hidden window has its size, title and native handle"){
    local win = window.open({
      title: "test", width: 320, height: 200, hidden: true
    })
    assert(type(win) == "window.Window")
    assert(win.open)
    assert(win.size == {320, 200}, win.size)
    assert(win.width == 320 and win.height == 200)
    local px = win.pixel_size
    assert(px[0] == 320 * win.pixel_density, px)
    assert(win.title == "test")
    win.title = "renamed"
    assert(win.title == "renamed")
    local native = win.native
    assert(type(native.kind) == "string")
    win:close()
    assert(not win.open)
    win:close()
  }
  t.test("a closed window raises when used"){
    local win = window.open({hidden: true})
    win:close()
    t.raises(func(){
      return win.size
    }, "window: the window is closed")
  }
  t.test("settable size and resizable"){
    local win = window.open({hidden: true, resizable: true})
    assert(win.resizable)
    win.size = {500, 400}
    assert(win.size == {500, 400})
    win.resizable = false
    assert(not win.resizable)
    win:close()
  }
  t.test("events are tables with a type"){
    local win = window.open({hidden: true})
    for(let local e in values(window.events())){
      assert(type(e.type) == "string")
    }
    win:close()
  }
}

t.group("window: input"){
  t.test("keys are named in lower case"){
    assert(window.key_down("w") == false)
    assert(window.key_down("left_shift") == false)
    assert(window.key_down("space") == false)
    t.raises(func(){
      window.key_down("no such key")
    }, "window: no key named no such key")
  }
  t.test("mouse and modifiers"){
    local m = window.mouse()
    assert(type(m.x) == "double" and type(m.left) == "bool")
    assert(type(window.mouse_down("left")) == "bool")
    assert(type(window.mods().shift) == "bool")
  }
  t.test("gamepads are a list"){
    assert(raw_type(window.gamepads()) == "table")
  }
}

t.group("window: the rest"){
  t.test("version and screen"){
    assert(require("slang/string").starts_with(window.version(), "3."))
    local s = window.screen()
    assert(s.width > 0 and s.height > 0 and s.refresh_rate >= 0)
  }
  t.test("the clipboard holds text"){
    local before = window.clipboard
    window.clipboard = "slang window test"
    assert(window.clipboard == "slang window test")
    window.clipboard = before
  }
}
