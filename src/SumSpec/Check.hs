{-# LANGUAGE OverloadedStrings #-}

-- | Type checker for SumSpec v1. It checks a parsed spec against the rules
-- listed at the end of spec/grammar.ebnf and reports every error it finds,
-- sorted by position.
module SumSpec.Check
  ( CheckError (..)
  , checkSpec
  , renderCheckErrors
  ) where

import Data.List (find, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import SumSpec.Syntax
import Text.Megaparsec (SourcePos (..), initialPos, sourcePosPretty, unPos)

data CheckError = CheckError
  { errorPos :: SourcePos
  , errorMessage :: Text
  }
  deriving stock (Eq, Show)

-- | Checks a spec and returns its errors sorted by position; no errors
-- means the spec is valid. The file path is used for errors that have no
-- place in the source, such as a missing @App@.
checkSpec :: FilePath -> Spec -> [CheckError]
checkSpec file spec =
  sortOn (position . errorPos) $
    concat
      [ checkHeaders spec
      , checkApp file env
      , checkTypeDefs env typeDefs
      , checkTransitions env spec transitions
      ]
  where
    position pos = (unPos (sourceLine pos), unPos (sourceColumn pos))
    typeDefs = [d | DefType d <- specDefinitions spec]
    transitions = [t | DefTransition t <- specDefinitions spec]
    env = mkEnv spec typeDefs

-- | Renders errors like parse errors: position, source line, caret and
-- message, with a blank line between errors.
renderCheckErrors :: Text -> [CheckError] -> String
renderCheckErrors source = unlines . map render
  where
    sourceLines = T.lines source
    render (CheckError pos message) =
      unlines
        [ sourcePosPretty pos <> ":"
        , gutter <> " |"
        , lineNumber <> " | " <> T.unpack line
        , gutter <> " | " <> replicate (unPos (sourceColumn pos) - 1) ' ' <> "^"
        , T.unpack message
        ]
      where
        lineNumber = show (unPos (sourceLine pos))
        gutter = map (const ' ') lineNumber
        line = case drop (unPos (sourceLine pos) - 1) sourceLines of
          l : _ -> l
          [] -> ""

-- ---------- Environment ----------

-- | The declared atomics and the defined types. A type defined twice keeps
-- its first definition; the second is reported as an error.
data Env = Env
  { envAtomics :: Set Text
  , envTypes :: Map Text TypeExpr
  }

mkEnv :: Spec -> [TypeDef] -> Env
mkEnv spec defs =
  Env
    { envAtomics = Set.fromList (map nameText (specAtomics spec))
    , envTypes =
        Map.fromListWith
          (\_ first -> first)
          [(nameText (typeDefName d), typeDefBody d) | d <- defs]
    }

isKnownType :: Env -> Text -> Bool
isKnownType env name =
  Set.member name (envAtomics env) || Map.member name (envTypes env)

-- ---------- Headers and App ----------

checkHeaders :: Spec -> [CheckError]
checkHeaders spec =
  [ errorAt n (nameText n <> " is listed twice in __atomics")
  | (n, _) <- repeats nameText (specAtomics spec)
  ]
    <> [ errorAt n (nameText n <> " is listed twice in __txs")
       | (n, _) <- repeats nameText (specTxs spec)
       ]

checkApp :: FilePath -> Env -> [CheckError]
checkApp file env
  | Map.member "App" (envTypes env) = []
  | otherwise =
      [ CheckError
          (initialPos file)
          "App is not defined; every spec needs an App type as its entry point"
      ]

-- ---------- Type definitions ----------

checkTypeDefs :: Env -> [TypeDef] -> [CheckError]
checkTypeDefs env defs =
  [ errorAt n (nameText n <> " is defined twice (first on line " <> lineOf first <> ")")
  | (TypeDef n _, TypeDef first _) <- repeats (nameText . typeDefName) defs
  ]
    <> [ errorAt n (nameText n <> " is declared in __atomics and also defined")
       | TypeDef n _ <- defs
       , Set.member (nameText n) (envAtomics env)
       ]
    <> concatMap (checkTypeExpr env . typeDefBody) defs
    <> mapMaybe (newtypeCycle env) (firsts (nameText . typeDefName) defs)

checkTypeExpr :: Env -> TypeExpr -> [CheckError]
checkTypeExpr env = \case
  TypeSum variants ->
    [ errorAt n ("variant " <> nameText n <> " appears twice in this sum")
    | (Variant n _, _) <- repeats (nameText . variantName) variants
    ]
      <> concat [checkTypeExpr env p | Variant _ (Just p) <- variants]
  TypeProduct terms ->
    [ errorAt (termName t) ("factor " <> termKey t <> " appears twice in this product")
    | (t, _) <- repeats termKey terms
    ]
      <> concatMap (checkTerm env) terms
  TypeTerm term -> checkTerm env term

checkTerm :: Env -> TypeTerm -> [CheckError]
checkTerm env term
  | isKnownType env (nameText n) = []
  | otherwise = [unknownType n]
  where
    n = termName term

-- | A newtype that leads back to itself (@A = B@, @B = A@) has no
-- structure at all. Reported at the definition, with the chain.
newtypeCycle :: Env -> TypeDef -> Maybe CheckError
newtypeCycle env (TypeDef start _) = go [nameText start] (nameText start)
  where
    go seen current = case Map.lookup current (envTypes env) of
      Just (TypeTerm (TermName next))
        | nameText next == nameText start ->
            Just
              ( errorAt start $
                  "newtype "
                    <> nameText start
                    <> " refers back to itself: "
                    <> T.intercalate " = " (reverse (nameText start : seen))
              )
        | nameText next `elem` seen -> Nothing
        | otherwise -> go (nameText next : seen) (nameText next)
      _ -> Nothing

-- ---------- Transitions ----------

checkTransitions :: Env -> Spec -> [Transition] -> [CheckError]
checkTransitions env spec transitions =
  [ errorAt n ("transition " <> nameText n <> " is not listed in __txs")
  | Transition n _ _ <- firsts (nameText . transitionName) transitions
  , nameText n `Set.notMember` listed
  ]
    <> [ errorAt n ("transition " <> nameText n <> " is listed in __txs but has no signature")
       | n <- firsts nameText (specTxs spec)
       , nameText n `Set.notMember` signed
       ]
    <> concat
      [ checkPrimes Source from
          <> checkPrimes Target to
          <> checkPattern env from
          <> checkPattern env to
      | Transition _ from to <- transitions
      ]
  where
    listed = Set.fromList (map nameText (specTxs spec))
    signed = Set.fromList (map (nameText . transitionName) transitions)

-- | The side of a transition a pattern is on: the source is a
-- precondition, the target is the effect.
data Side = Source | Target

-- | A prime marks a new value, so it goes only on the target side, once,
-- on a bare type name (@Missions'@). On a path or after arguments it
-- would say nothing new: the written variant already gives the value.
checkPrimes :: Side -> Pattern -> [CheckError]
checkPrimes side = \case
  PatternPrimed pos inner ->
    [ CheckError pos "a prime (') marks a new value, so it can only be on the target side"
    | Source <- [side]
    ]
      <> case inner of
        PatternPrimed _ _ -> [CheckError pos "a name takes at most one prime (')"]
        PatternPath (_ :| []) [] -> []
        _ ->
          [ CheckError pos $
              "a prime (') goes only on a bare type name; "
                <> "a written variant or argument already says what the new value is"
          ]
      <> checkPrimes side inner
  PatternPath _ args -> concatMap (checkPrimes side) args
  PatternList _ -> []

-- | What a position in a pattern stands for: a type or a variant, with a
-- label for messages (@Page.Plan@) and the type expression its path and
-- arguments look into. The body is 'Nothing' for an atomic type and for a
-- variant without a payload.
data Node = Node
  { nodeLabel :: Text
  , nodeBody :: Maybe TypeExpr
  }

typeNode :: Env -> Text -> Maybe Node
typeNode env name = case Map.lookup name (envTypes env) of
  Just body -> Just (Node name (Just body))
  Nothing
    | Set.member name (envAtomics env) -> Just (Node name Nothing)
    | otherwise -> Nothing

-- | A whole side of a transition. Its first name must be a type. Primes
-- are checked by 'checkPrimes'; here a primed pattern is checked like the
-- pattern it primes.
checkPattern :: Env -> Pattern -> [CheckError]
checkPattern env = \case
  PatternPrimed _ inner -> checkPattern env inner
  PatternList term -> checkTerm env term
  PatternPath (h :| path) args -> case typeNode env (nameText h) of
    Nothing -> [unknownType h]
    Just node -> walk env node h path args

-- | Follows the rest of a path from a node, then checks the arguments at
-- its end. @at@ is the last name read, where errors about the node go.
walk :: Env -> Node -> Name -> [Name] -> [Pattern] -> [CheckError]
walk env node at path args = case path of
  [] -> checkArgs env node at args
  v : rest -> case nodeBody node of
    Just (TypeSum variants) ->
      case find ((== nameText v) . nameText . variantName) variants of
        Just (Variant _ payload) ->
          walk env (Node (nodeLabel node <> "." <> nameText v) payload) v rest args
        Nothing -> [errorAt v (nameText v <> " is not a variant of " <> nodeLabel node)]
    Just (TypeTerm (TermName base))
      | Just (TypeSum _) <- Map.lookup (nameText base) (envTypes env) ->
          [ errorAt v $
              nodeLabel node
                <> " carries "
                <> nameText base
                <> " and has no variants of its own; write "
                <> nodeLabel node
                <> "("
                <> nameText base
                <> "."
                <> nameText v
                <> ")"
          ]
    _ ->
      [ errorAt v (nodeLabel node <> " has no variants, so ." <> nameText v <> " is invalid")
      ]

-- | Written arguments must match the node: one argument for a single
-- payload or newtype, some or all of the factors of a product, none for a
-- sum (pick a variant with "." instead). What left-out parts mean depends
-- on the side (see "Source and target" in spec-v1.md); either way they
-- are valid.
checkArgs :: Env -> Node -> Name -> [Pattern] -> [CheckError]
checkArgs _ _ _ [] = []
checkArgs env node at args = case nodeBody node of
  Nothing -> [errorAt at (nodeLabel node <> " takes no arguments")]
  Just (TypeSum _) ->
    [ errorAt at $
        nodeLabel node <> " is a sum; pick a variant with \".\" instead of arguments"
    ]
  Just (TypeProduct factors) -> checkFactors env node factors args
  Just (TypeTerm term) -> case args of
    [arg] -> checkArg env term arg
    _ ->
      [ errorAt at $
          nodeLabel node
            <> " takes one argument, "
            <> termKey term
            <> ", but "
            <> T.pack (show (length args))
            <> " are given"
      ]

-- | Arguments of a product: each one is a factor, matched by type name in
-- any order, and written at most once (@A * A'@ writes @A@ twice). Factors
-- may be left out.
checkFactors :: Env -> Node -> [TypeTerm] -> [Pattern] -> [CheckError]
checkFactors env node factors args =
  [ errorAt (patternHead a) $
      patternKey a
        <> " is not a factor of "
        <> nodeLabel node
        <> " ("
        <> T.intercalate " * " (map termKey factors)
        <> ")"
  | a <- args
  , patternKey a `Map.notMember` byKey
  ]
    <> [ errorAt (patternHead a) ("factor " <> patternKey a <> " is written twice")
       | (a, _) <- repeats patternKey args
       ]
    <> concat
      [ checkArg env factor a
      | a <- firsts patternKey args
      , Just factor <- [Map.lookup (patternKey a) byKey]
      ]
  where
    byKey = Map.fromList [(termKey f, f) | f <- factors]

-- | An argument where the type @term@ is expected: a pattern headed by
-- that type, or the same list type.
checkArg :: Env -> TypeTerm -> Pattern -> [CheckError]
checkArg env term arg = case (term, arg) of
  (_, PatternPrimed _ inner) -> checkArg env term inner
  (TermName expected, PatternPath (h :| path) args)
    | nameText h == nameText expected -> case typeNode env (nameText h) of
        -- An unknown type is already reported where it is defined.
        Nothing -> []
        Just node -> walk env node h path args
  (TermList _, PatternList element)
    | termKey term == termKey (TermList element) -> []
  _ ->
    [ errorAt (patternHead arg) $
        "expected " <> termKey term <> " here, not " <> patternKey arg
    ]

-- ---------- Helpers ----------

errorAt :: Name -> Text -> CheckError
errorAt = CheckError . namePos

unknownType :: Name -> CheckError
unknownType n =
  errorAt n $
    "unknown type " <> nameText n <> "; declare it in __atomics or define it"

lineOf :: Name -> Text
lineOf = T.pack . show . unPos . sourceLine . namePos

-- | The name a type term is built on: @A@ for @A@, @[A]@ and @[[A]]@.
termName :: TypeTerm -> Name
termName = \case
  TermName n -> n
  TermList t -> termName t

-- | How a factor is identified in a product: its type name, or the list
-- type written out (@[A]@).
termKey :: TypeTerm -> Text
termKey = \case
  TermName n -> nameText n
  TermList t -> "[" <> termKey t <> "]"

patternHead :: Pattern -> Name
patternHead = \case
  PatternPath (h :| _) _ -> h
  PatternList t -> termName t
  PatternPrimed _ p -> patternHead p

-- | The factor an argument stands for: its first name, or its list type.
-- A prime doesn't change it: @A'@ stands for the factor @A@.
patternKey :: Pattern -> Text
patternKey = \case
  PatternPath (h :| _) _ -> nameText h
  PatternList t -> termKey (TermList t)
  PatternPrimed _ p -> patternKey p

-- | Every element whose key was already seen, paired with the first
-- element that had that key.
repeats :: (a -> Text) -> [a] -> [(a, a)]
repeats key = go Map.empty
  where
    go _ [] = []
    go seen (x : xs) = case Map.lookup (key x) seen of
      Just first -> (x, first) : go seen xs
      Nothing -> go (Map.insert (key x) x seen) xs

-- | The first element for each key, in order.
firsts :: (a -> Text) -> [a] -> [a]
firsts key = go Set.empty
  where
    go _ [] = []
    go seen (x : xs)
      | Set.member (key x) seen = go seen xs
      | otherwise = x : go (Set.insert (key x) seen) xs
