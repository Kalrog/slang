#!/bin/sh
dart compile exe bin/slang.dart
for test in test/*_test.slang; do
  echo "Running $test"
  bin/slang.exe run $test
  # print error if the test failed
  if [ $? -ne 0 ]; then
    echo "Test failed"
    exit 1
  fi
done
