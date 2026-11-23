# bench/machine

How fast a machine runs slang, and how fast it is without slang, so that
two machines (an ARM Mac and an x86 PC) can be compared: is slang slower
on one because its CPU is slower, or because slang does worse on it?

```sh
make build                                  # slang for this machine
bench/machine/build.sh                      # native.c and Lua 5.4.7 (zig cc -O2)
bin/slang run bench/machine/run.slang       # writes results/<platform>-<cpu>.json
bin/slang run bench/machine/compare.slang results/a.json results/b.json
```

`build.sh` needs zig 0.17, `curl` and `sh` (on Windows: Git Bash or MSYS2).
It fetches Lua's pinned release into `.cache/` and builds into `bin/`
(neither is kept in git). Commit the new file in `results/`.

| Group | What | Tells |
|---|---|---|
| native | `native.c`: float and integer loops, a bytecode loop with `switch` and with computed goto, random memory reads; slang's Zig crypto | the CPU itself, and how it takes an interpreter's dispatch |
| interp | `bench/compare`'s programs in slang and in Lua 5.4 | slang's VM against another interpreter on the same CPU |
| micro | `bench/micro.slang`: ns per VM operation | which operations lose most |

`compare.slang` divides each ratio by Lua's: a slower CPU makes Lua
slower too, so what is left ("vs lua" above 1) is slang's own loss on
that machine. The allocating micro rows (`{x: i, y: i}`, `concat(...)`)
vary between runs with the garbage collector; read them as rough.
