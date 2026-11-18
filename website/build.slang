// The website: `bin/slang run website/build.slang [out]` (or `make website`)
// writes a static site to website/out (or out): the home page, the tour
// (website/tour), the guides (website/guide), the playground, the API docs
// of slang's library (slang doc's pages in the site's layout) and
// website/pages. Code samples are highlighted here, by the real parser.
// The playground runs slang.wasm (`make wasm`) in the browser.
//
// A tour page is a slang program whose leading comment block is its title
// (the first line) and its text (the rest, in doc comment notation); the
// code below it is the page's runnable example.
local os = require("slang/os")
local str = require("slang/string")
local json = require("slang/json")
local encoding = require("slang/encoding")
local compiler = require("slang/compiler")
local doc = require("slang/doc")
local tbl = require("slang/table")

local here = "website"
local out = args()[0] or concat(here, "/out")
local REPO = "https://github.com/Kalrog/slang"

local func escape(s){
  s = str.replace(s, "&", "&amp;")
  s = str.replace(s, "<", "&lt;")
  s = str.replace(s, ">", "&gt;")
  return str.replace(s, "\"", "&quot;")
}

// ------------------------------------------------------------ highlighting

// code as HTML with a span per token, classed by its category (t-keyword,
// t-string, ...; a category's modifiers are dropped). With a prefix (an
// extension statement) the code is parsed after it, and shown without it.
local func highlight(code, prefix){
  prefix = prefix or ""
  compiler.reset()
  // code that does not parse is shown as it is
  local h = try {
    compiler.highlight(concat(prefix, code), "example.slang")
  } catch { null }
  if(h == null){
    return escape(code)
  }
  local parts = {}
  local shift = len(prefix)
  local pos = 0
  for(let local tk in values(h.tokens)){
    local t = {
      category: tk.category,
      start: tk.start - shift,
      stop: tk.stop - shift,
    }
    if(t.start >= pos){
      append(parts, escape(str.substring(code, pos, t.start)))
      local kind = str.split(t.category, ".")[0]
      append(parts, concat(
        "<span class=\"t-",
        kind,
        "\">",
        escape(str.substring(code, t.start, t.stop)),
        "</span>",
      ))
      pos = t.stop
    }
  }
  append(parts, escape(str.substring(code, pos)))
  return str.join(parts, "")
}

// a static, highlighted code block
local func code_block(code){
  return concat("<pre class=\"code\"><code>", highlight(code), "</code></pre>")
}

// whether code parses when it follows prefix
local func parses(code, prefix){
  compiler.reset()
  local h = try {
    compiler.highlight(concat(prefix, code), "example.slang")
  } catch { null }
  if(h == null){
    return false
  }
  for(let local d in values(h.diagnostics or {})){
    if(d.severity == "error"){
      return false
    }
  }
  return true
}

// a highlighted code block of a sample that has to parse, as a program or
// as an expression (a slang.project is a table literal); null when it
// does neither
local func checked_block(code){
  for(let local prefix in values({"", "return "})){
    if(parses(code, prefix)){
      return concat(
        "<pre class=\"code\"><code>",
        highlight(code, prefix),
        "</code></pre>",
      )
    }
  }
  return null
}

// an editor with code in it, highlighted already; what the page's script
// makes live (data-editor), with a Run button and an output pane. Options:
// format, reset and open (buttons); class; prefix, a line the code runs
// after unseen (an extension statement); expanded, the code's expansion,
// for an Example / Expanded toggle, or true for a Code / Expanded toggle
// that expands in the browser when opened.
local func editor(code, options){
  options = options or {}
  local tools = {
    "<button class=\"btn run\" data-run title=\"Ctrl+Enter\">Run</button>",
  }
  if(options.format){
    append(tools, "<button class=\"btn\" data-format>Format</button>")
  }
  if(options.reset){
    append(tools, "<button class=\"btn ghost\" data-reset>Reset</button>")
  }
  if(options.open){
    append(tools, concat(
      "<a class=\"btn ghost\" data-open href=\"",
      options.open,
      "\">Open in playground</a>",
    ))
  }
  local tabs = ""
  if(options.expanded != null){
    local lazy = options.expanded == true
    tabs = concat(
      "<div class=\"tabs\" role=\"tablist\">",
      "<button role=\"tab\" aria-selected=\"true\" data-tab=\"code\">",
      lazy and "Code" or "Example",
      "</button>",
      "<button role=\"tab\" aria-selected=\"false\" data-tab=\"expanded\">Expanded</button>",
      "</div><pre class=\"code expanded-view\" data-expanded",
      lazy and "=\"lazy\"" or "",
      " hidden><code>",
      lazy and "" or highlight(options.expanded),
      "</code></pre>",
    )
  }
  return concat(
    "<div class=\"workbench",
    options.class and concat(" ", options.class) or "",
    "\" data-workbench",
    options.prefix and concat(" data-prefix=\"", escape(options.prefix), "\"") or
      "",
    ">",
    tabs,
    "<div class=\"editor\" data-editor><pre class=\"ed-hl\" aria-hidden=\"true\"><code>",
    highlight(code, options.prefix),
    "\n</code></pre><textarea class=\"ed-input\" spellcheck=\"false\" ",
    "wrap=\"off\" rows=\"",
    string(len(str.split(code, "\n"))),
    "\" ",
    "autocapitalize=\"off\" autocomplete=\"off\" aria-label=\"Code\">",
    escape(code),
    "</textarea></div>",
    "<div class=\"problems\" data-problems></div>",
    "<div class=\"tools\">",
    str.join(tools, ""),
    "<span class=\"status\" data-status></span></div>",
    "<pre class=\"output\" data-output aria-live=\"polite\"></pre>",
    "</div>",
  )
}

// ------------------------------------------------------------ layout

local NAV = {
  {key: "install", href: "guide/install.html", label: "Install"},
  {key: "tour", href: "tour/", label: "Tour"},
  {key: "docs", href: "docs/", label: "Docs"},
  {key: "play", href: "play/", label: "Playground"},
  // (the page itself is made by the notebook package: see the Makefile's
  // website target)
  {key: "notebook", href: "notebook/", label: "Notebook"},
}

// page(o: {title, body, root, section?, kind?, description?}) -> string
// [root]: the way back to the site's root from the page ("", "../")
// [kind]: the body's class: "home", "tour", "play" or "docs"
local func page(o){
  local links = {}
  for(let local n in values(NAV)){
    append(links, concat(
      "<a href=\"",
      o.root,
      n.href,
      "\"",
      o.section == n.key and " aria-current=\"page\"" or "",
      ">",
      n.label,
      "</a>",
    ))
  }
  // (the footer has the link too: narrow screens show it only there)
  append(links, concat("<a class=\"ext\" href=\"", REPO, "\">GitHub</a>"))
  return concat(
    "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n",
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n",
    "<title>",
    escape(o.title),
    "</title>\n",
    "<meta name=\"description\" content=\"",
    escape(
      o.description or "Slang, a small scripting language you can extend.",
    ),
    "\">\n",
    "<link rel=\"icon\" href=\"",
    o.root,
    "assets/logo.svg\" type=\"image/svg+xml\">\n",
    "<link rel=\"preconnect\" href=\"https://fonts.googleapis.com\">\n",
    "<link rel=\"preconnect\" href=\"https://fonts.gstatic.com\" crossorigin>\n",
    "<link rel=\"stylesheet\" href=\"https://fonts.googleapis.com/css2?",
    "family=Bricolage+Grotesque:opsz,wght@12..96,500..800&",
    "family=JetBrains+Mono:wght@400;600&display=swap\">\n",
    "<link rel=\"stylesheet\" href=\"",
    o.root,
    "assets/style.css\">\n",
    "<script type=\"module\" src=\"",
    o.root,
    "assets/site.js\"></script>\n",
    "</head>\n<body class=\"",
    o.kind or "",
    "\" data-root=\"",
    o.root,
    "\">\n",
    "<header class=\"top\"><a class=\"brand\" href=\"",
    o.root,
    "./\">",
    "<img src=\"",
    o.root,
    "assets/logo.svg\" alt=\"\" width=\"28\" height=\"28\">",
    "<span>slang</span></a><nav>",
    str.join(links, ""),
    "</nav></header>\n",
    o.body,
    "\n<footer class=\"bottom\"><span>slang — a small language you can ",
    "extend.</span><span><a href=\"",
    REPO,
    "\">Source on GitHub</a></span>",
    "</footer>\n</body>\n</html>\n",
  )
}

local func write(path, text){
  local full = concat(out, "/", path)
  local slash = len(full) - 1
  for(str.byte_at(full, slash) != 47){
    slash = slash - 1
  }
  os.mkdir_all(str.substring(full, 0, slash))
  os.write_file(full, text)
}

// a list of strings in order
local func sorted(list){
  return tbl.sort(tbl.slice(list))
}

// ------------------------------------------------------------ the tour

// a tour page from its file: {slug, title, text, code}
local func tour_page(file){
  local source = os.read_file(concat(here, "/tour/", file))
  local lines = str.split(source, "\n")
  local comment = {}
  local i = 0
  for(i < len(lines) and str.starts_with(lines[i], "//")){
    local l = str.substring(lines[i], 2)
    if(str.starts_with(l, " ")){
      l = str.substring(l, 1)
    }
    append(comment, l)
    i = i + 1
  }
  local code = {}
  for(; i < len(lines); i = i + 1){
    append(code, lines[i])
  }
  local slug = str.substring(file, 3, len(file) - 6)
  local text = {}
  for(local k = 1; k < len(comment); k = k + 1){
    append(text, comment[k])
  }
  return {
    slug: slug,
    title: comment[0],
    text: str.trim(str.join(text, "\n")),
    code: str.trim(str.join(code, "\n")),
  }
}

local func tour_pages(){
  local files = {}
  for(let local f in values(os.list_dir(concat(here, "/tour")))){
    if(str.ends_with(f, ".slang")){
      append(files, f)
    }
  }
  local pages = {}
  for(let local f in values(sorted(files))){
    append(pages, tour_page(f))
  }
  return pages
}

local func build_tour(pages){
  for(local i = 0; i < len(pages); i = i + 1){
    local p = pages[i]
    local steps = {}
    for(local k = 0; k < len(pages); k = k + 1){
      append(steps, concat(
        "<li",
        k == i and " aria-current=\"step\"" or "",
        "><a href=\"",
        pages[k].slug,
        ".html\"><span class=\"num\">",
        string(k + 1),
        "</span>",
        escape(pages[k].title),
        "</a></li>",
      ))
    }
    local prev = i > 0 and concat(
        "<a class=\"btn ghost\" href=\"",
        pages[i - 1].slug,
        ".html\">← ",
        escape(pages[i - 1].title),
        "</a>",
      ) or "<span></span>"
    local next = i + 1 < len(pages) and concat(
        "<a class=\"btn\" href=\"",
        pages[i + 1].slug,
        ".html\">",
        escape(pages[i + 1].title),
        " →</a>",
      ) or "<a class=\"btn\" href=\"../guide/install.html\">Install slang →</a>"
    local body = concat(
      "<main class=\"tour-main\">",
      "<aside class=\"tour-steps\"><details open><summary>Tour · ",
      string(i + 1),
      " of ",
      string(len(pages)),
      "</summary><ol>",
      str.join(steps, ""),
      "</ol></details></aside>",
      "<article class=\"tour-text\"><p class=\"kicker\">Step ",
      string(i + 1),
      "</p><h1>",
      escape(p.title),
      "</h1>",
      doc.blocks_html(p.text),
      "<div class=\"pager\">",
      prev,
      next,
      "</div></article>",
      "<section class=\"tour-code\">",
      editor(p.code, {format: true, reset: true, open: "../play/"}),
      "</section></main>",
    )
    write(concat("tour/", p.slug, ".html"), page({
      title: concat(p.title, " · slang tour"),
      body: body,
      root: "../",
      section: "tour",
      kind: "tour",
    }))
  }
  // the tour's address opens its first page
  write("tour/index.html", concat(
    "<!doctype html><meta charset=\"utf-8\"><title>slang tour</title>",
    "<meta http-equiv=\"refresh\" content=\"0; url=",
    pages[0].slug,
    ".html\"><a href=\"",
    pages[0].slug,
    ".html\">The tour</a>",
  ))
}

// ------------------------------------------------------------ playground

local GRAPHICS_EXAMPLES = {
  {title: "Breakout (raylib, sound)", path: "examples/breakout/main.slang"},
  {title: "3D cubes (raylib)", path: "packages/raylib/examples/cubes.slang"},
  {
    title: "Sparks: the mouse (raylib)",
    path: "packages/raylib/examples/sparks.slang",
  },
  {
    title: "3D terrain (raylib)",
    path: "packages/raylib/examples/terrain.slang",
  },
  {title: "Boxes: 2D physics (Box2D)", path: "examples/physics/boxes.slang"},
  {title: "Tower: 3D physics (Jolt)", path: "examples/physics/tower.slang"},
  // (on the browser's WebGPU: not every browser has it yet)
  {title: "Triangle (gpu: WebGPU)", path: "examples/gpu/triangle.slang"},
  {title: "Lit cube (gpu: WebGPU)", path: "examples/gpu/cube.slang"},
  {title: "Ripples (gpu: a wgsl block)", path: "examples/gpu/waves.slang"},
}

// every extension in extensions/ by path, as the playground's VM finds
// them next to main.slang
local func extension_files(){
  local files = {}
  for(let local f in values(sorted(os.list_dir("extensions")))){
    if(str.ends_with(f, ".slang")){
      local path = concat("extensions/", f)
      files[path] = os.read_file(path)
    }
  }
  return files
}

local func build_playground(pages){
  local examples = {}
  for(let local p in values(pages)){
    append(examples, {title: p.title, code: p.code})
  }
  // the examples that draw, as they are in the repository (the playground
  // runs them on its graphics VM)
  for(let local e in values(GRAPHICS_EXAMPLES)){
    append(examples, {title: e.title, code: os.read_file(e.path)})
  }
  for(let local f in values(sorted(os.list_dir(concat(here, "/examples"))))){
    if(str.ends_with(f, ".slang")){
      local t = tour_page(concat("../examples/", f))
      append(examples, {title: t.title, code: t.code})
    }
  }
  local options = {}
  for(local i = 0; i < len(examples); i = i + 1){
    append(options, concat(
      "<option value=\"",
      string(i),
      "\">",
      escape(examples[i].title),
      "</option>",
    ))
  }
  local first = examples[len(pages)] or examples[0]
  local body = concat(
    "<main class=\"play-main\">",
    "<div class=\"play-bar\"><h1>Playground</h1>",
    "<label class=\"pick\">Examples <select data-examples>",
    "<option value=\"\">Choose…</option>",
    str.join(options, ""),
    "</select></label>",
    "<button class=\"btn ghost\" data-share>Share</button></div>",
    editor(first.code, {format: true, class: "big", expanded: true}),
    "<p class=\"note\">Runs in your browser as WebAssembly. Modules that ",
    "need the operating system (files, processes, networking, the FFI) are ",
    "not available here; everything else is the real slang, and ",
    "<code>extension \"extensions/html\"</code> and the other ",
    "<a href=\"../docs/\">extensions</a> load as they do at home. ",
    "Expanded shows the code after macros and extensions have run.</p>",
    "<script type=\"application/json\" id=\"examples\">",
    str.replace(json.encode(examples), "</", "<\\/"),
    "</script>",
    // the extensions' sources, for programs that load one
    "<script type=\"application/json\" id=\"ext-files\">",
    str.replace(json.encode(extension_files()), "</", "<\\/"),
    "</script>",
    "</main>",
  )
  write("play/index.html", page({
    title: "Playground · slang",
    body: body,
    root: "../",
    section: "play",
    kind: "play",
  }))
}

// ------------------------------------------------------------ siege
//
// Not built for now (see the end of the file).

// The game page: Siege (examples/siege) runs on the graphics VM as it
// is, its files carried by the page (the font as base64); the sources
// are shown under it, highlighted.
local func build_siege(){
  local dir = "examples/siege"
  local files = {}
  local sources = {}
  local func add(rel){
    files[rel] = os.read_file(concat(dir, "/", rel))
    append(sources, rel)
  }
  add("main.slang")
  for(let local f in values(sorted(os.list_dir(concat(dir, "/game"))))){
    if(str.ends_with(f, ".slang")){
      add(concat("game/", f))
    }
  }
  for(let local f in values(sorted(os.list_dir(concat(dir, "/levels"))))){
    if(str.ends_with(f, ".slang")){
      add(concat("levels/", f))
    }
  }
  // the packages the graphics VM carries live at /raylib and /jolt there
  files["slang.project"] = concat(
    "{name: \"siege\", dependencies: {raylib: {path: \"/raylib\"}, ",
    "jolt: {path: \"/jolt\"}}, search_paths: {\".\"}}",
  )
  files["slang.lock"] = "{[\"jolt\"]: {path: \"/jolt\"}, [\"raylib\"]: {path: \"/raylib\"}}"
  files["assets/Fredoka.ttf"] = {
    b64: encoding.base64 .encode(
      os.read_file(concat(dir, "/assets/Fredoka.ttf")),
    ),
  }
  // the sources are shown from the page's own copy, highlighted when
  // opened (the page carries each file once)
  local listing = {}
  for(let local rel in values(sources)){
    append(listing, concat(
      "<details class=\"source\" data-file=\"",
      escape(rel),
      "\"><summary>",
      escape(rel),
      "</summary><pre class=\"code\"><code></code></pre></details>",
    ))
  }
  local body = concat(
    "<main class=\"siege-main\">",
    "<section class=\"siege-hero\">",
    "<p class=\"sticker\">a whole game, in slang</p>",
    "<h1>Siege</h1>",
    "<p class=\"lede\">Drive a catapult, wind it up and wreck the place: ",
    "stone, wood, glass, barrels that explode, and the furniture inside. ",
    "A 3D physics game written in slang on the raylib and Jolt packages, ",
    "running here in your browser as WebAssembly.</p>",
    "</section>",
    "<div class=\"game\" data-game data-main=\"main.slang\">",
    "<div class=\"game-bar\"><button class=\"btn big run\" data-play>Play</button>",
    "<span class=\"status\" data-status>about 20 MB to load the first time</span></div>",
    "<div class=\"stage\"></div>",
    "<pre class=\"output\" data-output></pre>",
    "</div>",
    "<section class=\"siege-text\">",
    "<h2>How to play</h2>",
    "<ul>",
    "<li><b>W A S D</b> or the arrows drive, <b>space</b> is the handbrake, ",
    "<b>R</b> puts the catapult back on its wheels.</li>",
    "<li>The <b>mouse</b> aims: left and right turn the arm, up and down lift it. ",
    "<b>Hold the left button</b> to wind, let go to throw. The dotted line shows ",
    "where the shot lands.</li>",
    "<li><b>1 2 3 4</b> choose the ammo: a rock, a triple shot, a bomb, a chain shot.</li>",
    "<li>Points for every part knocked loose, smashed or blown up; the furniture ",
    "inside the buildings is worth the most. Reach the level's target before ",
    "the ammo runs out.</li>",
    "<li>Right drag looks around, the wheel zooms, <b>Esc</b> pauses, <b>F1</b> ",
    "shows the help. The level editor is on the title screen; a level you save ",
    "there is printed under the game as JSON.</li>",
    "</ul>",
    "<h2>How it is built</h2>",
    "<p>Everything is slang: the physics world and what breaks in it, the ",
    "catapult (a Jolt wheeled vehicle with ray-cast suspension), the terrain ",
    "mesh and its height field, the procedural buildings, the level builder and ",
    "editor, the lighting shader, and every texture and sound, generated at ",
    "start from noise and numbers. raylib draws and Jolt simulates, both through ",
    "<code>slang/ffi</code> from their C headers; Jolt's contact callbacks run ",
    "as slang functions. The same files run on the desktop with ",
    "<code>make siege</code>.</p>",
    "<h2>The source</h2>",
    "<p>",
    string(len(sources)),
    " files, as they are in ",
    "<a href=\"",
    REPO,
    "/tree/main/examples/siege\">examples/siege</a>.</p>",
    str.join(listing, ""),
    "</section>",
    "<script type=\"application/json\" id=\"game-files\">",
    str.replace(json.encode(files), "</", "<\\/"),
    "</script>",
    "</main>",
  )
  write("siege/index.html", page({
    title: "Siege · a game in slang",
    description: "Siege: a 3D catapult game written in slang on raylib and Jolt, running in the browser.",
    body: body,
    root: "../",
    section: "siege",
    kind: "siege",
  }))
}

// ------------------------------------------------------------ the docs

// the sidebar's groups: a module goes to the first group naming it
local GROUPS = {
  {
    title: "Language",
    modules: {
      "globals",
      "slang/string",
      "slang/utf8",
      "slang/regex",
      "slang/math",
      "slang/table",
      "slang/thread",
      "slang/time",
      "slang/encoding",
      "slang/hash",
      "slang/json",
      "slang/std",
      "slang/vm",
    },
  },
  {
    title: "Programs",
    modules: {
      "slang/os",
      "slang/path",
      "slang/test",
      "slang/html",
      "slang/bundle",
      "slang/bundle_tool",
    },
  },
  {
    title: "Async and the web",
    modules: {
      "slang/async",
      "slang/isolate",
      "slang/http",
      "slang/web",
      "slang/ws",
      "slang/tls",
      "slang/crypto",
      "slang/jwt",
      "slang/sqlite",
      "slang/webview",
      "slang/zlib",
    },
  },
  {
    title: "C and memory",
    modules: {"slang/ffi", "slang/buffer", "slang/ctypes", "slang/ffi_core"},
  },
  {
    title: "The compiler",
    modules: {
      "slang/compiler",
      "slang/grammar",
      "slang/peg",
      "slang/ast",
      "slang/symbols",
      "slang/format",
      "slang/doc",
      "slang/codegen",
      "slang/optimizer",
      "slang/pkg",
      "slang/build",
    },
  },
  {title: "Extensions", prefix: "extensions/", modules: {}},
  {title: "Native modules", modules: {}},
}

// The guides (website/guide/NAME.md) in order, with what the docs' front
// page says about each. A guide's title is its first heading.
local GUIDES = {
  {
    slug: "install",
    blurb: "Build slang, write a first program, a module and a test, and set up an editor.",
  },
  {
    slug: "language",
    blurb: "The reference behind the tour: scope, values, operators, tables, metatables, patterns, errors, coroutines and isolates.",
  },
  {
    slug: "projects",
    blurb: "slang.project, how require finds modules, dependencies from git, and packages with native code.",
  },
  {
    slug: "tools",
    blurb: "The slang command, tests, the formatter, doc comments, editors and the debugger.",
  },
  {
    slug: "build",
    blurb: "One executable of a program, its modules and its assets.",
  },
  {
    slug: "async",
    blurb: "Futures and await, HTTP, the web framework, WebSockets and SQLite.",
  },
  {
    slug: "notebooks",
    blurb: "Notebooks as Markdown files: cells that share a session, plots and tables, in the browser and in the terminal.",
  },
  {
    slug: "extensions",
    blurb: "Quotes and compile, extension statements, dialects for a project, and the grammar API.",
  },
  {
    slug: "c",
    blurb: "Calling C libraries from their headers, shared memory, native modules and embedding.",
  },
}

// a guide's title: the first line of its file, a # heading
local func guide_title(slug){
  local source = os.read_file(concat(here, "/guide/", slug, ".md"))
  local line = str.split(source, "\n", 2)[0]
  return str.trim(str.trim_prefix(line, "#"))
}

for(let local g in values(GUIDES)){
  g.title = guide_title(g.slug)
}

// where a page's links lead: the docs' pages and the guides, from a page
// in docs/ and from one in guide/
local FROM_DOCS = {docs: "", guide: "../guide/"}
local FROM_GUIDE = {docs: "../docs/", guide: ""}

// sidebar(modules, current, base): [current] is a module's name, "index",
// "writing-docs" or "guide:SLUG"
local func sidebar(modules, current, base){
  local by_name = {}
  for(let local m in values(modules)){
    by_name[m.name] = m
  }
  local placed = {}
  local groups = {}
  for(let local g in values(GROUPS)){
    local items = {}
    for(let local name in values(g.modules)){
      if(by_name[name] != null){
        placed[name] = true
        append(items, name)
      }
    }
    if(g.prefix != null){
      for(let local m in values(modules)){
        if(str.starts_with(m.name, g.prefix)){
          placed[m.name] = true
          append(items, m.name)
        }
      }
    } else if(len(g.modules) == 0){
      // the rest: the natives' stubs (uv, zlib, ...)
      for(let local m in values(modules)){
        if(not placed[m.name]){
          append(items, m.name)
        }
      }
    }
    if(len(items) > 0){
      local links = {}
      for(let local name in values(items)){
        append(links, concat(
          "<li><a href=\"",
          base.docs,
          doc.page_name(name),
          "\"",
          name == current and " aria-current=\"page\"" or "",
          ">",
          escape(name),
          "</a></li>",
        ))
      }
      append(groups, concat(
        "<h2>",
        escape(g.title),
        "</h2><ul>",
        str.join(links, ""),
        "</ul>",
      ))
    }
  }
  local guides = {}
  for(let local g in values(GUIDES)){
    append(guides, concat(
      "<li><a href=\"",
      base.guide,
      g.slug,
      ".html\"",
      current == concat("guide:", g.slug) and " aria-current=\"page\"" or "",
      ">",
      escape(g.title),
      "</a></li>",
    ))
  }
  append(guides, concat(
    "<li><a href=\"",
    base.docs,
    "writing-docs.html\"",
    current == "writing-docs" and " aria-current=\"page\"" or "",
    ">Writing docs</a></li>",
  ))
  return concat(
    "<aside class=\"doc-nav\"><details open><summary>Docs</summary>",
    "<p><a href=\"",
    base.docs,
    "index.html\"",
    current == "index" and " aria-current=\"page\"" or "",
    ">Overview</a></p>",
    "<h2>Guides</h2><ul class=\"guides\">",
    str.join(guides, ""),
    "</ul>",
    str.join(groups, ""),
    "</details></aside>",
  )
}

// code samples in the docs, highlighted like the rest of the site
local func highlight_samples(html){
  local parts = str.split(html, "<pre><code>")
  local outp = {parts[0]}
  for(local i = 1; i < len(parts); i = i + 1){
    local stop = str.index_of(parts[i], "</code></pre>")
    local code = str.substring(parts[i], 0, stop)
    code = str.replace(code, "&quot;", "\"")
    code = str.replace(code, "&lt;", "<")
    code = str.replace(code, "&gt;", ">")
    code = str.replace(code, "&amp;", "&")
    append(outp, concat(
      "<pre class=\"code\"><code>",
      highlight(code),
      "</code></pre>",
      str.substring(parts[i], stop + 13),
    ))
  }
  return str.join(outp, "")
}

// an extension's page: its examples live (run, edit, and toggle to their
// expansion in the browser), with the extension's source (and the sources
// of the extensions it loads) in the page for the playground's VM
local func extension_content(m){
  local prefix = concat("extension \"", m.name, "\"\n")
  local body = doc.extension_body(m, func(ex){
    return editor(ex.code, {
      prefix: prefix,
      expanded: ex.expanded,
      reset: true,
      class: "example-bench",
    })
  })
  local files = {}
  for(let local name in values({m.name, ...m.uses})){
    local path = concat(name, ".slang")
    if(os.exists(path)){
      files[path] = os.read_file(path)
    }
  }
  return concat(
    body,
    "<script type=\"application/json\" id=\"ext-files\">",
    str.replace(json.encode(files), "</", "<\\/"),
    "</script>",
  )
}

// doc_page(modules, current, title, content, o?: {base?, section?, class?,
//   description?}): a page in the docs' layout, the sidebar beside it
local func doc_page(modules, current, title, content, o){
  o = o or {}
  return page({
    title: title,
    description: o.description,
    body: concat(
      "<main class=\"doc-main\">",
      sidebar(modules, current, o.base or FROM_DOCS),
      "<article class=\"doc",
      o.class and concat(" ", o.class) or "",
      "\">",
      content,
      "</article></main>",
    ),
    root: "../",
    section: o.section or "docs",
    kind: "docs",
  })
}

// the modules of slang's library, its natives' stubs and the extensions
// that come with it: what slang doc collects, {modules, status}
local func collect_modules(){
  local paths = {}
  for(let local dir in values(__PACKAGES.library_sources or {})){
    if(os.is_dir(dir)){
      append(paths, dir)
    }
  }
  for(let local dir in values(__PACKAGES.stub_sources or {})){
    if(os.is_dir(dir)){
      append(paths, dir)
      break
    }
  }
  // the extensions that come with slang
  append(paths, "extensions")
  return doc.collect(paths)
}

// the modules of the docs' front page, in the sidebar's groups and
// order, each with the first sentence of its doc (without the name it
// starts with)
local func module_index(modules){
  local by_name = {}
  for(let local m in values(modules)){
    by_name[m.name] = m
  }
  local placed = {}
  local parts = {}
  for(let local g in values(GROUPS)){
    local items = {}
    for(let local name in values(g.modules)){
      if(by_name[name] != null){
        placed[name] = true
        append(items, by_name[name])
      }
    }
    for(let local m in values(modules)){
      local rest = if(g.prefix != null){
        str.starts_with(m.name, g.prefix)
      } else {
        len(g.modules) == 0
      }
      if(rest and not placed[m.name]){
        placed[m.name] = true
        append(items, m)
      }
    }
    if(len(items) > 0){
      local list = doc.index_body(items, g.title)
      list = str.substring(list, str.index_of(list, "<dl>"))
      for(let local m in values(items)){
        list = str.replace(
          list,
          concat("<dd>", escape(m.name), ": "),
          "<dd>",
        )
      }
      // a summary starts with a capital
      local rows = str.split(list, "<dd>")
      for(local i = 1; i < len(rows); i = i + 1){
        local b = str.byte_at(rows[i], 0)
        if(b != null and b >= 'a' and b <= 'z'){
          rows[i] = concat(
            str.upper(str.substring(rows[i], 0, 1)),
            str.substring(rows[i], 1),
          )
        }
      }
      append(parts, concat(
        "<h3 class=\"group\">",
        escape(g.title),
        "</h3>",
        str.join(rows, "<dd>"),
      ))
    }
  }
  return str.join(parts, "\n")
}

// the guides of the docs' front page
local func guide_index(){
  local rows = {}
  for(let local g in values(GUIDES)){
    append(rows, concat(
      "<dt><a href=\"../guide/",
      g.slug,
      ".html\">",
      escape(g.title),
      "</a></dt><dd>",
      escape(g.blurb),
      "</dd>",
    ))
  }
  append(rows, concat(
    "<dt><a href=\"writing-docs.html\">Writing docs</a></dt>",
    "<dd>Doc comments: typed signatures, types, and how extensions and ",
    "native modules are documented.</dd>",
  ))
  return concat("<dl class=\"guides\">", str.join(rows, "\n"), "</dl>")
}

local func build_docs(modules){
  for(let local m in values(modules)){
    local content = null
    if(m.kind == "extension"){
      content = extension_content(m)
    } else {
      content = highlight_samples(doc.module_body(m))
    }
    write(concat("docs/", doc.page_name(m.name)), doc_page(
      modules,
      m.name,
      concat(m.name, " · slang docs"),
      content,
    ))
  }
  // the front page: pages/docs-intro.html, with the guides and the
  // modules where it says {{guides}} and {{modules}}
  local intro = os.read_file(concat(here, "/pages/docs-intro.html"))
  intro = str.replace(intro, "{{guides}}", guide_index())
  intro = str.replace(intro, "{{modules}}", module_index(modules))
  write("docs/index.html", doc_page(modules, "index", "Docs · slang", intro))
  write("docs/writing-docs.html", doc_page(
    modules,
    "writing-docs",
    "Writing docs · slang",
    highlight_samples(os.read_file(concat(here, "/pages/writing-docs.html"))),
  ))
}

// ------------------------------------------------------------ guides
//
// A guide is a Markdown file, so that the repository shows the same text
// the site does. The subset understood here: # headings, paragraphs,
// fenced code, lists of "- " items (continued by indented lines), tables,
// and inline `code`, [links](url) and **bold**. A ```slang sample has to
// parse, as a program or as an expression: one that does not is reported
// and fails the build, so the guides cannot drift from the grammar.
//
// Links are written to work in the repository and are turned into the
// site's: another guide (name.md), the library's docs (../../doc/) and
// pages/writing-docs.html. A code span naming a module links to its
// docs, one naming a path of the repository to its source.

local REPO_DIRS = {
  "examples/",
  "packages/",
  "extensions/",
  "editors/",
  "lsp/",
  "zig/",
}

// what a guide's link leads to on the site
local func guide_href(href){
  if(str.starts_with(href, "../../doc/")){
    return concat("../docs/", str.substring(href, 10))
  }
  if(href == "../pages/writing-docs.html"){
    return "../docs/writing-docs.html"
  }
  if(str.ends_with(href, ".md") and not str.contains(href, "/")){
    return concat(str.substring(href, 0, len(href) - 3), ".html")
  }
  return href
}

// where a code span leads, or null: a module's docs, a path's source
local func code_href(code, pages){
  if(pages[code] != null){
    return concat("../docs/", pages[code])
  }
  for(let local dir in values(REPO_DIRS)){
    if(str.starts_with(code, dir) and not str.contains(code, " ")){
      local path = str.trim_suffix(code, "/")
      if(os.is_dir(path)){
        return concat(REPO, "/tree/main/", path)
      }
      if(os.exists(path)){
        return concat(REPO, "/blob/main/", path)
      }
    }
  }
  return null
}

// the inline part of Markdown as HTML
local func inline(text, pages){
  local outp = {}
  local n = len(text)
  local i = 0
  // where the text not yet written starts
  local plain = 0
  for(i < n){
    local b = str.byte_at(text, i)
    local stop = -1
    local html = null
    if(b == '`'){
      stop = str.index_of(text, "`", i + 1)
      if(stop >= 0){
        local code = str.substring(text, i + 1, stop)
        html = concat("<code>", escape(code), "</code>")
        local href = code_href(code, pages)
        if(href != null){
          html = concat("<a href=\"", escape(href), "\">", html, "</a>")
        }
        stop = stop + 1
      }
    } else if(b == '['){
      local mid = str.index_of(text, "](", i + 1)
      if(mid >= 0){
        stop = str.index_of(text, ")", mid + 2)
      }
      if(stop >= 0){
        html = concat(
          "<a href=\"",
          escape(guide_href(str.substring(text, mid + 2, stop))),
          "\">",
          inline(str.substring(text, i + 1, mid), pages),
          "</a>",
        )
        stop = stop + 1
      }
    } else if(b == '*' and str.starts_with(text, "**", i)){
      stop = str.index_of(text, "**", i + 2)
      if(stop >= 0){
        html = concat(
          "<strong>",
          inline(str.substring(text, i + 2, stop), pages),
          "</strong>",
        )
        stop = stop + 2
      }
    }
    if(html == null){
      i = i + 1
    } else {
      append(outp, escape(str.substring(text, plain, i)))
      append(outp, html)
      i = stop
      plain = stop
    }
  }
  append(outp, escape(str.substring(text, plain)))
  return str.join(outp, "")
}

// a heading's id: its words in lowercase, joined by dashes
local func heading_id(title){
  local parts = {}
  local word = {}
  for(local i = 0; i <= len(title); i = i + 1){
    local b = str.byte_at(title, i)
    local letter = b != null and
      (b >= 'a' and b <= 'z' or b >= 'A' and b <= 'Z' or b >= '0' and b <= '9')
    if(letter){
      append(word, b)
    } else if(len(word) > 0){
      append(parts, str.lower(str.from_bytes(word)))
      word = {}
    }
  }
  return str.join(parts, "-")
}

// the cells of a table's row: | a | b |, where \| is a bar in a cell
local func cells(line){
  local protected = str.replace(str.trim(line), "\\|", "\x01")
  local parts = str.split(protected, "|")
  local outp = {}
  for(local i = 1; i + 1 < len(parts); i = i + 1){
    append(outp, str.trim(str.replace(parts[i], "\x01", "|")))
  }
  return outp
}

local func is_item(line){
  return str.starts_with(line, "- ")
}

// whether a line starts a block of its own, ending a paragraph
local func starts_block(line){
  return str.trim(line) == "" or str.starts_with(line, "```") or
    str.starts_with(line, "#") or
    str.starts_with(line, "|") or
    is_item(line)
}

// markdown(text, o: {pages, origin}) -> {title, html, sections, failed}
// [pages]: the docs' page of every module, by name
// [origin]: the file, for reports
// [sections]: the ## headings, {id, title}
// [failed]: how many slang samples do not parse
local func markdown(text, o){
  local lines = str.split(text, "\n")
  local n = len(lines)
  local outp = {}
  local r = {title: "", sections: {}, failed: 0}
  local i = 0
  for(i < n){
    local line = lines[i]
    if(str.trim(line) == ""){
      i = i + 1
    } else if(str.starts_with(line, "```")){
      local lang = str.trim(str.substring(line, 3))
      local first = i + 1
      local code = {}
      i = i + 1
      for(i < n and not str.starts_with(lines[i], "```")){
        append(code, lines[i])
        i = i + 1
      }
      i = i + 1
      local source = str.join(code, "\n")
      local block = null
      if(lang == "slang"){
        block = checked_block(source)
        if(block == null){
          r.failed = r.failed + 1
          os.write_stderr(concat(
            "website: ",
            o.origin,
            ":",
            string(first + 1),
            ": this slang sample does not parse\n",
          ))
        }
      }
      append(outp, block or concat(
          "<pre class=\"code\"><code>",
          escape(source),
          "</code></pre>",
        ))
    } else if(str.starts_with(line, "#")){
      local level = 0
      for(str.byte_at(line, level) == '#'){
        level = level + 1
      }
      local title = str.trim(str.substring(line, level))
      if(level == 1){
        r.title = title
        append(outp, concat("<h1>", inline(title, o.pages), "</h1>"))
      } else {
        local id = heading_id(title)
        if(level == 2){
          append(r.sections, {id: id, title: title})
        }
        append(outp, concat(
          "<h",
          string(level),
          " id=\"",
          id,
          "\">",
          inline(title, o.pages),
          "</h",
          string(level),
          ">",
        ))
      }
      i = i + 1
    } else if(str.starts_with(line, "|")){
      local rows = {}
      for(i < n and str.starts_with(lines[i], "|")){
        append(rows, cells(lines[i]))
        i = i + 1
      }
      local html = {"<div class=\"table\"><table>"}
      // a head of empty cells is none
      if(str.join(rows[0], "") != ""){
        append(html, "<thead><tr>")
        for(let local c in values(rows[0])){
          append(html, concat("<th>", inline(c, o.pages), "</th>"))
        }
        append(html, "</tr></thead>")
      }
      append(html, "<tbody>")
      // rows[1] is the line of dashes
      for(local k = 2; k < len(rows); k = k + 1){
        append(html, "<tr>")
        for(let local c in values(rows[k])){
          append(html, concat("<td>", inline(c, o.pages), "</td>"))
        }
        append(html, "</tr>")
      }
      append(html, "</tbody></table></div>")
      append(outp, str.join(html, ""))
    } else if(is_item(line)){
      local items = {}
      for(i < n and (is_item(lines[i]) or str.starts_with(lines[i], "  "))){
        if(is_item(lines[i])){
          append(items, str.substring(lines[i], 2))
        } else {
          items[len(items) - 1] = concat(
            items[len(items) - 1],
            " ",
            str.trim(lines[i]),
          )
        }
        i = i + 1
      }
      local html = {"<ul>"}
      for(let local item in values(items)){
        append(html, concat("<li>", inline(item, o.pages), "</li>"))
      }
      append(html, "</ul>")
      append(outp, str.join(html, ""))
    } else {
      local text_lines = {str.trim(line)}
      i = i + 1
      for(i < n and not starts_block(lines[i])){
        append(text_lines, str.trim(lines[i]))
        i = i + 1
      }
      append(outp, concat(
        "<p>",
        inline(str.join(text_lines, " "), o.pages),
        "</p>",
      ))
    }
  }
  r.html = str.join(outp, "\n")
  return r
}

// the guides' pages (guide/SLUG.html), in the docs' layout; the number
// of samples that do not parse
local func build_guides(modules){
  local pages = {}
  for(let local m in values(modules)){
    pages[m.name] = doc.page_name(m.name)
  }
  local failed = 0
  for(local i = 0; i < len(GUIDES); i = i + 1){
    local g = GUIDES[i]
    local file = concat(here, "/guide/", g.slug, ".md")
    local r = markdown(os.read_file(file), {pages: pages, origin: file})
    failed = failed + r.failed
    // what is on the page, under its title
    local toc = {}
    for(let local sec in values(r.sections)){
      append(toc, concat(
        "<li><a href=\"#",
        sec.id,
        "\">",
        escape(sec.title),
        "</a></li>",
      ))
    }
    local html = r.html
    if(len(toc) > 2){
      html = str.replace(
        html,
        "</h1>",
        concat("</h1>\n<ul class=\"toc on-page\">", str.join(toc, ""), "</ul>"),
        1,
      )
    }
    local prev = i > 0 and concat(
        "<a class=\"btn ghost\" href=\"",
        GUIDES[i - 1].slug,
        ".html\">← ",
        escape(GUIDES[i - 1].title),
        "</a>",
      ) or "<span></span>"
    local next = i + 1 < len(GUIDES) and concat(
        "<a class=\"btn\" href=\"",
        GUIDES[i + 1].slug,
        ".html\">",
        escape(GUIDES[i + 1].title),
        " →</a>",
      ) or "<a class=\"btn\" href=\"../docs/index.html#library\">The standard library →</a>"
    write(concat("guide/", g.slug, ".html"), doc_page(
      modules,
      concat("guide:", g.slug),
      concat(g.title, " · slang"),
      concat(
        "<p class=\"kicker\">Guide</p>",
        html,
        "<div class=\"pager\">",
        prev,
        next,
        "</div>",
      ),
      {
        base: FROM_GUIDE,
        class: "guide",
        section: g.slug == "install" and "install" or "docs",
        description: g.blurb,
      },
    ))
  }
  // the guides' address opens the docs' front page, which lists them
  write("guide/index.html", concat(
    "<!doctype html><meta charset=\"utf-8\"><title>slang guides</title>",
    "<meta http-equiv=\"refresh\" content=\"0; url=../docs/index.html\">",
    "<a href=\"../docs/index.html\">The docs</a>",
  ))
  return failed
}

// ------------------------------------------------------------ home

// the home page's template: {{code:name}} is the highlighted sample
// website/pages/home/name.slang, {{editor:name}} the same as an editor
local func build_home(){
  local template = os.read_file(concat(here, "/pages/home.html"))
  local parts = str.split(template, "{{")
  local outp = {parts[0]}
  for(local i = 1; i < len(parts); i = i + 1){
    local stop = str.index_of(parts[i], "}}")
    local tag = str.split(str.substring(parts[i], 0, stop), ":")
    local code = str.trim(os.read_file(
      concat(here, "/pages/home/", tag[1], ".slang"),
    ))
    if(tag[0] == "editor"){
      append(outp, editor(code, {class: "hero-editor", open: "play/"}))
    } else {
      append(outp, code_block(code))
    }
    append(outp, str.substring(parts[i], stop + 2))
  }
  write("index.html", page({
    title: "slang — a small language you can extend",
    body: str.join(outp, ""),
    root: "",
    section: "home",
    kind: "home",
  }))
}

// ------------------------------------------------------------ assets

local func copy_assets(){
  local dir = concat(here, "/public")
  for(let local f in values(os.list_dir(dir))){
    if(not str.starts_with(f, ".")){
      os.mkdir_all(concat(out, "/assets"))
      os.copy_file(concat(dir, "/", f), concat(out, "/assets/", f))
    }
  }
  if(not os.exists(concat(dir, "/slang.wasm"))){
    os.write_stderr(
      "website: no public/slang.wasm (make wasm): the playground will not run\n",
    )
  }
}

local pages = tour_pages()
copy_assets()
build_home()
build_tour(pages)
build_playground(pages)
// (the Siege page is off until the game is ready: build_siege() brings
// it back, with its link in NAV and its section on the home page)
local collected = collect_modules()
build_docs(collected.modules)
local failed = build_guides(collected.modules)
print("website: ", out, "/index.html\n")
os.exit(if(failed > 0){ 1 } else { collected.status })
