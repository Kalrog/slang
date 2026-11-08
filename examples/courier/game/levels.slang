// game/levels: the districts, from the wide and slow outskirts to the
// core. Each is a set of numbers the city generator, the traffic and the
// jobs read: the grid, the street width, the heights and how much hangs
// off the towers, the bridges, the lane heights and how many lanes run
// side by side (three each way in the core), how many cars and how fast,
// the time a delivery gets,
// and how many deliveries move you on. Past the last district the core
// comes back faster each time.
local m = {}

m.list = {
  {
    name: "Outskirts", n: 8, block: 64, street: 56, height: {36, 120},
    tiers: 2, decor: 0.35, bridges: 0.25, tubes: 0.2, halos: 0,
    lane_levels: {24, 64, 104}, lane_offsets: {6},
    cars: 1400, speed: {11, 19}, time_speed: 13, deliveries: 3,
  },
  {
    name: "Midtown", n: 9, block: 70, street: 44, height: {45, 190},
    tiers: 3, decor: 0.6, bridges: 0.45, tubes: 0.3, halos: 0.15,
    lane_levels: {24, 54, 84, 114, 144}, lane_offsets: {6},
    cars: 2800, speed: {15, 27}, time_speed: 16, deliveries: 4,
  },
  {
    name: "Downtown", n: 10, block: 76, street: 32, height: {45, 275},
    tiers: 3, decor: 0.85, bridges: 0.6, tubes: 0.4, halos: 0.3,
    lane_levels: {24, 54, 84, 114, 144, 174}, lane_offsets: {6},
    cars: 5500, speed: {17, 34}, time_speed: 19, deliveries: 5,
  },
  {
    name: "The Core", n: 10, block: 80, street: 44, height: {60, 300},
    tiers: 4, decor: 1, bridges: 0.8, tubes: 0.5, halos: 0.4,
    lane_levels: {24, 54, 84, 114, 144, 174, 204}, lane_offsets: {5, 9.5, 14},
    cars: 9000, speed: {24, 42}, time_speed: 23, deliveries: 6,
  },
}

// get(index) -> the level (from 0); past the list, the last one faster
func m.get(index){
  if(index < len(m.list)){
    return m.list[index]
  }
  local last = m.list[len(m.list) - 1]
  local k = index - len(m.list) + 1
  local level = {}
  for(let local e in entries(last)){
    level[e[0]] = e[1]
  }
  level.name = concat(last.name, " +", string(k))
  level.speed = {last.speed[0] * (1 + 0.12 * k), last.speed[1] * (1 + 0.12 * k)}
  level.cars = to_int(last.cars * (1 + 0.1 * k))
  level.time_speed = last.time_speed + 1.5 * k
  return level
}

m.default = m.list[2]

return m
