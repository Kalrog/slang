
print("Hello World\n")

-{block:
 func ternary(cond, true_case, false_case){
    print("Calling ternary\n")
    return +{
      func(){
        print("Evaluating ternary\n")
        if(-{cond}){
          return -{true_case}
        } else {
          return -{false_case}
        }
      }()
      }
    }
 } 

 print(-{ternary(+{func(){
  print("I am being evaluated\n")
  return true
 }()},+{"true"},+{"false"})})

 -{block:
  local p = require("slang/parser")
  p.add_statement(
    "print_hello",
    p.keyword("print_hello"):map(func(result){
      return +{stat: 
        print("Hello")
      }
    })
  )
 }

print_hello

