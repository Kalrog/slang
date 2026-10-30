// extensions/custom_operators: infix/prefix/postfix are keywords, and the
// operators they define are tagged operator, both in the definition and
// where they are used.
extension "extensions/custom_operators"

infix _<>_ before _==_ (left, right){
  return concat(string(left), string(right))
}

infix _**_ right (base, exponent){
  return base ^ exponent
}

prefix |-_ before _==_ (value){
  if(value < 0){ return -value }
  return value
}

postfix _! before _unary_ (n){
  local r = 1
  for(local i = 2; i <= n; i = i + 1){ r = r * i }
  return r
}

print(1 <> 2 <> 3, "\n")
print(2 ** 3 ** 2, "\n")
print(|- - 7, "\n")
print(5!, "\n")
