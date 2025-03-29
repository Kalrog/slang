-{block:
  local p = require("slang/parser")
   p.add_statement(
    p.seq(
      p.keyword("unless"),
      p.token("("),
      p.expr(),
      p.token(")"),
      p.block()
    ):map(func(list){
      return {
        token:list[0],
        ast:+{stat:
            if(not -{list[2]}){
              -{list[4]}
            }
        }
      }
    })
  );
  p.add_statement(
    p.seq(
      p.keyword("do"),
      p.block(),
      p.keyword("while"),
      p.token("("),
      p.expr(),
      p.token(")")
    ):map(func(list){
      local first_run = p.uniq_id()
      return {
        token:list[0],
        ast:+{block:
            local -{first_run} = true
            for(-{list[4]} or -{first_run}){
              -{list[1]}
              -{first_run} = false
            }
        }
      }
    })
  );
  print("        added do while\n");
}
print("start\n")

local a = true

print(-{block:
print("should only","print once\n")
return +{a}
}, "should print true\n")

unless(a){
  print("a is not 1\n")
}
print("a is 1\n")

do{
  print("should print once\n")
}while(not a)

