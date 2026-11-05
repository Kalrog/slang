// pegc lives in the compiler now (slang/compiler/pegc.slang); this is it
// (the source file first, so that changes to it show before a reseed)
return try {
  require("slang/compiler/pegc")
} catch({kind: ^error.kinds.not_found}) {
  require("slang/pegc")
}
