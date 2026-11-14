// The binding without a window: math, colors, images, collisions, text and
// how structs and pointers map (run with `make test` in packages/raylib)
local t = require("slang/test")
local ffi = require("slang/ffi")
local rl = require("raylib")

local func near(a, b){
  return a - b < 0.0001 and b - a < 0.0001
}

t.group("raylib: structs are tables"){
  t.test("by name or by position, results by name"){
    local v = rl.vector2.add({1, 2}, {x: 3, y: 4})
    assert(v.x == 4 and v.y == 6)
    local r = rl.collision.rec({0, 0, 10, 10}, {5, 5, 10, 10})
    assert(r.x == 5 and r.width == 5)
    assert(rl.collision.recs({0, 0, 10, 10}, {5, 5, 10, 10}))
    assert(not rl.collision.point_rec({20, 20}, {0, 0, 10, 10}))
  }
  t.test("colors: alpha defaults to 255, constants are raylib's"){
    assert(rl.color.to_int({255, 255, 255}) == rl.color.to_int(rl.WHITE))
    assert(rl.RAYWHITE.r == 245 and rl.RAYWHITE.a == 255)
    local c = rl.color.fade(rl.RED, 0.5)
    assert(c.r == rl.RED.r and c.a == 127)
    assert(rl.KEY_SPACE == 32 and rl.version == "5.5")
    assert(near(rl.PI, 3.14159265))
  }
  t.test("nested structs and matrices"){
    local camera = {
      position: {0, 10, 10}, target: {0, 0, 0}, up: {0, 1, 0}, fovy: 45,
      projection: rl.CAMERA_PERSPECTIVE
    }
    local m = rl.camera.matrix(camera)
    assert(near(m.m0, 1))
    local id = rl.matrix.identity()
    assert(id.m0 == 1 and id.m5 == 1 and id.m1 == 0)
    local q = rl.quaternion.from_euler(0, 0, 0)
    assert(near(q.w, 1))
  }
  t.test("a struct raylib writes is a table it updates"){
    local p = {}
    assert(rl.collision.lines({0, 0}, {10, 10}, {0, 10}, {10, 0}, p))
    assert(p.x == 5 and p.y == 5)
  }
  t.test("a list and its count are one argument"){
    // a square as a polygon: the point is inside
    local square = {{0, 0}, {10, 0}, {10, 10}, {0, 10}}
    assert(rl.collision.point_poly({5, 5}, square))
    assert(not rl.collision.point_poly({15, 5}, square))
    // a buffer is its memory: no conversion
    local points = require("slang/buffer").from(square, "Vector2", rl.decls)
    assert(rl.collision.point_poly({5, 5}, points))
  }
  t.test("argument errors name what was expected"){
    local e = t.raises(func(){ rl.collision.recs("x", {}) })
    assert(
      e.message ==
        "bad argument #1 to 'rl.collision.recs' (Rectangle expected, got string)",
      e.message,
    )
    // a missing argument is null: a struct still has to be given
    e = t.raises(func(){ rl.vector2.add({1, 2}) })
    assert(
      e.message ==
        "bad argument #2 to 'rl.vector2.add' (Vector2 expected, got null)",
      e.message,
    )
  }
}

t.group("raylib: structs that own memory"){
  t.test("images: functions change the table, pointers reach the pixels"){
    local img = rl.image.color(4, 3, rl.RED)
    assert(img.width == 4 and img.height == 3)
    assert(img.format == rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8)
    img:resize(8, 6)
    assert(img.width == 8 and img.height == 6)
    assert(len(img:colors()) == 48)
    assert(len(img:pixel_data()) == 8 * 6 * 4)
    assert(img:pixel(0, 0).g == rl.RED.g)
    // the pixels through a pointer: read and written in place
    local pixels = ffi.cast(img.data, "unsigned char")
    assert(pixels[0] == rl.RED.r)
    local colors = ffi.cast(img.data, "Color", rl.decls)
    colors[1] = rl.BLUE
    assert(img:pixel(1, 0).b == rl.BLUE.b)
    local copy = img:copy()
    copy:crop({0, 0, 2, 2})
    assert(copy.width == 2 and img.width == 8)
    copy:unload()
    img:unload()
  }
}

t.group("raylib: resources are objects"){
  t.test("an image's functions are its methods and properties"){
    local img = rl.image.color(4, 3, rl.RED)
    assert(type(img) == "raylib.Image" and img.valid)
    img:resize(8, 6)
    assert(img.width == 8 and img.height == 6)
    assert(img:pixel(0, 0).r == rl.RED.r)
    local copy = img:copy()
    copy:crop({0, 0, 2, 2})
    assert(copy.width == 2 and img.width == 8)
    assert(len(copy:colors()) == 4)
    img.note = "mine"
    assert(img.note == "mine")
    copy:unload()
    img:unload()
  }
  t.test("waves from samples; cameras with defaults; C's names"){
    local samples = {}
    for(local i = 0; i < 100; i = i + 1){
      append(samples, i / 100)
    }
    local w = rl.wave({samples: samples, sample_rate: 8000})
    assert(type(w) == "raylib.Wave" and w.frame_count == 100 and w.valid)
    local again = w:copy()
    assert(again.sample_rate == 8000)
    again:unload()
    w:unload()
    local cam = rl.camera_3d({position: {0, 2, 5}})
    assert(cam.up.y == 1 and cam.fovy == 45 and type(cam) == "raylib.Camera3D")
    assert(near(cam.matrix.m5, cam.matrix.m5))
    assert(rl.camera_2d().zoom == 1)
    assert(rl.c.KEY_SPACE == 32 and rl.c.ColorToInt(
        rl.WHITE,
      ) == rl.color.to_int(
          rl.WHITE,
        ))
  }
}

t.group("raylib: where the functions are"){
  t.test("namespaces of raylib's families, properties, rl's own"){
    assert(type(rl.window) == "raylib.window" and type(
        rl.draw,
      ) == "raylib.draw")
    assert(type(rl.draw.rectangle) == "function" and type(
        rl.key.pressed,
      ) == "function")
    assert(rl.draw.clear != null and rl.window.open != null)
    // (instances are the package's own; rlgl's functions it uses are not
    // its API, only C's names)
    assert(type(rl.instances) == "function" and type(rl.draw.mesh_instances) == "function")
    assert(rl.rl_enable_depth_mask == null and rl.c.rlEnableDepthMask != null)
    assert(rl.random(5, 5) == 5)
    local seq = rl.random_sequence(4, 0, 3)
    assert(len(seq) == 4)
    rl.random_seed = 7
    local a = rl.random(0, 1000)
    rl.random_seed = 7
    assert(rl.random(0, 1000) == a)
    assert(rl.is_file_extension("a.png", ".png") and rl.file_extension(
        "a.png",
      ) == ".png")
    assert(type(rl.time) == "double")
  }
  t.test("a raylib name that moved says where it went"){
    local e = t.raises(func(){ rl.get_mouse_position() })
    assert(
      e.message == "raylib: rl.get_mouse_position is now rl.mouse.position",
      e.message,
    )
    e = t.raises(func(){ rl.begin_mode_3d() })
    assert(
      e.message == "raylib: rl.begin_mode_3d is now rl.mode_3d(camera){ ... }",
      e.message,
    )
    e = t.raises(func(){ rl.set_window_title("x") })
    assert(
      e.message == "raylib: rl.set_window_title is now rl.window.title = ...",
      e.message,
    )
    assert(rl.no_such_thing == null)
  }
  t.test("a resource's namespace makes one when called"){
    local w = rl.wave({samples: {0.0, 0.5, -0.5}})
    assert(type(w) == "raylib.Wave" and w.frame_count == 3)
    w:unload()
    local img = rl.image.checked(4, 4, 2, 2, rl.WHITE, rl.BLACK)
    assert(img:pixel(0, 0).r == 255 and img:pixel(2, 0).r == 0)
    img:unload()
  }
}

t.group("raylib: text"){
  t.test("strings in, strings out"){
    assert(rl.text.to_upper("abc") == "ABC")
    assert(rl.text.join({"a", "b", "c"}, "-") == "a-b-c")
    assert(rl.text.replace("a-b", "-", "+") == "a+b")
    assert(rl.compute_crc32("hello") == rl.compute_crc32("hello"))
    assert(rl.text.format("%d-%s", 7, "x") == "7-x")
  }
}

t.group("raylib: names"){
  t.test("a font size after a text is passed, not taken for its length"){
    local names = require("raylib/names")
    local param = func(name) => {name: name, type: {kind: "prim"}}
    assert(not names.is_count(param("fontSize")))
    assert(names.is_count(param("dataSize")) and names.is_count(
        param("pointCount"),
      ))
  }
}

t.group("raylib/stream"){
  t.test("a block function in an isolate feeds the device"){
    local stream = require("raylib/stream")
    local time = require("slang/time")
    local player = stream.play(func(){
      return func(out, frames){
        out:fill(0.0)
      }
    })
    // some devices (a headset) take a while to start: up to 3 s for the
    // first callbacks
    local stats = null
    local failure = null
    for(local waited = 0; waited < 3000; waited = waited + 100){
      time.sleep(100)
      try {
        stats = player:stats()
      } catch(local e) {
        failure = e
      }
      if(failure != null or stats.callbacks > 0){
        break
      }
    }
    if(failure != null){
      try {
        player:stop()
      } catch {}
      // no audio device here: nothing more to see
      local str = require("slang/string")
      assert(
        str.index_of(failure.message, "no audio device") >= 0,
        failure.message,
      )
      return null
    }
    player:stop()
    assert(stats.playing and stats.callbacks > 0, "played")
    assert(stats.load >= 0.0 and stats.load < 1.0)
  }
}
