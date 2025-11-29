-- © 2025 John Emanuelsson
-- File created 2025-11-28 23:13:49 CET
-- Loads usefull stuff to global variables

_G.lpeg = require("lpeg")
---@global lct
_G.lct = require("lib_lua_code_tool")

-- https://www.inf.puc-rio.br/~roberto/lpeg/
-- Lpeg
P = lpeg.P -- Matches string exactly
S = lpeg.S -- Matches any character
R = lpeg.R -- Match character between x and y
UtfR = lpeg.utfR
B = lpeg.B -- Match bbbehind current position, consuming no input
V = lpeg.V -- Create a nonterminal ????
-- Lpeg captures
C = lpeg.C --
Carg = lpeg.Carg
Cb = lpeg.Cb
Cc = lpeg.Cc
Cf = lpeg.Cf
Cg = lpeg.Cg
Cp = lpeg.Cp
Cs = lpeg.Cs
Ct = lpeg.Ct
Cmt = lpeg.Cmt

SpaceChar = S(" \t")
Space = SpaceChar^1
Newline = P("\n")
AnyExceptNewline = P(1) - Newline

Alpha = R("az", "AZ")
Num = R("09")
Underline = P("_")
Alpha_ = Alpha + Underline
Alnum_ = Alpha + Underline + Num
Word = Alpha_ * Alnum_^0
-- not_alnum_ = 1 - alnum_
WordBoundary = (1 - Alnum_) + P("")

