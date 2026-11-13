// game/garage: what can be chosen about the truck. A setup is a table
// with one option's id per category; the renderer builds the truck a
// setup describes (render/truck), a menu walks the categories and their
// options, and nothing here needs a window.
//
//   local setup = garage.default()
//   garage.next(setup, "paint")          // the next color
//   garage.option("roof", setup.roof).name
//   garage.categories                    // in the order a menu shows them
local m = {}

// A choice of a category.
// type Option = {id: string, name: string, color?: {int}, about?: string}
// [color]: for paints, r, g, b as the screen shows them (0..255)

// A group of choices.
// type Category = {id: string, name: string, options: {Option}}

m.categories = {
  {
    id: "paint", name: "Paint",
    options: {
      {id: "dune", name: "Dune", color: {196, 168, 122}},
      {id: "moss", name: "Moss", color: {88, 104, 62}},
      {id: "ember", name: "Ember", color: {196, 84, 32}},
      {id: "glacier", name: "Glacier", color: {150, 176, 190}},
      {id: "slate", name: "Slate", color: {70, 76, 84}},
      {id: "chalk", name: "Chalk", color: {226, 222, 208}},
      {id: "signal", name: "Signal", color: {226, 172, 28}},
      {id: "brick", name: "Brick", color: {150, 38, 30}},
      {id: "lagoon", name: "Lagoon", color: {24, 110, 116}},
      {id: "night", name: "Night", color: {24, 26, 30}},
    },
  },
  {
    id: "roof_paint", name: "Roof",
    options: {
      {id: "body", name: "Body color"},
      {id: "chalk", name: "Chalk", color: {226, 222, 208}},
      {id: "night", name: "Night", color: {24, 26, 30}},
    },
  },
  {
    id: "wheels", name: "Wheels",
    options: {
      {id: "steel", name: "Steel", about: "pressed steel, painted"},
      {id: "beadlock", name: "Beadlock", about: "black, a bolted ring holds the bead"},
      {id: "alloy", name: "Six spoke", about: "cast alloy"},
    },
  },
  {
    id: "bumper", name: "Front bumper",
    options: {
      {id: "stock", name: "Stock"},
      {id: "bar", name: "Bull bar", about: "steel, with a hoop over the grille"},
      {id: "winch", name: "Winch bumper", about: "steel, a winch behind a roller fairlead"},
    },
  },
  {
    id: "roof", name: "Roof load",
    options: {
      {id: "none", name: "Bare"},
      {id: "rack", name: "Basket rack"},
      {id: "expedition", name: "Expedition", about: "a platform with cans, boards, a shovel and a case"},
      {id: "tent", name: "Roof tent"},
    },
  },
  {
    id: "light_bar", name: "Light bar",
    options: {
      {id: "none", name: "None"},
      {id: "roof", name: "Over the windscreen"},
    },
  },
  {
    id: "snorkel", name: "Snorkel",
    options: {
      {id: "none", name: "None"},
      {id: "snorkel", name: "Raised intake"},
    },
  },
  {
    id: "spare", name: "Spare wheel",
    options: {
      {id: "tailgate", name: "On the tailgate"},
      {id: "none", name: "None"},
    },
  },
  {
    id: "sides", name: "Sills",
    options: {
      {id: "none", name: "Bare"},
      {id: "sliders", name: "Rock sliders"},
      {id: "steps", name: "Side steps"},
    },
  },
  {
    id: "flaps", name: "Mud flaps",
    options: {
      {id: "none", name: "None"},
      {id: "flaps", name: "Fitted"},
    },
  },
}

m.by_id = {}
for(let local c in values(m.categories)){
  m.by_id[c.id] = c
}

// category(id: string) -> Category (raises for a name that is none)
func m.category(id){
  local c = m.by_id[id]
  if(c == null){
    raise(error.new(error.kinds.argument, concat("garage: no category ", string(id))))
  }
  return c
}

// index_of(category: string, option: string) -> int, or -1
func m.index_of(category, option){
  local options = m.category(category).options
  for(local i = 0; i < len(options); i = i + 1){
    if(options[i].id == option){
      return i
    }
  }
  return -1
}

// option(category: string, id: string) -> Option, the category's first
// when id names none
func m.option(category, id){
  local options = m.category(category).options
  local i = m.index_of(category, id)
  if(i < 0){
    i = 0
  }
  return options[i]
}

// default() -> Setup: the truck as it stands at the start
// type Setup = {paint: string, roof_paint: string, wheels: string,
//   bumper: string, roof: string, light_bar: string, snorkel: string,
//   spare: string, sides: string, flaps: string}
func m.default(){
  return {
    paint: "ember",
    roof_paint: "chalk",
    wheels: "steel",
    bumper: "winch",
    roof: "rack",
    light_bar: "none",
    snorkel: "snorkel",
    spare: "tailgate",
    sides: "sliders",
    flaps: "flaps",
  }
}

// plain() -> Setup: nothing fitted
func m.plain(){
  local setup = {}
  for(let local c in values(m.categories)){
    setup[c.id] = c.options[0].id
  }
  setup.spare = "none"
  return setup
}

// complete(setup?: table) -> Setup: every category filled in, what names
// no option replaced by the default
func m.complete(setup){
  local out = m.default()
  if(setup != null){
    for(let local c in values(m.categories)){
      local v = setup[c.id]
      if(v != null and m.index_of(c.id, v) >= 0){
        out[c.id] = v
      }
    }
  }
  return out
}

// next(setup, category: string, step?: int) -> Option
// Moves a category of a setup to its next option (step -1: the one
// before), around the ends, and returns it.
func m.next(setup, category, step){
  local options = m.category(category).options
  local i = m.index_of(category, setup[category])
  if(i < 0){
    i = 0
  }
  local n = len(options)
  i = (i + (step or 1) + n) % n
  setup[category] = options[i].id
  return options[i]
}

// key(setup) -> string: the same for the same setup (what a cache of
// built trucks is keyed by)
func m.key(setup){
  local parts = {}
  for(let local c in values(m.categories)){
    append(parts, string(setup[c.id]))
    append(parts, "/")
  }
  return concat(...parts)
}

// parse(text: string) -> Setup: "paint=moss,roof=tent" over the default
func m.parse(text){
  local str = require("slang/string")
  local setup = {}
  for(let local part in values(str.split(text, ","))){
    local eq = str.index_of(part, "=")
    if(eq > 0){
      setup[str.trim(str.substring(part, 0, eq))] = str.trim(str.substring(part, eq + 1))
    }
  }
  return m.complete(setup)
}

// paint_color(setup) -> {r, g, b} of the body; roof_color(setup) of the roof
func m.paint_color(setup){
  return m.option("paint", setup.paint).color
}

func m.roof_color(setup){
  local o = m.option("roof_paint", setup.roof_paint)
  if(o.color == null){
    return m.paint_color(setup)
  }
  return o.color
}

return m
