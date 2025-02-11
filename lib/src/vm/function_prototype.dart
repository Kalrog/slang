import 'dart:collection';

/// Prototype for a function.
/// The prototype contains a functions instructions and constants.
/// The prototype can be used to execute the function.
class FunctionPrototype {
  final UnmodifiableListView<int> instructions;
  final UnmodifiableListView<Object?> constants;
  final int maxStackSize;

  FunctionPrototype(
    List<int> instructions,
    List<Object?> constants, {
    required this.maxStackSize,
  })  : instructions = UnmodifiableListView(instructions),
        constants = UnmodifiableListView(constants);
}
