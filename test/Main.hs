-- | Golden tests over two corpora of spec files.
--
-- test/parse/: the golden file next to each case holds the spec printed
-- back in canonical form, or the parse error.
-- test/check/: the golden file holds "OK", or the type errors.
-- The example specs (spec/example*) are cases in both, with their golden
-- files in those directories.
--
-- Run with @cabal test --test-options=--accept@ to regenerate, then
-- review the diff before committing.
module Main (main) where

import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Data.Text.IO qualified as T
import SumSpec
  ( checkSpec
  , parseSpec
  , renderCheckErrors
  , renderParseError
  , renderSpec
  )
import System.FilePath (replaceExtension, takeBaseName, takeFileName, (</>))
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.Golden (findByExtension, goldenVsString)

main :: IO ()
main = do
  parseCases <- corpus "test/parse"
  checkCases <- corpus "test/check"
  defaultMain $
    testGroup
      "sumspec"
      [ testGroup "parse" [golden parseOnce c | c <- parseCases]
      , testGroup "round trip" [golden parseTwice c | c <- parseCases]
      , testGroup "check" [golden check c | c <- checkCases]
      ]

-- | Each case is a spec file and its golden file. The example specs are
-- cases in every corpus, with golden files named @spec-<example>.golden@.
corpus :: FilePath -> IO [(FilePath, FilePath)]
corpus dir = do
  files <- findByExtension [".sumspec"] dir
  pure $
    [(file, dir </> "spec-" <> takeFileName file <> ".golden") | file <- examples]
      <> [(file, replaceExtension file ".golden") | file <- files]

examples :: [FilePath]
examples = ["spec/example", "spec/example-todomvc", "spec/example-git"]

golden :: (FilePath -> Text -> Text) -> (FilePath, FilePath) -> TestTree
golden run (file, goldenFile) =
  goldenVsString (takeBaseName file) goldenFile $
    LBS.fromStrict . T.encodeUtf8 . run file <$> T.readFile file

-- | The canonical form of the spec, or the parse error.
parseOnce :: FilePath -> Text -> Text
parseOnce file source =
  either (T.pack . renderParseError) renderSpec (parseSpec file source)

-- | Parses the canonical form again. It must print the same, so this
-- test shares the golden file of 'parseOnce'.
parseTwice :: FilePath -> Text -> Text
parseTwice file source = case parseSpec file source of
  Left err -> T.pack (renderParseError err)
  Right spec -> parseOnce file (renderSpec spec)

-- | "OK", or the type errors (or the parse error, if it doesn't parse).
check :: FilePath -> Text -> Text
check file source = case parseSpec file source of
  Left err -> T.pack (renderParseError err)
  Right spec -> case checkSpec file spec of
    [] -> T.pack "OK\n"
    errors -> T.pack (renderCheckErrors source errors)
