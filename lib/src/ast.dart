sealed class AstNode {
  const AstNode();

  T accept<T, A>(AstNodeVisitor<T, A> visitor, A arg);
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
