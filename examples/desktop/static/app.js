// The page: renders the list and calls slang for every change. slang.call
// returns a Promise of what the bound slang function returned; slang.on
// hears what slang pushes (here: "the list changed", from any window).
const list = document.getElementById("todos");
const count = document.getElementById("count");

async function render() {
  const items = await slang.call("list");
  list.replaceChildren(...items.map((t) => {
    const li = document.createElement("li");
    li.className = t.done ? "done" : "";
    const box = document.createElement("input");
    box.type = "checkbox";
    box.checked = t.done;
    box.onchange = () => slang.call("toggle", t.id);
    const text = document.createElement("span");
    text.textContent = t.text;
    const del = document.createElement("button");
    del.textContent = "×";
    del.className = "delete";
    del.onclick = () => slang.call("remove", t.id);
    li.append(box, text, del);
    return li;
  }));
  const left = items.filter((t) => !t.done).length;
  count.textContent = `${left} ${left === 1 ? "item" : "items"} left`;
}

document.getElementById("add").onsubmit = async (e) => {
  e.preventDefault();
  const input = e.target.elements.text;
  const text = input.value.trim();
  if (text) await slang.call("add", text);
  input.value = "";
};
document.getElementById("clear").onclick = () => slang.call("clear_done");
document.getElementById("another").onclick = () => slang.call("another");

slang.on((msg) => { if (msg.changed) render(); });
render();
