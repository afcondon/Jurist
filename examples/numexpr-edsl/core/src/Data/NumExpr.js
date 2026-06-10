// JS backend shim for Data.NumExpr's transcendental primitives (node/ workspace).
// The JS package set keeps these on Math.*; PS curried Number->Number->Number
// for numPow.
export const numPow = a => b => Math.pow(a, b);
export const numSin = Math.sin;
export const numCos = Math.cos;
export const numExp = Math.exp;
export const numLog = Math.log;
export const numSqrt = Math.sqrt;
