// tool/scenes/life_cast: the valley's singers one by one (sound/life),
// each alone and close by: four songs of every member of the cast, two
// by one bird and two by another, so that what stays (the kind's song)
// and what differs (the bird, the time) can be seen in a spectrogram.
// The songs go through the mixer as in the game (the life layer alone),
// with the place's reflections off and at a level far above the game's.
//
// Arguments: the members to hear (all by default: tit chaffinch
// chiffchaff blackbird woodpecker cuckoo buzzard raven marmot bee), and
// "far" to hear them from a hundred meters (duller, the highs gone).
// Prints when each song starts and how long it is.
local str = require("slang/string")
local params = require("sound/params")
local life = require("sound/life")

return func(kit, args){
  local wanted = {}
  local cutoff = 16000
  for(let local a in values(args)){
    if(a == "far"){
      cutoff = 16000 / (1 + 100 / 22)
    } else if(life.index[a] != null){
      append(wanted, life.index[a])
    }
  }
  if(len(wanted) == 0){
    for(local i = 0; i < len(life.CAST); i = i + 1){
      append(wanted, i)
    }
  }
  // the songs and when each starts
  local scratch = life.song(kit.RATE)
  local songs = {}
  local at = 0.5
  for(let local member in values(wanted)){
    local bird = life.CAST[member]
    for(local k = 0; k < 4; k = k + 1){
      local who = 1001 + to_int(k / 2) + member * 10
      local kind = k % bird.types
      local variation = 17 + k
      life.compose(scratch, member, who, kind, variation)
      append(songs, {member: member, who: who, kind: kind, variation: variation, at: at, length: scratch.length})
      print(str.format("%6.2f s  %-10s bird %d song %d: %.2f s, %d syllables\n", at, bird.name, who, kind, scratch.length, scratch.count))
      at = at + scratch.length + 1.2
    }
    at = at + 0.8
  }
  local next = 0
  return kit.mix(at, func(t, set, send){
    set("master", 1)
    set("space_ground", 0)
    set("space_tail", 0)
    set("life_0_left", 0.2)
    set("life_0_right", 0.2)
    set("life_0_far", cutoff)
    if(next < len(songs) and t >= songs[next].at){
      local song = songs[next]
      send(params.EVENTS.life + song.member, 0, song.who, song.kind + 64 * song.variation)
      next = next + 1
    }
  }, {only: {"life"}})
}
