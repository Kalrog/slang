#!/bin/zsh
for test in test/*_test.slang; do
  echo "Running $test"
  dart run bin/slang.dart run $test
done