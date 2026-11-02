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
    local v = rl.vector2_add({1, 2}, {x: 3, y: 4})
    assert(v.x == 4 and v.y == 6)
    local r = rl.get_collision_rec({0, 0, 10, 10}, {5, 5, 10, 10})
    assert(r.x == 5 and r.width == 5)
    assert(rl.check_collision_recs({0, 0, 10, 10}, {5, 5, 10, 10}))
    assert(not rl.check_collision_point_rec({20, 20}, {0, 0, 10, 10}))
  }
  t.test("colors: alpha defaults to 255, constants are raylib's"){
    assert(rl.color_to_int({255, 255, 255}) == rl.color_to_int(rl.WHITE))
    assert(rl.RAYWHITE.r == 245 and rl.RAYWHITE.a == 255)
    local c = rl.fade(rl.RED, 0.5)
    assert(c.r == rl.RED.r and c.a == 127)
    assert(rl.KEY_SPACE == 32 and rl.version == "5.5")
    assert(near(rl.PI, 3.14159265))
  }
  t.test("nested structs and matrices"){
    local camera = {
      position: {0, 10, 10}, target: {0, 0, 0}, up: {0, 1, 0}, fovy: 45,
      projection: rl.CAMERA_PERSPECTIVE
    }
    local m = rl.get_camera_matrix(camera)
    assert(near(m.m0, 1))
    local id = rl.matrix_identity()
    assert(id.m0 == 1 and id.m5 == 1 and id.m1 == 0)
    local q = rl.quaternion_from_euler(0, 0, 0)
    assert(near(q.w, 1))
  }
  t.test("a struct raylib writes is a table it updates"){
    local p = {}
    assert(rl.check_collision_lines({0, 0}, {10, 10}, {0, 10}, {10, 0}, p))
    assert(p.x == 5 and p.y == 5)
  }
  t.test("a list and its count are one argument"){
    // a square as a polygon: the point is inside
    local square = {{0, 0}, {10, 0}, {10, 10}, {0, 10}}
    assert(rl.check_collision_point_poly({5, 5}, square))
    assert(not rl.check_collision_point_poly({15, 5}, square))
    // a buffer is its memory: no conversion
    local points = require("slang/buffer").from(square, "Vector2", rl.decls)
    assert(rl.check_collision_point_poly({5, 5}, points))
  }
  t.test("argument errors name what was expected"){
    local r = pcall(rl.check_collision_recs, "x", {})
    assert(r[0] == "err")
    assert(
      r[1].message ==
        "bad argument #1 to 'check_collision_recs' (Rectangle expected, got string)",
      r[1].message,
    )
    r = pcall(rl.vector2_add, {1, 2})
    assert(
      r[0] == "err" and r[1].message == "vector2_add takes 2 arguments, got 1",
    )
  }
}

t.group("raylib: structs that own memory"){
  t.test("images: functions change the table, pointers reach the pixels"){
    local img = rl.gen_image_color(4, 3, rl.RED)
    assert(img.width == 4 and img.height == 3)
    assert(img.format == rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8)
    rl.image_resize(img, 8, 6)
    assert(img.width == 8 and img.height == 6)
    assert(len(rl.load_image_colors(img)) == 48)
    assert(len(rl.get_image_data(img)) == 8 * 6 * 4)
    assert(rl.get_image_color(img, 0, 0).g == rl.RED.g)
    // the pixels through a pointer: read and written in place
    local pixels = ffi.cast(img.data, "unsigned char")
    assert(pixels[0] == rl.RED.r)
    local colors = ffi.cast(img.data, "Color", rl.decls)
    colors[1] = rl.BLUE
    assert(rl.get_image_color(img, 1, 0).b == rl.BLUE.b)
    local copy = rl.image_copy(img)
    rl.image_crop(copy, {0, 0, 2, 2})
    assert(copy.width == 2 and img.width == 8)
    rl.unload_image(copy)
    rl.unload_image(img)
  }
}

t.group("raylib: resources are objects"){
  t.test("an image's functions are its methods and properties"){
    local img = rl.gen_image_color(4, 3, rl.RED)
    assert(type(img) == "raylib.Image" and img.valid)
    img:resize(8, 6)
    assert(img.width == 8 and img.height == 6)
    assert(img:get_color(0, 0).r == rl.RED.r)
    local copy = img:copy()
    copy:crop({0, 0, 2, 2})
    assert(copy.width == 2 and img.width == 8)
    assert(len(copy:load_colors()) == 4)
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
    assert(near(rl.get_camera_matrix(cam).m5, rl.get_camera_matrix(cam).m5))
    assert(rl.camera_2d().zoom == 1)
    assert(rl.c.KEY_SPACE == 32 and rl.c.ColorToInt(rl.WHITE) == rl.color_to_int(rl.WHITE))
  }
}

t.group("raylib: text"){
  t.test("strings in, strings out"){
    assert(rl.text_to_upper("abc") == "ABC")
    assert(rl.text_join({"a", "b", "c"}, "-") == "a-b-c")
    assert(rl.text_replace("a-b", "-", "+") == "a+b")
    assert(rl.compute_crc32("hello") == rl.compute_crc32("hello"))
    assert(rl.text_format("%d-%s", 7, "x") == "7-x")
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
    time.sleep(0.3)
    local r = pcall(func(){ return player:stats() })
    local stopped = pcall(func(){ player:stop() })
    if(r[0] == "err"){
      // no audio device here: nothing more to see
      local str = require("slang/string")
      assert(str.index_of(r[1].message, "no audio device") >= 0, r[1].message)
      return null
    }
    assert(stopped[0] == "ok", "stopped")
    assert(r[1].playing and r[1].callbacks > 0, "played")
    assert(r[1].load >= 0.0 and r[1].load < 1.0)
  }
}
