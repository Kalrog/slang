sealed class AstNode {
  const AstNode();

  T accept<T, A>(AstNodeVisitor<T, A> visitor, A arg);

  void prettyPrint() {
    final visitor = PrettyPrintVisitor();
    visitor.prettyPrint(this);
  }
}

abstract class AstNodeVisitor<T, A> {
  T visit(AstNode node, A arg) {
    return node.accept(this, arg);
  }

  T visitIntLiteral(IntLiteral node, A arg);
  T visitStringLiteral(StringLiteral node, A arg);
  T visitFalseLiteral(FalseLiteral node, A arg);
  T visitTrueLiteral(TrueLiteral node, A arg);
  T visitTableLiteral(TableLiteral node, A arg);
  T visitField(Field node, A arg);

  T visitName(Name node, A arg);
  T visitIndex(Index node, A arg);
  T visitBinOp(BinOp node, A arg);
  T visitUnOp(UnOp node, A arg);
  T visitFunctionExpression(FunctionExpression node, A arg);
  T visitFunctionCall(FunctionCall node, A arg);

  T visitBlock(Block node, A arg);
  T visitFunctionStatement(FunctionCallStatement node, A arg);
  T visitIfStatement(IfStatement node, A arg);
  T visitReturnStatement(ReturnStatement node, A arg);
  T visitAssignment(Assignment node, A arg);

  T visitForLoop(ForLoop node, A arg);
}

class PrettyPrintVisitor extends AstNodeVisitor<void, Null> {
  final StringBuffer _buffer = StringBuffer();
  int _indent = 0;

  void _increaseIndent() {
    _indent += 2;
  }

  void _decreaseIndent() {
    _indent -= 2;
  }

  void _append(String str) {
    _buffer.write(str);
  }

  void _newLine() {
    _buffer.writeln();
    _buffer.write(' ' * _indent);
  }

  @override
  void visit(AstNode node, [Null arg]) {
    node.accept(this, arg);
  }

  void prettyPrint(AstNode node) {
    visit(node);
    print(_buffer.toString());
  }

  @override
  void visitIntLiteral(IntLiteral node, [Null arg]) {
    _append('${node.value}');
  }

  @override
  void visitStringLiteral(StringLiteral node, [Null arg]) {
    _append(node.value);
  }

  @override
  void visitFalseLiteral(FalseLiteral node, [Null arg]) {
    _append('false');
  }

  @override
  void visitTrueLiteral(TrueLiteral node, [Null arg]) {
    _append('true');
  }

  @override
  void visitTableLiteral(TableLiteral node, [Null arg]) {
    _append('{');
    _increaseIndent();
    for (var field in node.fields) {
      _newLine();
      visit(field);
      _append(",");
    }
    _decreaseIndent();
    _newLine();
    _append('}');
  }

  @override
  void visitField(Field node, [Null arg]) {
    if (node.key != null) {
      visit(node.key!);
      _append(':');
    }
    visit(node.value);
  }

  @override
  void visitName(Name node, [Null arg]) {
    _append(node.value);
  }

  @override
  void visitIndex(Index node, [Null arg]) {
    visit(node.target);
    _append('[');
    visit(node.key);
    _append(']');
  }

  @override
  void visitBinOp(BinOp node, [Null arg]) {
    visit(node.left);
    _append(' ${node.op} ');
    visit(node.right);
  }

  @override
  void visitUnOp(UnOp node, [Null arg]) {
    _append(node.op);
    visit(node.exp);
  }

  @override
  void visitFunctionExpression(FunctionExpression node, [Null arg]) {
    _append('function(');
    for (var param in node.params) {
      _append(param.value);
      _append(',');
    }
    _append(')');
    visit(node.body);
  }

  @override
  void visitFunctionCall(FunctionCall node, [Null arg]) {
    visit(node.target);
    _append('(');
    for (var arg in node.args) {
      visit(arg);
      _append(',');
    }
    _append(')');
  }

  @override
  void visitBlock(Block node, [Null arg]) {
    _append('{');
    _increaseIndent();
    for (var statement in node.statements) {
      _newLine();
      visit(statement);
      _append(';');
    }
    if (node.finalStatement != null) {
      _newLine();
      visit(node.finalStatement!);
      _append(';');
    }
    _decreaseIndent();
    _newLine();
    _append('}');
  }

  @override
  void visitFunctionStatement(FunctionCallStatement node, [Null arg]) {
    visit(node.call);
  }

  @override
  void visitIfStatement(IfStatement node, [Null arg]) {
    _append('if (');
    visit(node.condition);
    _append(') ');
    visit(node.thenBranch);
    if (node.elseBranch != null) {
      _append(' else ');
      visit(node.elseBranch!);
    }
  }

  @override
  void visitForLoop(ForLoop node, [Null arg]) {
    _append('for (');
    if (node.init != null) {
      visit(node.init!);
    }
    _append(';');
    visit(node.condition);
    _append(';');
    if (node.update != null) {
      visit(node.update!);
    }
    _append(')');
    visit(node.body);
  }

  @override
  void visitReturnStatement(ReturnStatement node, [Null arg]) {
    _append('return ');
    visit(node.exp);
  }

  @override
  void visitAssignment(Assignment node, [Null arg]) {
    if (node.isLocal) {
      _append('local ');
    }
    visit(node.left);
    _append(' = ');
    visit(node.exp);
  }
}

sealed class Exp extends AstNode {
  const Exp();
}

class IntLiteral extends Exp {
  final int value;
  IntLiteral(this.value);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitIntLiteral(this, arg);
  }

  @override
  String toString() => '$runtimeType($value)';
}

class StringLiteral extends Exp {
  final String value;
  StringLiteral(this.value);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitStringLiteral(this, arg);
  }

  @override
  String toString() => '$runtimeType($value)';
}

class FalseLiteral extends Exp {
  const FalseLiteral();
  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitFalseLiteral(this, arg);
  }

  @override
  String toString() => '$runtimeType';
}

class TrueLiteral extends Exp {
  const TrueLiteral();
  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitTrueLiteral(this, arg);
  }

  @override
  String toString() => '$runtimeType';
}

class TableLiteral extends Exp {
  final List<Field> fields;
  TableLiteral(this.fields);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitTableLiteral(this, arg);
  }

  @override
  String toString() => '$runtimeType($fields)';
}

class Field extends AstNode {
  final Exp? key;
  final Exp value;
  Field(this.key, this.value);

  @override
  T accept<T, A>(AstNodeVisitor<T, A> visitor, A arg) {
    return visitor.visitField(this, arg);
  }

  @override
  String toString() => '$runtimeType($key, $value)';
}

class Name extends Exp {
  final String value;
  Name(this.value);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitName(this, arg);
  }

  @override
  String toString() => '$runtimeType($value)';
}

class Index extends Exp {
  final Exp target;
  final Exp key;

  Index(this.target, this.key);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitIndex(this, arg);
  }

  @override
  toString() => '$runtimeType($target, $key)';
}

class BinOp extends Exp {
  final Exp left;
  final Exp right;
  final String op;
  BinOp(this.left, this.op, this.right);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitBinOp(this, arg);
  }

  @override
  String toString() => '$runtimeType($left, $op, $right)';
}

class UnOp extends Exp {
  final Exp exp;
  final String op;
  UnOp(this.op, this.exp);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitUnOp(this, arg);
  }

  @override
  String toString() => '$runtimeType($op, $exp)';
}

class FunctionExpression extends Exp {
  final List<Name> params;
  final Block body;
  FunctionExpression(this.params, this.body);
  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitFunctionExpression(this, arg);
  }

  @override
  String toString() => '$runtimeType($params, $body)';
}

class FunctionCall extends Exp {
  final Exp target;
  final List<Exp> args;

  FunctionCall(this.target, this.args);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitFunctionCall(this, arg);
  }

  @override
  String toString() => '$runtimeType($target, $args)';
}

sealed class Statement extends AstNode {
  const Statement();
}

class FunctionCallStatement extends Statement {
  final FunctionCall call;
  FunctionCallStatement(this.call);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitFunctionStatement(this, arg);
  }

  @override
  String toString() => '$runtimeType($call)';
}

class Block extends Statement {
  final List<Statement> statements;
  final Statement? finalStatement;

  Block(this.statements, [this.finalStatement]);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitBlock(this, arg);
  }

  @override
  String toString() => '$runtimeType($statements, $finalStatement)';
}

class IfStatement extends Statement {
  final Exp condition;
  final Statement thenBranch;
  final Statement? elseBranch;
  IfStatement(this.condition, this.thenBranch, this.elseBranch);
  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitIfStatement(this, arg);
  }

  @override
  String toString() => '$runtimeType($condition, $thenBranch, $elseBranch)';
}

class ForLoop extends Statement {
  final Statement? init;
  final Exp condition;
  final Statement? update;
  final Statement body;
  ForLoop(this.init, this.condition, this.update, this.body);
  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitForLoop(this, arg);
  }

  @override
  String toString() => '$runtimeType($init, $condition, $update, $body)';
}

class ReturnStatement extends Statement {
  final Exp exp;
  ReturnStatement(this.exp);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitReturnStatement(this, arg);
  }

  @override
  String toString() => '$runtimeType($exp)';
}

class Assignment extends Statement {
  final Exp left;
  final Exp exp;
  final bool isLocal;
  Assignment(this.left, this.exp, {required this.isLocal});

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitAssignment(this, arg);
  }

  @override
  String toString() => '$runtimeType($left, $exp, isLocal: $isLocal)';
}
