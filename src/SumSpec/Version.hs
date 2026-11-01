-- | Language versions (see VERSIONING.md): @major.minor@, where a new major
-- version breaks existing specs and a new minor version only adds to the
-- language.
module SumSpec.Version
  ( LanguageVersion (..)
  , defaultVersion
  , latestVersion
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

-- | The newest language version this sumspec implements. Until the first
-- release, the language is 1.0 and changes in place (see VERSIONING.md,
-- "Before the first release"); after it, raise this when a new language
-- version is implemented ("Releasing").
latestVersion :: LanguageVersion
latestVersion = LanguageVersion 1 0

-- | A spec can be read if it has the same major version as
-- 'latestVersion' and a minor version no newer than it.
isSupported :: LanguageVersion -> Bool
isSupported v = versionMajor v == versionMajor latestVersion && v <= latestVersion

renderVersion :: LanguageVersion -> String
renderVersion (LanguageVersion major minor) = show major <> "." <> show minor
