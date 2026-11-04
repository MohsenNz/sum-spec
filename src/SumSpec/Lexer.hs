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
  , upperName
  , lowerName
  , valueName
  , naming
  , versionNumber
  , parens
  , brackets
  , braces
  ) where

import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Void (Void)
import SumSpec.Syntax (Name (..))
import SumSpec.Version (LanguageVersion (..))
import Text.Megaparsec
import Text.Megaparsec.Char (char, space1)
import Text.Megaparsec.Char.Lexer qualified as L

type Parser = Parsec Void Text

-- | Skips whitespace and line comments.
spaceConsumer :: Parser ()
spaceConsumer = L.space space1 (L.skipLineComment "--") empty

lexeme :: Parser a -> Parser a
lexeme = L.lexeme spaceConsumer

symbol :: Text -> Parser Text
symbol = L.symbol spaceConsumer

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

parens, brackets, braces :: Parser a -> Parser a
parens = between (symbol "(") (symbol ")")
brackets = between (symbol "[") (symbol "]")
braces = between (symbol "{") (symbol "}")
