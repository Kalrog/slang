#!/bin/sh
dart compile exe bin/slang.dart
# for test in test/*_test.slang; do
#   echo "Running $test"
#   bin/slang.exe run $test
#   # print error if the test failed
#   if [ $? -ne 0 ]; then
#     echo "Test failed"
#     exit 1
#   fi
# done
rm test/all_tests.slang
echo "local test = require(\"test/testing\")" >> test/all_tests.slang
for test in test/*_test.slang; do
  #remove the .slang extension
  test=${test%.slang}
  printf "require(\"$test\")\n" >> test/all_tests.slang
done
echo "test.run()" >> test/all_tests.slang

bin/slang.exe run test/all_tests.slang