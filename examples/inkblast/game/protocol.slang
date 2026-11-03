// The messages between the Inkblast server and its clients.
//
// Client to server: hello once (reliable), input whenever the held
// direction changes and a few times a second besides (sequenced: only the
// newest counts), drop for each charge (reliable: a press is never lost).
//
// Server to client: welcome with the client's slot, roster when players
// come and go (both reliable), state every tick (sequenced: a late one is
// worthless), and news of what happened, for sounds and the feed
// (unreliable: a lost bang is no loss).
local net = require("slang/net")

return net.protocol({name: "inkblast", messages: {
  hello: {"name"},
  input: {"dir"},
  drop: {},
  welcome: {"slot", "seed"},
  roster: "any",
  state: {"tick", "left", "phase", "winner", "cells", "paint", "players", "charges", "blasts"},
  news: "any",
}})
