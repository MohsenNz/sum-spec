-- | Language versions (see VERSIONING.md): @major.minor@, where a new major
-- version breaks existing specs and a new minor version only adds to the
-- language.
module SumSpec.Version
  ( LanguageVersion (..)
  , defaultVersion
  , latestVersion
  , inputsVersion
  , namesVersion
  , elementPathsVersion
  , keyedListsVersion
  , namedListsVersion
  , isSupported
  , renderVersion
  ) where

data LanguageVersion = LanguageVersion
  { versionMajor :: Int
  , versionMinor :: Int
  }
  deriving stock (Eq, Ord, Show)

-- | The version of a spec without a @__version@ header.
defaultVersion :: LanguageVersion
defaultVersion = LanguageVersion 1 0

-- | The newest language version this sumspec implements. Raise it when a
-- new language version is implemented (see VERSIONING.md, "Releasing").
latestVersion :: LanguageVersion
latestVersion = LanguageVersion 1 2

-- | The first version with transition inputs (@f X :: A -> B@).
inputsVersion :: LanguageVersion
inputsVersion = LanguageVersion 1 1

-- | The first version with named values (@P#x@ and @x@ in patterns).
namesVersion :: LanguageVersion
namesVersion = LanguageVersion 1 1

-- | The first version with element paths (@Todos[id]@ in patterns).
elementPathsVersion :: LanguageVersion
elementPathsVersion = LanguageVersion 1 2

-- | The first version with keyed lists (@[T by K]@).
keyedListsVersion :: LanguageVersion
keyedListsVersion = LanguageVersion 1 2

-- | The first version where a list goes only as the whole body of a type
-- definition (@Points = [Point]@), and nowhere else.
namedListsVersion :: LanguageVersion
namedListsVersion = LanguageVersion 1 2

-- | A spec can be read if it has the same major version as
-- 'latestVersion' and a minor version no newer than it.
isSupported :: LanguageVersion -> Bool
isSupported v = versionMajor v == versionMajor latestVersion && v <= latestVersion

renderVersion :: LanguageVersion -> String
renderVersion (LanguageVersion major minor) = show major <> "." <> show minor
