// The pattern on the screen: which tracks and rows fit, what is where
// (for the mouse), and the drawing of headers, cells, the selection, the
// cursor and the playhead.
local math = require("slang/math")
local song = require("song")
local grid = require("grid")
local gfx = require("gfx")

local view = {}

local CW = gfx.CW
local CH = gfx.CH
local C = gfx.colors

view.NUMBERS = 3 // characters of the row numbers
view.HEADER = 2 // lines of the tracks' headers

// layout(A, x, y, w, h) -> where things are: the tracks that fit from
// A.first_track on ({t, x, w} in pixels), the rows shown
func view.layout(A, x, y, w, h){
  local s = A.song
  local rows = s.patterns[grid.pattern(A)].rows
  local lines = to_int((h - view.HEADER * CH) / CH)
  local L = {
    x: x,
    y: y,
    w: w,
    h: h,
    top: y + view.HEADER * CH,
    lines: lines,
    first_row: 0,
    rows: rows,
    tracks: {},
  }
  // the cursor's track in view
  if(A.cursor.t < A.first_track){
    A.first_track = A.cursor.t
  }
  for(true){
    L.tracks = {}
    local at = x + view.NUMBERS * CW
    local seen = false
    for(local t = A.first_track; t < len(s.tracks); t = t + 1){
      local tw = grid.width_of(s.tracks[t]) * CW
      if(at + tw - CW > x + w and len(L.tracks) > 0){
        break
      }
      append(L.tracks, {t: t, x: at, w: tw})
      if(t == A.cursor.t){
        seen = true
      }
      at = at + tw
    }
    if(seen or A.first_track >= A.cursor.t){
      break
    }
    A.first_track = A.first_track + 1
  }
  // a pattern longer than the view scrolls with the row to keep in view
  if(rows > lines){
    local keep = A.cursor.row
    if(A.follow and A.play_row != null){
      keep = A.play_row
    }
    L.first_row = math.clamp(keep - to_int(lines / 2), 0, rows - lines)
  }
  return L
}

// hit(A, L, mx, my) -> {t, f, row} of the cell at a point, {t} for a
// track's header, or null
func view.hit(A, L, mx, my){
  for(let local tr in values(L.tracks)){
    if(mx >= tr.x and mx < tr.x + tr.w){
      if(my >= L.y and my < L.top){
        return {
          t: tr.t, header: true, x: mx - tr.x, line: to_int((my - L.y) / CH)
        }
      }
      local row = L.first_row + to_int((my - L.top) / CH)
      if(my < L.top or row >= L.rows or row - L.first_row >= L.lines){
        return null
      }
      local fs = grid.fields_of(A.song.tracks[tr.t])
      local cx = to_int((mx - tr.x) / CW)
      local f = len(fs) - 1
      for(local i = 0; i < len(fs); i = i + 1){
        if(cx < fs[i].x + fs[i].w){
          f = i
          break
        }
      }
      return {t: tr.t, f: f, row: row}
    }
  }
  return null
}

// draw(A, L): the headers, the rows, the selection, the cursor and the
// playhead
func view.draw(A, L){
  local s = A.song
  local p = grid.pattern(A)
  local pat = s.patterns[p]
  local r = grid.range(A)
  local selecting = A.anchor != null
  local bar_rows = s.lpb * 4
  // the rows' backgrounds
  for(local line = 0; line < L.lines; line = line + 1){
    local row = L.first_row + line
    if(row >= pat.rows){
      break
    }
    local y = L.top + line * CH
    local back = null
    if(row % bar_rows == 0){
      back = C.bar
    } else if(row % s.lpb == 0){
      back = C.beat
    }
    if(row == A.cursor.row){
      back = C.cursor_row
    }
    if(A.play_row == row and A.play_pattern == p){
      back = C.play
    }
    if(back != null){
      gfx.rect(L.x, y, L.w, CH, back)
    }
    local number = song.two(row)
    local color = C.faint
    if(row % s.lpb == 0){
      color = C.dim
    }
    gfx.text(number, L.x, y, color)
  }
  for(let local tr in values(L.tracks)){
    local t = tr.t
    local track = s.tracks[t]
    local hue = gfx.hue(t)
    local current = t == A.cursor.t
    // the header: the name on its color, then the instrument and a meter
    local head = gfx.shade(hue, if(current){ 0.55 } else { 0.3 })
    gfx.rect(tr.x, L.y, tr.w - CW, CH, head)
    gfx.text(gfx.fit(track.name, to_int(tr.w / CW) - 3), tr.x + 2, L.y, C.title)
    if(track.mute){
      gfx.right("M", tr.x + tr.w - CW - 1, L.y, C.bad)
    }
    local strip = A.P.tracks[t]
    local level = 0.0
    if(strip != null){
      local pk = strip.peak
      level = math.max(pk.left, pk.right)
    }
    gfx.text(
      gfx.fit(track.unit, 5),
      tr.x + 2,
      L.y + CH,
      if(current){ hue } else { C.dim },
    )
    local mx = tr.x + 6 * CW
    local mw = tr.w - CW - 6 * CW - 2
    if(mw > 6){
      gfx.bar(
        mx, L.y + CH + 4, mw, 4, math.sqrt(level), gfx.shade(hue, 0.9), C.line
      )
    }
    // the cells
    local fs = grid.fields_of(track)
    local d = pat.data[t]
    for(local line = 0; line < L.lines; line = line + 1){
      local row = L.first_row + line
      if(row >= pat.rows){
        break
      }
      local y = L.top + line * CH
      for(local f = 0; f < len(fs); f = f + 1){
        local fd = fs[f]
        local x = tr.x + fd.x * CW
        if(selecting and row >= r.r0 and row <= r.r1){
          local gi = -1
          for(local i = r.f0; i <= r.f1; i = i + 1){
            if(r.fields[i].t == t and r.fields[i].f == f){
              gi = i
            }
          }
          if(gi >= 0){
            gfx.rect(x - 1, y, fd.w * CW + 2, CH, C.select)
          }
        }
        if(current and f == A.cursor.f and row == A.cursor.row){
          gfx.rect(x - 1, y, fd.w * CW + 2, CH, C.cursor)
        }
        local on_cursor = current and f == A.cursor.f and row == A.cursor.row
        if(fd.kind == "note"){
          local n = d.notes[fd.col][row]
          local color = C.faint
          if(n != null){
            color = if(n == song.OFF){ C.off } else { C.note }
          }
          local text = song.note_name(n)
          if(track.unit == "drums" and n != null and n >= 0){
            // a drums track shows its drums; a note that plays none is
            // a warning
            local drum = song.drum_name(n)
            if(drum != null){
              text = drum
            } else {
              color = C.bad
            }
          }
          if(on_cursor){
            color = C.back
          }
          gfx.text(text, x, y, color)
        } else if(fd.kind == "vel"){
          local v = d.vels[fd.col][row]
          local color = if(v == null){ C.faint } else { C.vel }
          if(on_cursor){
            color = C.back
          }
          gfx.text(song.two(v), x, y, color)
        } else {
          local v = d.fx[row]
          local color = if(v == null){ C.faint } else { C.fx }
          if(track.lane == null){
            color = gfx.shade(C.faint, 0.6)
          }
          if(on_cursor){
            color = C.back
          }
          gfx.text(song.two(v), x, y, color)
        }
      }
    }
    // a line between tracks
    gfx.rect(
      tr.x + tr.w - to_int(CW / 2) - 1, L.top, 1,
      math.min(L.lines, pat.rows) * CH, C.line
    )
  }
  // more tracks than fit: say so at the edges
  if(A.first_track > 0){
    gfx.text("<", L.x + view.NUMBERS * CW - CW, L.y, C.warn)
  }
  if(len(L.tracks) > 0 and L.tracks[len(L.tracks) - 1].t < len(s.tracks) - 1){
    gfx.right(">", L.x + L.w, L.y, C.warn)
  }
}

return view
