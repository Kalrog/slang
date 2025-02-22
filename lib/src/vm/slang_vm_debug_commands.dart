// import 'package:petitparser/petitparser.dart';
//
// class SlangVmDebugCommandParser extends GrammarDefinition {
//   Parser<int> integer() => digit().plus().flatten().trim().map(int.parse);
//
//   Parser
//
//   @override
//   Parser start() => ref0(command).trim().end();
//
//   Parser command() => ref0(cont) | ref0(step) | ref0(inspect);
//
//   Parser cont() => char('c') & string('ontinue').optional();
//
//   Parser step() => char('.');
// }
