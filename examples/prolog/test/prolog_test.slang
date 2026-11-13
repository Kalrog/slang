// The checks of plans/LOGIC_PROGRAMMING.md, section by section: the
// queries it lists and the answers it expects, as the toplevel would show
// them.
local t = require("slang/test")
local str = require("slang/string")
local prolog = require("prolog")
local terms = require("terms")

// a Prolog system with program loaded; warnings while loading fail the
// test, and what the program writes is collected in .written
local func system(program){
  local written = {}
  local p = prolog.new({
    output: func(text){ append(written, text) },
    warn: func(text){ raise(error.new("warning", text)) },
  })
  p.written = written
  if(program != null){
    p:consult(program)
  }
  return p
}

local func output_of(p) => str.join(p.written, "")

// the answers of a query joined with " ; "
local func answers(p, query, limit) => str.join(p:answers(query, limit), " ; ")

local func check(p, query, expected){
  local got = answers(p, query)
  assert(got == expected, concat("?- ", query, "\n  got:      ", got,
    "\n  expected: ", expected))
}

local FAMILY = """
parent(tom, bob).   parent(tom, liz).
parent(bob, ann).   parent(bob, pat).
parent(pat, jim).

grandparent(X, Z) :- parent(X, Y), parent(Y, Z).
ancestor(X, Y) :- parent(X, Y).
ancestor(X, Y) :- parent(X, Z), ancestor(Z, Y).

append([], L, L).
append([H|T], L, [H|R]) :- append(T, L, R).

member(X, [X|_]).
member(X, [_|T]) :- member(X, T).
"""

t.group("1. terms"){
  t.test("terms print as they read"){
    local p = system()
    check(p, "X = f(A, g(B, [1,2|T]), 'a b')", "X = f(A, g(B, [1, 2|T]), 'a b')")
  }
  t.test("a clause's variables are its own"){
    local p = system("same(X, X).")
    check(p, "same(A, 1), same(B, 2)", "A = 1, B = 2")
  }
}

t.group("2. unification"){
  t.test("the table"){
    local p = system()
    check(p, "f(X, b) = f(a, Y)", "X = a, Y = b")
    check(p, "f(X, X) = f(a, b)", "false")
    check(p, "f(X, X) = f(a, a)", "X = a")
    check(p, "f(X, Y) = f(Y, a)", "X = a, Y = a")
    check(p, "[H|T] = [1, 2, 3]", "H = 1, T = [2, 3]")
    check(p, "[A, B|_] = [x]", "false")
    check(p, "f(X) = g(X)", "false")
    check(p, "f(X) = f(X, Y)", "false")
    check(p, "X = Y, Y = Z, Z = q", "X = q, Y = q, Z = q")
    check(p, "unify_with_occurs_check(X, f(X))", "false")
    check(p, "1 = 1.0", "false")
  }
  t.test("a failed unification leaves no bindings"){
    local p = system()
    check(p, "f(X, b) = f(a, c), var(X)", "false")
    local q = p:query("f(X, b) = f(a, c)")
    assert(not q.next())
    assert(terms.deref(q.names.vars.X).ref == null, "X is unbound")
  }
}

t.group("3. renaming apart"){
  t.test("same/2"){
    local p = system("same(X, X).")
    check(p, "same(A, 1), same(B, 2)", "A = 1, B = 2")
    check(p, "same(f(Q), R)", "R = f(Q)")
  }
}

t.group("4. resolution"){
  t.test("family"){
    local p = system(FAMILY)
    check(p, "grandparent(tom, W)", "W = ann ; W = pat")
    check(p, "ancestor(tom, jim)", "true")
    // depth first: tom (through bob and pat) is found before bob (through
    // pat); the guide lists pat, bob, tom
    check(p, "ancestor(X, jim)", "X = pat ; X = tom ; X = bob")
  }
  t.test("append both ways"){
    local p = system(FAMILY)
    check(p, "append([1,2], [3], L)", "L = [1, 2, 3]")
    check(p, "append(X, Y, [1,2,3])", concat(
      "X = [], Y = [1, 2, 3] ; X = [1], Y = [2, 3] ; ",
      "X = [1, 2], Y = [3] ; X = [1, 2, 3], Y = []",
    ))
    check(p, "append(X, [3], [1,2,3])", "X = [1, 2]")
  }
  t.test("member, and stopping after three of infinitely many"){
    local p = system(FAMILY)
    check(p, "member(X, [a,b,c])", "X = a ; X = b ; X = c")
    local three = p:answers("member(b, L)", 3)
    assert(len(three) == 3)
    assert(str.starts_with(three[0], "L = [b|_"), three[0])
    assert(str.starts_with(three[1], "L = [_") and str.contains(three[1], ", b|_"),
      three[1])
  }
}

t.group("5. the machine"){
  t.test("answers on demand"){
    local p = system(FAMILY)
    local q = p:query("member(X, [1,2,3])")
    assert(q.next() and q.text() == "X = 1")
    assert(q.next() and q.text() == "X = 2")
    q.close()
  }
  t.test("deep recursion does not use the slang stack"){
    local p = system("""
      len([], 0).
      len([_|T], N) :- len(T, M), N is M + 1.
    """)
    check(p, "numlist(1, 100000, _L), len(_L, N)", "N = 100000")
  }
  t.test("a failure-driven loop"){
    local p = system(FAMILY)
    check(p, "member(X, [a,b,c]), write(X), nl, fail", "false")
    assert(output_of(p) == "a\nb\nc\n", output_of(p))
  }
}

t.group("6. cut"){
  local CUTS = """
    t(1). t(2). t(3).
    first(X) :- t(X), !.
    after1(X) :- t(X), X > 1, !.
    a(X) :- first(X).
    a(4).
    b(X) :- call((t(X), !)).
    b(9).
    max(X, Y, X) :- X >= Y, !.
    max(_, Y, Y).
  """
  t.test("the table"){
    local p = system(CUTS)
    check(p, "first(X)", "X = 1")
    check(p, "after1(X)", "X = 2")
    check(p, "a(X)", "X = 1 ; X = 4")
    check(p, "b(X)", "X = 1 ; X = 9")
  }
  t.test("a red cut is wrong like in real Prolog"){
    local p = system(CUTS)
    check(p, "max(3, 1, M)", "M = 3")
    check(p, "max(3, 1, 1)", "true")
  }
}

t.group("7. control"){
  t.test("negation as failure"){
    local p = system()
    check(p, "X = a, \\+ X = b", "X = a")
    check(p, "\\+ X = b, X = a", "false")
  }
  t.test("if-then-else"){
    local p = system()
    check(p, "( member(X, [1,2,3]), X > 1 -> Y = yes ; Y = no )", "X = 2, Y = yes")
    check(p, "( fail -> Y = 1 ; Y = 2 )", "Y = 2")
    check(p, "( fail -> Y = 1 )", "false")
  }
  t.test("a cut in a disjunction cuts the clause"){
    local p = system("""
      d(X) :- ( X = 1 ; X = 2 ), !.
      d(3).
    """)
    check(p, "d(X)", "X = 1")
  }
  t.test("maplist with a lambda"){
    local p = system()
    check(p, "maplist([X,Y]>>(Y is X*2), [1,2,3], L)", "L = [2, 4, 6]")
  }
}

t.group("8. arithmetic"){
  local NUMBERS = """
    fact(0, 1) :- !.
    fact(N, F) :- N1 is N - 1, fact(N1, F1), F is N * F1.

    fib(0, 0). fib(1, 1).
    fib(N, F) :- N > 1, A is N-1, B is N-2, fib(A, FA), fib(B, FB), F is FA+FB.

    nat_add(0, Y, Y).
    nat_add(s(X), Y, s(Z)) :- nat_add(X, Y, Z).
  """
  t.test("terms are not evaluated until asked"){
    local p = system()
    check(p, "X = 1 + 2", "X = 1+2")
    check(p, "X is 1 + 2", "X = 3")
    check(p, "1 + 2 =:= 3", "true")
    check(p, "1 + 2 == 3", "false")
  }
  t.test("fact and fib"){
    local p = system(NUMBERS)
    check(p, "fact(20, F)", "F = 2432902008176640000")
    check(p, "fib(15, F)", "F = 610")
  }
  t.test("no big integers: overflow is an error, not a wrong number"){
    local p = system(NUMBERS)
    check(p, "fact(30, F)", "error: Arithmetic: evaluation error: int_overflow")
  }
  t.test("an unbound variable is an instantiation error"){
    local p = system()
    check(p, "X is Y + 1", "error: Arguments are not sufficiently instantiated")
  }
  t.test("Peano numbers run backwards"){
    local p = system(NUMBERS)
    check(p, "nat_add(X, Y, s(s(0)))", concat(
      "X = 0, Y = s(s(0)) ; X = s(0), Y = s(0) ; X = s(s(0)), Y = 0",
    ))
  }
  t.test("division and friends"){
    local p = system()
    check(p, "X is 7 / 2, Y is 8 / 2, Z is 7 // 2", "X = 3.5, Y = 4, Z = 3")
    check(p, "X is -7 // 2, Y is -7 mod 2, Z is -7 rem 2", "X = -3, Y = 1, Z = -1")
    check(p, "X is 2 ** 10, Y is 2 ^ 62", "X = 1024, Y = 4611686018427387904")
    check(p, "X is 1 / 0", "error: Arithmetic: evaluation error: zero_divisor")
  }
}

t.group("9. the meta level"){
  t.test("findall, bagof, setof"){
    local p = system(FAMILY)
    check(p, "findall(X, member(X, [c,a,b]), L)", "L = [c, a, b]")
    check(p, "findall(X, fail, L)", "L = []")
    check(p, "bagof(X, fail, L)", "false")
    check(p, "setof(X, member(X, [c,a,b,a]), L)", "L = [a, b, c]")
    check(p, "bagof(C, parent(P, C), L)", concat(
      "P = bob, L = [ann, pat] ; P = pat, L = [jim] ; P = tom, L = [bob, liz]",
    ))
    check(p, "bagof(C, P^parent(P, C), L)", "L = [bob, liz, ann, pat, jim]")
  }
  t.test("taking terms apart"){
    local p = system()
    check(p, "f(a, X) =.. L", "L = [f, a, X]")
    check(p, "T =.. [g, 1]", "T = g(1)")
    check(p, "functor(f(a, b), N, A)", "N = f, A = 2")
    check(p, "functor(T, g, 2), T = g(A, B)", "T = g(A, B)")
    check(p, "arg(2, f(a, b), X)", "X = b")
    check(p, "copy_term(f(X, Y, X), C), C = f(1, 2, Z)", "C = f(1, 2, 1), Z = 1")
  }
  t.test("the standard order"){
    local p = system()
    check(p, "msort([b, 1, f(x), a, X, 2.0], S)", "S = [X, 1, 2.0, a, b, f(x)]")
    check(p, "compare(O, 1, 1.0)", "O = >")
    check(p, "sort([c, a, b, a], S)", "S = [a, b, c]")
    check(p, "sort(0, @>=, [1, 3, 2, 3], S)", "S = [3, 3, 2, 1]")
  }
  t.test("the meta-interpreter"){
    local p = system("""
      solve(true) :- !.
      solve((A, B)) :- !, solve(A), solve(B).
      solve(H) :- clause(H, Body), solve(Body).

      app([], L, L).
      app([H|T], L, [H|R]) :- app(T, L, R).
    """)
    check(p, "solve(app(X, Y, [1,2]))",
      "X = [], Y = [1, 2] ; X = [1], Y = [2] ; X = [1, 2], Y = []")
  }
  t.test("assert, retract and the logical update view"){
    local p = system("""
      :- dynamic counter/1, q/1.
      counter(0).
      q(1). q(2).
      bump :- retract(counter(N)), N1 is N + 1, assertz(counter(N1)).
    """)
    check(p, "bump, bump, counter(X)", "X = 2")
    check(p, "findall(X, (q(X), assertz(q(9))), L)", "L = [1, 2]")
    check(p, "findall(X, q(X), L)", "L = [1, 2, 9, 9]")
    // retract/1 retracts the next matching clause on backtracking: once/1
    check(p, "once(retract(q(9))), findall(X, q(X), L)", "L = [1, 2, 9]")
    check(p, "retractall(q(_)), findall(X, q(X), L)", "L = []")
    check(p, "q(1)", "false")
    check(p, "asserta(q(0)), assertz(q(5)), findall(X, q(X), L)", "L = [0, 5]")
    check(p, "clause(bump, (retract(C), _)), C = counter(N)", "C = counter(N)")
  }
}

t.group("10. reading"){
  t.test("operators"){
    local p = system()
    check(p, "X = (a :- b, c), X =.. L", "X = (a:-b, c), L = [:-, a, (b, c)]")
    check(p, "X = 1 - 2 - 3, X = A - B", "X = 1-2-3, A = 1-2, B = 3")
    check(p, "X = (a , b , c), X = (P , Q)", "X = (a, b, c), P = a, Q = (b, c)")
    check(p, "X = - 1, integer(X)", "false")
    check(p, "X = -1, integer(X)", "X = -1")
    check(p, "X = 'a.b', Y = 1.5", "X = 'a.b', Y = 1.5")
  }
  t.test("op/3 changes how later clauses read"){
    local p = system(":- op(700, xfx, ===>).\nrule(a ===> b).")
    check(p, "rule(X), X =.. L", "X = (a===>b), L = [===>, a, b]")
  }
  t.test("write_canonical"){
    local p = system()
    check(p, "write_canonical(1 + 2 * 3)", "true")
    assert(output_of(p) == "+(1,*(2,3))", output_of(p))
  }
  t.test("DCGs"){
    local p = system("""
      greeting --> [hello], name.
      name --> [world].
      name --> [prolog].

      expr(E) --> term(T), expr_rest(T, E).
      expr_rest(Acc, E) --> [+], !, term(T), expr_rest(Acc + T, E).
      expr_rest(E, E) --> [].
      term(T) --> factor(F), term_rest(F, T).
      term_rest(Acc, T) --> [*], !, factor(F), term_rest(Acc * F, T).
      term_rest(T, T) --> [].
      factor(N) --> [N], { number(N) }.
    """)
    check(p, "phrase(greeting, [hello, X])", "X = world ; X = prolog")
    check(p, "phrase(expr(E), [1, +, 2, *, 3]), V is E", "E = 1+2*3, V = 7")
  }
}

t.group("11. indexing and the last call"){
  t.test("a deterministic call leaves no choice point"){
    local p = system("""
      len([], 0).
      len([_|T], N) :- len(T, M), N is M + 1.
      count(0).
      count(N) :- N > 0, N1 is N - 1, count(N1).
    """)
    // the first argument tells the two clauses of len/2 apart
    local q = p:query("len([a, b, c], N)")
    assert(q.next())
    assert(not q.has_more(), "no choice point left")
    q.close()
    // count(0) matches both clauses of count/1 (N is not known to be > 0
    // until the body runs), so one is left, as in SWI-Prolog
    q = p:query("count(10000)")
    assert(q.next())
    assert(q.has_more())
    assert(not q.next())
    q.close()
  }
}

t.group("12. exceptions"){
  t.test("catch and throw"){
    local p = system()
    check(p, "catch(X is 1/0, error(E, _), true)", "E = evaluation_error(zero_divisor)")
    check(p, "catch(throw(my), my, Y = caught)", "Y = caught")
    check(p, "catch(throw(f(1)), f(X), true)", "X = 1")
    check(p, "catch(member(X, [1,2]), _, true), X > 1", "X = 2")
    check(p, "catch(true, _, true), throw(oops)", "error: Unhandled exception: oops")
    check(p, "catch(undefined_thing, error(existence_error(procedure, PI), _), true)",
      "PI = undefined_thing/0")
  }
  t.test("bindings made before a throw are undone"){
    local p = system()
    check(p, "catch((X = 1, throw(e)), e, true)", "true")
  }
}

t.group("programs"){
  t.test("queens: 6 queens have 4 solutions"){
    local p = system("""
      queens(N, Qs) :- numlist(1, N, Ns), permutation(Ns, Qs), safe(Qs).
      safe([]).
      safe([Q|Qs]) :- no_attack(Q, Qs, 1), safe(Qs).
      no_attack(_, [], _).
      no_attack(Q, [Q1|Qs], D) :-
          Q =\\= Q1 + D, Q =\\= Q1 - D, D1 is D + 1, no_attack(Q, Qs, D1).
    """)
    check(p, "findall(Q, queens(6, Q), L), length(L, N)", concat(
      "L = [[2, 4, 6, 1, 3, 5], [3, 6, 2, 5, 1, 4], [4, 1, 5, 2, 6, 3], ",
      "[5, 3, 1, 6, 4, 2]], N = 4",
    ))
  }
  t.test("format"){
    local p = system()
    check(p, "format(\"~w and ~a: ~d, ~2f~n\", [f(x), abc, 42, 3.14159])", "true")
    check(p, "format(atom(A), \"~t~w~10||~n\", [right])", "A = '     right|\\n'")
    assert(output_of(p) == "f(x) and abc: 42, 3.14\n", output_of(p))
  }
  t.test("portray/1 changes how answers and print/1 show terms"){
    local p = system("""
      sum(A, 0, A).
      sum(A, s(B), s(C)) :- sum(A, B, C).
      nat_int(0, I, I).
      nat_int(s(N), I0, I) :- I1 is I0 + 1, nat_int(N, I1, I).
      portray(s(N)) :- ground(N), nat_int(s(N), 0, I), write(I).
    """)
    check(p, "sum(s(0), s(s(0)), X)", "X = 3")
    check(p, "X = f(s(s(0)), s(Y))", "X = f(2, s(Y))")
    check(p, "print(s(s(0))), write(' '), write(s(s(0))), write(' '), writeq(s(0))", "true")
    assert(output_of(p) == "2 s(s(0)) s(0)", output_of(p))
  }
  t.test("listing"){
    local p = system(FAMILY)
    check(p, "listing(ancestor/2)", "true")
    assert(output_of(p) == concat(
      "ancestor(A, B) :-\n    parent(A, B).\n",
      "ancestor(A, B) :-\n    parent(A, C),\n    ancestor(C, B).\n\n",
    ), output_of(p))
  }
  t.test("strings and atoms"){
    local p = system()
    check(p, "atom_codes(abc, L)", "L = [97, 98, 99]")
    check(p, "atom_chars(X, [a, b])", "X = ab")
    check(p, "atom_length(hello, N)", "N = 5")
    check(p, "atom_concat(X, Y, ab)", "X = '', Y = ab ; X = a, Y = b ; X = ab, Y = ''")
    check(p, "sub_atom(hello, B, 2, A, ll)", "B = 2, A = 1")
    check(p, "atomic_list_concat([a, b, c], '-', X)", "X = 'a-b-c'")
    check(p, "atomic_list_concat(L, ',', 'x,y')", "L = [x, y]")
    check(p, "atom_number('12', N)", "N = 12")
    check(p, "atom_number(foo, N)", "false")
    check(p, "term_to_atom(f(x, 'a b'), A)", "A = 'f(x,\\'a b\\')'")
    check(p, "term_to_atom(T, 'foo(1 + 2)')", "T = foo(1+2)")
  }
}
