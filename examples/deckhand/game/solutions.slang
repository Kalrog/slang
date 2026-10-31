// game/solutions: a way through every mission, as autopilot steps. The
// tests prove them; DECKHAND_DEMO=<mission> plays one on screen.
return {
  doorman: {
    {go: "port1"}, {jack: "port1"}, {type: "door1.open()"}, {unjack: true},
    {go: "dossier"}, {go: "exit"}
  },
  timing: {
    {go: "port1"}, {jack: "port1"}, {type: "wait(2); door1.open(3)"},
    {unjack: true}, {go: "dossier"}, {go: "exit"}
  },
  eyes: {
    {go: "port1"}, {jack: "port1"}, {type: "cam1.off(6)"}, {unjack: true},
    {go: "dossier"}, {go: "exit"}
  },
  tripwire: {
    {go: "port1"}, {jack: "port1"},
    {type: "laser1.off(3); wait(2); door1.open(3)"}, {unjack: true},
    {go: "dossier"}, {go: "exit"}
  },
  pulse: {
    {go: "port1"},
    {jack: "port1"},
    {
      type: "for(local i = 0; i < 4; i = i + 1){ cam1.off(2); cam2.off(2); wait(2) }",
    },
    {unjack: true},
    {go: "dossier"},
    {go: "exit"},
  },
  relay: {
    {go: "port1"}, {jack: "port1"}, {type: "door1.open()"}, {unjack: true},
    {go: "port2"}, {jack: "port2"},
    {type: "cam1.off(6); laser1.off(7); wait(4); door2.open(3)"},
    {unjack: true}, {go: "dossier"}, {go: "exit"}
  },
}
