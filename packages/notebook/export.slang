extension "extensions/html"
// notebook/export: a notebook as one HTML file, with what its cells
// showed: something to send to someone who has no slang.
//
//   local document = require("notebook/document")
//   local export = require("notebook/export")
//   os.write_file("notes.html", export.html(document.read("notes.md")))
//
// The page needs nothing else: its styles, images and sound are in it.
// Values that were tables stay trees to unfold.
//
// [app] makes the other kind of page: the notebook itself, to edit and
// run, with slang inside the page (as WebAssembly) in place of a server:
//
//   os.write_file("notes.html", export.app(document.read("notes.md")))
local html = require("slang/html")
local str = require("slang/string")
local os = require("slang/os")
local tbl = require("slang/table")
local json = require("slang/json")
local encoding = require("slang/encoding")
local compiler = require("slang/compiler")
local document = require("notebook/document")
local browser = require("notebook/browser")
local markdown = require("notebook/markdown")
local highlight = require("notebook/highlight")
local inspect = require("notebook/inspect")
local nb = require("notebook")

local export = {}

local VALUE = "application/vnd.slang.value+json"

// assets_dir() -> string
// The folder of the styles a notebook's page needs (notebook.css), next
// to this module.
func export.assets_dir(){
  return concat(
    compiler.dirname(compiler.module_path("notebook/export")), "/assets"
  )
}

// ------------------------------------------------------------ values

local scalar_kinds = {
  string: true, int: true, double: true, bool: true, ["null"]: true,
  ["function"]: true
}

local func Leaf(props){
  local node = props.node
  local kind = "other"
  if(scalar_kinds[node.t]){
    kind = node.t
  }
  local text = node.v or ""
  if(node.t == "string"){
    text = inspect.quote(text)
    if(node.more != null){
      text = concat(text, "... ", string(node.more), " more bytes")
    }
  }
  return <span class={concat("v-", kind)}>{text}</span>
}

local func Key(props){
  if(props.name == null){
    return null
  }
  return <><span class="nb-key">{props.name}</span>{": "}</>
}

// a value of a tree: a line, or a table that folds
local func Value(props){
  local node = props.node
  if(node.t != "table" and node.t != "itself" and node.t != "deep"){
    return <div class="nb-leaf"><Key name={props.name}/><Leaf node={node}/></div>
  }
  local size = concat(string(node.n), " entries")
  if(node.n == 1){
    size = "1 entry"
  }
  if(node.t == "itself"){
    size = "itself"
  }
  local head = <>
    <Key name={props.name}/>
    {node.type and concat(node.type, " ")}
    {"{"}<span class="nb-meta">{size}</span>{"}"}
  </>
  local items = node.items or {}
  if(node.t != "table" or len(items) == 0){
    return <div class="nb-leaf">{head}</div>
  }
  return <details open={props.open == true}>
    <summary>{head}</summary>
    <div class="nb-kids">
      {tbl.map(items, func(item){
        return <Value node={item.v} name={item.k}/>
      })}
      {node.more and <div class="nb-leaf nb-meta">
        ... {node.more} more
      </div>}
    </div>
  </details>
}

// tree_html(node: inspect.Node) -> string
// A value's tree (notebook/inspect) as HTML that folds without a script.
func export.tree_html(node){
  return html.render(<div class="nb-tree"><Value node={node} open/></div>)
}

// ------------------------------------------------------------ outputs

local images = {"image/png", "image/jpeg", "image/gif", "image/webp"}
local CONTROL = "application/vnd.slang.control+json"
local STACK = "application/vnd.slang.stack+json"

// the richest form of what was shown
local Data = null
Data = func(props){
  local data = props.data
  // several values one under another (an output of notebook's that shows
  // more than one)
  local stack = data[STACK]
  if(raw_type(stack) == "table"){
    return <div class="nb-stack">
      {tbl.map(stack, func(d){ return <Data data={d or {}}/> })}
    </div>
  }
  // a control as it was last set (its HTML is as it was made)
  if(raw_type(data[CONTROL]) == "table"){
    return <div class="nb-rich">{html.raw(nb.control_html(data[CONTROL]))}</div>
  }
  if(data["text/html"] != null){
    return <div class="nb-rich">{html.raw(data["text/html"])}</div>
  }
  if(data["image/svg+xml"] != null){
    return <div class="nb-rich">{html.raw(data["image/svg+xml"])}</div>
  }
  for(let local mime in values(images)){
    if(data[mime] != null){
      return <div class="nb-rich">
        <img alt="" src={concat("data:", mime, ";base64,", data[mime])}/>
      </div>
    }
  }
  if(data["audio/wav"] != null){
    return <audio
      controls src={concat("data:audio/wav;base64,", data["audio/wav"])}
    ></audio>
  }
  if(data["text/markdown"] != null){
    return <div class="nb-rich nb-md">
      {html.raw(markdown.render(data["text/markdown"], {
        highlight: func(code, language){
          return language == "slang" and highlight.html(code) or null
        }
      }))}
    </div>
  }
  if(data[VALUE] != null){
    return <div class="nb-tree"><Value node={data[VALUE]} open/></div>
  }
  return <pre>{string(data["text/plain"] or "")}</pre>
}

local func Failure(props){
  local e = props.error
  local where = null
  if(e.location != null and e.location.line != null){
    where = concat(string(e.location.origin), ":", string(e.location.line))
  }
  return <div class="nb-error">
    <div class="nb-error-head">
      <span class="nb-error-kind">{string(e.kind or "error")}:</span>
      {" "}{string(e.message or "")}{" "}
      {where and <span class="nb-error-where">{where}</span>}
    </div>
    {e.stack and e.stack != "" and <pre>{e.stack}</pre>}
  </div>
}

local func Output(props){
  local output = props.output
  if(output.type == "stream"){
    local kind = "nb-stdout"
    if(output.name == "stderr"){
      kind = "nb-stderr"
    }
    return <pre class={kind}>{output.text or ""}</pre>
  }
  if(output.type == "error"){
    return <Failure error={output.error or {}}/>
  }
  return <Data data={output.data or {}}/>
}

// output_html(output: document.Output) -> string
// What a cell showed, as HTML (styled by notebook.css).
func export.output_html(output){
  return html.render(<Output output={output}/>)
}

// ------------------------------------------------------------ the page

local PAGE_CSS = """
body { margin: 0; background: var(--nb-bg); color: var(--nb-ink); font-family: var(--nb-body); }
main { max-width: 860px; margin: 0 auto; padding: 48px 24px 96px; }
.cell { margin: 0 0 22px; }
.cell-code { background: var(--nb-code); border: 1px solid var(--nb-line); border-radius: 10px; overflow: hidden; }
.cell-code > pre { margin: 0; padding: 12px 16px; font: 13px/1.55 var(--nb-mono); overflow-x: auto; }
.cell-code > .nb-out { border-top: 1px solid var(--nb-line); padding: 12px 16px; background: var(--nb-card); }
footer { max-width: 860px; margin: 0 auto; padding: 0 24px 40px; color: var(--nb-faint); font-size: 12px; }
"""

// How [html] makes a page.
// type Options = {title?: string, code?: bool}
// [title]: the page's title; the notebook's first heading by default
// [code]: false leaves the code out and shows only text and outputs

// html(nb: {path?: string, cells: {document.Cell}}, options?: Options) -> string
// The notebook as a page of its own: its text rendered, its code
// highlighted, and under each cell what it showed when it last ran.
func export.html(nb, options){
  options = options or {}
  local name = "notebook"
  if(nb.path != null){
    name = compiler.absolute_path(nb.path)
    name = str.substring(name, str.last_index_of(name, "/") + 1)
  }
  local title = options.title or document.title(nb.cells, name)
  local css = concat(
    os.read_file(concat(export.assets_dir(), "/notebook.css")), PAGE_CSS
  )
  local with_code = options.code != false
  local func slang_code(source, language){
    if(language != "slang"){
      return null
    }
    return highlight.html(source, nb.path)
  }
  local func Cell(props){
    local cell = props.cell
    if(cell.type == "markdown"){
      return <section class="cell nb-md">
        {html.raw(markdown.render(cell.source, {highlight: slang_code}))}
      </section>
    }
    local outputs = cell.outputs or {}
    if(not with_code and len(outputs) == 0){
      return null
    }
    return <section class="cell cell-code">
      {with_code and <pre><code>
        {html.raw(highlight.html(cell.source, nb.path))}
      </code></pre>}
      {len(outputs) > 0 and <div class="nb-out">
        {tbl.map(outputs, func(o){ return <Output output={o}/> })}
      </div>}
    </section>
  }
  return concat(html.render(<>
    {html.doctype}
    <html lang="en">
      <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <title>{title}</title>
        <style>{html.raw(css)}</style>
      </head>
      <body>
        <main>
          {tbl.map(nb.cells, func(cell){ return <Cell cell={cell}/> })}
        </main>
        <footer>{name}, a slang notebook</footer>
      </body>
    </html>
  </>), "\n")
}

// ------------------------------------------------------------ the app

// text for the inside of a <script>: it cannot hold the tag that ends it
local func script_text(text){
  return html.raw(str.replace(text, "</script", "<\\/script"))
}

local THEME_SCRIPT = """
  // the theme chosen before, ahead of the first paint
  try {
    var theme = localStorage.getItem("slang-notebook-theme");
    if (theme) document.documentElement.dataset.theme = theme;
  } catch (e) {}
"""

// the mark at the top left: a link when the page is part of a site
local func Brand(props){
  if(props.home != null){
    return <a class="brand" href={props.home} title="Back to the site">
      {props.children}
    </a>
  }
  return <span class="brand">{props.children}</span>
}

// How [app] makes a page.
// type AppOptions = {title?: string, vm?: string, home?: string}
// [title]: the page's title; the notebook's first heading by default
// [home]: where the page's mark at the top left leads: the site the page
//   is part of. Nowhere by default
// [vm]: the URL of slang.wasm, for a page that is served with one next to
//   it. By default slang.wasm is inside the page (about 2 MB more), and
//   the page is one file that opens from anywhere, a disk too

// app(nb?: {path?: string, cells: {document.Cell}, settings?: document.Settings},
//   options?: AppOptions) -> string
// A notebook as a page that runs it: the notebook server's page without
// the server. slang runs in the page as WebAssembly (the notebook's
// session and its kernel are workers of the page, see
// notebook/service_web), so the cells can be edited and run by anyone who
// has the page, and they see nothing of the reader's machine. The reader
// can start a new notebook, open one from their machine and save to it;
// what they change is kept in their browser.
//
// The page starts with nb, showing what its cells showed when they last
// ran; without nb, with an empty notebook. A browser has no event loop for
// slang and no files: cells cannot await, and the notebook's project is
// not in the page.
// Raises when slang.wasm is to be inside the page and there is none
// (notebook/browser's vm_path).
func export.app(nb, options){
  options = options or {}
  local web_dir = browser.web_dir()
  local config = {files: browser.package_files(), key: "app"}
  // the language server, for what the page's editor knows about the code
  for(let local e in entries(browser.language_files())){
    config.files[e[0]] = e[1]
  }
  local title = options.title or "slang notebook"
  if(nb != null){
    local name = "notebook.md"
    if(nb.path != null){
      name = compiler.absolute_path(nb.path)
      name = str.substring(name, str.last_index_of(name, "/") + 1)
    }
    local text = document.format(nb.cells, nb.settings)
    config.notebook = {
      name: name, text: text, outputs: document.outputs_text(nb.cells)
    }
    config.key = concat(name, ":", document.hash(text))
    title = options.title or document.title(nb.cells, name)
  }
  local vm = null
  if(options.vm != null){
    config.vm = options.vm
  } else {
    local path = browser.vm_path()
    if(path == null){
      raise(error.new(error.kinds.not_found,
        "there is no slang.wasm to put in the page (make wasm builds it)"))
    }
    vm = encoding.base64.encode(require("slang/zlib").deflate(
      os.read_file(path), {format: "gzip", level: 9},
    ))
  }
  local logo = concat("data:image/svg+xml;base64,", encoding.base64.encode(
    os.read_file(concat(web_dir, "/logo.svg")),
  ))
  local css = concat(
    os.read_file(concat(export.assets_dir(), "/notebook.css")),
    os.read_file(concat(web_dir, "/app.css")),
  )
  // (< is written as an escape: the configuration sits inside a script)
  local config_text = str.replace(json.encode(config), "<", "\\u003c")
  return concat(html.render(<>
    {html.doctype}
    <html lang="en">
      <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <title>{title}</title>
        <link rel="icon" href={logo}/>
        <style>{html.raw(css)}</style>
        <script>{html.raw(THEME_SCRIPT)}</script>
      </head>
      <body>
        <header class="bar">
          <Brand home={options.home}>
            <img src={logo} alt="" width="26" height="26"/>
            <span>notebook</span>
          </Brand>
          <nav class="crumbs" id="crumbs" aria-label="Notebook"></nav>
          <div class="actions" id="actions"></div>
        </header>
        <main id="main"></main>
        <div class="toasts" id="toasts" role="status" aria-live="polite"></div>
        <script type="application/json" id="nb-config">{html.raw(config_text)}</script>
        <script type="text/plain" id="nb-worker">
          {script_text(browser.worker_source())}
        </script>
        {vm and <script type="application/octet-stream" id="nb-vm">{html.raw(vm)}</script>}
        <script>{script_text(os.read_file(concat(web_dir, "/app.js")))}</script>
      </body>
    </html>
  </>), "\n")
}

return export
