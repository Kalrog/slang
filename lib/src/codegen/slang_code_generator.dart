import 'package:slang/slang.dart';
import 'package:slang/src/codegen/function_assembler.dart';
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
    super.visit(node, arg);
  }

  @override
  void visitIntLiteral(IntLiteral node, Null arg) {
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
      case Name(:final value):
        var localVar = _assembler.getLocalVar(value);
        if (node.isLocal) {
          localVar = _assembler.createLocalVar(value);
        }
        if (localVar != null) {
          visit(node.exp);
          _assembler.emitMove(localVar.register);
          return;
        }

        var upvalue = _assembler.getUpvalue(value);
        if (upvalue != null) {
          visit(node.exp);
          _assembler.emitSetUpvalue(upvalue.index);
          return;
        }
        visit(
          Assignment(Index(Name("_ENV"), StringLiteral(value)), node.exp,
              isLocal: false),
        );
      case Index(:final target, :final key):
        visit(target);
        visit(key);
        visit(node.exp);
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

    visit(Index(Name("_ENV"), StringLiteral(node.value)));
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
    List<Field> arrayFields =
        node.fields.where((node) => node.key == null).toList();
    List<Field> mapFields =
        node.fields.where((node) => node.key != null).toList();
    _assembler.emitNewTable(arrayFields.length, mapFields.length);
    arrayFields = arrayFields.indexed
        .map((e) => Field(IntLiteral(e.$1), e.$2.value))
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
  void visitTrueLiteral(TrueLiteral node, Null arg) {
    _assembler.emitLoadBool(true);
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
}
