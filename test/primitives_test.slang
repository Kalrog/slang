// test that all primitives exist and work
print("test null");
assert(null != 1);
assert(null == null);
print("test int");
assert(1 == 1);
assert(1 + 1 == 2);
print("test float");
assert(1.0 == 1.0);
assert((1.0 + 1.0) > 1.9);
print("test string");
assert("foo" == "foo");
print("test bool");
assert(true == true);
assert(true != false);
