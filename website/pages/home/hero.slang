local people = {
  {name: "Ada", born: 1815},
  {name: "Grace", born: 1906},
  {name: "Alan", born: 1912},
}

for(let {name: local n, born: local b} in values(people)){
  print(n, " was born ", 2026 - b, " years ago\n")
}
