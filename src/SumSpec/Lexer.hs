{-# LANGUAGE OverloadedStrings #-}

-- | Tokens of SumSpec v1 (see the "Lexical" section of spec/grammar.ebnf).
--
-- Every token parser skips the whitespace and @--@ comments after it,
-- so the parser only has to skip what comes before the first token.
module SumSpec.Lexer
  ( Parser
  , spaceConsumer
  , symbol
  , upperName
  , lowerName
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

-- | A type or variant name: @UPPER@.
upperName :: Parser Name
upperName = identifier isAsciiUpper <?> "type or variant name"

-- | A transition name: @LOWER@.
lowerName :: Parser Name
lowerName = identifier isAsciiLower <?> "transition name"

identifier :: (Char -> Bool) -> Parser Name
identifier isFirst = lexeme $ do
  pos <- getSourcePos
  first <- satisfy isFirst
  rest <- takeWhileP Nothing isIdentChar
  pure (Name pos (T.cons first rest))
  where
    isIdentChar c = isAsciiUpper c || isAsciiLower c || isDigit c

-- | A language version, @major.minor@, written as one token (@1.1@).
versionNumber :: Parser LanguageVersion
versionNumber =
  lexeme (LanguageVersion <$> L.decimal <* char '.' <*> L.decimal)
    <?> "version number such as 1.1"

parens, brackets, braces :: Parser a -> Parser a
parens = between (symbol "(") (symbol ")")
brackets = between (symbol "[") (symbol "]")
braces = between (symbol "{") (symbol "}")
