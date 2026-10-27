module Main (main) where

import Data.Text.IO qualified as T
import SumSpec
  ( checkSpec
  , parseSpec
  , renderCheckErrors
  , renderParseError
  , renderSpec
  )
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStr, hPutStrLn, stderr)

main :: IO ()
main =
  getArgs >>= \case
    ["parse", file] -> do
      source <- T.readFile file
      case parseSpec file source of
        Left err -> hPutStr stderr (renderParseError err) >> exitFailure
        Right spec -> T.putStr (renderSpec spec)
    ["check", file] -> do
      source <- T.readFile file
      case parseSpec file source of
        Left err -> hPutStr stderr (renderParseError err) >> exitFailure
        Right spec -> case checkSpec file spec of
          [] -> pure ()
          errors -> hPutStr stderr (renderCheckErrors source errors) >> exitFailure
    _ -> do
      hPutStrLn stderr "usage: sumspec (parse | check) FILE"
      exitFailure
