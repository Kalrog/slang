import 'dart:math';

import 'package:slang/slang.dart';
import 'package:slang/src/stdlib/package_lib.dart';

class SlangMathLib {
  static final Map<String, DartFunction> _functions = {
    "random": _random,
    "round": _round,
    "floor": _floor,
    "ceil": _ceil,
    "abs": _abs,
    "min": _min,
    "max": _max,
    "sqrt": _sqrt,
    "sin": _sin,
    "cos": _cos,
    "tan": _tan,
    "asin": _asin,
    "acos": _acos,
    "atan": _atan,
    "atan2": _atan2,
    "log": _log,
    "exp": _exp,
  };

  static final Map<String, Object> _constants = {
    "pi": pi,
    "e": e,
  };

  /// random([min=0,] [max=1])
  /// Returns a random double between min and max.
  static bool _random(SlangVm vm) {
    var min = vm.getNumArg(0, name: "min", defaultValue: 0);
    var max = vm.getNumArg(1, name: "max", defaultValue: 1);
    vm.push(Random().nextDouble() * (max - min) + min);
    return true;
  }

  /// round(x)
  /// Returns the nearest integer to x.
  static bool _round(SlangVm vm) {
    var x = vm.getNumArg(0, name: "x");
    vm.push(x.round().toDouble());
    return true;
  }

  /// floor(x)
  /// Returns the largest integer less than or equal to x.
  static bool _floor(SlangVm vm) {
    var x = vm.getNumArg(0, name: "x");
    vm.push(x.floor().toDouble());
    return true;
  }

  /// ceil(x)
  /// Returns the smallest integer greater than or equal to x.
  static bool _ceil(SlangVm vm) {
    var x = vm.getNumArg(0, name: "x");
    vm.push(x.ceil().toDouble());
    return true;
  }

  /// abs(x)
  /// Returns the absolute value of x.
  static bool _abs(SlangVm vm) {
    var x = vm.getNumArg(0, name: "x");
    vm.push(x.abs());
    return true;
  }

  /// min(...numbers)
  /// Returns the smallest number.
  static bool _min(SlangVm vm) {
    num min = double.infinity;
    for (var i = 0; i < vm.getTop(); i++) {
      var x = vm.toAny(i) as num;
      if (x < min) {
        min = x;
      }
    }
    vm.push(min);
    return true;
  }

  /// max(...numbers)
  /// Returns the largest number.
  static bool _max(SlangVm vm) {
    num max = double.negativeInfinity;
    for (var i = 0; i < vm.getTop(); i++) {
      var x = vm.toAny(i) as num;
      if (x > max) {
        max = x;
      }
    }
    vm.push(max);
    return true;
  }

  /// sqrt(x)
  /// Returns the square root of x.
  static bool _sqrt(SlangVm vm) {
    var x = vm.getNumArg(0, name: "x");
    vm.push(sqrt(x));
    return true;
  }

  /// sin(x)
  /// Returns the sine of x.
  static bool _sin(SlangVm vm) {
    var x = vm.getNumArg(0, name: "x");
    vm.push(sin(x));
    return true;
  }

  /// cos(x)
  /// Returns the cosine of x.
  static bool _cos(SlangVm vm) {
    var x = vm.getNumArg(0, name: "x");
    vm.push(cos(x));
    return true;
  }

  /// tan(x)
  /// Returns the tangent of x.
  static bool _tan(SlangVm vm) {
    var x = vm.getNumArg(0, name: "x");
    vm.push(tan(x));
    return true;
  }

  /// asin(x)
  /// Returns the arcsine of x.
  static bool _asin(SlangVm vm) {
    var x = vm.getNumArg(0, name: "x");
    vm.push(asin(x));
    return true;
  }

  /// acos(x)
  /// Returns the arccosine of x.
  static bool _acos(SlangVm vm) {
    var x = vm.getNumArg(0, name: "x");
    vm.push(acos(x));
    return true;
  }

  /// atan(x)
  /// Returns the arctangent of x.
  static bool _atan(SlangVm vm) {
    var x = vm.getNumArg(0, name: "x");
    vm.push(atan(x));
    return true;
  }

  /// atan2(y,x)
  /// Returns the arctangent of y/x.
  static bool _atan2(SlangVm vm) {
    var y = vm.getNumArg(0, name: "y");
    var x = vm.getNumArg(1, name: "x");
    vm.push(atan2(y, x));
    return true;
  }

  /// log(x)
  ///  Returns the natural logarithm of x.
  static bool _log(SlangVm vm) {
    var x = vm.getNumArg(0, name: "x");
    vm.push(log(x));
    return true;
  }

  /// exp(x)
  /// Returns e raised to the power of x.
  static bool _exp(SlangVm vm) {
    var x = vm.getNumArg(0, name: "x");
    vm.push(exp(x));
    return true;
  }

  static void register(SlangVm vm) {
    vm.newTable();
    for (var entry in _functions.entries) {
      vm.pushStack(-1);
      vm.push(entry.key);
      vm.pushDartFunction(entry.value);
      vm.setTable();
    }
    for (var entry in _constants.entries) {
      vm.pushStack(-1);
      vm.push(entry.key);
      vm.push(entry.value);
      vm.setTable();
    }
    SlangPackageLib.preloadModuleValue(vm, "slang/math");
  }
}
