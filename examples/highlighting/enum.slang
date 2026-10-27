// extensions/enum: `enum` is a keyword the extension adds; the name is
// tagged enum.declaration and the members enumMember.declaration, so a
// theme colours them like an enum in any other language.
extension "extensions/enum"

enum Color { Red, Green, Blue }
enum Direction { North, East, South, West }

local func describe(c){
  if(c == Color.Red){ return "warm" }
  if(c == Color.Blue){ return "cold" }
  return "mild"
}

for(let local name in values({Color.Red, Color.Green, Color.Blue})){
  print(name, " is ", describe(name), "\n")
}
print("facing ", Direction.North, "\n")
