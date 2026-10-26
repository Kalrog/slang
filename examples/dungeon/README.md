# Slang Dungeon

A small dungeon crawler that shows what slang's metaprogramming is for. The
Go program in `host/` only wraps [Ebitengine](https://ebitengine.org): a
window, a game loop and about twenty natives for drawing and input. Everything
else is slang, and most of the game's content is written in small languages
defined in `dsl/`: pixel art, levels, entity types, monster brains, dialogue,
loot tables, event rules and multi-frame scripts.

```sh
make dungeon                      # from the repository root, or:
cd examples/dungeon && go run ./host .
make dungeon-test                 # the DSL tests (no window needed)
```

Requirements: Go 1.26 and whatever Ebitengine needs on your platform (on
macOS the Xcode command line tools). The first build downloads Ebitengine.

Arrows or WASD move; walk into things to fight, talk or open them; Enter
confirms, R restarts after the end, F5 reloads all scripts.

## Layout

```
main.slang   window setup, the game flow (a state machine), update() and draw()
host/        the Go host: Ebitengine wrapper exposing the `ebiten` module
go.mod       the Go module of the host (it depends on ../../go through a replace directive)
dsl/         the languages: sprite, level, entity, machine, dialogue, loot, events, script
engine/      their runtimes plus world, input, gfx, scheduler, events
game/        the content: sprites, tiles, entities, brains, dialogues, loot, rules, levels, hud
test/        tests of the DSLs (run with bin/slang test test from this directory)
```

The host adds the game directory to the module search path, loads
`main.slang` and calls the globals `update(dt)` and `draw()` sixty times a
second. Nothing else crosses the language boundary.

## The languages

Each DSL is an ordinary slang file loaded with an `extension` statement. It
registers statements with the parser API and expands them into plain slang
code, usually a call that stores something in a registry (`sprites`,
`levels`, `entities`, ...). The interesting part is what happens at compile
time.

**Sprites** are ASCII pixel art. The palette lookup, the shape checks and the
RGBA encoding all happen while the file compiles; the bytecode contains the
finished pixel bytes and the game never parses art at run time. Errors point
at the offending row.

```slang
palette main { k: "#1a1a1a", g: "#3a7d44", G: "#2a5a30" }
sprite goblin main {
  .....kkkkkk.....
  ....kggggggk....
  ...
}
```

**Levels** are maps with a legend. The legend is checked against the tiles
and entity types declared earlier (`tile wall {...}`, `entity Goblin {...}`),
and every map is checked to be rectangular, to use only legend characters and
to contain exactly one `Player`.

```slang
legend mine { "#": wall, ".": floor, "@": Player, "g": Goblin, "k": Key }
level entrance mine {
  ########
  #@...g.#
  #..k..>#
  ########
}
```

**Entities** are types with defaults, inheritance and methods. Instances fall
back to their type's fields, `type(e)` is the type name and
`'Goblin{hp: local hp}` patterns match them.

```slang
entity Monster { solid: true, hp: 2, on_bump: func(self, who){ ... } }
entity Goblin extends Monster { sprite: "goblin", hp: 3, brain: "goblin" }
```

**Machines** describe behaviour as states with `enter`, `update(dt)` and
`exit` hooks. `goto` is checked at compile time against the declared states.
The monsters use it, and so does the game flow in `main.slang` (title,
playing, dead, won).

```slang
machine goblin {
  state idle  { update(dt) { if(world.distance(self, player) < 5){ goto chase } } }
  state chase { update(dt) { ... } }
}
```

**Dialogues** compile to coroutines. `say` and `choice` yield; the HUD shows
the text and the player's input resumes the conversation, while the rest of
the game keeps drawing. Anything in between is ordinary slang.

```slang
dialogue elder {
  say "Ah, a visitor."
  choice {
    "Where am I?"   => { say "The old mines." }
    "I'll manage."  => { say "Suit yourself." }
  }
  if(world.state.player.keys > 0){ say "You already have the key!" }
}
```

**Loot tables** are rolled once per drop; a table whose chances add up to
more than 100% is a compile error.

```slang
loot chest { 45% potion  35% coins(5, 10)  20% sword }
```

**Rules** react to events by pattern, and **scripts** run across frames with
`wait SECONDS` and `wait for EVENT`:

```slang
on {kind: "picked_up", item: "key"} {
  scheduler.start(func(){
    wait 1
    hud.message("Something stirs in the dark...")
    wait 1.5
    world.add(entities.Goblin(event.x, event.y))
  })
}
```

Operator metamethods (`__add`, `__eq`, `__call`, ...) are what make
`entities.Goblin(x, y)` callable and would carry vector math if the game
needed it.

## Testing and automation

`test/` exercises every DSL without a window: baked pixels, level grids and
spawns, inheritance, machine transitions, dialogue flow, loot rolls, event
dispatch and waiting scripts, plus the compile errors each language reports.

The host understands a few environment variables for scripted runs:

```
DUNGEON_FRAMES=120            quit after 120 frames
DUNGEON_SCREENSHOT=out.png    save the last frame
DUNGEON_KEYS=Enter,ArrowRight simulate key presses, one every six frames (`-` pauses)
DUNGEON_LEVEL=hoard           start at a level
```

## Things worth knowing

Keywords introduced by a DSL (`sprite`, `level`, `entity`, `machine`, `goto`,
`on`, `wait`, `say`, `choice`, `dialogue`, `loot`, ...) are global: once a
file has loaded the extension they are reserved as variable names for every
file compiled afterwards. They stay usable as field names, so `gfx.sprite`
or `e.state` are fine. This is why the engine modules use names like `dlg`
and `loot_api` for their locals.

Metamethods and `say`/`wait` run inside coroutines; they cannot yield across
a native call, so a `wait` inside a metamethod would fail.
