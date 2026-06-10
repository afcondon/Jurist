-- | The honest stub. A production verb (symbolic differentiation, proven
-- | roots, …) evaluated on a runtime where its production interpreter doesn't
-- | exist must not fake data — an empty array from a stubbed `provenRoots` is
-- | indistinguishable from "proven: no roots", the exact lie the verb exists
-- | to prevent. Instead the verb returns a typed IOU: `Deferred` carries a
-- | human-readable description of what the production interpreter will
-- | compute, and the type forces every host to handle the pending case. The
-- | reference denotation answers `Deferred`; the Julia denotation answers
-- | `Computed` (ADR-0007).
module Data.Answer
  ( Answer(..)
  , describe
  ) where

import Prelude

data Answer a = Computed a | Deferred String

instance functorAnswer :: Functor Answer where
  map f = case _ of
    Computed a -> Computed (f a)
    Deferred s -> Deferred s

-- | Render an answer for display: the computed value via the supplied
-- | formatter, or the deferred description, labelled as such.
describe :: forall a. (a -> String) -> Answer a -> String
describe f = case _ of
  Computed a -> f a
  Deferred s -> "deferred — " <> s
