# Inkblast

A party game for up to four players over the network, written in slang on
[slang/net](../../slang/lib/net.slang) and [raylib](https://www.raylib.com).
Set charges, blast crates, and paint the floor in your colour. When the 90
seconds are up, whoever owns the most floor wins. A blast knocks out
whoever it catches for a few seconds, and paints over everyone else's ink.
Pots splash ink around whoever picks them up; lenses make your next two
charges reach further. Bots fill the slots nobody plays.

```
brew install raylib
make inkblast                                        # host a game and play
bin/slang run examples/inkblast/main.slang join 10.0.0.7   # join from another machine
bin/slang run examples/inkblast/main.slang server          # a server without a window
```

Arrows or WASD move, space sets a charge, escape quits. Options:
`--port n` (7777), `--name text`, `--no-bots`, `--round seconds`, and for a
client `--lag ms` and `--loss 0.1` to play over a worse network than there
is.

## How it is built

- `game/rules.slang` is the whole game with no window and no network: the
  arena, moving cell to cell, charges, blasts and chains, ink, knockouts,
  the round. Only the server runs it.
- `game/server.slang` steps the rules 30 times a second, applies what
  players send and broadcasts the state after every step. `game/bots.slang`
  plays the empty slots: it flees blasts that are coming (chains included),
  sets charges only where it can get away, and goes for pickups, crates and
  foreign floor.
- `game/client.slang` keeps the two newest states and draws players
  between them, so movement stays smooth whatever arrives when.
- `game/protocol.slang` names the messages: the hello, welcome and roster
  messages and every charge are reliable; the held direction and the state
  are sequenced (only the newest counts); news for sounds and the feed is
  unreliable.
- The host plays through the network too, over loopback, so what it sees
  is what a remote player sees.

`make inkblast-test` runs the rules on small arenas and a whole match over
loopback, one client on a simulated bad network. With
`INKBLAST_AUTOPLAY=1 INKBLAST_FRAMES=600` a bot plays for you and the game
quits after 600 frames; `INKBLAST_SHOT=300:shot.png` saves a screenshot.
