# Prolog in slang

A Prolog interpreter written to be read: an explicit machine (goal list,
choice points, trail), cut, exceptions, an operator-precedence reader, DCGs,
and a library partly written in Prolog. It follows
`plans/LOGIC_PROGRAMMING.md`, and the checks listed there are its tests.

```sh
bin/slang run examples/prolog/main.slang                        # ?- prompt
bin/slang run examples/prolog/main.slang examples/prolog/programs/queens.pl
bin/slang run examples/prolog/main.slang examples/prolog/programs/bench.pl -g bench
bin/slang test examples/prolog/test                             # the checks
```

At the prompt, end a query with `.`. After an answer that may have more,
type `;` for the next one or just return to stop. `halt.` leaves.

## Reading order

| file | what it is |
| ---- | ---------- |
| `ast.slang` | the terms: Atom, Integer, Float, String, Compound, the reader's Variable, and while running Var (a logic variable) and Slot (a variable of a stored clause) |
| `grammar.slang` | the reader: tokens, and op/3's operator table on a Pratt walker; reads a file clause by clause because op/3 changes later clauses |
| `terms.slang` | following bindings (deref), copying, the standard order of terms, lists, error terms |
| `compile.slang` | clauses stored with numbered slots (renaming apart), first-argument keys, the DCG translation |
| `engine.slang` | the database and the machine: unification, clause selection, choice points, the trail, cut, catch/throw |
| `arith.slang` | `is/2` and the comparisons |
| `writer.slang` | terms back to text, with operators and quoting |
| `builtins.slang` | the built-in predicates written in slang |
| `prelude.pl` | the library written in Prolog: lists, between/3, retract/1, ... |
| `prolog.slang` | a whole system: consulting files, directives, queries, answers as text |
| `main.slang` | the toplevel |
| `programs/` | family tree, N queens, the zebra puzzle, Hanoi and a sentence DCG, benchmarks |

## How it runs

`engine.slang` explains the machine at its top. In short: the goals still
to prove are a linked list of frames, so saving "the rest" in a choice
point costs nothing. Failure pops the newest choice point and undoes the
bindings on the trail since it was made. A Prolog recursion is a longer
list, not a deeper slang stack, so a million-deep recursion is fine. A call
tries only the clauses whose first argument could match, and a call with a
single candidate leaves no choice point. With the trail rule in `bind`,
a deterministic loop such as `count(1000000)` runs in constant memory.

Every goal frame carries a cut barrier: the height of the choice stack when
the call it belongs to started. `!` pops back to it. `call/1`, `\+` and the
condition of `->` make a new barrier, so a cut inside them stays inside.

A program can change how its terms are shown by defining `portray/1`, as
in SWI-Prolog: the toplevel's answers, `print/1` and `format`'s `~p` call it
for every subterm, and when it succeeds, what it wrote replaces the term
(`programs/natural.pl` shows Peano numbers as integers this way).
`write/1` and `writeq/1` never call it.

## Where it differs from ISO / SWI-Prolog

- Integers are 64 bits: an overflow is `evaluation_error(int_overflow)`,
  there are no big integers.
- `7 / 2` is 3.5 and `8 / 2` is 4 (SWI's default; ISO says 4.0).
- `"text"` is a string (SWI's default), not a code list.
- Lists are `'.'(H, T)` (ISO; SWI 7 uses `'[|]'`).
- A quoted atom is never an operator: `'-'` is always just an atom.
- A predicate belongs to the file (consult) that defined it: a program's own
  `append/3` replaces the library's, and consulting a file again replaces
  its predicates.
- The logical update view: a running call sees the clauses as they were
  when it started.
- No streams beyond standard output: `format/3` writes to `atom(A)`,
  `string(S)` and `codes(C)`, and `read/1` reads standard input.
- No occurs check by default (`unify_with_occurs_check/2` has one).
- The guide's `ancestor(X, jim)` order (pat, bob, tom) is not what depth
  first gives: tom is found through bob and pat before bob is. This, like
  SWI-Prolog, answers pat, tom, bob.

Speed: about 180,000 LIPS on naive reverse (`programs/bench.pl`).
Everything is chosen for clarity first: goals are interpreted as terms on
every call, clause bodies are copied per use, and key strings are built per
call.
