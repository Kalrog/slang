import 'package:slang/src/codegen/function_assembler.dart';

enum PatternAssemblyStep {
  /// Checking if the value matches the pattern
  check,

  /// Assigning variables inside the pattern if the pattern matched
  assign,
}

class PatternAssembler {
  PatternAssemblyStep _step = PatternAssemblyStep.check;
  PatternAssemblyStep get step => _step;
  List<int> _missmatchJumps = [];
  int _stackIncrease = 0;

  final FunctionAssembler _parent;

  PatternAssembler(this._parent);

  void completeCheckStep() {
    if (step != PatternAssemblyStep.check) {
      throw Exception('Cannot complete check step after completing the assign step');
    }
    _step = PatternAssemblyStep.assign;
  }

  void closeMissmatchJumps() {
    for (final jump in _missmatchJumps) {
      _parent.patchJump(jump);
    }
  }

  void increaseStackHeight() {
    _stackIncrease++;
  }

  void decreaseStackHeight() {
    _stackIncrease--;
  }

  void testMissmatch({required bool missmatchIf}) {
    _parent.emitTest(!missmatchIf);
    final matchJump = _parent.emitJump();
    if (_stackIncrease > 0) {
      _parent.emitPop(0, _stackIncrease);
    }
    _missmatchJumps.add(_parent.emitJump());
    _parent.patchJump(matchJump);
  }
}
