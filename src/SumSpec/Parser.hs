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
  (atomics, events) <- headers
  Spec version atomics events <$> many definition

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

-- headers = atomics_block , events_block | events_block , atomics_block ;
headers :: Parser ([Atomic], [Name])
headers = atomicsFirst <|> eventsFirst
  where
    atomicsFirst = (,) <$> atomicsBlock <*> eventsBlock
    eventsFirst = flip (,) <$> eventsBlock <*> atomicsBlock

-- atomics_block = "__atomics" , "{" , { atomic } , "}" ;
atomicsBlock :: Parser [Atomic]
atomicsBlock = symbol "__atomics" *> braces (many atomic)

-- atomic = UPPER , [ "=" , primitive ] ;
atomic :: Parser Atomic
atomic = Atomic <$> upperName <*> optional (equals *> primitive)

-- primitive = "__int" | "__float" | "__text" ;
primitive :: Parser Primitive
primitive =
  choice [p <$ keyword (primitiveWord p) | p <- [minBound .. maxBound]]
    <?> "a primitive type (__int, __float or __text)"

eventsBlock :: Parser [Name]
eventsBlock = symbol "__events" *> braces (many lowerName)

-- definition = init_state | type_def | event_def ;
definition :: Parser Definition
definition =
  choice
    [ uncurry DefInit <$> initState
    , DefEvent <$> eventDef
    , DefType <$> typeDef
    ]

-- init_state = "__init" , "::" , pattern ;
initState :: Parser (Name, Pattern)
initState = do
  pos <- getSourcePos
  keyword "__init"
  _ <- symbol "::"
  (,) (Name pos "__init") <$> pattern

typeDef :: Parser TypeDef
typeDef = TypeDef <$> upperName <* equals <*> typeExpr

-- type_expr = sum | product | type_term ;
--
-- The three forms share their first token, so the parser reads the first
-- term and then decides from what follows it.
typeExpr :: Parser TypeExpr
typeExpr = do
  first <- typeTerm
  case first of
    TermName name -> afterName name
    TermList _ _ -> productOrTerm first
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
    , TypeTerm . uncurry TermList <$> listTerm
    , TypeTerm . TermName <$> try (upperName <* notFollowedBy equals)
    ]

-- type_term = UPPER | "[" , type_term , [ "by" , UPPER ] , "]" ;
typeTerm :: Parser TypeTerm
typeTerm = TermName <$> upperName <|> uncurry TermList <$> listTerm

-- The bracketed alternative of type_term: the element type, and the key
-- type of a keyed list.
listTerm :: Parser (TypeTerm, Maybe Name)
listTerm = brackets ((,) <$> typeTerm <*> optional (keyword "by" *> upperName))

-- event_def = LOWER , [ input ] , transition , { transition } ;
eventDef :: Parser Event
eventDef =
  Event
    <$> lowerName
    <*> optional (input <?> "input type")
    <*> ((:|) <$> transition <*> many transition)

-- transition = "::" , ( shared , "=>" , { shared , "=>" } , arguments ,
--                       "->" , arguments
--                     | pattern , "->" , pattern ) ;
--
-- A shared path starts like a pattern; the "=>" after it tells them
-- apart.
transition :: Parser Transition
transition = do
  _ <- symbol "::"
  paths <- many (try (shared <* symbol "=>"))
  let side = if null paths then (:| []) <$> pattern else arguments
  Transition paths <$> side <*> (symbol "->" *> side)

-- shared = path , [ element_key ] ;
shared :: Parser Shared
shared = Shared <$> path <*> optional elementKey

-- arguments = pattern , { "*" , pattern } ;
arguments :: Parser (NonEmpty Pattern)
arguments = (:|) <$> pattern <*> many (symbol "*" *> pattern)

-- input = type_pattern , [ NAMING ] ;
input :: Parser Pattern
input = withNaming =<< typePattern

-- pattern = ( type_pattern | LOWER ) , { "'" } , [ NAMING ] ;
pattern :: Parser Pattern
pattern = do
  base <- typePattern <|> PatternName <$> valueName
  primes <- many (getSourcePos <* symbol "'")
  withNaming (foldl (flip PatternPrimed) base primes)

-- type_pattern = path , [ element_key ] ,
--                [ "(" , pattern , { "*" , pattern } , ")" ]
--              | "[" , type_term , "]" ;
typePattern :: Parser Pattern
typePattern =
  choice
    [ uncurry PatternList <$> listTerm
    , do
        names <- path
        key <- optional elementKey
        args <- option [] (parens (sepBy1 pattern (symbol "*")))
        pure (maybe (PatternPath names args) (\k -> PatternElement names k args) key)
    ]

-- element_key = "[" , LOWER , "]" ;
elementKey :: Parser Name
elementKey = brackets valueName

-- [ NAMING ] after a pattern.
withNaming :: Pattern -> Parser Pattern
withNaming p = maybe p (PatternNamed p) <$> optional naming

-- path = UPPER , { "." , UPPER } ;
path :: Parser (NonEmpty Name)
path = (:|) <$> upperName <*> many (symbol "." *> upperName)
