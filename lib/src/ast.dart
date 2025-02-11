sealed class AstNode {
  const AstNode();

  T accept<T, A>(AstNodeVisitor<T, A> visitor, A arg);
}

abstract class AstNodeVisitor<T, A> {
  T visitAstNode(AstNode node, A arg) {
    return node.accept(this, arg);
  }

  T visitIntLiteral(IntLiteral node, A arg);
  T visitStringLiteral(StringLiteral node, A arg);
  T visitTableLiteral(TableLiteral node, A arg);

  T visitName(Name node, A arg);
  T visitBinOp(BinOp node, A arg);
  T visitUnOp(UnOp node, A arg);

  T visitBlock(Block block, A arg);
  T returnStatement(ReturnStatement statement, A arg);
  T assignment(Assignment statement, A arg);
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

class Field {
  final Exp? key;
  final Exp value;
  Field(this.key, this.value);

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

sealed class Statement extends AstNode {
  const Statement();
}

class Block extends AstNode {
  final List<Statement> statements;
  final Statement? finalStatement;

  Block(this.statements, [this.finalStatement]);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitBlock(this, arg);
  }
}

class ReturnStatement extends Statement {
  final Exp exp;
  ReturnStatement(this.exp);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.returnStatement(this, arg);
  }
}

class Assignment extends Statement {
  final Name name;
  final Exp exp;
  final bool isLocal;
  Assignment(this.name, this.exp, {required this.isLocal});

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.assignment(this, arg);
  }
}
