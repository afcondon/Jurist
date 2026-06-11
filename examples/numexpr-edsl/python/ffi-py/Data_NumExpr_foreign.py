# FFI for Data.NumExpr (numexpr-core) - the six irreducible machine-math
# primitives behind core's uniform interface (see core/src/Data/NumExpr.purs:
# one line per backend; this is the purepy line).
import math as _math

def numPow(x): return lambda y: x ** y
def numSin(x): return _math.sin(x)
def numCos(x): return _math.cos(x)
def numExp(x): return _math.exp(x)
def numLog(x): return _math.log(x)
def numSqrt(x): return _math.sqrt(x)
