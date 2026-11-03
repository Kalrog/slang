// Tables
//
// The table is slang's one data structure. Its list part is indexed from
// 0; named keys make it a record or a map, and `[expr]: value` computes a
// key. `len` counts the entries, `append` adds to the end, `keys` and
// `values` iterate.
//
// Tables compare by value with `==`, and assigning `null` removes a key
// (only that key: the others keep their indices); `remove(list, i)` takes
// an element out of a list and moves the later ones down.
local fruits = {"apple", "pear"}
append(fruits, "plum")
print(fruits[0], " ", len(fruits), "\n")

local point = {x: 1, y: 2}
point.z = 3
point["x"] = 10
print(point, "\n")

local key = "dynamic"
local t = {[key]: true}
print(t.dynamic, "\n")

for(let local k in keys(point)){
  print(k, "=", point[k], " ")
}
print("\n")
print({1, {a: 2}} == {1, {a: 2}}, "\n")
