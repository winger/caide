module Caide.Registry (
      languages
    , findLanguage
    , builders
    , findBuilder
    , findFeature
) where

import Control.Applicative ((<$>))
import Data.Char (toLower)
import Data.List (find)

import Caide.Types
import qualified Caide.CPP.CPPSimple as CPPSimple
import qualified Caide.CPP.CPP as CPP
import qualified Caide.Builders.None as None
import qualified Caide.Builders.Custom as Custom

import qualified Caide.Features.Codelite as Codelite
import qualified Caide.Features.VisualStudio as VS


languages :: [([String], ProgrammingLanguage)]
languages = [(["simplecpp", "simplec++"], CPPSimple.language),
             (["cpp", "c++"], CPP.language)]

findLanguage :: String -> Maybe ProgrammingLanguage
findLanguage name = snd <$> find (\(names, _) -> map toLower name `elem` names) languages

builders :: [(String, Builder)]
builders = [("none", None.builder)]

findBuilder :: String -> Builder
findBuilder name = case find ((== map toLower name) . fst) builders of
    Just (_, builder) -> builder
    Nothing           -> Custom.builder name

features :: [(String, Feature)]
features = [("codelite", Codelite.feature),
            ("vs", VS.feature)]

findFeature :: String -> Maybe Feature
findFeature name = snd <$> find ((== map toLower name). fst) features
