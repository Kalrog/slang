// slang/html and the JSX-like templates of extensions/html
local t = require("slang/test")
local str = require("slang/string")
local html = require("slang/html")
local compiler = require("slang/compiler")

local func run(source){
  return compile(
    concat("extension \"extensions/html\"\n", source),
    "html_test",
  )()
}

t.group("html runtime"){
  t.test("escape"){
    assert(html.escape("plain") == "plain")
    assert(html.escape(
      "a < b & \"c\" 'd' > e",
    ) == "a &lt; b &amp; &quot;c&quot; &#39;d&#39; &gt; e")
  }
  t.test("elements, attributes and void tags"){
    local n = html.element(
      "input", {type: "text", disabled: true, hidden: false, value: "a\"b"},
      null
    )
    assert(
      string(n) == "<input type=\"text\" disabled value=\"a&quot;b\">",
      string(n),
    )
    assert(html.render(html.element("p", null, {
      "x", 1, html.element("br", null, null)
    })) == "<p>x1<br></p>")
    assert(html.render(html.fragment({"a", html.raw("<b>")})) == "a<b>")
    assert(html.render(
      html.element("meta", {charset: "utf-8"}, null),
    ) == "<meta charset=\"utf-8\">")
  }
  t.test("value escapes strings and keeps nodes and trusted lists"){
    local node = html.element("i", null, null)
    local v = html.value({"<", node, 2, {">"}, null})
    assert(html.render(v) == "&lt;<i></i>2&gt;")
    assert(html.value(null) == "" and html.value(false) == "" and html.value(
        "x&",
      ) == "x&amp;")
    assert(html.value(v) == v, "a list value made is trusted")
    local p = html.element("p", null, {"<b>"})
    assert(
      html.value(p.children) == p.children,
      "the children of an element are trusted",
    )
  }
}

t.group("html templates"){
  t.test("elements render with attributes, text and values"){
    local r = run("""
      local n = 2
      local s = "<b>"
      return {
        string(<p class="a" id={s} hidden={false} checked={true}>{s} and {n}</p>),
        string(<br/>),
        string(<>a<i>b</i></>),
        string(<div>{null}{false}{true}{n > 1 and <b>many</b>}</div>),
        string(<input value="x & y" data-id={n}/>),
        string(<p>{{"<", <b/>, {"x"}}}</p>),
      }
    """)
    assert(
      r[0] == "<p class=\"a\" id=\"&lt;b&gt;\" checked>&lt;b&gt; and 2</p>",
      r[0],
    )
    assert(r[1] == "<br>" and r[2] == "a<i>b</i>", concat(r[1], " ", r[2]))
    assert(r[3] == "<div><b>many</b></div>", r[3])
    assert(r[4] == "<input value=\"x &amp; y\" data-id=\"2\">", r[4])
    assert(r[5] == "<p>&lt;<b></b>x</p>", r[5])
  }
  t.test(
    "text keeps entities, escapes the rest, and follows the whitespace rules",
  ){
    local r = run("""
      local name = "Ada"
      return {
        string(<p>Tom &amp; Jerry &#169; a > b & c</p>),
        string(<p>
          Hello {name},
          welcome
        </p>),
        string(<ul>
          <li>a</li>
          <li>b</li>
        </ul>),
        string(<p><b>a</b> <i>b</i></p>),
        string(<p>  spaced  </p>),
      }
    """)
    assert(r[0] == "<p>Tom &amp; Jerry &#169; a &gt; b &amp; c</p>", r[0])
    assert(r[1] == "<p>Hello Ada, welcome</p>", r[1])
    assert(r[2] == "<ul><li>a</li><li>b</li></ul>", r[2])
    assert(r[3] == "<p><b>a</b> <i>b</i></p>", r[3])
    assert(r[4] == "<p>  spaced  </p>", r[4])
  }
  t.test("components receive the attributes and their children"){
    local r = run("""
      local table = require("slang/table")
      local ui = {}
      func ui.Card(props){ return <section class={props.kind}>{props.children}</section> }
      local func Item(props){ return <li>{props.children}</li> }
      local func List(props){
        return <ul>{table.map(props.items, func(x){ return <Item>{x}</Item> })}</ul>
      }
      local attrs = {id: "k", title: "t"}
      return {
        string(<ui.Card kind="note"><List items={{"a<b", "c"}}/></ui.Card>),
        string(<Item/>),
        string(<a href="/" {...attrs} title="u">x</a>),
        type(<Item/>),
        string(<Item>plain &amp; <b>bold</b></Item>),
      }
    """)
    assert(
      r[0] ==
        "<section class=\"note\"><ul><li>a&lt;b</li><li>c</li></ul></section>",
      r[0],
    )
    assert(r[1] == "<li></li>", r[1])
    assert(r[2] == "<a href=\"/\" id=\"k\" title=\"u\">x</a>", r[2])
    assert(r[3] == "Html")
    assert(r[4] == "<li>plain &amp; <b>bold</b></li>", r[4])
  }
  t.test("a mismatched closing tag is a located error"){
    local r = pcall(run, "local x = <div>\n  <p>hi</span></div>")
    assert(r[0] == "err")
    assert(str.index_of(
      r[1].message,
      "</p> expected to close the <p> opened at 3:3",
    ) >= 0, r[1].message)
    assert(
      r[1].location.line == 3 and r[1].location.column == 10,
      concat("location ", r[1].location),
    )
  }
  t.test("templates are highlighted and expand to html calls"){
    local h = compiler.highlight(
      "extension \"extensions/html\"\nlocal x = <ul class=\"a\"><Item done>t</Item></ul>\n",
      "html.slang",
    )
    local cats = {}
    for(let local tk in values(h.tokens)){ append(cats, tk.category) }
    local joined = str.join(cats, " ")
    assert(str.index_of(
      joined,
      "punctuation keyword property punctuation string punctuation punctuation function property punctuation",
    ) >= 0, joined)
    assert(len(h.diagnostics) == 0)
    local out = compiler.expand(
      "extension \"extensions/html\"\nlocal x = <p id={1}>a</p>\n",
      "e.slang",
    )
    assert(
      str.index_of(out, "__slang_html.element(\"p\", {id: 1}, {\"a\"})") >= 0,
      out,
    )
  }
  t.test(
    "the runtime is required once per unit, before the first statement that needs it",
  ){
    local out = compiler.expand(
      "extension \"extensions/html\"\nlocal a = 1\nlocal func f(){ return <p>{a}</p> }\nlocal b = <br/>\n",
      "e.slang",
    )
    local lines = str.split(str.trim(out), "\n")
    assert(lines[0] == "local a = 1", lines[0])
    assert(lines[1] == "local __slang_html = require(\"slang/html\")", lines[1])
    assert(str.starts_with(lines[2], "local func f()"), lines[2])
    assert(
      str.index_of(out, "local b = __slang_html.element(\"br\", null, null)") >=
        0,
      out,
    )
    assert(len(str.split(out, "require(\"slang/html\")")) == 2, "one require")
    local r = run(
      "local func f(){ return <i>{1}</i> }\nreturn concat(string(f()), string(<b/>))",
    )
    assert(r == "<i>1</i><b></b>", r)
  }
}
