import 'package:slang/src/compiler/ast.dart';

class ToStringVisitor extends AstNodeVisitor<void, Null> {
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

  String visitToString(AstNode node) {
    visit(node);
    return _buffer.toString();
  }

  @override
  void visitIntLiteral(IntLiteral node, [Null arg]) {
    _append('${node.value}');
  }

  @override
  void visitDoubleLiteral(DoubleLiteral node, Null arg) {
    _append('${node.value}');
  }

  String _escapeString(String str) {
    return str
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r')
        .replaceAll('\t', '\\t')
        .replaceAll('\b', '\\b')
        .replaceAll('\f', '\\f');
  }

  @override
  void visitStringLiteral(StringLiteral node, [Null arg]) {
    _append('"');
    _append(_escapeString(node.value));
    _append('"');
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
  void visitIdentifier(Identifier node, [Null arg]) {
    _append(node.value);
  }

  @override
  void visitIndex(Index node, [Null arg]) {
    if (node.dotStyle) {
      visit(node.receiver);
      _append('.');
      if (node.index is StringLiteral) {
        _append((node.index as StringLiteral).value);
      } else {
        visit(node.index);
      }
    } else {
      visit(node.receiver);
      _append('[');
      visit(node.index);
      _append(']');
    }
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
    visit(node.operand);
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
    visit(node.function);
    if (node.name != null) {
      _append(':');
      _append(node.name!.value);
    }
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
    visit(node.value);
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
    visit(node.value);
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
    for (var field in node.fields) {
      visit(field);
      _append(',');
    }
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
  void visitLetExp(LetExp node, Null arg) {
    _append('let ');
    visit(node.pattern);
    _append(' = ');
    visit(node.right);
  }

  @override
  void visitBreak(Break node, Null arg) {
    _append('break');
  }

  @override
  void visitQuote(Quote quote, Null arg) {
    _append('quote');
    _append('{');
    _append(quote.type);
    _append(':');
    visit(quote.ast);
    _append('}');
  }

  @override
  void visitUnquote(Unquote node, Null arg) {
    _append('unquote');
    _append('{');
    _append(node.type);
    _append(':');
    visit(node.ast);
    _append('}');
  }
}
