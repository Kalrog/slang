import 'package:petitparser/petitparser.dart';
import 'package:petitparser/reflection.dart';
import 'package:slang/slang.dart';

void main(List<String> arguments) {
  Parser parser = SlangParser().build();
  optimize(parser, callback: (old, newp) {
    print("old: $old");
    print("new: $newp");
  });
}
