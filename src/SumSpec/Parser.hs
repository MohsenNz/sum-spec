{-# LANGUAGE OverloadedStrings #-}

-- | Parser for SumSpec v1. Each parser follows the rule of the same name
-- in spec/grammar.ebnf.
module SumSpec.Parser
  ( parseSpec
  , ParseError
  , renderParseError
  ) where

import Control.Monad (unless, void)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (fromMaybe)
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
    , DefConst <$> constDef
    , DefType <$> typeDef
    ]

-- init_state = "__init" , "::" , pattern ;
initState :: Parser (Name, Pattern)
initState = do
  pos <- getSourcePos
  keyword "__init"
  _ <- symbol "::"
  (,) (Name pos "__init") <$> pattern

-- const_def = UPPER , "=" , UPPER , ( "(" , literal , ")" | "." , UPPER ) ;
--
-- A constant starts like a type definition. A "." after the second name,
-- or a "(" that isn't followed by a type, tells them apart, and from
-- there the parser is committed, so an error inside a constant is
-- reported as one. A payload in parentheses starts with a type name or
-- "[", never with a literal.
constDef :: Parser ConstDef
constDef = do
  name <- try (upperName <* equals <* lookAhead constStart)
  ConstDef name <$> upperName <*> constValue
  where
    constStart =
      upperName
        *> ( void (symbol ".")
               <|> void (symbol "(" *> notFollowedBy (void upperName <|> void (symbol "[")))
           )
    constValue =
      choice
        [ uncurry ConstLiteral <$> parens (numberLiteral <|> stringLiteral)
        , ConstVariant <$> (symbol "." *> upperName)
        ]

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

-- transition = "::" , ( shared , { "/" , shared } , branch , { branch }
--                     | pattern , [ guard ] , "->" , pattern ) ;
--
-- A shared path starts like a pattern; the "/" or "=>" after it tells
-- them apart.
transition :: Parser Transition
transition = do
  _ <- symbol "::"
  paths <- option [] (try (sepBy1 shared slash <* lookAhead (symbol "=>")))
  case paths of
    [] -> Transition [] . pure <$> plain
    _ -> Transition paths <$> ((:|) <$> branch <*> many branch)
  where
    plain = Branch <$> one <*> optional guard <*> (symbol "->" *> one)
    one = (:| []) <$> pattern

-- branch = "=>" , arguments , [ guard ] , "->" , arguments ;
branch :: Parser Branch
branch =
  Branch
    <$> (symbol "=>" *> arguments)
    <*> optional guard
    <*> (symbol "->" *> arguments)

-- guard = "//" , predicate ;
guard :: Parser Guard
guard = symbol "//" *> predicate

-- predicate = conjunction , { "or" , conjunction } ;
predicate :: Parser Guard
predicate = operands GuardOr conjunction "or"

-- conjunction = negation , { "and" , negation } ;
conjunction :: Parser Guard
conjunction = operands GuardAnd negation "and"

-- negation = "not" , negation | "(" , predicate , ")" | comparison
--          | membership | type_pattern ;
negation :: Parser Guard
negation =
  choice
    [ GuardNot <$> (keyword "not" *> negation)
    , parens predicate
    , comparisonOrPattern
    ]

-- comparison = operand , CMP , operand ;
-- membership = operand , "in" , LOWER ;
-- operand = LOWER | literal | path ;
--
-- A condition starting with a name or a literal is known from its first
-- token. One starting with a path is a pattern unless an operator or "in"
-- follows the bare path, which is then a variant or a constant.
comparisonOrPattern :: Parser Guard
comparisonOrPattern =
  choice
    [ afterOperand . uncurry OperandLiteral =<< literal
    , afterOperand . OperandName =<< guardName
    , do
        p <- typePattern
        case p of
          PatternPath names [] ->
            fromMaybe (GuardPattern p) <$> optional (afterOperand (OperandVariant names))
          _ -> pure (GuardPattern p)
    ]
  where
    literal = numberLiteral <|> stringLiteral
    afterOperand left =
      choice
        [ GuardIn left <$> (keyword "in" *> guardName)
        , (`GuardCompare` left) <$> compareOp <*> operand
        ]

operand :: Parser Operand
operand =
  choice
    [ uncurry OperandLiteral <$> (numberLiteral <|> stringLiteral)
    , OperandName <$> guardName
    , OperandVariant <$> path
    ]
    <?> "a value, a literal or a variant"

-- A LOWER in a condition: the words of a guard are not value names there.
guardName :: Parser Name
guardName = notFollowedBy (choice (map keyword ["not", "and", "or", "in"])) *> valueName

-- One operand, or two or more joined by a word, as one guard.
operands :: (NonEmpty Guard -> Guard) -> Parser Guard -> Text -> Parser Guard
operands join item word = do
  first <- item
  rest <- many (keyword word *> item)
  pure $ case rest of
    [] -> first
    _ -> join (first :| rest)

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

-- type_pattern = path , "." , "{" , alternatives , "}"
--              | path , [ element_key ] ,
--                [ "(" , ( NAMING | pattern , { "*" , pattern } ) , ")" ]
--              | "[" , type_term , "]" ;
typePattern :: Parser Pattern
typePattern =
  choice
    [ uncurry PatternList <$> listTerm
    , do
        names <- path
        choice
          [ PatternAlts names <$> (symbol "." *> braces alternatives)
          , do
              key <- optional elementKey
              args <- option [] argumentList
              pure (maybe (PatternPath names args) (\k -> PatternElement names k args) key)
          ]
    ]

-- "(" , ( NAMING | pattern , { "*" , pattern } ) , ")"
argumentList :: Parser [Pattern]
argumentList = parens (bound <|> sepBy1 pattern (symbol "*"))
  where
    bound = pure . PatternBound <$> naming

-- alternatives = alternative , "|" , alternative , { "|" , alternative } ;
alternatives :: Parser (NonEmpty Pattern)
alternatives = do
  first <- alternative
  _ <- symbol "|" <?> "\"|\" (alternatives need at least two variants)"
  (first :|) <$> sepBy1 alternative (symbol "|")

-- alternative = path , [ "." , "{" , alternatives , "}"
--                      | "(" , ( NAMING | pattern , { "*" , pattern } ) , ")" ] ;
alternative :: Parser Pattern
alternative = do
  names <- path
  choice
    [ PatternAlts names <$> (symbol "." *> braces alternatives)
    , PatternPath names <$> option [] argumentList
    ]

-- element_key = "[" , LOWER , "]" ;
elementKey :: Parser Name
elementKey = brackets valueName

-- [ NAMING ] after a pattern.
withNaming :: Pattern -> Parser Pattern
withNaming p = maybe p (PatternNamed p) <$> optional naming

-- path = UPPER , { "." , UPPER } ;
path :: Parser (NonEmpty Name)
path = (:|) <$> upperName <*> many (try (symbol "." *> upperName))
