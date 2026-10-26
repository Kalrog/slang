// What drops from whom (dsl/loot). The chances of a table must stay within 100%.
extension "dsl/loot"

loot goblin {
  40% coins(1, 3)
  15% potion
}

loot bat {
  20% coins(1, 1)
}

loot chest {
  45% potion
  35% coins(5, 10)
  20% sword
}
