% N queens: place N queens on an N x N board so that none attacks another.
% Qs lists the row of the queen in each column.
%   ?- queens(8, Qs).
%   ?- solutions(8, N).          % 92

queens(N, Qs) :-
    numlist(1, N, Ns),
    place(Ns, [], Qs).

% place(Unplaced, Placed, Qs): choose the next queen among the unplaced
% rows, checking it against the ones placed so far (generate and test,
% but testing as early as possible)
place([], Qs, Qs).
place(Unplaced, Placed, Qs) :-
    select(Q, Unplaced, Rest),
    safe(Q, Placed, 1),
    place(Rest, [Q|Placed], Qs).

safe(_, [], _).
safe(Q, [Q1|Qs], D) :-
    Q =\= Q1 + D,
    Q =\= Q1 - D,
    D1 is D + 1,
    safe(Q, Qs, D1).

solutions(N, Count) :- aggregate_all(count, queens(N, _), Count).

% a board, printed
show(Qs) :-
    length(Qs, N),
    forall(member(Q, Qs),
           ( forall(between(1, N, C), ( C =:= Q -> write(' Q') ; write(' .') )), nl )).
