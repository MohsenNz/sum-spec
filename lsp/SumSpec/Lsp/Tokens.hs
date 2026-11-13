{-# LANGUAGE LambdaCase #-}

-- | Semantic highlighting. A lexical scan of the source finds the tokens;
-- each name then takes its kind from the index, so a variant and a type
-- with the same spelling are told apart. A name the index doesn't know
-- (in a definition that didn't parse) isn't highlighted, and the editor's
-- own syntax file colours it. The arguments of an annotation are opaque
-- text and get no tokens but comments, so the editor colours them too.
module SumSpec.Lsp.Tokens
  ( semanticTokens
  , encodeSemanticTokens
  , legend
  ) where

import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List (isPrefixOf)
import Data.Map.Strict qualified as M
import Data.Text (Text)
import Data.Text qualified as T
import Language.LSP.Protocol.Types
  ( Position (..)
  , SemanticTokenAbsolute (..)
  , SemanticTokenModifiers (..)
  , SemanticTokenTypes (..)
  , SemanticTokens
  , SemanticTokensLegend
  , UInt
  , defaultSemanticTokensLegend
  , makeSemanticTokens
  )
import SumSpec.Lsp.Index (Kind (..), Occurrence (..))
import SumSpec.Lsp.Position (sourcePosition)
import SumSpec.Parser (scanArguments)
import SumSpec.Syntax (Name (..))

-- | The token types and modifiers the server sends: LSP's standard ones.
legend :: SemanticTokensLegend
legend = defaultSemanticTokensLegend

-- | Encodes the tokens relative to each other, as LSP sends them.
encodeSemanticTokens :: [SemanticTokenAbsolute] -> Either Text SemanticTokens
encodeSemanticTokens = makeSemanticTokens legend

-- | Every token of the source, in order. The occurrences are those of the
-- spec parsed from this source.
semanticTokens :: Text -> [Occurrence] -> [SemanticTokenAbsolute]
semanticTokens source occs =
  filter (not . opaque) (concat (zipWith (scanLine names) [0 ..] (T.lines source)))
  where
    spans = argumentSpans source
    opaque SemanticTokenAbsolute {_line = line, _startChar = col, _tokenType = kind} =
      kind /= SemanticTokenTypes_Comment
        && any (\(from, to) -> from <= (line, col) && (line, col) < to) spans
    names =
      M.fromList
        [ ((line, character), o)
        | o <- occs
        , let Position line character = sourcePosition source (namePos (occName o))
        ]

-- | Where the arguments of each annotation are, from the character after
-- its name to the end of its arguments, as (line, column) with columns
-- in UTF-16 code units. The arguments may span lines, so this reads the
-- whole source; they end where the parser's 'scanArguments' ends them.
-- Arguments that don't scan (an unclosed bracket or string) have none.
argumentSpans :: Text -> [((UInt, UInt), (UInt, UInt))]
argumentSpans = go (0, 0) . T.unpack
  where
    go _ [] = []
    go pos s@(c : cs)
      | "--" `isPrefixOf` s =
          let (comment, rest) = break (== '\n') s
          in  go (advance pos comment) rest
      | c == '"' =
          let
            (body, rest) = break (\x -> x == '"' || x == '\n') cs
            str = c : body <> takeWhile (== '"') (take 1 rest)
          in
            go (advance pos str) (drop (length str) s)
      | c == '@'
      , w : _ <- cs
      , isAsciiLower w =
          let
            (word, rest) = span isWordChar cs
            start = advance pos (c : word)
          in
            case scanArguments rest of
              Right (n, _)
                | n > 0 ->
                    let
                      (args, rest') = splitAt n rest
                      end = advance start args
                    in
                      (start, end) : go end rest'
              _ -> go start rest
      | otherwise = go (advance pos [c]) cs
    advance = foldl' step
    step (line, col) ch
      | ch == '\n' = (line + 1, 0)
      | otherwise = (line, col + width [ch])

-- | The tokens of one line. Columns count UTF-16 code units, like LSP.
scanLine :: M.Map (UInt, UInt) Occurrence -> UInt -> Text -> [SemanticTokenAbsolute]
scanLine names line = go 0 . T.unpack
  where
    go _ [] = []
    go col s@(c : cs)
      | "--" `isPrefixOf` s = [token col s SemanticTokenTypes_Comment []]
      | c == '"' =
          let
            (body, rest) = break (== '"') cs
            str = c : body <> take 1 rest
          in
            emit col str (drop 1 rest) SemanticTokenTypes_String []
      | isDigit c =
          let
            (int, rest) = span isDigit s
            (frac, rest') = case rest of
              '.' : d : ds | isDigit d -> let (f, r) = span isDigit (d : ds) in ('.' : f, r)
              _ -> ("", rest)
          in
            emit col (int <> frac) rest' SemanticTokenTypes_Number []
      | "__" `isPrefixOf` s =
          let (word, rest) = span isWordChar (drop 2 s)
          in  emit col ("__" <> word) rest SemanticTokenTypes_Keyword []
      | c == '@' =
          let
            (word, rest) = span isWordChar cs
            modifiers = maybe [] (declaration . occDefinition) (M.lookup (line, col) names)
          in
            emit col (c : word) rest SemanticTokenTypes_Decorator modifiers
      | c == '#'
      , w : _ <- cs
      , isAsciiLower w =
          let (word, rest) = span isWordChar cs
          in  word' col (c : word) (col + 1) rest
      | isAsciiUpper c || isAsciiLower c =
          let (word, rest) = span isWordChar s
          in  word' col word col rest
      | Just op <- operator s =
          emit col op (drop (length op) s) SemanticTokenTypes_Operator []
      | otherwise = go (col + width [c]) cs
    -- A name, classified by the occurrence at the given column; the
    -- token itself may start earlier, at the # of a naming.
    word' col word at rest = case classify (M.lookup (line, at) names) word of
      Just (kind, modifiers) -> emit col word rest kind modifiers
      Nothing -> go (col + width word) rest
    emit col text rest kind modifiers =
      token col text kind modifiers : go (col + width text) rest
    token col text kind modifiers =
      SemanticTokenAbsolute
        { _line = line
        , _startChar = col
        , _length = width text
        , _tokenType = kind
        , _tokenModifiers = modifiers
        }

classify
  :: Maybe Occurrence -> String -> Maybe (SemanticTokenTypes, [SemanticTokenModifiers])
classify occ word = case occ of
  Just o -> Just (kindType (occKind o), extra (occKind o) <> declaration (occDefinition o))
  Nothing
    | word `elem` ["by", "not", "and", "or", "in", "each"] ->
        Just (SemanticTokenTypes_Keyword, [])
    | otherwise -> Nothing
  where
    kindType = \case
      KType -> SemanticTokenTypes_Type
      KVariant -> SemanticTokenTypes_EnumMember
      KEvent -> SemanticTokenTypes_Event
      KAnnotation -> SemanticTokenTypes_Decorator
      KConst -> SemanticTokenTypes_Variable
      KValue -> SemanticTokenTypes_Variable
    extra = \case
      KConst -> [SemanticTokenModifiers_Readonly]
      _ -> []

declaration :: Bool -> [SemanticTokenModifiers]
declaration isDefinition = [SemanticTokenModifiers_Declaration | isDefinition]

-- | The operators, longest first. A prime marks a new value.
operator :: String -> Maybe String
operator s =
  case filter (`isPrefixOf` s) ops of
    op : _ -> Just op
    [] -> Nothing
  where
    ops =
      [ "::"
      , "->"
      , "=>"
      , "//"
      , "=="
      , "!="
      , "<="
      , ">="
      , "|"
      , "*"
      , "+"
      , "-"
      , "="
      , "<"
      , ">"
      , "/"
      , "'"
      ]

isWordChar :: Char -> Bool
isWordChar c = isAsciiUpper c || isAsciiLower c || isDigit c

-- | LSP counts UTF-16 code units.
width :: String -> UInt
width = fromIntegral . sum . map (\c -> if fromEnum c > 0xFFFF then 2 else 1 :: Int)
