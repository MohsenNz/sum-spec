{-# LANGUAGE OverloadedStrings #-}

-- | Converting the source positions of the AST (megaparsec's line and
-- column, which move a tab to the next multiple of 8) to LSP positions
-- (a zero-based line and UTF-16 code units).
module SumSpec.Lsp.Position
  ( sourcePosition
  , tokenRange
  , nameRange
  , inRange
  , codePoints
  , utf16
  ) where

import Data.Char (isAlphaNum)
import Data.Text (Text)
import Data.Text qualified as T
import Language.LSP.Protocol.Types (Position (..), Range (..))
import SumSpec.Syntax (Name (..))
import Text.Megaparsec (SourcePos (..), unPos)

-- | The LSP position of a source position.
sourcePosition :: Text -> SourcePos -> Position
sourcePosition source pos = fst (split source pos)

-- | The range of the token that starts at this position: a name (with its
-- @\@@ or @#@, if any), or else one character; empty at the end of a line.
-- Used for the errors, which carry a position only.
tokenRange :: Text -> SourcePos -> Range
tokenRange source pos = Range start (advance start token)
  where
    (start, rest) = split source pos
    token = case T.uncons rest of
      Nothing -> ""
      Just (c, cs)
        | isNameChar c || c == '@' || c == '#' -> T.cons c (T.takeWhile isNameChar cs)
        | otherwise -> T.singleton c
    isNameChar c = isAlphaNum c || c == '_' || c == '\''

-- | The range of a name as written. An annotation's name sits at its @\@@,
-- which the range takes in.
nameRange :: Text -> Name -> Range
nameRange source (Name pos text) = Range start (advance start written)
  where
    (start, rest) = split source pos
    written
      | T.take 1 rest == "@" = T.cons '@' text
      | otherwise = text

-- | Whether the position is in the range, its end included, so that a
-- cursor just after a name still finds it.
inRange :: Position -> Range -> Bool
inRange p (Range start end) = start <= p && p <= end

-- | The LSP position of a source position, and the rest of its line.
split :: Text -> SourcePos -> (Position, Text)
split source pos =
  (Position (fromIntegral lineNo) (utf16 before), rest)
  where
    lineNo = unPos (sourceLine pos) - 1
    text = case drop lineNo (T.lines source) of
      l : _ -> l
      [] -> ""
    (before, rest) = T.splitAt (codePoints (unPos (sourceColumn pos)) text) text

advance :: Position -> Text -> Position
advance (Position line character) text = Position line (character + utf16 text)

-- | LSP counts UTF-16 code units.
utf16 :: (Num a) => Text -> a
utf16 =
  fromIntegral
    . sum
    . map (\c -> if fromEnum c > 0xFFFF then 2 else 1 :: Int)
    . T.unpack

-- | The number of characters before a megaparsec column, which moves a
-- tab to the next multiple of 8 (plus one).
codePoints :: Int -> Text -> Int
codePoints column = go 1 0 . T.unpack
  where
    go col n cs
      | col >= column = n
      | otherwise = case cs of
          [] -> n
          '\t' : rest -> go (((col - 1) `div` 8 + 1) * 8 + 1) (n + 1) rest
          _ : rest -> go (col + 1) (n + 1) rest
