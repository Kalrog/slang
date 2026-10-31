// HTML from tables
local html = require("slang/html")

local items = {"tables", "closures", "coroutines & more"}
local list = {}
for(let local item in values(items)){
  append(list, html.element("li", null, {html.value(item)}))
}
local card = html.element("div", {class: "card"}, {
  html.element("h1", null, {"slang has"}),
  html.element("ul", null, list),
})
print(html.render(card), "\n")
