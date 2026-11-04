// Writes the root grammar's generated parsers (slang/pegc) as bytecode,
// to be embedded in the compiler as the module slang/pegc_root:
//   bin/slang run slang/seed_parsers.slang boot/slang/pegc_root.slb
// `make seed` runs it after building, so the module matches the grammar
// of the compiler it ships with (and `make fixpoint` checks it does). At
// run time compiler.pegc_cache compares the hash of what it generates
// with the module's and uses it when they match: no compile, no cache.
local compiler = require("slang/compiler")
local pegc = require("slang/pegc")
local os = require("slang/os")
local vm = require("slang/vm")

local out = args()[0] or "boot/slang/pegc_root.slb"
local g = compiler.grammar()
// the grammar as it is, not generated while being generated
g.state.opts.pegc = "off"
g:parse_source("local x = 1", "seed")
local made = pegc.compile(g)
local f = compile(made:embeddable(), "slang/pegc_root")
os.write_file(out, vm.to_bytes(f))
print("seed: root parsers -> ", out, " (", made.hash, ", ", made.functions, " functions)\n")
