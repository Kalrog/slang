enum PatternAssemblyStep {
  /// Checking if the value matches the pattern
  check,

  /// Assigning variables inside the pattern if the pattern matched
  assign,
}

class PatternAssembler {
  PatternAssemblyStep _step = PatternAssemblyStep.check;

  PatternAssemblyStep get step => _step;

  PatternAssembler();

  void completedCheck() {
    if (step != PatternAssemblyStep.check) {
      throw Exception('Cannot complete check step after completing the assign step');
    }
    _step = PatternAssemblyStep.assign;
  }
}
