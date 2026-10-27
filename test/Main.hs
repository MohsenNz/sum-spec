-- | Golden tests over a corpus of spec files.
--
-- For each file under test/parse/ (and spec/example), the golden file
-- next to it holds the expected output: the spec printed back in
-- canonical form, or the parse error. Run with
-- @cabal test --test-options=--accept@ to regenerate, then review the
-- diff before committing.
module Main (main) where

import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Data.Text.IO qualified as T
import SumSpec (parseSpec, renderParseError, renderSpec)
import System.FilePath (replaceExtension, takeBaseName)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.Golden (findByExtension, goldenVsString)

main :: IO ()
main = do
  corpus <- findByExtension [".sumspec"] "test/parse"
  let cases =
        ("spec/example", "test/parse/spec-example.golden")
          : [(file, replaceExtension file ".golden") | file <- corpus]
  defaultMain $
    testGroup
      "sumspec"
      [ testGroup "parse" [golden parseOnce c | c <- cases]
      , testGroup "round trip" [golden parseTwice c | c <- cases]
      ]

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
