eq(0,0).

eq(s(X),s(Y)) :- eq(X,Y).

sum(A,0,A).

sum(A, s(B), s(C)) :-
	sum(A, B, C).

% nat(Peano, Int): s(s(0)) and 2, in either direction
nat(N, I) :- integer(I), !, I >= 0, int_nat(I, N).
nat(N, I) :- nat_int(N, 0, I).

int_nat(0, 0) :- !.
int_nat(I, s(N)) :- I1 is I - 1, int_nat(I1, N).

nat_int(0, I, I).
nat_int(s(N), I0, I) :- I1 is I0 + 1, nat_int(N, I1, I).

portray(s(N)) :- ground(N), nat_int(s(N), 0, I), write(I).

