{-# LANGUAGE OverloadedStrings #-}

-- | Tokens of SumSpec v1 (see the "Lexical" section of spec/grammar.ebnf).
--
-- Every token parser skips the whitespace and @--@ comments after it,
-- so the parser only has to skip what comes before the first token.
module SumSpec.Lexer
  ( Parser
  , spaceConsumer
  , symbol
  , keyword
  , equals
  , slash
  , upperName
  , lowerName
  , valueName
  , naming
  , annotationDecl
  , annotation
  , numberLiteral
  , stringLiteral
  , compareOp
  , additiveOp
  , timesOp
  , versionNumber
  , parens
  , brackets
  , braces
  ) where

import Data.Char (isAsciiLower, isAsciiUpper, isDigit, isSpace)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Void (Void)
import SumSpec.Syntax
  ( Annotation (..)
  , ArithOp (..)
  , CompareOp (..)
  , Literal (..)
  , Name (..)
  )
import SumSpec.Version (LanguageVersion (..))
import Text.Megaparsec
import Text.Megaparsec.Char (char, digitChar, space1)
import Text.Megaparsec.Char.Lexer qualified as L

type Parser = Parsec Void Text

-- | Skips whitespace and line comments.
spaceConsumer :: Parser ()
spaceConsumer = L.space space1 (L.skipLineComment "--") empty

lexeme :: Parser a -> Parser a
lexeme = L.lexeme spaceConsumer

symbol :: Text -> Parser Text
symbol = L.symbol spaceConsumer

-- | @/@ between shared paths, never the start of @//@, which starts a
-- guard.
slash :: Parser ()
slash = lexeme (try (char '/' *> notFollowedBy (char '/'))) <?> "'/'"

-- | A word of the language, such as @by@ in @[T by K]@. It isn't reserved:
-- it's read as a word only where the grammar expects it, and not when a
-- letter or digit follows (@byX@).
keyword :: Text -> Parser ()
keyword word = lexeme (try (chunk word *> notFollowedBy (satisfy isIdentChar)))

-- | The @=@ of a type definition. Tokens are matched longest first, and
-- @=>@ is another token, so @=@ isn't followed by @>@.
equals :: Parser ()
equals = lexeme (try (char '=' *> notFollowedBy (char '>'))) <?> "'='"

-- | A type or variant name: @UPPER@.
upperName :: Parser Name
upperName = identifier isAsciiUpper <?> "type or variant name"

-- | An event name: @LOWER@.
lowerName :: Parser Name
lowerName = identifier isAsciiLower <?> "event name"

-- | A name for a value in a pattern: @LOWER@.
valueName :: Parser Name
valueName = identifier isAsciiLower <?> "value name"

-- | @#x@, naming the value of the pattern before it. One token: no space
-- between the @#@ and the name.
naming :: Parser Name
naming = lexeme (char '#' *> (rawIdentifier isAsciiLower <?> "name right after #"))

-- | @\@name@, as declared in @__annotations@: one token, no space between
-- the @\@@ and the name. The name is kept without the @\@@, at the
-- position of the @\@@.
annotationDecl :: Parser Name
annotationDecl = lexeme rawAnnotationName

rawAnnotationName :: Parser Name
rawAnnotationName = do
  pos <- getSourcePos
  _ <- char '@'
  Name _ text <- rawIdentifier isAsciiLower <?> "annotation name right after @"
  pure (Name pos text)

-- | @\@name args@: an annotation and its arguments, which are opaque text
-- (see 'scanArguments'). This is the one place where a line break matters.
annotation :: Parser Annotation
annotation = do
  name <- rawAnnotationName
  start <- getOffset
  rest <- getInput
  case scanArguments (T.unpack rest) of
    Left (at, message) -> do
      setOffset (start + at)
      fail (message <> " in the arguments of @" <> T.unpack (nameText name))
    Right (used, args) -> do
      _ <- takeP Nothing used
      spaceConsumer
      pure (Annotation name (T.pack args))

-- | Reads the arguments of an annotation: the characters up to the end of
-- the line, a @--@ comment, or one of @\@ = | * ::@ or a closing bracket,
-- outside brackets. Brackets nest and may span lines, and a string is one
-- unit. Gives how many characters it read and the arguments, with comments
-- dropped and each run of whitespace made one space; or the offset and
-- message of an error.
scanArguments :: String -> Either (Int, String) (Int, String)
scanArguments = go 0 [] [] False
  where
    -- n: characters read; stack: the open brackets, innermost first, as
    -- (closer, opener, offset); out: the arguments so far, reversed;
    -- space: whitespace was read since the last character kept.
    go
      :: Int
      -> [(Char, Char, Int)]
      -> String
      -> Bool
      -> String
      -> Either (Int, String) (Int, String)
    go n stack out space input = case input of
      []
        | (_, opener, at) : _ <- stack -> Left (at, "unclosed " <> [opener])
        | otherwise -> done
      '-' : '-' : rest
        | null stack -> done
        | otherwise ->
            let (comment, rest') = break (== '\n') rest
            in  go (n + 2 + length comment) stack out True rest'
      c : rest
        | c == '\n', null stack -> done
        | isSpace c -> go (n + 1) stack out True rest
      ':' : ':' : _ | null stack -> done
      c : _ | null stack, c `elem` ("@|*=)]}" :: String) -> done
      '"' : rest ->
        let (text, rest') = break (\x -> x == '"' || x == '\n') rest
        in  case rest' of
              '"' : rest'' ->
                go (n + 2 + length text) stack (keep ('"' : text <> "\"")) False rest''
              _ -> Left (n, "unclosed string")
      c : rest
        | Just closer <- lookup c [('(', ')'), ('[', ']'), ('{', '}')] ->
            go (n + 1) ((closer, c, n) : stack) (keep [c]) False rest
      c : rest
        | c `elem` (")]}" :: String) -> case stack of
            (closer, _, _) : outer
              | c == closer -> go (n + 1) outer (keep [c]) False rest
            (closer, opener, _) : _ ->
              Left (n, "expected " <> [closer] <> " to close " <> [opener])
            [] -> done
      c : rest -> go (n + 1) stack (keep [c]) False rest
      where
        done = Right (n, reverse out)
        keep chars = reverse chars <> (if space && not (null out) then ' ' : out else out)

identifier :: (Char -> Bool) -> Parser Name
identifier = lexeme . rawIdentifier

rawIdentifier :: (Char -> Bool) -> Parser Name
rawIdentifier isFirst = do
  pos <- getSourcePos
  first <- satisfy isFirst
  rest <- takeWhileP Nothing isIdentChar
  pure (Name pos (T.cons first rest))

isIdentChar :: Char -> Bool
isIdentChar c = isAsciiUpper c || isAsciiLower c || isDigit c

-- | A language version, @major.minor@, written as one token (@1.0@).
versionNumber :: Parser LanguageVersion
versionNumber =
  lexeme (LanguageVersion <$> L.decimal <* char '.' <*> L.decimal)
    <?> "version number such as 1.0"

-- | An integer (@15@, @-1@) or a decimal (@1.5@): the @-@ touches the digits,
-- and a decimal has digits after the dot.
numberLiteral :: Parser (SourcePos, Literal)
numberLiteral = lexeme $ do
  pos <- getSourcePos
  sign <- maybe "" T.singleton <$> optional (try (char '-' <* lookAhead digitChar))
  whole <- takeWhile1P (Just "digit") isDigit
  fraction <- optional (try (char '.' *> takeWhile1P (Just "digit") isDigit))
  pure . (,) pos $ case fraction of
    Nothing -> LitInt (read (T.unpack (sign <> whole)))
    Just digits -> LitDecimal (sign <> whole <> "." <> digits)

-- | @"text"@: no escapes, so no quote or line break inside.
stringLiteral :: Parser (SourcePos, Literal)
stringLiteral = lexeme $ do
  pos <- getSourcePos
  _ <- char '"'
  text <- takeWhileP Nothing (\c -> c /= '"' && c /= '\n')
  _ <- char '"' <?> "closing quote"
  pure (pos, LitText text)

-- | @==@, @!=@, @<=@, @>=@, @<@ or @>@, longest first.
compareOp :: Parser CompareOp
compareOp =
  lexeme
    ( choice
        [ OpLe <$ chunk "<="
        , OpGe <$ chunk ">="
        , OpEq <$ chunk "=="
        , OpNe <$ chunk "!="
        , OpLt <$ char '<'
        , OpGt <$ char '>'
        ]
    )
    <?> "comparison operator"

-- | @+@ or @-@ between two values, with its position. A @-@ is never the
-- start of @->@ (or of @--@, which the space before it already skipped).
additiveOp :: Parser (SourcePos, ArithOp)
additiveOp =
  lexeme
    ( (,)
        <$> getSourcePos
        <*> choice
          [ OpAdd <$ char '+'
          , OpSub <$ try (char '-' <* notFollowedBy (char '>' <|> char '-'))
          ]
    )
    <?> "\"+\" or \"-\""

-- | @*@ between two values, inside parentheses, with its position.
timesOp :: Parser (SourcePos, ArithOp)
timesOp = lexeme ((,) <$> getSourcePos <*> (OpMul <$ char '*')) <?> "\"*\""

parens, brackets, braces :: Parser a -> Parser a
parens = between (symbol "(") (symbol ")")
brackets = between (symbol "[") (symbol "]")
braces = between (symbol "{") (symbol "}")
