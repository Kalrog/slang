# Legacy Dart implementation

This is the original Dart implementation of slang, kept as the stage-0
bootstrap reference. It is not used by the Go toolchain. It still runs:

```sh
cd legacy
dart pub get
dart run bin/slang.dart run ../test/all_tests.slang
dart run tool/stage0.dart --ast ../test/closures_test.slang   # AST dump used by tool/ast_oracle.sh
```

`tool/ast_oracle.sh` and `tool/bytecode_oracle.sh` in the repository root
compare this implementation with the self-hosted compiler.
