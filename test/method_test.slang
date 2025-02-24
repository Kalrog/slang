local thing = {
  a: 1
}

local func thing.inc(self) {
  self.a = self.a + 1
}

thing:inc()
assert(thing.a == 2)

