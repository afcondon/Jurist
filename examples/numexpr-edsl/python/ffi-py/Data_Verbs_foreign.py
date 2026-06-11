# FFI for Data.Verbs (python workspace) - the middle-tier production verbs.
#
# A NumExpr crosses the seam as purepy's tag-tuple representation
# (("Mul", ("Lit", 10.0), ("Var", "x")) ...); this shim walks it once into a
# sympy expression - the staging doctrine at small scale: the structure
# crosses, the CAS does the calculus, LaTeX comes back. sympy is imported
# lazily so programs that never call a verb never pay for it.

def _to_sympy(e, sp, syms):
    tag = e[0]
    if tag == "Lit":
        v = e[1]
        return sp.Integer(int(v)) if v == int(v) else sp.Float(v)
    if tag == "Var":
        return syms.setdefault(e[1], sp.Symbol(e[1]))
    if tag == "Add":
        return _to_sympy(e[1], sp, syms) + _to_sympy(e[2], sp, syms)
    if tag == "Sub":
        return _to_sympy(e[1], sp, syms) - _to_sympy(e[2], sp, syms)
    if tag == "Mul":
        return _to_sympy(e[1], sp, syms) * _to_sympy(e[2], sp, syms)
    if tag == "Div":
        return _to_sympy(e[1], sp, syms) / _to_sympy(e[2], sp, syms)
    if tag == "Neg":
        return -_to_sympy(e[1], sp, syms)
    if tag == "Pow":
        return _to_sympy(e[1], sp, syms) ** _to_sympy(e[2], sp, syms)
    if tag == "Ap":
        fn = {"Sin": "sin", "Cos": "cos", "Exp": "exp",
              "Log": "log", "Sqrt": "sqrt"}[e[1][0]]
        return getattr(sp, fn)(_to_sympy(e[2], sp, syms))
    raise RuntimeError("Data.Verbs: unknown NumExpr constructor " + str(tag))


def exprLatexImpl(declare):
    def go(f):
        import sympy as sp
        syms = {v: sp.Symbol(v) for v in declare}
        return sp.latex(_to_sympy(f, sp, syms))
    return go


def gradientLatexImpl(declare):
    def go1(wrt):
        def go2(f):
            import sympy as sp
            syms = {v: sp.Symbol(v) for v in declare}
            expr = _to_sympy(f, sp, syms)
            return [sp.latex(sp.diff(expr, syms.setdefault(v, sp.Symbol(v))))
                    for v in wrt]
        return go2
    return go1
