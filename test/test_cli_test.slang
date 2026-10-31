// slang test --json and --only, and its exit code
local t = require("slang/test")
local str = require("slang/string")
local os = require("slang/os")

local dir = concat(
  os.getenv("TMPDIR") or "/tmp/", "/slang-test-cli-", string(os.time_ms())
)

t.group("slang test"){
  t.test("--json reports each test, --only picks some, failures exit 1"){
    os.mkdir_all(dir)
    os.write_file(concat(dir, "/demo_test.slang"), str.join({
      "local t = require(\"slang/test\")",
      "t.group(\"g\"){",
      "  t.test(\"ok\"){ assert(true) }",
      "  t.test(\"bad\"){ assert(1 == 2, \"one is not two\") }",
      "}",
      "",
    }, "\n"))
    local slang = os.executable()
    local r = os.exec({
      slang, "test", "--json", concat(dir, "/demo_test.slang")
    })
    assert(r.status == 1, r.stdout)
    assert(str.index_of(
      r.stdout,
      "{\"event\":\"test\",\"path\":[\"g\",\"ok\"],\"status\":\"passed\"}",
    ) >= 0, r.stdout)
    assert(
      str.index_of(r.stdout, "\"message\":\"one is not two\"") >= 0,
      r.stdout,
    )
    r = os.exec({
      slang, "test", "--json", "--only", "g / ok",
      concat(dir, "/demo_test.slang")
    })
    assert(r.status == 0, r.stdout)
    assert(str.index_of(
      r.stdout,
      "{\"event\":\"done\",\"passed\":1,\"failed\":0}",
    ) >= 0, r.stdout)
    os.exec({"rm", "-rf", dir})
  }
}
