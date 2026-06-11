-- | The demo structure — a pure typed description, shared verbatim by every
-- | denotation: the Julia workspace migrates it functorially; the portable
-- | workspace holds the same value and answers `Deferred`.
module Data.Migration.Models
  ( modules
  , funcs
  , codeGraph
  ) where

import Data.Migration (CodeGraph, Edge, Func)

modules :: Array String
modules = [ "Auth", "Db", "Api", "Util" ]

fn :: String -> Int -> Func
fn name inMod = { name, inMod }

funcs :: Array Func
funcs =
  [ fn "login" 0, fn "hashPwd" 0
  , fn "query" 1, fn "connect" 1
  , fn "handleReq" 2, fn "route" 2
  , fn "log" 3, fn "validate" 3
  ]

edge :: Int -> Int -> Edge
edge from to = { from, to }

codeGraph :: CodeGraph
codeGraph =
  { modules
  , funcs
  , calls:
      [ edge 0 2, edge 0 3                       -- Auth → Db   (×2)
      , edge 0 6, edge 1 6                       -- Auth → Util (×2)
      , edge 2 6                                 -- Db → Util   (×1)
      , edge 4 0, edge 5 1                       -- Api → Auth  (×2)
      , edge 5 2, edge 4 2, edge 4 3             -- Api → Db    (×3)
      , edge 4 6                                 -- Api → Util  (×1)
      , edge 0 1, edge 2 3                       -- intra-module: Auth, Db
      ]
  }
