import 'package:slang/slang.dart';

class SlangConstantExpressionOptimizer extends AstNodeVisitor<AstNode, Null> {
  bool _isConstant(Exp exp) {
    return exp is IntLiteral ||
        exp is DoubleLiteral ||
        exp is StringLiteral ||
        exp is TrueLiteral ||
        exp is FalseLiteral ||
        exp is NullLiteral;
  }

  dynamic _evaluate(Exp exp) {
    switch (exp) {
      case IntLiteral():
        return exp.value;
      case DoubleLiteral():
        return exp.value;
      case StringLiteral():
        return exp.value;
      case TrueLiteral():
        return true;
      case FalseLiteral():
        return false;
      case NullLiteral():
        return null;
      default:
        return null;
    }
  }

  AstNode _evaluateBinOp(BinOp node, Exp left, Exp right) {
    final leftValue = _evaluate(left);
    final rightValue = _evaluate(right);

    switch (node.op) {
      case "+":
        return IntLiteral(node.token, leftValue + rightValue);
      case "-":
        return IntLiteral(node.token, leftValue - rightValue);
      case "*":
        return IntLiteral(node.token, leftValue * rightValue);
      case "/":
        return IntLiteral(node.token, leftValue ~/ rightValue);
      case "%":
        return IntLiteral(node.token, leftValue % rightValue);
      case "==":
        return leftValue == rightValue
            ? TrueLiteral(node.token)
            : FalseLiteral(node.token);
      case "!=":
        return leftValue != rightValue
            ? TrueLiteral(node.token)
            : FalseLiteral(node.token);
      case "<":
        return leftValue < rightValue
            ? TrueLiteral(node.token)
            : FalseLiteral(node.token);
      case "<=":
        return leftValue <= rightValue
            ? TrueLiteral(node.token)
            : FalseLiteral(node.token);
      case ">":
        return leftValue > rightValue
            ? TrueLiteral(node.token)
            : FalseLiteral(node.token);
      case ">=":
        return leftValue >= rightValue
            ? TrueLiteral(node.token)
            : FalseLiteral(node.token);
      default:
        return node;
    }
  }

  @override
  AstNode visit(AstNode node, [Null arg]) {
    return super.visit(node, arg);
  }

  AstNode? maybeVisit(AstNode? node) {
    if (node == null) {
      return null;
    }
    return visit(node);
  }

  @override
  AstNode visitAssignment(Assignment node, Null arg) {
    return Assignment(
      node.token,
      node.left,
      visit(node.right) as Exp,
    );
  }

  @override
  AstNode visitBinOp(BinOp node, Null arg) {
    final left = visit(node.left) as Exp;
    final right = visit(node.right) as Exp;
    if (_isConstant(left) && _isConstant(right)) {
      return _evaluateBinOp(node, left, right);
    }
    return BinOp(node.token, left, node.op, right);
  }

  @override
  AstNode visitBlock(Block node, Null arg) {
    return Block(
        node.token,
        node.statements.map(visit).cast<Statement>().toList(),
        maybeVisit(node.finalStatement) as Statement?);
  }

  @override
  AstNode visitFalseLiteral(FalseLiteral node, Null arg) {
    return node;
  }

  @override
  AstNode visitField(Field node, Null arg) {
    return Field(
        node.token, maybeVisit(node.key) as Exp?, visit(node.value) as Exp);
  }

  @override
  AstNode visitForLoop(ForLoop node, Null arg) {
    return ForLoop(
        node.token,
        maybeVisit(node.init) as Statement,
        visit(node.condition) as Exp,
        maybeVisit(node.update) as Statement,
        visit(node.body) as Statement);
  }

  @override
  AstNode visitFunctionCall(FunctionCall node, Null arg) {
    return FunctionCall(
        node.token,
        visit(node.target) as Exp,
        maybeVisit(node.name) as Name?,
        node.args.map(visit).cast<Exp>().toList());
  }

  @override
  AstNode visitFunctionExpression(FunctionExpression node, Null arg) {
    return FunctionExpression(
        node.token, node.params, visit(node.body) as Block);
  }

  @override
  AstNode visitFunctionStatement(FunctionCallStatement node, Null arg) {
    return FunctionCallStatement(node.token, visit(node.call) as FunctionCall);
  }

  @override
  AstNode visitIfStatement(IfStatement node, Null arg) {
    return IfStatement(
        node.token,
        visit(node.condition) as Exp,
        visit(node.thenBranch) as Statement,
        maybeVisit(node.elseBranch) as Statement?);
  }

  @override
  AstNode visitIndex(Index node, Null arg) {
    return Index(node.token, visit(node.target) as Exp, visit(node.key) as Exp);
  }

  @override
  AstNode visitIntLiteral(IntLiteral node, Null arg) {
    return node;
  }

  @override
  AstNode visitDoubleLiteral(DoubleLiteral node, Null arg) {
    return node;
  }

  @override
  AstNode visitName(Name node, Null arg) {
    return node;
  }

  @override
  AstNode visitNullLiteral(NullLiteral node, Null arg) {
    return node;
  }

  @override
  AstNode visitReturnStatement(ReturnStatement node, Null arg) {
    return ReturnStatement(node.token, visit(node.exp) as Exp);
  }

  @override
  AstNode visitStringLiteral(StringLiteral node, Null arg) {
    return node;
  }

  @override
  AstNode visitTableLiteral(TableLiteral node, Null arg) {
    return TableLiteral(
        node.token, node.fields.map(visit).cast<Field>().toList());
  }

  @override
  AstNode visitTrueLiteral(TrueLiteral node, Null arg) {
    return node;
  }

  @override
  AstNode visitUnOp(UnOp node, Null arg) {
    final exp = visit(node.exp) as Exp;
    if (_isConstant(exp)) {
      final value = _evaluate(exp);
      switch (node.op) {
        case "not":
          return value ? FalseLiteral(node.token) : TrueLiteral(node.token);
        case "-":
          return IntLiteral(node.token, -value);
      }
    }
    return UnOp(node.token, node.op, exp);
  }

  @override
  AstNode visitDeclaration(Declaration node, Null arg) {
    return Declaration(
        node.token, node.isLocal, node.left, maybeVisit(node.right) as Exp?);
  }
}
