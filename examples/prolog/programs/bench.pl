% Benchmarks: naive reverse (the classic LIPS measure: nrev of a 30
% element list is 496 inferences), fib, and a long deterministic loop.
%   bin/slang run examples/prolog/main.slang examples/prolog/programs/bench.pl -g bench

app([], L, L).
app([H|T], L, [H|R]) :- app(T, L, R).

nrev([], []).
nrev([H|T], R) :- nrev(T, RT), app(RT, [H], R).

nrev_times(0, _) :- !.
nrev_times(N, L) :- nrev(L, _), N1 is N - 1, nrev_times(N1, L).

fib(0, 0).
fib(1, 1).
fib(N, F) :- N > 1, A is N - 1, B is N - 2, fib(A, FA), fib(B, FB), F is FA + FB.

count(0) :- !.
count(N) :- N1 is N - 1, count(N1).

bench :-
    numlist(1, 30, L),
    write('nrev of 30 elements, 300 times:'), nl,
    time(nrev_times(300, L)),
    write('fib(20):'), nl,
    time(fib(20, _)),
    write('count(300000):'), nl,
    time(count(300000)).
