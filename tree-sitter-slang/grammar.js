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
    [$.prefix_expression, $.function_call],
  ],
  extras: $ => [
    /\s/,
    //allow newlines anywhere
    /\n/,
    seq("//", /[^\n]*/, "\n")
  ],
  rules: {
    source_file: $ => seq(
      repeat(seq($.statement, optional(";"))),
      optional(seq($.final_statement, optional(";")))
    ),
    statement: $ => choice(
      $.declaration,
      $.assignment,
      $.if_statement,
      $.for_loop,
      $.function_call,
      $.function_definition_statement,
    ),
    statement_or_block: $ => choice(
      $.statement,
      $.block,
    ),
    assignment: $ => seq(
      $.var_ref,
      "=",
      $.expression
    ),
    declaration: $ => seq(
      "local",
      $.var_ref,
      optional(seq("=", $.expression)),
    ),
    if_statement: $ => prec.left(seq(
      "if",
      "(",
      $.expression,
      ")",
      $.statement_or_block,
      optional(seq("else", $.statement_or_block)),
    )),
    for_loop: $ => seq(
      "for",
      "(",
      optional(seq($.statement, ";")),
      $.expression,
      optional(seq(";", $.statement)),
      ")",
      $.statement_or_block
    ),
    for_in_loop: $ => seq(
      "for",
      "(",
      $.slang_pattern,
      "in",
      $.expression,
      ")",
      $.statement_or_block
    ),
    block: $ => seq(
      "{",
      repeat(seq($.statement_or_block, optional(";"))),
      optional(seq($.final_statement, optional(";"))),
      "}"
    ),
    function_call: $ => seq(
      field("name",
        $.var_ref),
      repeat1($.name_and_args)
    ),
    function_definition_statement: $ => seq(
      optional("local"),
      "func",
      field("name",
        $.var_ref),
      $.function_definition,
    ),
    final_statement: $ => $.return_statement,
    return_statement: $ => seq(
      "return",
      $.expression
    ),

    int: $ => /[+-]?\d+/,
    double: $ => /[+-]?\d+\.\d+/,
    string: $ => /"[^"]*"/,
    true: $ => "true",
    false: $ => "false",
    null: $ => "null",
    table: $ => seq(
      "{",
      repeatSeperatedWithTrailing($.table_field, ","),
      "}"
    ),
    table_field: $ => seq(
      optional(field("key", $.field_key)),
      $.expression,
    ),
    field_key: $ => prec(1, choice(
      seq($.name, ":"),
      seq("[", $.expression, "]", ":"),
    )),
    name: $ => /[a-zA-Z_]\w*/,
    name_and_args: $ => seq(optional(field("name", seq(":", $.name))), field("args", $.args)),
    args: $ => seq("(", optional(seq($.expression, repeat(seq(",", $.expression)))), ")"),
    var_ref: $ => prec.left(seq($.name, optional(field("suffix", repeat($.var_suffix))))),
    var_suffix: $ => seq(
      repeat($.name_and_args),
      choice(
        $.dot_suffix,
        $.bracket_suffix
      ),
    ),
    dot_suffix: $ => seq(".", $.name),
    bracket_suffix: $ => seq("[", $.expression, "]"),
    prefix_expression: $ => prec.left(seq($.var_ref, repeat($.name_and_args))),
    function_expression: $ => seq(
      "func",
      $.function_definition
    ),
    function_definition: $ => prec.left(-1, choice(
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
      $.double,
      $.string,
      $.true,
      $.false,
      $.null,
      $.table,
      $.prefix_expression,
      $.function_expression,
      $.pattern_assignment_expression,
      $.unary_expression,
      $.binary_expression,
      seq("(", $.expression, ")")
    ),
    unary_expression: $ => choice(
      prec(5,
        choice(
          seq("-", $.expression),
          seq("not", $.expression),
        ),
      ),
    ),

    binary_expression: $ => choice(
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
    slang_pattern: $ => choice(
      $.table_pattern,
      $.const_pattern,
      $.var_pattern,
    ),
    table_pattern: $ => seq(
      "{",
      repeatSeperated($.field_pattern, ","),
      "}",
    ),
    field_pattern: $ => seq(
      seq(
        optional(
          choice(
            seq($.name, ":"),
            seq("[", $.expression, "]", ":"),
          ),
        ),
        $.slang_pattern,
      ),
    ),
    const_pattern: $ => choice(
      $.int,
      $.double,
      $.string,
      $.true,
      $.false,
      $.null,
    ),
    var_pattern: $ => seq(
      optional("local"),
      $.name,
      optional("?"),
    ),
    pattern_assignment_expression: $ => prec.left(7, seq(
      "let",
      $.slang_pattern,
      "=",
      $.expression,
    )),
  }
});

function repeatSeperated(rule, seperator) {
  return optional(seq(rule, repeat(seq(seperator, rule))))
}

function repeat1Seperated(rule, seperator) {
  return seq(rule, repeat(seq(seperator, rule)))
}

function repeatSeperatedWithTrailing(rule, seperator) {
  return seq(repeatSeperated(rule, seperator), optional(seperator))
}
