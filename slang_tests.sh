#!/bin/zsh
dart compile exe bin/slang.dart
for test in test/*_test.slang; do
  echo "Running $test"
  bin/slang.exe run $test
done