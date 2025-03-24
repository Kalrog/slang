part of 'slang_vm.dart';

class SlangVmImplDebug implements SlangVmDebug {
  final SlangVmImpl vm;

  @override
  DebugMode mode = DebugMode.run;

  Set<int> breakPoints = {};
  int? debugInstructionContext = 5;

  bool debugPrintToggle = true;

  bool debugPrintInstructions = true;

  bool debugPrintStack = true;

  bool debugPrintConstants = false;

  bool debugPrintUpvalues = false;

  bool debugPrintOpenUpvalues = false;

  SlangVmImplDebug(this.vm);

  @override
  void debugPrint() {
    if (debugPrintToggle) {
      if (debugPrintInstructions) {
        printInstructions();
      }
      if (debugPrintStack) {
        printStack();
      }
      if (debugPrintConstants) {
        printConstants();
      }
      if (debugPrintUpvalues) {
        printUpvalues();
      }
      if (debugPrintOpenUpvalues) {
        printOpenUpvalues();
      }
    }
  }

  @override
  void printAllStackFrames() {
    for (SlangStackFrame? frame = vm._frame; frame != null; frame = frame.parent) {
      print("Stack:");
      print(frame.toString());
    }
  }

  @override
  void printConstants() {
    print("Constants:");
    print(vm._frame.function!.constantsToString());
  }

  @override
  void printInstructions() {
    print("Instructions:");
    print(vm._frame.function!
        .instructionsToString(pc: vm._frame.pc, context: debugInstructionContext));
  }

  @override
  void printOpenUpvalues() {
    print("Open Upvalues:");
    for (final upvalue in vm._frame.openUpvalues.values) {
      print('${upvalue.index}: $upvalue');
    }
  }

  @override
  void printStack() {
    print("Stack:");
    print(vm._frame.toString());
  }

  @override
  void printUpvalues() {
    print("Upvalues:");
    for (var i = 0; i < vm._frame.function!.upvalues.length; i++) {
      print('${vm._frame.function!.upvalues[i]}: ${vm._frame.closure!.upvalues[i]}');
    }
  }

  void _runDebugFunctionality() {
    if (mode == DebugMode.run) {
      return;
    }
    bool brk = false;
    if (breakPoints.contains(vm._frame.pc) && mode == DebugMode.runDebug) {
      brk = true;
    }
    if (mode == DebugMode.step) {
      brk = true;
    }
    if (mode case DebugMode.runDebug || DebugMode.step) {
      debugPrint();
    }
    while (brk) {
      final instr = io.stdin.readLineSync();
      switch (instr) {
        case 'c':
          mode = DebugMode.runDebug;
          brk = false;
        case '.' || '':
          mode = DebugMode.step;
          brk = false;
        case 's' || 'stk' || 'stack':
          printStack();
        case 'i' || 'ins' || 'instructions':
          printInstructions();
        case 'c' || 'const' || 'constants':
          printConstants();
        case 'u' || 'up' || 'upvalues':
          printUpvalues();
        case 'd' || 'debug':
          debugPrintToggle = !debugPrintToggle;
        case _ when instr!.startsWith("toggle"):
          switch (instr.replaceFirst("toggle", "").trim()) {
            case 'i' || 'ins' || 'instructions':
              debugPrintInstructions = !debugPrintInstructions;
            case 's' || 'stk' || 'stack':
              debugPrintStack = !debugPrintStack;
            case 'c' || 'const' || 'constants':
              debugPrintConstants = !debugPrintConstants;
            case 'u' || 'up' || 'upvalues':
              debugPrintUpvalues = !debugPrintUpvalues;
            case 'o' || 'open' || 'openupvalues':
              debugPrintOpenUpvalues = !debugPrintOpenUpvalues;
          }
        default:
          // set [name] [value]
          final setRegex = RegExp(r'set (\w+) (.+)');
          final setMatch = setRegex.firstMatch(instr);
          if (setMatch != null) {
            final name = setMatch.group(1);
            final value = setMatch.group(2);
            switch (name) {
              case 'mode':
                switch (value) {
                  case 'run':
                    mode = DebugMode.run;
                  case 'step':
                    mode = DebugMode.step;
                }
              case 'instr_context':
                debugInstructionContext = int.tryParse(value ?? "null");
            }
          }

          // b[reak] [pc]
          final breakRegex = RegExp(r'b(reak)? (\d+)?');
          final breakMatch = breakRegex.firstMatch(instr);
          if (breakMatch != null) {
            final pc = int.tryParse(breakMatch.group(2) ?? "null");
            if (pc != null) {
              if (breakPoints.contains(pc)) {
                breakPoints.remove(pc);
                print("Removed breakpoint at $pc");
              } else {
                breakPoints.add(pc);
                print("Set breakpoint at $pc");
              }
            }
          }
          //b(reak)? @line
          final breakLineRegex = RegExp(r'b(reak)? @(\d+)?');
          final breakLineMatch = breakLineRegex.firstMatch(instr);
          if (breakLineMatch != null) {
            final line = int.tryParse(breakLineMatch.group(2) ?? "null");

            if (line != null) {
              int? pc;
              for (int i = 1; i < vm._frame.function!.sourceLocations.length; i++) {
                if (vm._frame.function!.sourceLocations[i].location.line == line) {
                  pc = vm._frame.function!.sourceLocations[i].firstInstruction;
                  break;
                }
                if (vm._frame.function!.sourceLocations[i].location.line > line &&
                    vm._frame.function!.sourceLocations[i - 1].location.line <= line) {
                  pc = vm._frame.function!.sourceLocations[i - 1].firstInstruction;
                  break;
                }
              }
              pc ??= vm._frame.function!.sourceLocations.last.firstInstruction;
              if (breakPoints.contains(pc)) {
                breakPoints.remove(pc);
                print("Removed breakpoint at $pc");
              } else {
                breakPoints.add(pc);
                print("Set breakpoint at $pc");
              }
            }
          }
      }
    }
  }
}
