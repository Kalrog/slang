% Towers of Hanoi, and a DCG that reads simple sentences.
%   ?- hanoi(3).
%   ?- phrase(sentence(T), [the, cat, sees, a, dog]).

hanoi(N) :- move(N, left, right, middle).

move(0, _, _, _) :- !.
move(N, From, To, Via) :-
    M is N - 1,
    move(M, From, Via, To),
    format("move a disk from ~w to ~w~n", [From, To]),
    move(M, Via, To, From).

sentence(s(NP, VP)) --> noun_phrase(NP), verb_phrase(VP).
noun_phrase(np(D, N)) --> determiner(D), noun(N).
verb_phrase(vp(V, NP)) --> verb(V), noun_phrase(NP).
determiner(d(W)) --> [W], { member(W, [the, a]) }.
noun(n(W)) --> [W], { member(W, [cat, dog, mouse]) }.
verb(v(W)) --> [W], { member(W, [sees, chases]) }.
