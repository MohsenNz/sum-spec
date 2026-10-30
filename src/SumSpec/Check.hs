{-# LANGUAGE OverloadedStrings #-}

-- | Type checker for SumSpec v1. It checks a parsed spec against the rules
-- listed at the end of spec/grammar.ebnf and reports every error it finds,
-- sorted by position, with the warnings among them.
module SumSpec.Check
  ( CheckError (..)
  , Severity (..)
  , checkSpec
  , hasErrors
  , renderCheckErrors
  ) where

import Data.List (find, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import SumSpec.Syntax
import SumSpec.Version
  ( LanguageVersion
  , defaultVersion
  , inputsVersion
  , namesVersion
  , renderVersion
  )
import Text.Megaparsec (SourcePos (..), initialPos, sourcePosPretty, unPos)

data CheckError = CheckError
  { errorSeverity :: Severity
  , errorPos :: SourcePos
  , errorMessage :: Text
  }
  deriving stock (Eq, Show)

-- | An error makes a spec invalid. A warning points at a part of a valid
-- spec that is less precise than it could be.
data Severity = Error | Warning
  deriving stock (Eq, Show)

-- | Whether any of the reported problems is an error, not a warning.
hasErrors :: [CheckError] -> Bool
hasErrors = any ((== Error) . errorSeverity)

-- | Checks a spec and returns its errors and warnings sorted by position;
-- no errors means the spec is valid. The file path is used for errors
-- that have no place in the source, such as a missing @App@.
checkSpec :: FilePath -> Spec -> [CheckError]
checkSpec file spec =
  sortOn (position . errorPos) $
    concat
      [ checkHeaders spec
      , checkApp file env
      , checkTypeDefs env typeDefs
      , checkTransitions env spec transitions
      , warnListElements env transitions
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
    render (CheckError severity pos message) =
      unlines
        [ sourcePosPretty pos <> ":"
        , gutter <> " |"
        , lineNumber <> " | " <> T.unpack line
        , gutter <> " | " <> replicate (unPos (sourceColumn pos) - 1) ' ' <> "^"
        , prefix <> T.unpack message
        ]
      where
        lineNumber = show (unPos (sourceLine pos))
        gutter = map (const ' ') lineNumber
        prefix = case severity of
          Error -> ""
          Warning -> "warning: "
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
      [ errorAtPos
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
  | Transition n _ _ _ <- firsts (nameText . transitionName) transitions
  , nameText n `Set.notMember` listed
  ]
    <> checkInputs transitions
    <> [ needsVersion inputsVersion "transition inputs" (patternHead i)
       | version < inputsVersion
       , Transition _ (Just i) _ _ <- transitions
       ]
    <> [ errorAt n ("transition " <> nameText n <> " is listed in __txs but has no signature")
       | n <- firsts nameText (specTxs spec)
       , nameText n `Set.notMember` signed
       ]
    <> concatMap checkSignature transitions
  where
    listed = Set.fromList (map nameText (specTxs spec))
    signed = Set.fromList (map (nameText . transitionName) transitions)
    version = fromMaybe defaultVersion (specVersion spec)
    -- The input is checked like the source: it's what the transition
    -- receives, so it can name values but not give new ones.
    checkSignature (Transition _ input from to) =
      concatMap (checkPrimes Source) input
        <> checkPrimes Source from
        <> checkPrimes Target to
        <> checkNamings input from to
        <> concatMap (checkPattern env names) input
        <> checkPattern env names from
        <> checkPattern env names to
        <> [ needsVersion namesVersion "named values" n
           | version < namesVersion
           , n <- nameRefs from <> nameRefs to
           ]
      where
        names = Map.fromList [(nameText n, k) | (n, k) <- signatureNames input from]

-- | An input belongs to the transition, not to one signature (as an EFSM
-- event has one parameter list), so every signature takes the input of
-- the first one, or none like it.
checkInputs :: [Transition] -> [CheckError]
checkInputs transitions =
  [ errorAt (maybe n patternHead input) $
      "transition "
        <> nameText n
        <> " takes "
        <> describe firstInput
        <> " (line "
        <> lineOf firstName
        <> "), but this signature takes "
        <> describe input
  | Transition n input _ _ <- transitions
  , Just (Transition firstName firstInput _ _) <- [Map.lookup (nameText n) firstByName]
  , fmap patternKey input /= fmap patternKey firstInput
  ]
  where
    firstByName =
      Map.fromList
        [ (nameText (transitionName t), t)
        | t <- firsts (nameText . transitionName) transitions
        ]
    describe = maybe "no input" patternKey

-- | The names a signature gives, with their types: in its input and on
-- its source side.
signatureNames :: Maybe Pattern -> Pattern -> [(Name, Text)]
signatureNames input from = concatMap namings input <> namings from

-- | The values a pattern names (@P#x@), with the type of each: the head
-- type of @P@, or its list type. A name given to a name (@x#y@) is an
-- error, so it gives no type here.
namings :: Pattern -> [(Name, Text)]
namings = \case
  PatternNamed (PatternName _) _ -> []
  PatternNamed p n -> (n, patternKey p) : namings p
  PatternPath _ args -> concatMap namings args
  PatternPrimed _ p -> namings p
  PatternList _ -> []
  PatternName _ -> []

-- | Every name written in a pattern, given (@#x@) or used (@x@).
nameRefs :: Pattern -> [Name]
nameRefs = \case
  PatternNamed p n -> n : nameRefs p
  PatternName n -> [n]
  PatternPath _ args -> concatMap nameRefs args
  PatternPrimed _ p -> nameRefs p
  PatternList _ -> []

-- | Where names may be given: once each, in the input or on the source
-- side, and only to a type pattern. On the target side a name is only
-- used, to set a value.
checkNamings :: Maybe Pattern -> Pattern -> Pattern -> [CheckError]
checkNamings input from to =
  [ errorAt n (nameText n <> " is named twice in this signature")
  | ((n, _), _) <- repeats (nameText . fst) (signatureNames input from)
  ]
    <> [ errorAt n $
           "a value is named only in the input or on the source side; "
             <> "on the target side, write the name alone: "
             <> nameText n
       | (_, n) <- named to
       ]
    <> [ errorAt
           n
           ("only a type pattern can be named; " <> nameText x <> " already names a value")
       | (PatternName x, n) <- concatMap named (maybe [] pure input <> [from])
       ]
  where
    named = \case
      PatternNamed p n -> (p, n) : named p
      PatternPath _ args -> concatMap named args
      PatternPrimed _ p -> named p
      PatternList _ -> []
      PatternName _ -> []

-- | The side of a transition a pattern is on: the source is a
-- precondition, the target is the effect.
data Side = Source | Target

-- | A prime marks a new value, so it goes only on the target side, once,
-- on a bare type name (@Missions'@). On a path or after arguments it
-- would say nothing new: the written variant already gives the value.
checkPrimes :: Side -> Pattern -> [CheckError]
checkPrimes side = \case
  PatternPrimed pos inner ->
    [ errorAtPos pos "a prime (') marks a new value, so it can only be on the target side"
    | Source <- [side]
    ]
      <> case inner of
        PatternPrimed _ _ -> [errorAtPos pos "a name takes at most one prime (')"]
        PatternPath (_ :| []) [] -> []
        _ ->
          [ errorAtPos pos $
              "a prime (') goes only on a bare type name; "
                <> "a written variant or argument already says what the new value is"
          ]
      <> checkPrimes side inner
  PatternPath _ args -> concatMap (checkPrimes side) args
  PatternNamed p _ -> checkPrimes side p
  PatternList _ -> []
  PatternName _ -> []

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

-- | The names a signature gives, with the type of each.
type Names = Map Text Text

-- | A whole side of a transition, or an input. Its first name must be a
-- type, or it's a name. Primes are checked by 'checkPrimes' and the
-- places of names by 'checkNamings'; here a primed or named pattern is
-- checked like the pattern inside.
checkPattern :: Env -> Names -> Pattern -> [CheckError]
checkPattern env names = \case
  PatternPrimed _ inner -> checkPattern env names inner
  PatternNamed inner _ -> checkPattern env names inner
  PatternName n -> [unknownName n | nameText n `Map.notMember` names]
  PatternList term -> checkTerm env term
  PatternPath (h :| path) args -> case typeNode env (nameText h) of
    Nothing -> [unknownType h]
    Just node -> walk env names node h path args

-- | Follows the rest of a path from a node, then checks the arguments at
-- its end. @at@ is the last name read, where errors about the node go.
walk :: Env -> Names -> Node -> Name -> [Name] -> [Pattern] -> [CheckError]
walk env names node at path args = case path of
  [] -> checkArgs env names node at args
  v : rest -> case nodeBody node of
    Just (TypeSum variants) ->
      case find ((== nameText v) . nameText . variantName) variants of
        Just (Variant _ payload) ->
          walk env names (Node (nodeLabel node <> "." <> nameText v) payload) v rest args
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
checkArgs :: Env -> Names -> Node -> Name -> [Pattern] -> [CheckError]
checkArgs _ _ _ _ [] = []
checkArgs env names node at args = case nodeBody node of
  Nothing -> [errorAt at (nodeLabel node <> " takes no arguments")]
  Just (TypeSum _) ->
    [ errorAt at $
        nodeLabel node <> " is a sum; pick a variant with \".\" instead of arguments"
    ]
  Just (TypeProduct factors) -> checkFactors env names node factors args
  Just (TypeTerm term) -> case args of
    [arg] -> checkArg env names term arg
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
-- may be left out. A name stands for the factor of its type.
checkFactors :: Env -> Names -> Node -> [TypeTerm] -> [Pattern] -> [CheckError]
checkFactors env names node factors args =
  [unknownName n | (a, Nothing) <- keyed, PatternName n <- [bare a]]
    <> [ errorAt (patternHead a) $
           describeArg a key
             <> " is not a factor of "
             <> nodeLabel node
             <> " ("
             <> T.intercalate " * " (map termKey factors)
             <> ")"
       | (a, Just key) <- keyed
       , key `Map.notMember` byKey
       ]
    <> [ errorAt (patternHead a) ("factor " <> key <> " is written twice")
       | ((a, key), _) <- repeats snd known
       ]
    <> concat
      [ checkArg env names factor a
      | (a, key) <- firsts snd known
      , Just factor <- [Map.lookup key byKey]
      ]
  where
    byKey = Map.fromList [(termKey f, f) | f <- factors]
    keyed = [(a, argKey names a) | a <- args]
    known = [(a, key) | (a, Just key) <- keyed]

-- | An argument where the type @term@ is expected: a pattern headed by
-- that type, the same list type, or a name of that type.
checkArg :: Env -> Names -> TypeTerm -> Pattern -> [CheckError]
checkArg env names term arg = case (term, arg) of
  (_, PatternPrimed _ inner) -> checkArg env names term inner
  (_, PatternNamed inner _) -> checkArg env names term inner
  (_, PatternName n) -> case Map.lookup (nameText n) names of
    Nothing -> [unknownName n]
    Just key
      | key == termKey term -> []
      | otherwise ->
          [ errorAt n $
              nameText n <> " has type " <> key <> ", but " <> termKey term <> " is expected here"
          ]
  (TermName expected, PatternPath (h :| path) args)
    | nameText h == nameText expected -> case typeNode env (nameText h) of
        -- An unknown type is already reported where it is defined.
        Nothing -> []
        Just node -> walk env names node h path args
  (TermList _, PatternList element)
    | termKey term == termKey (TermList element) -> []
  _ ->
    [ errorAt (patternHead arg) $
        "expected " <> termKey term <> " here, not " <> patternKey arg
    ]

-- ---------- Warnings ----------

-- | Where a type occurs inside @App@: the element types of the lists
-- crossed on the way to it, innermost first, and whether the type is the
-- element of the innermost list itself (@Todo@ in @[Todo]@).
data Place = Place [Text] Bool

-- | Every place of every type reachable from @App@. A recursive type is
-- followed again on a path only when it is inside another list, so a
-- tree's nodes are found both at the root and inside @[Tree]@.
listPlaces :: Env -> Map Text [Place]
listPlaces env =
  Map.fromListWith (flip (<>)) [(t, [p]) | (t, p) <- goType Set.empty [] False "App"]
  where
    goType seen lists direct name
      | Set.member visit seen = []
      | otherwise =
          (name, Place lists direct)
            : maybe [] (goExpr (Set.insert visit seen) lists) (Map.lookup name (envTypes env))
      where
        visit = (name, take 1 lists)
    goExpr seen lists = \case
      TypeSum variants -> concat [goExpr seen lists p | Variant _ (Just p) <- variants]
      TypeProduct terms -> concatMap (goTerm seen lists) terms
      TypeTerm term -> goTerm seen lists term
    goTerm seen lists = \case
      TermName n -> goType seen lists False (nameText n)
      TermList element -> goElement seen (termKey element : lists) element
    goElement seen lists = \case
      TermName n -> goType seen lists True (nameText n)
      TermList element -> goElement seen (termKey element : lists) element

-- | A transition on a part inside a list element changes one element, but
-- says which only when it is written from the element and compares a key
-- with a named value (@Todo(id * ...)@). Warns about the others, once per
-- signature.
warnListElements :: Env -> [Transition] -> [CheckError]
warnListElements env transitions =
  [ warningAt h (nameText n <> " " <> message)
  | Transition n _ from _ <- transitions
  , PatternPath (h :| _) args <- [bare from]
  , Just message <- [firstJust (map (problem (nameText h) args) (placesOf (nameText h)))]
  ]
  where
    places = listPlaces env
    placesOf t = [p | p@(Place (_ : _) _) <- Map.findWithDefault [] t places]
    keyed args = any (not . null . nameUses) args
    problem t args (Place lists direct) = case lists of
      element : outer
        | not direct ->
            Just $
              "changes a "
                <> t
                <> " inside one "
                <> element
                <> " of a list, but doesn't say which "
                <> element
                <> "; to pick it, write the transition from "
                <> element
                <> " and compare a key with a named value, such as "
                <> element
                <> "(id * ...)"
        | not (keyed args) ->
            Just $
              "changes one "
                <> t
                <> " of a list, but doesn't say which; to pick it, compare a key "
                <> "with a named value, such as "
                <> t
                <> "(id * ...)"
        | outerElement : _ <- outer ->
            Just $
              "picks a "
                <> t
                <> " by key, but not the "
                <> outerElement
                <> " it is in; a pattern can't pick an element of an outer list yet"
        | otherwise -> Nothing
      [] -> Nothing
    firstJust = foldr (\m rest -> maybe rest Just m) Nothing

-- | The names a pattern uses (@x@), not the ones it gives (@#x@).
nameUses :: Pattern -> [Name]
nameUses = \case
  PatternName n -> [n]
  PatternNamed p _ -> nameUses p
  PatternPath _ args -> concatMap nameUses args
  PatternPrimed _ p -> nameUses p
  PatternList _ -> []

-- ---------- Helpers ----------

errorAt :: Name -> Text -> CheckError
errorAt = errorAtPos . namePos

errorAtPos :: SourcePos -> Text -> CheckError
errorAtPos = CheckError Error

warningAt :: Name -> Text -> CheckError
warningAt = CheckError Warning . namePos

unknownType :: Name -> CheckError
unknownType n =
  errorAt n $
    "unknown type " <> nameText n <> "; declare it in __atomics or define it"

unknownName :: Name -> CheckError
unknownName n =
  errorAt n $
    "unknown name "
      <> nameText n
      <> "; name a value with #"
      <> nameText n
      <> " in the input or on the source side"

-- | A feature used in a spec whose version doesn't have it.
needsVersion :: LanguageVersion -> Text -> Name -> CheckError
needsVersion since feature n =
  errorAt n $
    feature
      <> " need SumSpec "
      <> T.pack (renderVersion since)
      <> "; declare __version "
      <> T.pack (renderVersion since)
      <> " or later"

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
  PatternNamed p _ -> patternHead p
  PatternName n -> n

-- | The type a pattern is headed by: its first name, or its list type.
-- A prime or a naming doesn't change it: @A'@ and @A#x@ are headed by
-- @A@. For a name (@x@) it is the name itself; see 'argKey' for its type.
patternKey :: Pattern -> Text
patternKey = \case
  PatternPath (h :| _) _ -> nameText h
  PatternList t -> termKey (TermList t)
  PatternPrimed _ p -> patternKey p
  PatternNamed p _ -> patternKey p
  PatternName n -> nameText n

-- | The factor an argument stands for: 'patternKey', or for a name the
-- type of the value it names ('Nothing' for an unknown name).
argKey :: Names -> Pattern -> Maybe Text
argKey names arg = case bare arg of
  PatternName n -> Map.lookup (nameText n) names
  _ -> Just (patternKey arg)

-- | A pattern without its primes and naming.
bare :: Pattern -> Pattern
bare = \case
  PatternPrimed _ p -> bare p
  PatternNamed p _ -> bare p
  p -> p

-- | An argument in messages: its type, and for a name the name too.
describeArg :: Pattern -> Text -> Text
describeArg arg key = case bare arg of
  PatternName n -> nameText n <> " (of type " <> key <> ")"
  _ -> key

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
