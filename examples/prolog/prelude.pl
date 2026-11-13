% The library: predicates written in Prolog on top of the built-ins
% (builtins.slang). Loaded before anything else. A program that defines
% one of these itself (its own append/3, say) replaces it.

% ------------------------------------------------------------------ control

once(G) :- call(G), !.
ignore(G) :- (call(G) -> true ; true).
not(G) :- \+ call(G).

% ------------------------------------------------------------------- lists

append([], L, L).
append([H|T], L, [H|R]) :- append(T, L, R).

% append(ListOfLists, List): concatenate all of them
append([], []).
append([L|Ls], As) :- append(L, Ws, As), append(Ls, Ws).

member(X, [X|_]).
member(X, [_|T]) :- member(X, T).

memberchk(X, L) :- member(X, L), !.

% length(List, N): counts a list, or makes lists of every length when
% both are unknown
length(List, N) :- var(N), !, '$length'(List, 0, N).
length(List, N) :- integer(N), N >= 0, '$length_make'(N, List).

'$length'([], N, N).
'$length'([_|T], N0, N) :- N1 is N0 + 1, '$length'(T, N1, N).

'$length_make'(0, []) :- !.
'$length_make'(N, [_|T]) :- N1 is N - 1, '$length_make'(N1, T).

reverse(L, R) :- '$reverse'(L, [], R).
'$reverse'([], A, A).
'$reverse'([H|T], A, R) :- '$reverse'(T, [H|A], R).

nth0(I, L, E) :- integer(I), !, I >= 0, '$nth'(I, L, E).
nth0(I, L, E) :- var(I), '$nth_enum'(L, E, 0, I).
nth1(I, L, E) :- integer(I), !, I0 is I - 1, nth0(I0, L, E).
nth1(I, L, E) :- var(I), nth0(I0, L, E), I is I0 + 1.

'$nth'(0, [E|_], E) :- !.
'$nth'(I, [_|T], E) :- I1 is I - 1, '$nth'(I1, T, E).
'$nth_enum'([E|_], E, I, I).
'$nth_enum'([_|T], E, I0, I) :- I1 is I0 + 1, '$nth_enum'(T, E, I1, I).

last([X|Xs], Last) :- '$last'(Xs, X, Last).
'$last'([], L, L).
'$last'([X|Xs], _, L) :- '$last'(Xs, X, L).

select(X, [X|T], T).
select(X, [H|T], [H|R]) :- select(X, T, R).

selectchk(X, L, R) :- select(X, L, R), !.

permutation([], []).
permutation(L, [H|T]) :- select(H, L, R), permutation(R, T).

delete([], _, []).
delete([H|T], X, R) :- ( H \= X -> R = [H|R1] ; R = R1 ), delete(T, X, R1).

exclude(_, [], []).
exclude(P, [X|Xs], R) :- ( call(P, X) -> R = R1 ; R = [X|R1] ), exclude(P, Xs, R1).

include(_, [], []).
include(P, [X|Xs], R) :- ( call(P, X) -> R = [X|R1] ; R = R1 ), include(P, Xs, R1).

partition(_, [], [], []).
partition(P, [X|Xs], I, E) :-
    (   call(P, X) -> I = [X|I1], E = E1
    ;   I = I1, E = [X|E1]
    ),
    partition(P, Xs, I1, E1).

subtract([], _, []).
subtract([H|T], D, R) :- ( memberchk(H, D) -> R = R1 ; R = [H|R1] ), subtract(T, D, R1).

intersection([], _, []).
intersection([H|T], L, R) :- ( memberchk(H, L) -> R = [H|R1] ; R = R1 ), intersection(T, L, R1).

union([], L, L).
union([H|T], L, R) :- ( memberchk(H, L) -> R = R1 ; R = [H|R1] ), union(T, L, R1).

% list_to_set(List, Set): the first of every element (by ==)
list_to_set(L, S) :- '$list_to_set'(L, [], S).
'$list_to_set'([], _, []).
'$list_to_set'([H|T], Seen, R) :-
    (   '$memberchk_eq'(H, Seen) -> R = R1
    ;   R = [H|R1]
    ),
    '$list_to_set'(T, [H|Seen], R1).
'$memberchk_eq'(X, [Y|Ys]) :- ( X == Y -> true ; '$memberchk_eq'(X, Ys) ).

flatten(List, Flat) :- '$flatten'(List, [], Flat0), !, Flat = Flat0.
'$flatten'(Var, Tl, [Var|Tl]) :- var(Var), !.
'$flatten'([], Tl, Tl) :- !.
'$flatten'([Hd|Tl], Tail, List) :- !,
    '$flatten'(Hd, FlatHeadTail, List),
    '$flatten'(Tl, Tail, FlatHeadTail).
'$flatten'(NonList, Tl, [NonList|Tl]).

sum_list(L, S) :- foldl('$plus', L, 0, S).
sumlist(L, S) :- sum_list(L, S).
'$plus'(X, A0, A) :- A is A0 + X.

max_list([H|T], M) :- foldl('$max', T, H, M).
min_list([H|T], M) :- foldl('$min', T, H, M).
'$max'(X, A0, A) :- A is max(A0, X).
'$min'(X, A0, A) :- A is min(A0, X).

max_member(M, [H|T]) :- foldl('$max_member', T, H, M).
min_member(M, [H|T]) :- foldl('$min_member', T, H, M).
'$max_member'(X, M0, M) :- ( X @> M0 -> M = X ; M = M0 ).
'$min_member'(X, M0, M) :- ( X @< M0 -> M = X ; M = M0 ).

numlist(L, H, R) :- L =< H, '$numlist'(L, H, R).
'$numlist'(H, H, [H]) :- !.
'$numlist'(L, H, [L|T]) :- L1 is L + 1, '$numlist'(L1, H, T).

pairs_keys_values([], [], []).
pairs_keys_values([K-V|T], [K|Ks], [V|Vs]) :- pairs_keys_values(T, Ks, Vs).
pairs_keys([], []).
pairs_keys([K-_|T], [K|Ks]) :- pairs_keys(T, Ks).
pairs_values([], []).
pairs_values([_-V|T], [V|Vs]) :- pairs_values(T, Vs).

% predsort(P, List, Sorted): sorted by call(P, Order, A, B), dropping the
% elements P finds equal (=); an insertion sort, short rather than fast
predsort(_, [], []).
predsort(P, [H|T], S) :- predsort(P, T, S0), '$predsort_insert'(P, H, S0, S).
'$predsort_insert'(_, X, [], [X]).
'$predsort_insert'(P, X, [Y|Ys], R) :-
    call(P, O, X, Y),
    '$predsort_insert'(O, P, X, Y, Ys, R).
'$predsort_insert'(<, _, X, Y, Ys, [X, Y|Ys]).
'$predsort_insert'(=, _, _, Y, Ys, [Y|Ys]).
'$predsort_insert'(>, P, X, Y, Ys, [Y|R]) :- '$predsort_insert'(P, X, Ys, R).

% ------------------------------------------------------------ higher order

maplist(_, []).
maplist(G, [A|As]) :- call(G, A), maplist(G, As).
maplist(_, [], []).
maplist(G, [A|As], [B|Bs]) :- call(G, A, B), maplist(G, As, Bs).
maplist(_, [], [], []).
maplist(G, [A|As], [B|Bs], [C|Cs]) :- call(G, A, B, C), maplist(G, As, Bs, Cs).
maplist(_, [], [], [], []).
maplist(G, [A|As], [B|Bs], [C|Cs], [D|Ds]) :-
    call(G, A, B, C, D), maplist(G, As, Bs, Cs, Ds).

foldl(G, L, A0, A) :- '$foldl'(L, G, A0, A).
'$foldl'([], _, A, A).
'$foldl'([X|Xs], G, A0, A) :- call(G, X, A0, A1), '$foldl'(Xs, G, A1, A).

foldl(G, L1, L2, A0, A) :- '$foldl'(L1, L2, G, A0, A).
'$foldl'([], [], _, A, A).
'$foldl'([X|Xs], [Y|Ys], G, A0, A) :-
    call(G, X, Y, A0, A1), '$foldl'(Xs, Ys, G, A1, A).

% ------------------------------------------------------------- arithmetic

% between(Low, High, X): Low =< X =< High, one by one (High may be inf)
between(L, H, X) :- integer(X), !, X >= L, X =< H.
between(L, H, L) :- L =< H.
between(L, H, X) :- L < H, L1 is L + 1, between(L1, H, X).

% ---------------------------------------------------------------- database

clause(H, B) :- '$clauses'(H, Cs), member(_-(H :- B), Cs).

retract((H :- B)) :- !, '$clauses'(H, Cs), member(Id-(H :- B), Cs), '$erase'(H, Id).
retract(H) :- '$clauses'(H, Cs), member(Id-(H :- true), Cs), '$erase'(H, Id).

retractall(H) :-
    '$ensure_dynamic'(H),
    '$clauses'(H, Cs),
    forall(member(Id-(H :- _), Cs), '$erase'(H, Id)).

% ------------------------------------------------------------------ timing

% time(G): G's first solution, and how long it took
time(G) :-
    statistics(inferences, I0),
    statistics(cputime, T0),
    (   catch(G, E, true) -> Result = yes ; Result = no ),
    statistics(cputime, T1),
    statistics(inferences, I1),
    I is I1 - I0 - 2,
    T is T1 - T0,
    (   T > 0 -> Lips is integer(I / T) ; Lips = 'Infinite' ),
    format("% ~D inferences, ~3f CPU seconds (~w Lips)~n", [I, T, Lips]),
    (   nonvar(E) -> throw(E) ; Result == yes ).
