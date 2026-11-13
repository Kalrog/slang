% The family tree of section 4 of the guide: facts, rules, recursion.
%   ?- grandparent(tom, W).
%   ?- ancestor(X, jim).

parent(tom, bob).   parent(tom, liz).
parent(bob, ann).   parent(bob, pat).
parent(pat, jim).

grandparent(X, Z) :- parent(X, Y), parent(Y, Z).

ancestor(X, Y) :- parent(X, Y).
ancestor(X, Y) :- parent(X, Z), ancestor(Z, Y).
