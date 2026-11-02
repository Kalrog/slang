// HTML templates

// The html extension makes an expression that starts with `<` build
// slang/html nodes, as JSX does. Components are plain functions, `{expr}`
// inserts a value (escaped), a list inserts its items and `{x and <b/>}` is
// a conditional. Switch to Expanded to see the calls the templates become.
extension "extensions/html"
local tbl = require("slang/table")

local func Feature(props){
  return <li class={props.new and "new"}>
    <b>{props.name}</b>: {props.children}
    {props.new and <em> (new)</em>}
  </li>
}

local func Card(props){
  return <section class="card">
    <h1>{props.title}</h1>
    <ul>{props.children}</ul>
    <footer>{len(props.items)} features &middot; &copy; 2026</footer>
  </section>
}

local features = {
  {name: "tables", text: "lists, records and objects in one"},
  {name: "coroutines", text: "generators and async without callbacks"},
  {name: "extensions", text: "grow the grammar, like this <html>", new: true},
}

local card = <Card title="slang has" items={features}>
  {tbl.map(features, func(f){
    return <Feature name={f.name} new={f.new}>{f.text}</Feature>
  })}
</Card>
print(string(card), "\n")
