// game/missions: the jobs, in order. Each is a map (dsl/map: game/grid
// lists the glyphs), a briefing, and the settings of its objects
// (game/world lists them); a port's network is what its deck reaches.
// test/missions_test.slang plays every one with the autopilot.
extension "dsl/map"

map doorman {
  ###########
  #S....P####
  #......D.$#
  #......####
  ##E########
}

map timing {
  ##################
  #P..............S#
  #.################
  #.#
  #.#####
  #........D...$.E#
  #################
}

map eyes {
  ################
  #S..#.........<#
  #...#.######.###
  #P....#    #$.E#
  #######    #####
}

map tripwire {
  ###################
  #S.P###############
  #...L.........D.$E#
  ###################
}

map pulse {
  ####################
  #.................<#
  #.#######^######.###
  #S#     ###    #.$E#
  #P#             ####
  ###
}

map relay {
  ###########################
  #S.P#P#####################
  #...D...............L..D$E#
  #########%%%%%%%%%%########
          #.........#
          #...^.....#
          ###########
}

local missions = {
  {
    name: "doorman",
    title: "Doorman",
    map: doorman,
    briefing: {
      "A locked door between you and the dossier.",
      "",
      "Walk up to the hack port (the blue screen), look at it and press E.",
      "Your deck runs slang. Type",
      "    door1.open()",
      "and press Enter. Esc puts the deck away.",
      "Take the dossier, then leave through the exit (the green light).",
    },
    objects: {port1: {network: {"door1"}}},
  },
  {
    name: "timing",
    title: "Timing",
    map: timing,
    briefing: {
      "This door stays open for three seconds at most, and the port",
      "is a long way from it. Scripts keep running after you unplug:",
      "    wait(2); door1.open(3)",
      "waits two seconds before opening it. Start the script and run.",
      "",
      "Shift+Enter starts a new line, Up and Down recall what you typed.",
    },
    objects: {
      door1: {limit: 3, rest: 6},
      port1: {network: {"door1"}},
    },
  },
  {
    name: "eyes",
    title: "Eyes",
    map: eyes,
    briefing: {
      "A camera watches the corridor. If it sees you for half a second,",
      "the alarm goes off. Cameras switch off for a while:",
      "    cam1.off(6)",
      "It comes back on by itself, and needs time before the next off.",
      "The dossier is past the corridor.",
      "",
      "help() lists what a port reaches.",
    },
    objects: {
      cam1: {range: 12, fov: 30, sweep: 0, limit: 6, rest: 10},
      port1: {network: {"cam1"}},
    },
  },
  {
    name: "tripwire",
    title: "Tripwire",
    map: tripwire,
    briefing: {
      "A laser fence, then a door at the far end of the hall.",
      "Neither stays off or open for long, and both need a rest after.",
      "One script can do several things in turn:",
      "    laser1.off(3); wait(1); door1.open(3)",
      "Work out when you will reach each of them.",
    },
    objects: {
      laser1: {limit: 3, rest: 8},
      door1: {limit: 3, rest: 8},
      port1: {network: {"laser1", "door1"}},
    },
  },
  {
    name: "pulse",
    title: "Pulse",
    map: pulse,
    briefing: {
      "Two cameras, and these ones only go dark for two seconds,",
      "but they can go dark again at once. The deck has loops:",
      "    for(local i = 0; i < 3; i = i + 1){",
      "      cam1.off(2); wait(2)",
      "    }",
      "Your own functions work too: func blind(){ ... }",
    },
    objects: {
      cam1: {range: 18, fov: 30, sweep: 0, limit: 2},
      cam2: {range: 4, fov: 40, sweep: 140, period: 4, limit: 2},
      port1: {network: {"cam1", "cam2"}},
    },
  },
  {
    name: "relay",
    title: "Relay",
    map: relay,
    briefing: {
      "The last job. port1 only reaches the first door; the second port,",
      "past it, reaches the rest. Glass stops you, not the camera behind it.",
      "Everything on the far network is short-lived. Plan one script,",
      "start it, and run.",
    },
    objects: {
      cam1: {range: 9, fov: 50, sweep: 80, period: 5, limit: 7, rest: 15},
      laser1: {limit: 7, rest: 15},
      door2: {limit: 3, rest: 10},
      port1: {network: {"door1"}},
      port2: {network: {"cam1", "laser1", "door2"}},
    },
  },
}

return missions
