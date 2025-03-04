import 'package:slang/slang.dart';
import 'package:slang/src/codegen/function_assembler.dart';
import 'package:slang/src/codegen/pattern_assembler.dart';
import 'package:slang/src/vm/function_prototype.dart';

class SlangCodeGenerator extends AstNodeVisitor<void, Null> {
  late FunctionAssembler _assembler;

  FunctionPrototype generate(AstNode node) {
    final parent = FunctionAssembler();
    parent.createLocalVar("_ENV");
    _assembler = FunctionAssembler(parent: parent);
    visit(node);
    _assembler.emitReturn();
    return _assembler.assemble();
  }

  @override
  void visit(AstNode node, [Null arg]) {
    _assembler.setLocation(node.token);
    super.visit(node, arg);
  }

  @override
  void visitIntLiteral(IntLiteral node, Null arg) {
    _assembler.emitLoadConstant(node.value);
  }

  @override
  void visitDoubleLiteral(DoubleLiteral node, Null arg) {
    _assembler.emitLoadConstant(node.value);
  }

  @override
  void visitStringLiteral(StringLiteral node, Null arg) {
    _assembler.emitLoadConstant(node.value);
  }

  @override
  void visitBinOp(BinOp node, Null arg) {
    if (node.op case 'and') {
      visitLogicalAnd(node);
    } else if (node.op case 'or') {
      visitLogicalOr(node);
    } else {
      visitArithBinOp(node);
    }
  }

  void visitArithBinOp(BinOp node) {
    visit(node.left, null);
    visit(node.right, null);
    switch (node.op) {
      case '>':
        _assembler.emitBinOp('<=');
        _assembler.emitUnOp('not');
      case '>=':
        _assembler.emitBinOp('<');
        _assembler.emitUnOp('not');
      case '!=':
        _assembler.emitBinOp('==');
        _assembler.emitUnOp('not');
      default:
        _assembler.emitBinOp(node.op);
    }
  }

  void visitLogicalAnd(BinOp node) {
    visit(node.left);
    _assembler.emitPush(-1);
    _assembler.emitTest(true);
    final doneJump = _assembler.emitJump();
    _assembler.emitPop();
    visit(node.right);
    _assembler.patchJump(doneJump);
  }

  void visitLogicalOr(BinOp node) {
    visit(node.left);
    _assembler.emitPush(-1);
    _assembler.emitTest(false);
    final doneJump = _assembler.emitJump();
    _assembler.emitPop();
    visit(node.right);
    _assembler.patchJump(doneJump);
  }

  @override
  void visitUnOp(UnOp node, Null arg) {
    visit(node.exp);
    _assembler.emitUnOp(node.op);
  }

  @override
  void visitAssignment(Assignment node, Null arg) {
    switch (node.left) {
      case Name(:final token, :final value):
        var localVar = _assembler.getLocalVar(value);
        if (localVar != null) {
          visit(node.right);
          _assembler.emitMove(localVar.register);
          return;
        }

        var upvalue = _assembler.getUpvalue(value);
        if (upvalue != null) {
          visit(node.right);
          _assembler.emitSetUpvalue(upvalue.index);
          return;
        }
        visit(
          Assignment(
            token,
            Index(token, Name(token, "_ENV"), StringLiteral(token, value)),
            node.right,
          ),
        );
      case Index(:final target, :final key):
        visit(target);
        visit(key);
        visit(node.right);
        _assembler.emitSetTable();
      default:
        throw ArgumentError('Invalid assignment target: ${node.left}');
    }
  }

  @override
  void visitDeclaration(Declaration node, Null arg) {
    switch (node.left) {
      case Name(:final token, :final value):
        if (node.isLocal) {
          if (_assembler.getLocalVar(value) != null) {
            throw Exception('Variable already declared: $value ${token.line}:${token.column}');
          }
          _assembler.createLocalVar(value);
          var localVar = _assembler.getLocalVar(value);
          if (node.right != null) {
            visit(node.right!);
            _assembler.emitMove(localVar!.register);
          }
          return;
        }

        visit(
          Assignment(
            token,
            Index(token, Name(token, "_ENV"), StringLiteral(token, value)),
            node.right ?? NullLiteral(token),
          ),
        );
      case Index(:final target, :final key):
        visit(target);
        visit(key);
        visit(node.right!);
        _assembler.emitSetTable();
      default:
        throw ArgumentError('Invalid assignment target: ${node.left}');
    }
  }

  @override
  void visitReturnStatement(ReturnStatement node, Null arg) {
    visit(node.exp);
    _assembler.emitReturn();
  }

  @override
  void visitBlock(Block node, Null arg) {
    for (final statement in node.statements) {
      visit(statement);
    }

    _assembler.closeOpenUpvalues();
    if (node.finalStatement != null) {
      visit(node.finalStatement!);
    }
  }

  @override
  void visitName(Name node, Null arg) {
    final localVar = _assembler.getLocalVar(node.value);
    if (localVar != null) {
      _assembler.emitPush(localVar.register);
      return;
    }
    final upvalue = _assembler.getUpvalue(node.value);
    if (upvalue != null) {
      _assembler.emitGetUpvalue(upvalue.index);
      return;
    }

    final token = node.token;
    visit(Index(token, Name(token, "_ENV"), StringLiteral(token, node.value)));
  }

  @override
  void visitField(Field node, Null arg) {
    _assembler.emitPush(-1);
    visit(node.key!);
    visit(node.value);
    _assembler.emitSetTable();
  }

  @override
  void visitTableLiteral(TableLiteral node, Null arg) {
    List<Field> arrayFields = node.fields.where((node) => node.key == null).toList();
    List<Field> mapFields = node.fields.where((node) => node.key != null).toList();
    _assembler.emitNewTable(arrayFields.length, mapFields.length);
    arrayFields = arrayFields.indexed
        .map((e) => Field(e.$2.token, IntLiteral(e.$2.token, e.$1), e.$2.value))
        .toList();
    for (var field in arrayFields) {
      visit(field);
    }
    for (var field in mapFields) {
      visit(field);
    }
  }

  @override
  void visitIndex(Index node, Null arg) {
    visit(node.target);
    visit(node.key);
    _assembler.emitGetTable();
  }

  @override
  void visitFalseLiteral(FalseLiteral node, Null arg) {
    _assembler.emitLoadBool(false);
  }

  @override
  void visitTrueLiteral(TrueLiteral node, Null arg) {
    _assembler.emitLoadBool(true);
  }

  @override
  void visitNullLiteral(NullLiteral node, Null arg) {
    _assembler.emitLoadConstant(null);
  }

  @override
  void visitIfStatement(IfStatement node, Null arg) {
    visit(node.condition);
    _assembler.emitTest(true);
    int elseJump = _assembler.emitJump();
    visit(node.thenBranch);
    if (node.elseBranch != null) {
      int skipElseJump = _assembler.emitJump();
      _assembler.patchJump(elseJump);
      visit(node.elseBranch!);
      _assembler.patchJump(skipElseJump);
    } else {
      _assembler.patchJump(elseJump);
    }
  }

  @override
  void visitFunctionExpression(FunctionExpression node, Null arg) {
    final parent = _assembler;
    _assembler = FunctionAssembler(parent: parent);
    parent.children.add(_assembler);
    _assembler.enterScope();
    for (final param in node.params) {
      _assembler.createLocalVar(param.value);
    }
    visit(node.body);
    _assembler.leaveScope();
    _assembler.emitLoadConstant(null);
    _assembler.emitReturn();
    _assembler = parent;
    _assembler.emitLoadClosure(_assembler.children.length - 1);
  }

  @override
  void visitFunctionCall(FunctionCall node, Null arg) {
    visit(node.target);
    if (node.name != null) {
      _assembler.emitPush(-1);
      _assembler.emitLoadConstant(node.name!.value);
      _assembler.emitGetTable();
      _assembler.emitPush(-2);
      for (final arg in node.args) {
        visit(arg);
      }
      _assembler.emitCall(node.args.length + 1);
      _assembler.emitMove(-1);
    } else {
      for (final arg in node.args) {
        visit(arg);
      }
      _assembler.emitCall(node.args.length);
    }
  }

  @override
  void visitFunctionStatement(FunctionCallStatement node, Null arg) {
    visit(node.call);
    _assembler.emitPop();
  }

  @override
  void visitForLoop(ForLoop node, Null arg) {
    _assembler.enterScope();
    if (node.init != null) {
      visit(node.init!);
    }

    int loopStart = _assembler.nextInstructionIndex;
    visit(node.condition);
    _assembler.emitTest(true);
    int loopEnd = _assembler.emitJump();
    visit(node.body);
    if (node.update != null) {
      visit(node.update!);
    }
    _assembler.emitJump(loopStart);
    _assembler.patchJump(loopEnd);
    _assembler.leaveScope();
  }

  @override
  void visitConstPattern(ConstPattern node, Null arg) {
    final patternAsm = _assembler.currentPattern!;
    switch (patternAsm.step) {
      case PatternAssemblyStep.check:
        //check top of stack(previous check value, should be true)
        _assembler.emitPush(-1);
        _assembler.emitTest(true);
        //jump to next check if false
        final missmatchJump = _assembler.emitJump();
        _assembler.emitPop();
        //check value
        visit(node.exp);
        //compare value with pattern
        _assembler.emitBinOp('==');
        _assembler.patchJump(missmatchJump);
      case PatternAssemblyStep.assign:
      //nothing to do here
    }
  }

  @override
  void visitFieldPattern(FieldPattern node, Null arg) {
    final patternAsm = _assembler.currentPattern!;
    switch (patternAsm.step) {
      case PatternAssemblyStep.check:
        //check value
        _assembler.emitPush(-1);
        _assembler.emitLoadConstant(node.key!.value);
        _assembler.emitGetTable();
        _assembler.emitLoadBool(true);
        visit(node.value);
      case PatternAssemblyStep.assign:
        if (node.value is TablePattern || node.value is VarPattern) {
          //assign value
          _assembler.emitPush(-1);
          _assembler.emitLoadConstant(node.key!.value);
          _assembler.emitGetTable();
          visit(node.value);
        }
    }
  }

  @override
  void visitTablePattern(TablePattern node, Null arg) {
    final patternAsm = _assembler.currentPattern!;
    switch (patternAsm.step) {
      case PatternAssemblyStep.check:
        //check top of stack(previous check value, should be true)
        _assembler.emitPush(-1);
        _assembler.emitTest(true);
        //jump to next check if false
        final missmatchJumps = [];
        missmatchJumps.add(_assembler.emitJump());
        _assembler.emitPop();
        _assembler.emitPush(-1);
        _assembler.emitLoadConstant(null);
        _assembler.emitBinOp('==');
        _assembler.emitTest(false);
        missmatchJumps.add(_assembler.emitJump());
        //top of stack is a table, visit each named field and after each check if it fails jump to missmatch
        for (final field in node.fields) {
          visit(field);
          _assembler.emitTest(true);
          missmatchJumps.add(_assembler.emitJump());
        }
        _assembler.emitLoadBool(true, jump: true);
        for (final jump in missmatchJumps) {
          _assembler.patchJump(jump);
        }
        _assembler.emitLoadBool(false);
        _assembler.emitPop();
      case PatternAssemblyStep.assign:
        //run the assign step for each of the fields
        for (final field in node.fields) {
          visit(field);
        }
    }
  }

  @override
  void visitVarPattern(VarPattern node, Null arg) {
    final patternAsm = _assembler.currentPattern!;
    switch (patternAsm.step) {
      case PatternAssemblyStep.check:
        //check top of stack(previous check value, should be true)
        _assembler.emitPush(-1);
        _assembler.emitTest(true);
        //jump to next check if false
        final missmatchJumps = [];
        missmatchJumps.add(_assembler.emitJump());
        _assembler.emitPop();
        if (!node.canBeNull) {
          _assembler.emitLoadConstant(null);
          _assembler.emitBinOp('==');
          _assembler.emitTest(false);
          missmatchJumps.add(_assembler.emitJump());
        } else {
          _assembler.emitPop();
        }
        _assembler.emitLoadBool(true, jump: true);
        for (final jump in missmatchJumps) {
          _assembler.patchJump(jump);
        }
        _assembler.emitLoadBool(false);

      case PatternAssemblyStep.assign:
        //assign value
        if (node.isLocal) {
          _assembler.createLocalVar(node.name.value);
          _assembler.emitMove(_assembler.getLocalVar(node.name.value)!.register);
        } else {
          visit(Name(node.token, "_ENV"));
          _assembler.emitLoadConstant(node.name.value);
          _assembler.emitPush(-3);
          _assembler.emitSetTable();
          _assembler.emitPop();
        }
    }
  }

  @override
  void visitPatternAssignmentExp(PatternAssignmentExp node, Null arg) {
    //push value to stack
    visit(node.value);
    _assembler.emitPush(-1);
    _assembler.emitLoadBool(true);
    final patternAssembler = _assembler.startPattern();
    //check pattern
    visit(node.pattern);
    patternAssembler.completedCheck();
    _assembler.emitTest(true);
    final missmatchJump = _assembler.emitJump();
    //assign variables
    visit(node.pattern);
    _assembler.emitPop();
    _assembler.emitPop();
    //put true on the stack and skip the next instruction that would put false on the stack (for the missmatch jump)

    _assembler.emitLoadBool(true, jump: true);
    _assembler.patchJump(missmatchJump);
    _assembler.emitLoadBool(false);
  }
}
