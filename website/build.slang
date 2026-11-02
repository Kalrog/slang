// The website: `bin/slang run website/build.slang [out]` (or `make website`)
// writes a static site to website/out (or out): the home page, the tour
// (website/tour), the playground, the API docs of slang's library (slang
// doc's pages in the site's layout) and website/pages. Code samples are
// highlighted here, by the real parser. The playground runs slang.wasm
// (`make wasm`) in the browser.
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
  local r = pcall(compiler.highlight, concat(prefix, code), "example.slang")
  if(r[0] == "err"){
    return escape(code)
  }
  local parts = {}
  local shift = len(prefix)
  local pos = 0
  for(let local tk in values(r[1].tokens)){
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
  {key: "tour", href: "tour/", label: "Tour"},
  {key: "play", href: "play/", label: "Playground"},
  {key: "docs", href: "docs/", label: "Docs"},
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
  append(links, concat("<a href=\"", REPO, "\">GitHub</a>"))
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
      ) or "<a class=\"btn\" href=\"../play/\">On to the playground →</a>"
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

local RAYLIB_EXAMPLES = {
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
  // the raylib examples, as they are in the repository (the playground
  // runs them on its graphics VM)
  for(let local e in values(RAYLIB_EXAMPLES)){
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
    b64: encoding.base64.encode(os.read_file(concat(dir, "/assets/Fredoka.ttf"))),
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
    "<p>", string(len(sources)), " files, as they are in ",
    "<a href=\"", REPO, "/tree/main/examples/siege\">examples/siege</a>.</p>",
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
      "slang/http",
      "slang/web",
      "slang/ws",
      "slang/tls",
      "slang/crypto",
      "slang/jwt",
      "slang/sqlite",
      "slang/webview",
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

local func sidebar(modules, current){
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
  return concat(
    "<aside class=\"doc-nav\"><details open><summary>Modules</summary>",
    "<p><a href=\"index.html\"",
    current == "index" and " aria-current=\"page\"" or "",
    ">Overview</a> · <a href=\"",
    "writing-docs.html\"",
    current == "writing-docs" and " aria-current=\"page\"" or "",
    ">Writing docs</a></p>",
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

local func doc_page(modules, current, title, content){
  return page({
    title: title,
    body: concat(
      "<main class=\"doc-main\">",
      sidebar(modules, current),
      "<article class=\"doc\">",
      content,
      "</article></main>",
    ),
    root: "../",
    section: "docs",
    kind: "docs",
  })
}

local func build_docs(){
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
  local r = doc.collect(paths)
  local modules = r.modules
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
  local intro = os.read_file(concat(here, "/pages/docs-intro.html"))
  write("docs/index.html", doc_page(
    modules,
    "index",
    "Docs · slang",
    concat(intro, doc.index_body(modules, "Modules")),
  ))
  write("docs/writing-docs.html", doc_page(
    modules,
    "writing-docs",
    "Writing docs · slang",
    highlight_samples(os.read_file(concat(here, "/pages/writing-docs.html"))),
  ))
  return r.status
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
local status = build_docs()
print("website: ", out, "/index.html\n")
os.exit(status)
