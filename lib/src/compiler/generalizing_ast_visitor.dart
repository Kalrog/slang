import 'package:slang/src/compiler/ast.dart';

abstract class GeneralizingAstVisitor<A> extends AstNodeVisitor<void, A> {
  void maybeVisit(AstNode? node, A arg) {
    if (node != null) {
      visitNode(node, arg);
    }
  }

  void visitNode(AstNode node, A arg);

  void visitExpression(AstNode node, A arg) {
    return visitNode(node, arg);
  }

  void visitLiteral(AstNode node, A arg) {
    return visitExpression(node, arg);
  }

  void visitStatement(Statement node, A arg) {
    return visitNode(node, arg);
  }

  void visitPattern(Pattern node, A arg) {
    return visitNode(node, arg);
  }

  @override
  void visitAssignment(Assignment node, A arg) {
    visit(node.left, arg);
    visit(node.right, arg);
    visitStatement(node, arg);
  }

  @override
  void visitBinOp(BinOp node, A arg) {
    visit(node.left, arg);
    visit(node.right, arg);
    visitExpression(node, arg);
  }

  @override
  void visitBlock(Block node, A arg) {
    for (var statement in node.statements) {
      visitStatement(statement, arg);
    }
    visitNode(node, arg);
  }

  @override
  void visitBreak(Break node, A arg) {
    visitStatement(node, arg);
  }

  @override
  void visitConstPattern(ConstPattern node, A arg) {
    visit(node.value, arg);
    visitPattern(node, arg);
  }

  @override
  void visitDeclaration(Declaration node, A arg) {
    visit(node.left, arg);
    maybeVisit(node.right, arg);
    visitStatement(node, arg);
  }

  @override
  void visitDoubleLiteral(DoubleLiteral node, A arg) {
    visitLiteral(node, arg);
  }

  @override
  void visitFalseLiteral(FalseLiteral node, A arg) {
    visitLiteral(node, arg);
  }

  @override
  void visitField(Field node, A arg) {
    maybeVisit(node.key, arg);
    visit(node.value, arg);
  }

  @override
  void visitFieldPattern(FieldPattern node, A arg) {
    maybeVisit(node.key, arg);
    visit(node.value, arg);
  }

  @override
  void visitForInLoop(ForInLoop node, A arg) {
    visit(node.pattern, arg);
    visit(node.itterator, arg);
    visit(node.body, arg);
    visitStatement(node, arg);
  }

  @override
  void visitForLoop(ForLoop node, A arg) {
    maybeVisit(node.init, arg);
    visit(node.condition, arg);
    maybeVisit(node.update, arg);
    visit(node.body, arg);
    visitStatement(node, arg);
  }

  @override
  void visitFunctionCall(FunctionCall node, A arg) {
    visit(node.function, arg);
    maybeVisit(node.name, arg);
    for (var argument in node.args) {
      visit(argument, arg);
    }
    visitExpression(node, arg);
  }

  @override
  void visitFunctionExpression(FunctionExpression node, A arg) {
    for (var param in node.params) {
      visit(param, arg);
    }
    visit(node.body, arg);
    visitExpression(node, arg);
  }

  @override
  void visitFunctionStatement(FunctionCallStatement node, A arg) {
    visit(node.call, arg);
    visitStatement(node, arg);
  }

  @override
  void visitIdentifier(Identifier node, A arg) {
    visitExpression(node, arg);
  }

  @override
  void visitIfStatement(IfStatement node, A arg) {
    visit(node.condition, arg);
    visit(node.thenBranch, arg);
    maybeVisit(node.elseBranch, arg);
    visitStatement(node, arg);
  }

  @override
  void visitIndex(Index node, A arg) {
    visit(node.receiver, arg);
    visit(node.index, arg);
    visitExpression(node, arg);
  }

  @override
  void visitIntLiteral(IntLiteral node, A arg) {
    visitLiteral(node, arg);
  }

  @override
  void visitLetExp(LetExp node, A arg) {
    visit(node.pattern, arg);
    visit(node.right, arg);
    visitExpression(node, arg);
  }

  @override
  void visitNullLiteral(NullLiteral node, A arg) {
    visitLiteral(node, arg);
  }

  @override
  void visitQuote(Quote node, A arg) {
    visit(node.ast, arg);
    visitExpression(node, arg);
  }

  @override
  void visitReturnStatement(ReturnStatement node, A arg) {
    maybeVisit(node.value, arg);
    visitStatement(node, arg);
  }

  @override
  void visitStringLiteral(StringLiteral node, A arg) {
    visitLiteral(node, arg);
  }

  @override
  void visitTableLiteral(TableLiteral node, A arg) {
    for (var field in node.fields) {
      visit(field, arg);
    }
    visitExpression(node, arg);
  }

  @override
  void visitTablePattern(TablePattern node, A arg) {
    for (var field in node.fields) {
      visit(field, arg);
    }
    visitPattern(node, arg);
  }

  @override
  void visitTrueLiteral(TrueLiteral node, A arg) {
    visitLiteral(node, arg);
  }

  @override
  void visitUnOp(UnOp node, A arg) {
    visit(node.operand, arg);
    visitExpression(node, arg);
  }

  @override
  void visitUnquote(Unquote node, A arg) {
    visit(node.ast, arg);
    visitExpression(node, arg);
  }

  @override
  void visitVarPattern(VarPattern node, A arg) {
    visit(node.name, arg);
    visitPattern(node, arg);
  }
}
