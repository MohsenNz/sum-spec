{-# LANGUAGE OverloadedStrings #-}

-- | Parser for SumSpec v1. Each parser follows the rule of the same name
-- in spec/grammar.ebnf.
module SumSpec.Parser
  ( parseSpec
  , ParseError
  , renderParseError
  ) where

import Control.Monad (unless)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Void (Void)
import SumSpec.Lexer
import SumSpec.Syntax
import SumSpec.Version
import Text.Megaparsec hiding (ParseError)

type ParseError = ParseErrorBundle Text Void

-- | Parses a whole spec. The file path is used only in error messages.
parseSpec :: FilePath -> Text -> Either ParseError Spec
parseSpec = parse (spaceConsumer *> spec <* eof)

-- | Renders an error with its line, column and the offending source line.
renderParseError :: ParseError -> String
renderParseError = errorBundlePretty

-- spec = [ version_header ] , headers , { definition } ;
spec :: Parser Spec
spec = do
  version <- optional versionHeader
  (atomics, txs) <- headers
  Spec version atomics txs <$> many definition

-- version_header = "__version" , VERSION ;
--
-- A version this sumspec doesn't implement stops parsing here, so the
-- error names the version instead of some later syntax it can't read.
versionHeader :: Parser LanguageVersion
versionHeader = do
  _ <- symbol "__version"
  offset <- getOffset
  version <- versionNumber
  unless (isSupported version) $ do
    setOffset offset
    fail $
      "this spec is for SumSpec "
        <> renderVersion version
        <> ", but this sumspec supports "
        <> supported
  pure version
  where
    supported
      | defaultVersion == latestVersion = renderVersion latestVersion
      | otherwise = renderVersion defaultVersion <> " to " <> renderVersion latestVersion

-- headers = atomics_block , txs_block | txs_block , atomics_block ;
headers :: Parser ([Name], [Name])
headers = atomicsFirst <|> txsFirst
  where
    atomicsFirst = (,) <$> atomicsBlock <*> txsBlock
    txsFirst = flip (,) <$> txsBlock <*> atomicsBlock

atomicsBlock :: Parser [Name]
atomicsBlock = symbol "__atomics" *> braces (many upperName)

txsBlock :: Parser [Name]
txsBlock = symbol "__txs" *> braces (many lowerName)

definition :: Parser Definition
definition = DefTransition <$> transition <|> DefType <$> typeDef

typeDef :: Parser TypeDef
typeDef = TypeDef <$> upperName <* symbol "=" <*> typeExpr

-- type_expr = sum | product | type_term ;
--
-- The three forms share their first token, so the parser reads the first
-- term and then decides from what follows it.
typeExpr :: Parser TypeExpr
typeExpr = do
  first <- typeTerm
  case first of
    TermName name -> afterName name
    TermList _ -> productOrTerm first
  where
    afterName name =
      choice
        [ TypeSum . (Variant name Nothing :) <$> moreVariants
        , productAfter (TermName name)
        , sumWithPayload name
        , pure (TypeTerm (TermName name))
        ]
    sumWithPayload name = do
      p <- payload
      TypeSum . (Variant name (Just p) :) <$> moreVariants
    productOrTerm term = productAfter term <|> pure (TypeTerm term)
    productAfter term = TypeProduct . (term :) <$> some (symbol "*" *> typeTerm)
    moreVariants =
      some (symbol "|" *> variant)
        <?> "\"|\" (a sum needs at least two variants)"

variant :: Parser Variant
variant = Variant <$> upperName <*> optional payload

-- payload = type_term | "(" , type_expr , ")" ;
--
-- A bare UPPER followed by "=" starts the next type definition, so it is
-- never taken as a payload.
payload :: Parser TypeExpr
payload =
  choice
    [ parens typeExpr
    , TypeTerm . TermList <$> brackets typeTerm
    , TypeTerm . TermName <$> try (upperName <* notFollowedBy (symbol "="))
    ]

-- type_term = UPPER | "[" , type_term , "]" ;
typeTerm :: Parser TypeTerm
typeTerm = TermName <$> upperName <|> TermList <$> brackets typeTerm

transition :: Parser Transition
transition =
  Transition <$> lowerName <* symbol "::" <*> pattern <* symbol "->" <*> pattern

-- pattern = path , [ "(" , pattern , { "*" , pattern } , ")" ]
--         | "[" , type_term , "]" ;
pattern :: Parser Pattern
pattern =
  choice
    [ PatternList <$> brackets typeTerm
    , PatternPath <$> path <*> option [] (parens (sepBy1 pattern (symbol "*")))
    ]

-- path = UPPER , { "." , UPPER } ;
path :: Parser (NonEmpty Name)
path = (:|) <$> upperName <*> many (symbol "." *> upperName)
