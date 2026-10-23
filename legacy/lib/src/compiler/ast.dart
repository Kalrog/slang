import 'package:petitparser/petitparser.dart';
import 'package:slang/src/compiler/to_string_visitor.dart';

sealed class AstNode {
  const AstNode(this.token);

  final Token? token;

  T accept<T, A>(AstNodeVisitor<T, A> visitor, A arg);

  void prettyPrint() {
    final visitor = ToStringVisitor();
    visitor.prettyPrint(this);
  }

  @override
  String toString() {
    final visitor = ToStringVisitor();
    return visitor.visitToString(this);
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

  T visitIdentifier(Identifier node, A arg);
  T visitIndex(Index node, A arg);
  T visitBinOp(BinOp node, A arg);
  T visitUnOp(UnOp node, A arg);
  T visitFunctionExpression(FunctionExpression node, A arg);
  T visitFunctionCall(FunctionCall node, A arg);
  T visitLetExp(LetExp node, A arg);

  T visitBlock(Block node, A arg);
  T visitFunctionStatement(FunctionCallStatement node, A arg);
  T visitIfStatement(IfStatement node, A arg);
  T visitReturnStatement(ReturnStatement node, A arg);
  T visitAssignment(Assignment node, A arg);
  T visitDeclaration(Declaration node, A arg);
  T visitBreak(Break node, A arg);

  T visitForLoop(ForLoop node, A arg);
  T visitForInLoop(ForInLoop node, A arg);

  T visitVarPattern(VarPattern node, A arg);
  T visitTablePattern(TablePattern node, A arg);
  T visitFieldPattern(FieldPattern node, A arg);
  T visitConstPattern(ConstPattern node, A arg);

  T visitQuote(Quote node, A arg);
  T visitUnquote(Unquote node, A arg);
}

sealed class Exp extends AstNode {
  const Exp(super.token);
}

interface class Assignable {}

class IntLiteral extends Exp {
  final int value;
  IntLiteral(super.token, this.value);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitIntLiteral(this, arg);
  }
}

class DoubleLiteral extends Exp {
  final double value;
  DoubleLiteral(super.token, this.value);
  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitDoubleLiteral(this, arg);
  }
}

class StringLiteral extends Exp {
  final String value;
  StringLiteral(super.token, String value) : value = resolveEscapes(value);

  StringLiteral.fromIdentifier(Identifier id)
      : value = id.value,
        super(id.token);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitStringLiteral(this, arg);
  }

  static String resolveEscapes(String literal) {
    final buffer = StringBuffer();
    for (var i = 0; i < literal.length; i++) {
      if (literal[i] == '\\') {
        i++;
        if (i >= literal.length) {
          throw Exception('Invalid escape sequence in $literal');
        }
        switch (literal[i]) {
          case 'n':
            buffer.write('\n');
            break;
          case 'r':
            buffer.write('\r');
            break;
          case 't':
            buffer.write('\t');
            break;
          case 'b':
            buffer.write('\b');
            break;
          case 'f':
            buffer.write('\f');
            break;
          case 'v':
            buffer.write('\v');
            break;
          case '\\':
            buffer.write('\\');
            break;
          case '"':
            buffer.write('"');
            break;
          default:
            throw Exception('Invalid escape sequence in $literal');
        }
      } else {
        buffer.write(literal[i]);
      }
    }
    return buffer.toString();
  }
}

class FalseLiteral extends Exp {
  const FalseLiteral(super.token);
  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitFalseLiteral(this, arg);
  }
}

class TrueLiteral extends Exp {
  const TrueLiteral(super.token);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitTrueLiteral(this, arg);
  }
}

class NullLiteral extends Exp {
  const NullLiteral(super.token);

  @override
  T accept<T, A>(AstNodeVisitor<T, A> visitor, A arg) {
    return visitor.visitNullLiteral(this, arg);
  }
}

class TableLiteral extends Exp {
  final List<Field> fields;
  TableLiteral(super.token, this.fields);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitTableLiteral(this, arg);
  }
}

class Field extends AstNode {
  final Exp? key;
  final Exp value;
  Field(super.token, this.key, this.value);

  @override
  T accept<T, A>(AstNodeVisitor<T, A> visitor, A arg) {
    return visitor.visitField(this, arg);
  }
}

class Identifier extends Exp implements Assignable {
  final String value;
  Identifier(super.token, this.value);

  @override
  T accept<T, A>(AstNodeVisitor<T, A> visitor, A arg) {
    return visitor.visitIdentifier(this, arg);
  }
}

class Index extends Exp implements Assignable {
  final Exp receiver;
  final Exp index;

  /// [dotStyle] is true if the index was written in the dot style.
  /// e.g. `x.y` instead of `x[y]`
  final bool dotStyle;

  Index(super.token, this.receiver, this.index, {this.dotStyle = false});

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitIndex(this, arg);
  }
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
}

class UnOp extends Exp {
  final Exp operand;
  final String op;
  UnOp(super.token, this.op, this.operand);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitUnOp(this, arg);
  }
}

class FunctionExpression extends Exp {
  final List<Identifier> params;
  final Block body;
  FunctionExpression(super.token, this.params, this.body);
  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitFunctionExpression(this, arg);
  }
}

class FunctionCall extends Exp {
  final Exp function;
  final Identifier? name;
  final List<Exp> args;

  FunctionCall(super.token, this.function, this.name, this.args);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitFunctionCall(this, arg);
  }
}

class Quote extends Exp {
  final String type;
  final AstNode ast;
  Quote(super.token, this.type, this.ast);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitQuote(this, arg);
  }
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
}

class Block extends Statement {
  final List<Statement> statements;
  final Statement? finalStatement;

  Block(super.token, List<Statement?> statements, [this.finalStatement])
      : statements = statements.whereType<Statement>().toList();

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitBlock(this, arg);
  }
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
}

class ReturnStatement extends Statement {
  final Exp value;
  ReturnStatement(super.token, this.value);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitReturnStatement(this, arg);
  }
}

class Assignment extends Statement {
  final Exp left;
  final Exp right;
  Assignment(super.token, this.left, this.right);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitAssignment(this, arg);
  }
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
}

sealed class Pattern extends AstNode {
  const Pattern(super.token);
}

class VarPattern extends Pattern {
  final bool isLocal;
  final Identifier name;
  final bool canBeNull;
  VarPattern(super.token, this.name, {required this.isLocal, required this.canBeNull});

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitVarPattern(this, arg);
  }
}

class TablePattern extends Pattern {
  final String type;
  final List<FieldPattern> fields;
  TablePattern(super.token, this.fields, {String? type}) : type = type ?? "table";

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitTablePattern(this, arg);
  }
}

class FieldPattern extends AstNode {
  final Exp? key;
  final Pattern value;
  FieldPattern(super.token, this.key, this.value);

  @override
  T accept<T, A>(AstNodeVisitor<T, A> visitor, A arg) {
    return visitor.visitFieldPattern(this, arg);
  }
}

class ConstPattern extends Pattern {
  final Exp value;
  ConstPattern(super.token, this.value)
      : assert(value is IntLiteral ||
            value is DoubleLiteral ||
            value is StringLiteral ||
            value is TrueLiteral ||
            value is FalseLiteral ||
            value is NullLiteral);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitConstPattern(this, arg);
  }
}

class LetExp extends Exp {
  final Exp right;
  final Pattern pattern;

  LetExp(super.token, this.pattern, this.right);

  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitLetExp(this, arg);
  }
}

class Break extends Statement {
  Break(super.token);
  @override
  T accept<T, A>(AstNodeVisitor visitor, A arg) {
    return visitor.visitBreak(this, arg);
  }
}

class Unquote extends AstNode implements Statement, Exp, Identifier {
  final AstNode ast;
  final String type;

  Unquote(super.token, this.type, this.ast);

  @override
  T accept<T, A>(AstNodeVisitor<T, A> visitor, A arg) {
    return visitor.visitUnquote(this, arg);
  }

  @override
  String get value => throw UnimplementedError();
}
