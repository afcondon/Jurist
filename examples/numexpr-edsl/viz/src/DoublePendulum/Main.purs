module DoublePendulum.Main where

import Prelude

import DoublePendulum.Component as DP
import Effect (Effect)
import Halogen.Aff as HA
import Halogen.VDom.Driver (runUI)

main :: Effect Unit
main = HA.runHalogenAff do
  body <- HA.awaitBody
  void $ runUI DP.component unit body
