{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Parser for SumSpec v1. Each parser follows the rule of the same name
-- in spec/grammar.ebnf.
module SumSpec.Parser
  ( parseSpec
  , parseSpecPartial
  , ParseError
  , renderParseError
  , scanArguments
  ) where

import Control.Monad (unless, void, when)
import Data.Bifunctor qualified as B
import Data.List (intercalate)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Void (Void)
import SumSpec.Lexer
import SumSpec.Syntax
import SumSpec.Version
import Text.Megaparsec hiding (ParseError)
import Text.Megaparsec qualified as M
import Text.Megaparsec.Char (char)

type ParseError = ParseErrorBundle Text Void

-- | Parses a whole spec. The file path is used only in error messages.
-- The error holds every parse error found (see 'parseSpecPartial').
parseSpec :: FilePath -> Text -> Either ParseError Spec
parseSpec file source = do
  (parsed, errors) <- parseSpecPartial file source
  maybe (Right parsed) Left errors

-- | Parses a spec and goes on after an error in a definition: it skips to
-- the next line that starts a definition (see 'skipDefinition') and reads
-- on. Gives the definitions that parsed and every error, or only the
-- error when the version header or the header blocks don't parse.
parseSpecPartial :: FilePath -> Text -> Either ParseError (Spec, Maybe ParseError)
parseSpecPartial file source =
  case parse (spaceConsumer *> spec) file source of
    Left err -> Left err
    Right (parsed, []) -> Right (parsed, Nothing)
    Right (parsed, e : es) -> Right (parsed, Just (ParseErrorBundle (e :| es) posState))
  where
    posState =
      PosState
        { pstateInput = source
        , pstateOffset = 0
        , pstateSourcePos = initialPos file
        , pstateTabWidth = defaultTabWidth
        , pstateLinePrefix = ""
        }

-- | Renders an error with its line, column and the offending source line.
renderParseError :: ParseError -> String
renderParseError = errorBundlePretty

-- spec = [ version_header ] , headers , { definition } ;
--
-- The definitions are read up to the end of the input, with the errors of
-- those that don't parse.
spec :: Parser (Spec, [M.ParseError Text Void])
spec = do
  version <- optional versionHeader
  (atomics, events, annotations) <- headers
  B.first (Spec version atomics events annotations) <$> definitions

-- | Every definition up to the end of the input. A definition that doesn't
-- parse gives its error, and the parser goes on at the next one.
definitions :: Parser ([Definition], [M.ParseError Text Void])
definitions = go Nothing
  where
    go previous = do
      saved <- getParserState
      next <-
        withRecovery
          (\err -> Left <$> recover previous (stateOffset saved) err)
          (Right <$> ((Nothing <$ eof) <|> (Just <$> definition)))
      case next of
        Right Nothing -> pure ([], [])
        Right (Just d) -> B.first (d :) <$> go (Just saved)
        Left err -> B.second (err :) <$> go Nothing
    -- An error at the very start of a definition has lost the hints of
    -- the one before it ('withRecovery' catches it before they are
    -- added), so it would not say what could have continued that
    -- definition. Parse the previous definition again, followed by this
    -- one, to get the error with them.
    recover previous start err = do
      here <- getParserState
      full <- case previous of
        Just state | errorOffset err == start -> do
          setParserState state
          result <- observing (definition *> optional definition *> eof)
          setParserState here
          pure (either id (const err) result)
        _ -> pure err
      full <$ skipDefinition start

-- | Skips to the next line that starts a definition: one whose first
-- character is not a space and doesn't start a comment. Every example
-- starts its definitions in the first column and indents the lines that
-- continue them. Moves on by a line at least, unless the error is at the
-- start of a line past the definition's start, which may be the next
-- definition.
skipDefinition :: Int -> Parser ()
skipDefinition start = do
  offset <- getOffset
  column <- unPos . sourceColumn <$> getSourcePos
  when (offset == start || column /= 1) skipLine
  skipMany (notFollowedBy (boundary <|> eof) *> skipLine)
  where
    skipLine = takeWhileP Nothing (/= '\n') *> void (optional (char '\n'))
    boundary = void (satisfy (\c -> c /= ' ' && c /= '\t' && c /= '\n' && c /= '\r' && c /= '-'))

-- version_header = "__version" , VERSION ;
--
-- A version this sumspec doesn't implement stops parsing here, so the
-- error names the version instead of some later syntax it can't read.
versionHeader :: Parser LanguageVersion
versionHeader = do
  _ <- symbol "__version"
  offset <- getOffset
  version <- versionNumber
  unless (isSupported version) $
    failAt offset $
      "this spec is for SumSpec "
        <> renderVersion version
        <> ", but this sumspec supports "
        <> supported
  pure version
  where
    supported
      | defaultVersion == latestVersion = renderVersion latestVersion
      | otherwise = renderVersion defaultVersion <> " to " <> renderVersion latestVersion

-- headers = header_block , { header_block } ;
-- header_block = atomics_block | events_block | annotations_block ;
--
-- The blocks come in any order, each at most once; __atomics and __events
-- are required.
headers :: Parser ([Atomic], [Name], Maybe [Name])
headers = go Nothing Nothing Nothing
  where
    go atomics events annotations = do
      offset <- getOffset
      next <-
        optional . choice $
          [ Left . Left <$> atomicsBlock
          , Left . Right <$> eventsBlock
          , Right <$> annotationsBlock
          ]
      case next of
        Just (Left (Left a)) -> once offset "__atomics" atomics *> go (Just a) events annotations
        Just (Left (Right e)) -> once offset "__events" events *> go atomics (Just e) annotations
        Just (Right n) -> once offset "__annotations" annotations *> go atomics events (Just n)
        Nothing -> case (atomics, events) of
          (Just a, Just e) -> pure (a, e, annotations)
          _ -> do
            let missing = [b | (b, False) <- [("__atomics", isJust atomics), ("__events", isJust events)]]
            failAt
              offset
              ("missing " <> intercalate " and " missing <> ": the header blocks come first")
    once offset block seen = case seen of
      Nothing -> pure ()
      Just _ -> failAt offset (block <> " is written twice")

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

-- events_block = "__events" , "{" , { LOWER } , "}" ;
eventsBlock :: Parser [Name]
eventsBlock = symbol "__events" *> braces (many lowerName)

-- annotations_block = "__annotations" , "{" , { ANNOTATION } , "}" ;
annotationsBlock :: Parser [Name]
annotationsBlock = symbol "__annotations" *> braces (many annotationDecl)

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

-- type_def = UPPER , { annotation } , "=" , type_expr ;
--
-- The annotations of a newtype or a list may also follow its body; they
-- belong to the type either way.
typeDef :: Parser TypeDef
typeDef = do
  name <- upperName
  before <- many annotation
  equals
  (body, after) <- typeExpr
  pure (TypeDef name (before <> after) body)

-- type_expr = sum | product | type_term , { annotation } ;
--
-- The three forms share their first token, so the parser reads the first
-- term and its annotations, and then decides from what follows them. The
-- annotations after a single term are returned: they belong to what the
-- term defines.
typeExpr :: Parser (TypeExpr, [Annotation])
typeExpr = do
  first <- typeTerm
  notes <- many annotation
  let alone = pure (TypeTerm first, notes)
  case first of
    TermName name ->
      choice
        [ sumAfter (Variant name Nothing notes)
        , productAfter (Factor first notes)
        , if null notes then sumWithPayload name else empty
        , alone
        ]
    TermList _ _ -> productAfter (Factor first notes) <|> alone
  where
    sumWithPayload name = do
      (p, inner) <- payload
      notes <- many annotation
      sumAfter (Variant name (Just p) (inner <> notes))
    sumAfter v = (,[]) . TypeSum . (v :) <$> moreVariants
    productAfter f = (,[]) . TypeProduct . (f :) <$> some (symbol "*" *> factor)
    moreVariants =
      some (symbol "|" *> variant)
        <?> "\"|\" (a sum needs at least two variants)"

-- variant = UPPER , [ payload ] , { annotation } ;
--
-- The annotations of a payload written as one term in parentheses,
-- V (T @a), belong to the variant too.
variant :: Parser Variant
variant = do
  name <- upperName
  p <- optional payload
  notes <- many annotation
  pure $ case p of
    Just (body, inner) -> Variant name (Just body) (inner <> notes)
    Nothing -> Variant name Nothing notes

-- factor = type_term , { annotation } ;
factor :: Parser Factor
factor = Factor <$> typeTerm <*> many annotation

-- payload = type_term | "(" , type_expr , ")" ;
--
-- A bare UPPER followed by "=", or by annotations and then "=", starts the
-- next type definition, so it is never taken as a payload. A payload in
-- parentheses gives the annotations after a single term inside them.
payload :: Parser (TypeExpr, [Annotation])
payload =
  choice
    [ parens typeExpr
    , (,[]) . TypeTerm . uncurry TermList <$> listTerm
    , (,[]) . TypeTerm . TermName
        <$> try (upperName <* notFollowedBy (many annotation *> equals))
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
--                     | pattern , [ guard ] , "->" , pattern ,
--                       { annotation } ) ;
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
    plain =
      Branch <$> one <*> optional guard <*> (symbol "->" *> one) <*> many annotation
    one = (:| []) <$> pattern

-- branch = "=>" , arguments , [ guard ] , "->" , arguments , { annotation } ;
branch :: Parser Branch
branch =
  Branch
    <$> (symbol "=>" *> arguments)
    <*> optional guard
    <*> (symbol "->" *> arguments)
    <*> many annotation

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

-- arguments = arg_term , { ( "+" | "-" ) , arg_term } ;
-- arg_term  = pattern , { "*" , pattern } ;
--
-- Without "+" or "-", the patterns of the one arg_term are the
-- arguments, joined by "*": factors of a product, or, under a head that
-- holds one value, a multiplication (the checker tells them apart by the
-- head). With "+" or "-", they are one computed value, and every pattern
-- in it must be a value: a name, a literal, a constant or "(arith)".
arguments :: Parser (NonEmpty Pattern)
arguments = do
  first <- argTerm
  rest <- many ((,) <$> additiveOp <*> argTerm)
  case rest of
    [] -> pure (fmap snd (fst first :| map (\(_, o, p) -> (o, p)) (snd first)))
    _ -> do
      e <- termExpr first
      es <- traverse (\(op, t) -> (op,) <$> termExpr t) rest
      pure (PatternExpr (joinOps e es) :| [])
  where
    argTerm = do
      o <- getOffset
      p <- pattern
      more <- many ((,,) <$> (fst <$> timesOp) <*> getOffset <*> pattern)
      pure ((o, p), more)
    termExpr ((o, p), more) = do
      e <- value o p
      es <- traverse (\(pos, o', p') -> (,) (pos, OpMul) <$> value o' p') more
      pure (joinOps e es)
    value o = \case
      PatternName n -> pure (ExprName n)
      PatternPath (c :| []) [] -> pure (ExprConst c)
      PatternExpr e -> pure e
      _ ->
        failAt o $
          "only a name, a literal, a constant or a value in parentheses goes in a "
            <> "computed value, not a type pattern, a naming or a prime"

-- input = type_pattern , [ NAMING ] ;
input :: Parser Pattern
input = withNaming =<< typePattern

-- pattern = ( type_pattern | LOWER | literal | "(" , arith , ")" ) ,
--           { "'" } , [ NAMING ] ;
--
-- A lone name in parentheses is a 'PatternName', and a lone constant a
-- 'PatternPath', as without them.
pattern :: Parser Pattern
pattern = do
  base <-
    choice
      [ exprPattern <$> (literalAtom <|> parens arithFull)
      , typePattern
      , PatternName <$> valueName
      ]
  primes <- many (getSourcePos <* symbol "'")
  withNaming (foldl (flip PatternPrimed) base primes)
  where
    exprPattern = \case
      ExprName n -> PatternName n
      ExprConst c -> PatternPath (c :| []) []
      e -> PatternExpr e

-- arith_atom = LOWER | literal | UPPER | "(" , arith , ")" ;
arithAtom :: Parser Expr
arithAtom =
  choice
    [ literalAtom
    , ExprName <$> valueName
    , ExprConst <$> upperName
    , parens arithFull
    ]
    <?> "a value, a literal, a constant or \"(\""

literalAtom :: Parser Expr
literalAtom = uncurry ExprLit <$> (numberLiteral <|> stringLiteral) <?> "literal"

-- arith = arith_product , { ( "+" | "-" ) , arith_product } ;
arithFull :: Parser Expr
arithFull = joinOps <$> arithMul <*> many ((,) <$> additiveOp <*> arithMul)

-- arith_product = arith_atom , { "*" , arith_atom } ;
arithMul :: Parser Expr
arithMul = joinOps <$> arithAtom <*> many ((,) <$> timesOp <*> arithAtom)

-- Joins operands left to right: a - b - c is (a - b) - c.
joinOps :: Expr -> [((SourcePos, ArithOp), Expr)] -> Expr
joinOps = foldl (\left ((pos, op), right) -> ExprBin op pos left right)

-- type_pattern = path , "." , "{" , alternatives , "}"
--              | path , [ element_key ] ,
--                [ "(" , ( NAMING | arguments ) , ")" ]
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

-- "(" , ( NAMING | arguments ) , ")"
argumentList :: Parser [Pattern]
argumentList = parens (bound <|> NE.toList <$> arguments)
  where
    bound = pure . PatternBound <$> naming

-- alternatives = alternative , "|" , alternative , { "|" , alternative } ;
alternatives :: Parser (NonEmpty Pattern)
alternatives = do
  first <- alternative
  _ <- symbol "|" <?> "\"|\" (alternatives need at least two variants)"
  (first :|) <$> sepBy1 alternative (symbol "|")

-- alternative = path , [ "." , "{" , alternatives , "}"
--                      | "(" , ( NAMING | arguments ) , ")" ] ;
alternative :: Parser Pattern
alternative = do
  names <- path
  choice
    [ PatternAlts names <$> (symbol "." *> braces alternatives)
    , PatternPath names <$> option [] argumentList
    ]

-- element_key = "[" , ( LOWER , [ "in" , LOWER ] | "_" ) , "]" ;
elementKey :: Parser ElementKey
elementKey = brackets (each <|> one)
  where
    each = do
      pos <- getSourcePos
      KeyEach (Name pos "_") <$ symbol "_"
    one = do
      x <- valueName
      maybe (KeyOne x) (KeyIn x) <$> optional (keyword "in" *> valueName)

-- [ NAMING ] after a pattern.
withNaming :: Pattern -> Parser Pattern
withNaming p = maybe p (PatternNamed p) <$> optional naming

-- path = UPPER , { "." , UPPER } ;
path :: Parser (NonEmpty Name)
path = (:|) <$> upperName <*> many (try (symbol "." *> upperName))
