local t = require("test/testing")

t.group("metatables"){

    t.test("metatable __index basic"){
        local foo = {
            type: "Foo",
            bar: 42,
        }

        local bar = {
            type: "Bar",
            fooBar: 12,
        }

        bar.meta = {
            "__index": foo,
        }

        assert(bar.bar == 42, "metatable get table (__index) correctly")
        assert(bar.fooBar == 12, "metatable get normal table value correctly")
    }

    t.test("metatable __index works for pattern matching"){
        local foo = {
            type: "Foo",
            bar: 42,
        }

        local bar = {
            type: "Bar",
            fooBar: 12,
        }

        bar.meta = {
            "__index": foo,
        }

        if(not let {type: "Bar", bar: 42} = bar){
          assert(false, "should never reach here")
        }
    }

    t.test("metatable __index set value"){
      local foo = {
          type: "Foo",
          bar: 42,
      }
      local bar = {
          type: "Bar",
          fooBar: 12,
      }
      bar.meta = {
          "__index": foo,
      }
      bar.bar = 12
      assert(bar.bar == 12, "metatable set table value correctly")
      assert(foo.bar == 42, "metatable set table value correctly")
    }

    t.test("metatable __newindex"){
      local foo = {
          type: "Foo",
          bar: 42,
      }
      local bar = {
          type: "Bar",
          fooBar: 12,
      }
      bar.meta = {
          "__newindex": foo,
      }
      bar.bar = 12
      assert(foo.bar == 12, "metatable set table value correctly")
      bar.newField = 42
      assert(foo.newField == 42, "metatable set table value correctly")
      assert(bar.newField == null, "metatable set table only on meta table not on the table itself")
    }

    t.test("metatable __index function"){
      local expectedField
      local expectedTable
      local func expect(table,field){
        expectedField = field
        expectedTable = table
      }
      local func index(table, key){
        assert(table == expectedTable, "metatable __index function table is correct")
        assert(key == expectedField, "metatable __index function key is correct")
        return true
      }

      local foo = {
          type: "Foo",
          bar: 42,
      }

      foo.meta = {
          "__index": index,
      }

      expect(null, null)
      assert(foo.bar == 42, "__index is only called when field is not found")
      expect(foo, "foo")
      assert(foo.foo == true, "__index works and is called")
    }

    t.test("metatable __newindex function"){
      local expectedField
      local expectedTable
      local expectedValue
      local func expect(table,field,value){
        expectedField = field
        expectedTable = table
        expectedValue = value
      }
      local func newindex(table, key, value){
      assert(table == expectedTable, "metatable __newindex function table is correct")
      assert(key == expectedField, "metatable __newindex function key is correct")
      assert(value == expectedValue, "metatable __newindex function value is correct")
      }
      local foo = {
        type: "Foo",
        bar: 42,
      }
      foo.meta = {
        "__newindex": newindex,
      }
      expect(null, null, null)
      foo.bar = 42
      assert(foo.bar == 42, "__newindex is only called when field is not found")
      expect(foo, "foo", 42)
      foo.foo = 42
      assert(foo.foo == null, "__newindex works and is called")
    }

}
