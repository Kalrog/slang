# Web server

An HTTP/1.1 server written in slang: `slang/http` (request parsing with the
peg combinators, keep-alive, a small client) on `slang/async` (Futures,
Streams, await on coroutines) on the `uv` native extension (libuv). The
handlers in `main.slang` use the async/await syntax of `extensions/async`,
and the pages are written in the HTML templates of `extensions/html`.

```
brew install libuv
make build
bin/slang run examples/webserver/main.slang 8080
open http://127.0.0.1:8080/
curl -d 'hello' http://127.0.0.1:8080/echo
```

`/slow` awaits a timer for half a second without blocking other requests;
`/guestbook` takes a form and shows the entries, escaped by the templates.

## Templates

A template is an expression that looks like HTML and builds `slang/html`
nodes, which `string()` renders:

```
local func Layout(props){
  return <html>
    <head><title>{props.title}</title></head>
    <body>
      <Nav current={props.path}/>
      {props.children}
    </body>
  </html>
}
page.body = <Layout title="Time" path={req.path}><p>up for {seconds} s</p></Layout>
```

- `<tag attr="text" attr={expr} flag {...table}>...</tag>`, `<tag/>`,
  `<>...</>` for a fragment.
- A tag starting with a capital letter (or containing a dot) is a
  component: a function called with the attributes as a table, the
  children under `children`.
- `{expr}` inserts a value: strings escaped, numbers printed, nodes and
  lists as they are, null and booleans dropped (`{n > 0 and <p>...</p>}`).
  `html.raw(s)` inserts markup unescaped.
- Attribute values that are null or false omit the attribute, true writes
  it bare.
- Whitespace follows JSX: lines are trimmed and blank lines dropped, a line
  break inside text is one space.

`slang expand examples/webserver/main.slang` shows what the templates
compile to, and `test/html_test.slang` has the details.
