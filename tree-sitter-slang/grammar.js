/**
 * @file Slang grammar for tree-sitter
 * @author Jonathan Kohlhs
 * @license MIT
 */

/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

module.exports = grammar({
  name: "slang",
  conflicts: $ => [
    [$.prefixExpression, $.functionCall],
    [$.block, $.list],
  ],
  extras: $ => [
    /\s/,
    //allow newlines anywhere
    /\n/,
  ],
  rules: {
    // TODO: add the actual grammar rules
    source_file: $ => seq(
      repeat(seq($.statement, optional(";"))),
      optional(seq($.finalStatement, optional(";")))
    ),
    statement: $ => choice(
      $.assignment,
      $.ifStatement,
      $.forLoop,
      $.block,
      $.functionCall,
      $.functionDefinitionStatement,
    ),
    assignment: $ => seq(
      optional("local"),
      $.varRef,
      "=",
      $.expression
    ),
    ifStatement: $ => prec.left(seq(
      "if",
      "(",
      $.expression,
      ")",
      $.statement,
      optional(seq("else", $.statement))
    )),
    forLoop: $ => seq(
      "for",
      "(",
      optional(seq($.statement, ";")),
      $.expression,
      optional(seq(";", $.statement)),
      ")",
      $.statement
    ),
    block: $ => seq(
      "{",
      repeat(seq($.statement, optional(";"))),
      optional(seq($.finalStatement, optional(";"))),
      "}"
    ),
    functionCall: $ => seq(
      field("name",
        $.varRef),
      repeat1($.nameAndArgs)
    ),
    functionDefinitionStatement: $ => seq(
      optional("local"),
      "func",
      field("name",
        $.varRef),
      $.functionDefinition,
    ),
    finalStatement: $ => $.returnStatement,
    returnStatement: $ => seq(
      "return",
      $.expression
    ),

    int: $ => /[+-]?\d+/,
    string: $ => /"[^"]*"/,
    true: $ => "true",
    false: $ => "false",
    null: $ => "null",
    list: $ => seq("{", optional(seq($.field, repeat(seq(",", $.field)), optional(","))), "}"),
    field: $ => seq(optional(seq($.expression, ":")), $.expression),
    name: $ => /[a-zA-Z_]\w*/,
    nameAndArgs: $ => seq(optional(field("name", seq(":", $.name))), field("args", $.args)),
    args: $ => seq("(", optional(seq($.expression, repeat(seq(",", $.expression)))), ")"),
    varRef: $ => prec.left(seq($.name, repeat($.varSuffix))),
    varSuffix: $ => seq(
      repeat($.nameAndArgs),
      choice(
        $.dotSuffix,
        $.bracketSuffix
      ),
    ),
    dotSuffix: $ => seq(".", $.name),
    bracketSuffix: $ => seq("[", $.expression, "]"),
    prefixExpression: $ => prec.left(seq($.varRef, repeat($.nameAndArgs))),
    functionExpression: $ => seq(
      "func",
      $.functionDefinition
    ),
    functionDefinition: $ => prec.left(-1, choice(
      seq(
        $.params,
        $.block
      ),
      seq(
        $.params,
        "=>",
        $.expression
      ))),
    params: $ => seq("(", optional(seq($.name, repeat(seq(",", $.name)))), ")"),
    expression: $ => choice(
      $.int,
      $.string,
      $.true,
      $.false,
      $.null,
      $.list,
      $.prefixExpression,
      $.functionExpression,
      $.unaryExpression,
      $.binaryExpression,
      seq("(", $.expression, ")")
    ),
    unaryExpression: $ => choice(
      prec(5,
        choice(
          seq("-", $.expression),
          seq("not", $.expression),
        ),
      ),
    ),

    binaryExpression: $ => choice(
      prec.right(6,
        seq($.expression, "^", $.expression),
      ),
      prec.left(4,
        choice(
          seq($.expression, "*", $.expression),
          seq($.expression, "/", $.expression),
          seq($.expression, "%", $.expression),
        )
      ),
      prec.left(3,
        choice(
          seq($.expression, "+", $.expression),
          seq($.expression, "-", $.expression),
        )),
      prec.left(2,
        choice(
          seq($.expression, "==", $.expression),
          seq($.expression, "!=", $.expression),
          seq($.expression, ">", $.expression),
          seq($.expression, "<", $.expression),
          seq($.expression, ">=", $.expression),
          seq($.expression, "<=", $.expression),
        )),
      prec.left(1,
        seq($.expression, "and", $.expression)),
      prec.left(0,
        seq($.expression, "or", $.expression)),
    ),

  }
});
