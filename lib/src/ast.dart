import 'package:petitparser/petitparser.dart';

sealed class AstNode {
  const AstNode(this.token);

  final Token token;

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
  T visitDoubleLiteral(DoubleLiteral node, A arg);
  T visitStringLiteral(StringLiteral node, A arg);
  T visitFalseLiteral(FalseLiteral node, A arg);
  T visitTrueLiteral(TrueLiteral node, A arg);
  T visitNullLiteral(NullLiteral node, A arg);
  T visitTableLiteral(TableLiteral node, A arg);
  T visitField(Field node, A arg);

  T visitName(Name node, A arg);
  T visitIndex(Index node, A arg);
  T visitBinOp(BinOp node, A arg);
  T visitUnOp(UnOp node, A arg);
  T visitFunctionExpression(FunctionExpression node, A arg);
  T visitFunctionCall(FunctionCall node, A arg);
  T visitPatternAssignmentExp(PatternAssignmentExp node, A arg);

  T visitBlock(Block node, A arg);
  T visitFunctionStatement(FunctionCallStatement node, A arg);
  T visitIfStatement(IfStatement node, A arg);
  T visitReturnStatement(ReturnStatement node, A arg);
  T visitAssignment(Assignment node, A arg);
  T visitDeclaration(Declaration node, A arg);

  T visitForLoop(ForLoop node, A arg);
  T visitForInLoop(ForInLoop node, A arg);

  T visitVarPattern(VarPattern node, A arg);
  T visitTablePattern(TablePattern node, A arg);
  T visitFieldPattern(FieldPattern node, A arg);
  T visitConstPattern(ConstPattern node, A arg);
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
  void visitDoubleLiteral(DoubleLiteral node, Null arg) {
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
  void visitNullLiteral(NullLiteral node, [Null arg]) {
    _append('null');
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
    _append('(');
    visit(node.left);
    _append(' ${node.op} ');
    visit(node.right);
    _append(')');
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
  void visitForInLoop(ForInLoop node, [Null arg]) {
    _append('for (');
    visit(node.pattern);
    _append(' in ');
    visit(node.itterator);
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
    visit(node.left);
    _append(' = ');
    visit(node.right);
  }

  @override
  void visitDeclaration(Declaration node, Null arg) {
    if (node.isLocal) {
      _append('local ');
    } else {
      _append('global ');
    }

    visit(node.left);
    if (node.right != null) {
      _append(' = ');
      visit(node.right!);
    }
  }

  @override
  void visitConstPattern(ConstPattern node, Null arg) {
    visit(node.exp);
  }

  @override
  void visitFieldPattern(FieldPattern node, Null arg) {
    if (node.key != null) {
      visit(node.key!);
      _append(':');
    }
    visit(node.value);
  }

  @override
  void visitTablePattern(TablePattern node, Null arg) {
    _append('{');
    _increaseIndent();
    for (var field in node.fields) {
      _newLine();
      visit(field);
      _append(',');
    }
    _decreaseIndent();
    _newLine();
    _append('}');
  }

  @override
  void visitVarPattern(VarPattern node, Null arg) {
    if (node.isLocal) {
      _append('local ');
    } else {
      _append('global ');
    }
    _append(node.name.value);
    if (node.canBeNull) {
      _append('?');
    }
  }

  @override
  void visitPatternAssignmentExp(PatternAssignmentExp node, Null arg) {
    visit(node.value);
    _append(' => ');
    visit(node.pattern);
  }
}

sealed class Exp extends AstNode {
  const Exp(super.token);
}

class IntLiteral extends Exp {
  final int value;
  IntLiteral(super.token, this.value);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitIntLiteral(this, arg);
  }

  @override
  String toString() => '$runtimeType($value)';
}

class DoubleLiteral extends Exp {
  final double value;
  DoubleLiteral(super.token, this.value);
  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitDoubleLiteral(this, arg);
  }

  @override
  String toString() => '$runtimeType($value)';
}

class StringLiteral extends Exp {
  final String value;
  StringLiteral(super.token, this.value);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitStringLiteral(this, arg);
  }

  @override
  String toString() => '$runtimeType($value)';
}

class FalseLiteral extends Exp {
  const FalseLiteral(super.token);
  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitFalseLiteral(this, arg);
  }

  @override
  String toString() => '$runtimeType';
}

class TrueLiteral extends Exp {
  const TrueLiteral(super.token);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitTrueLiteral(this, arg);
  }

  @override
  String toString() => '$runtimeType';
}

class NullLiteral extends Exp {
  const NullLiteral(super.token);

  @override
  T accept<T, A>(AstNodeVisitor<T, A> visitor, A arg) {
    return visitor.visitNullLiteral(this, arg);
  }

  @override
  String toString() => '$runtimeType';
}

class TableLiteral extends Exp {
  final List<Field> fields;
  TableLiteral(super.token, this.fields);

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
  Field(super.token, this.key, this.value);

  @override
  T accept<T, A>(AstNodeVisitor<T, A> visitor, A arg) {
    return visitor.visitField(this, arg);
  }

  @override
  String toString() => '$runtimeType($key, $value)';
}

class Name extends Exp {
  final String value;
  Name(super.token, this.value);

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

  Index(super.token, this.target, this.key);

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
  BinOp(super.token, this.left, this.op, this.right);

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
  UnOp(super.token, this.op, this.exp);

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
  FunctionExpression(super.token, this.params, this.body);
  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitFunctionExpression(this, arg);
  }

  @override
  String toString() => '$runtimeType($params, $body)';
}

class FunctionCall extends Exp {
  final Exp target;
  final Name? name;
  final List<Exp> args;

  FunctionCall(super.token, this.target, this.name, this.args);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitFunctionCall(this, arg);
  }

  @override
  String toString() => '$runtimeType($target, $args)';
}

sealed class Statement extends AstNode {
  const Statement(super.token);
}

class FunctionCallStatement extends Statement {
  final FunctionCall call;
  FunctionCallStatement(super.token, this.call);

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

  Block(super.token, this.statements, [this.finalStatement]);

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
  IfStatement(super.token, this.condition, this.thenBranch, this.elseBranch);
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
  ForLoop(super.token, this.init, this.condition, this.update, this.body);
  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitForLoop(this, arg);
  }

  @override
  String toString() => '$runtimeType($init, $condition, $update, $body)';
}

class ForInLoop extends Statement {
  final Pattern pattern;
  final Exp itterator;
  final Statement body;
  ForInLoop(super.token, this.pattern, this.itterator, this.body);
  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitForInLoop(this, arg);
  }

  @override
  String toString() => '$runtimeType($pattern, $itterator, $body)';
}

class ReturnStatement extends Statement {
  final Exp exp;
  ReturnStatement(super.token, this.exp);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitReturnStatement(this, arg);
  }

  @override
  String toString() => '$runtimeType($exp)';
}

class Assignment extends Statement {
  final Exp left;
  final Exp right;
  Assignment(super.token, this.left, this.right);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitAssignment(this, arg);
  }

  @override
  String toString() => '$runtimeType($left, $right)';
}

class Declaration extends Statement {
  final bool isLocal;
  final Exp left;
  final Exp? right;
  Declaration(super.token, this.isLocal, this.left, this.right);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitDeclaration(this, arg);
  }

  @override
  String toString() => '$runtimeType($isLocal, $left, $right)';
}

sealed class Pattern extends AstNode {
  const Pattern(super.token);
}

class VarPattern extends Pattern {
  final bool isLocal;
  final Name name;
  final bool canBeNull;
  VarPattern(super.token, this.name,
      {required this.isLocal, required this.canBeNull});

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitVarPattern(this, arg);
  }

  @override
  String toString() => '$runtimeType($name)';
}

class TablePattern extends Pattern {
  final List<FieldPattern> fields;
  TablePattern(super.token, this.fields);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitTablePattern(this, arg);
  }

  @override
  String toString() => '$runtimeType($fields)';
}

class FieldPattern extends AstNode {
  final Exp? key;
  final Pattern value;
  FieldPattern(super.token, this.key, this.value);

  @override
  T accept<T, A>(AstNodeVisitor<T, A> visitor, A arg) {
    return visitor.visitFieldPattern(this, arg);
  }

  @override
  String toString() => '$runtimeType($key, $value)';
}

class ConstPattern extends Pattern {
  final Exp exp;
  ConstPattern(super.token, this.exp)
      : assert(exp is IntLiteral ||
            exp is DoubleLiteral ||
            exp is StringLiteral ||
            exp is TrueLiteral ||
            exp is FalseLiteral ||
            exp is NullLiteral);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitConstPattern(this, arg);
  }

  @override
  String toString() => '$runtimeType($exp)';
}

class PatternAssignmentExp extends Exp {
  final Exp value;
  final Pattern pattern;

  PatternAssignmentExp(super.token, this.pattern, this.value);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitPatternAssignmentExp(this, arg);
  }

  @override
  String toString() => '$runtimeType($value, $pattern)';
}
