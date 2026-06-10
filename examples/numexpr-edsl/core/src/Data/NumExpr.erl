-module(data_numExpr@foreign).
-export([numPow/2, numSin/1, numCos/1, numExp/1, numLog/1, numSqrt/1]).

numPow(X, Y) -> math:pow(X, Y).
numSin(X) -> math:sin(X).
numCos(X) -> math:cos(X).
numExp(X) -> math:exp(X).
numLog(X) -> math:log(X).
numSqrt(X) -> math:sqrt(X).
