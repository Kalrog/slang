// Variables
//
// `local` declares a variable in the current block. Locals are lexical: a
// function sees the locals around it where it is written, and a block's
// locals end with the block. A name can be declared only once where it is
// visible: slang reports a shadowed variable as an error instead of
// letting two meanings of one name coexist.
//
// A name assigned without `local` is a global. Programs keep globals for
// what really is global; modules use locals. Globals start with an
// uppercase letter: the editor warns about a lowercase one, which is
// usually a typo or a forgotten `local`. `global name = ...` declares one
// on purpose, whatever its name.
local count = 1
{
  local inner = count + 1
  print("inner ", inner, "\n")
}
count = count + 10
print("count ", count, "\n")

Greeting = "a global"
print(Greeting, "\n")
