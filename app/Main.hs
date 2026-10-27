module Main (main) where

import Data.Text.IO qualified as T
import SumSpec (parseSpec, renderParseError, renderSpec)
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
    _ -> do
      hPutStrLn stderr "usage: sumspec parse FILE"
      exitFailure
