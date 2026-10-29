# Desktop app

A todo list as a desktop program: a native macOS window with a WebKit
view (`slang/webview`), a page served by a `slang/web` app, logic and data
(SQLite) in slang. It is the Wails way of building a desktop app, with no
browser and no network port.

```
make build
bin/slang run examples/desktop/main.slang
```

| file | what it holds |
|---|---|
| `main.slang` | the app (the page and the static files), the windows, the functions the page calls |
| `store.slang` | the todo list in `todos.db`, next to the program |
| `static/app.js` | the page's script: renders the list, calls slang |
| `static/style.css` | the look, light and dark |

## How the page talks to slang

The window loads `app://localhost/`. Requests to `app://` never touch a
socket: WebKit hands them to the window, `slang/webview` passes them to
`app:handle`, and the response goes back the same way. So the page, its
script and its stylesheet come from ordinary `slang/web` routes
(`app:get("/")`, `app:static`).

The script calls slang functions directly:

```js
await slang.call("add", text)      // runs the function bound as "add"
const items = await slang.call("list")
slang.on((msg) => { if (msg.changed) render(); })
```

and `main.slang` binds them on each window:

```
w:bind("add", func(text){ store.add(text) changed() })
```

`slang.call` returns a Promise of what the slang function returned (a
Future is awaited first); an error in slang rejects it. Values travel as
JSON. `win:send(value)` pushes a value to the page's `slang.on` listeners:
`changed()` tells every open window that the list changed, so a second
window ("another window") stays in step with the first.

## Event loops

Opening a window makes `async.main` wait on Cocoa and libuv together, so
timers, files, SQLite on the thread pool and even an HTTP server keep
running while windows are open. The program ends when its last window
closes; Cmd-Q closes them all, and so does Ctrl-C in the terminal.

The webview tests open real windows, so they are not part of `make test`:
run `make test-gui`.
