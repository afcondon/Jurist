-- | The demo nets — pure typed descriptions, shared verbatim by every
-- | denotation: the Julia workspace solves them functorially; the portable
-- | workspace holds the same values and answers `Deferred`.
module Data.Petri.Models
  ( sir
  , seir
  ) where

import Data.Petri (PetriSpec)

sir :: PetriSpec
sir =
  { species: [ "S", "I", "R" ]
  , transitions:
      [ { name: "inf", inputs: [ "S", "I" ], outputs: [ "I", "I" ], rate: 0.0003 }
      , { name: "rec", inputs: [ "I" ], outputs: [ "R" ], rate: 0.1 }
      ]
  , initial: [ 990.0, 10.0, 0.0 ]
  }

-- | SEIR adds a latent Exposed compartment between infection and infectiousness.
seir :: PetriSpec
seir =
  { species: [ "S", "E", "I", "R" ]
  , transitions:
      [ { name: "expose", inputs: [ "S", "I" ], outputs: [ "E", "I" ], rate: 0.0004 }
      , { name: "onset", inputs: [ "E" ], outputs: [ "I" ], rate: 0.2 }
      , { name: "recover", inputs: [ "I" ], outputs: [ "R" ], rate: 0.1 }
      ]
  , initial: [ 990.0, 0.0, 10.0, 0.0 ]
  }
