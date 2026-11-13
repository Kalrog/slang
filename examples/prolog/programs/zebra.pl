% The zebra puzzle: who owns the zebra, and who drinks water?
%   ?- zebra(Owner, Drinker).
% Each house is h(Nationality, Colour, Pet, Drink, Smoke), five in a row.

right_of(A, B, [B, A|_]).
right_of(A, B, [_|T]) :- right_of(A, B, T).

next_to(A, B, L) :- right_of(A, B, L) ; right_of(B, A, L).

houses(Hs) :-
    length(Hs, 5),
    member(h(english, red, _, _, _), Hs),
    member(h(spanish, _, dog, _, _), Hs),
    member(h(_, green, _, coffee, _), Hs),
    member(h(ukrainian, _, _, tea, _), Hs),
    right_of(h(_, green, _, _, _), h(_, ivory, _, _, _), Hs),
    member(h(_, _, snails, _, oldgold), Hs),
    member(h(_, yellow, _, _, kools), Hs),
    Hs = [_, _, h(_, _, _, milk, _), _, _],
    Hs = [h(norwegian, _, _, _, _)|_],
    next_to(h(_, _, _, _, chesterfield), h(_, _, fox, _, _), Hs),
    next_to(h(_, _, _, _, kools), h(_, _, horse, _, _), Hs),
    member(h(_, _, _, orange_juice, luckystrike), Hs),
    member(h(japanese, _, _, _, parliament), Hs),
    next_to(h(norwegian, _, _, _, _), h(_, blue, _, _, _), Hs).

zebra(Owner, Drinker) :-
    houses(Hs),
    member(h(Owner, _, zebra, _, _), Hs),
    member(h(Drinker, _, _, water, _), Hs).
