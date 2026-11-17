// Variables
//
// `local` declares a variable in the current block. Locals are lexical: a
// function sees the locals around it where it is written, and a block's
// locals end with the block. An inner block may declare a name again,
// which hides the outer one until the block ends; declaring a name twice
// in one block is an error.
//
// A name assigned without `local` is a global. Programs keep globals for
// what really is global; modules use locals. Globals start with an
// uppercase letter: the editor warns about a lowercase one, which is
// usually a typo or a forgotten `local`. `global name = ...` declares one
// on purpose, whatever its name.
local count = 1
{
  local count = 100
  local inner = count + 1
  print("inner ", inner, "\n")
}
count = count + 10
print("count ", count, "\n")

Greeting = "a global"
print(Greeting, "\n")
