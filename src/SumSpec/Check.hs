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
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import SumSpec.Syntax
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
      , checkListPlaces typeDefs transitions
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
checkTerm env term =
  [ unknownType n
  | n <- termName term : termKeys term
  , not (isKnownType env (nameText n))
  ]

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
    <> [ errorAt n ("transition " <> nameText n <> " is listed in __txs but has no signature")
       | n <- firsts nameText (specTxs spec)
       , nameText n `Set.notMember` signed
       ]
    <> concatMap checkSignature transitions
  where
    listed = Set.fromList (map nameText (specTxs spec))
    signed = Set.fromList (map (nameText . transitionName) transitions)
    -- The input is checked like the source: it's what the transition
    -- receives, so it can name values but not give new ones.
    checkSignature (Transition _ input from to) =
      concatMap (checkPrimes Source) input
        <> checkPrimes Source from
        <> checkPrimes Target to
        <> checkNamings input from to
        <> [ errorAt k "an element path goes on the source or target side, not in the input"
           | k <- concatMap elementKeys input
           ]
        -- An element in the input is reported above; its key can't be
        -- named anywhere the input could see it.
        <> concat [checkPattern env names i | i <- maybe [] pure input, null (elementKeys i)]
        <> checkPattern env names from
        <> checkPattern env names to
      where
        names = Map.fromList [(nameText n, k) | (n, k) <- signatureNames input from]

-- | A list goes only as the whole body of a type definition, so every
-- list has a type name (@Points = [Point]@) and is written by it, in
-- patterns as well. A list's element is a type name too (@Row = [Cell]@
-- for a list of lists).
checkListPlaces :: [TypeDef] -> [Transition] -> [CheckError]
checkListPlaces defs transitions =
  concatMap (definitionLists . typeDefBody) defs
    <> concat
      [ concatMap patternLists (maybe [] pure i <> [from, to])
      | Transition _ i from to <- transitions
      ]
  where
    report term = errorAt (termName term)
    definitionLists = \case
      TypeTerm (TermList element _) -> elementLists element
      TypeTerm (TermName _) -> []
      expr -> inlineLists expr
    inlineLists = \case
      TypeSum variants -> concat [inlineLists p | Variant _ (Just p) <- variants]
      TypeProduct terms -> concatMap termLists terms
      TypeTerm term -> termLists term
    termLists = \case
      TermName _ -> []
      term ->
        [ report term $
            "a list goes only as a whole type definition; give it a type name, "
              <> "such as Points = [Point], and write the name here"
        ]
    elementLists = \case
      TermName _ -> []
      term ->
        [ report term $
            "the element of a list is a type name; give the inner list a type name, "
              <> "such as Row = [Cell]"
        ]
    patternLists = \case
      PatternList t key ->
        [ report (TermList t key) $
            "a list isn't written in a pattern; give it a type name, such as "
              <> "Ids = [Id], and write the name (Ids, or Ids#ids to name it)"
        ]
      PatternPath _ args -> concatMap patternLists args
      PatternElement _ _ args -> concatMap patternLists args
      PatternNamed p _ -> patternLists p
      PatternPrimed _ p -> patternLists p
      PatternName _ -> []

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
  -- Naming an element is an error, so it gives no type either.
  PatternNamed p@PatternElement {} _ -> namings p
  PatternNamed p n -> (n, patternKey p) : namings p
  PatternPath _ args -> concatMap namings args
  PatternElement _ _ args -> concatMap namings args
  PatternPrimed _ p -> namings p
  PatternList _ _ -> []
  PatternName _ -> []

-- | The keys of the element paths in a pattern (@id@ in @Todos[id]@).
elementKeys :: Pattern -> [Name]
elementKeys = \case
  PatternElement _ k args -> k : concatMap elementKeys args
  PatternPath _ args -> concatMap elementKeys args
  PatternNamed p _ -> elementKeys p
  PatternPrimed _ p -> elementKeys p
  PatternList _ _ -> []
  PatternName _ -> []

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
    <> [ errorAt n "an element can't be named yet; name its parts instead"
       | (PatternElement {}, n) <- concatMap named (maybe [] pure input <> [from])
       ]
  where
    named = \case
      PatternNamed p n -> (p, n) : named p
      PatternPath _ args -> concatMap named args
      PatternElement _ _ args -> concatMap named args
      PatternPrimed _ p -> named p
      PatternList _ _ -> []
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
        PatternElement names _ _ ->
          [ errorAtPos pos $
              "an element takes no prime ('); prime its parts instead, such as "
                <> nameText (NE.head names)
                <> "[x](A')"
          ]
        _ ->
          [ errorAtPos pos $
              "a prime (') goes only on a bare type name; "
                <> "a written variant or argument already says what the new value is"
          ]
      <> checkPrimes side inner
  PatternPath _ args -> concatMap (checkPrimes side) args
  PatternElement _ _ args -> concatMap (checkPrimes side) args
  PatternNamed p _ -> checkPrimes side p
  PatternList _ _ -> []
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
  PatternList term key -> checkTerm env (TermList term key)
  PatternPath (h :| path) args -> case typeNode env (nameText h) of
    Nothing -> [unknownType h]
    Just node -> walk env names node h path args
  PatternElement (h :| path) key args -> case typeNode env (nameText h) of
    Nothing -> [unknownType h]
    Just node -> checkElement env names node h path key args

-- | Follows the rest of a path from a node, then checks the arguments at
-- its end.
walk :: Env -> Names -> Node -> Name -> [Name] -> [Pattern] -> [CheckError]
walk env names node at path args = case resolve env node at path of
  Left errors -> errors
  Right (end, endAt) -> checkArgs env names end endAt args

-- | Follows the rest of a path from a node, to the node at its end and
-- the last name read. @at@ is the last name read so far, where errors
-- about the node go.
resolve :: Env -> Node -> Name -> [Name] -> Either [CheckError] (Node, Name)
resolve env node at path = case path of
  [] -> Right (node, at)
  v : rest -> case nodeBody node of
    Just (TypeSum variants) ->
      case find ((== nameText v) . nameText . variantName) variants of
        Just (Variant _ payload) ->
          resolve env (Node (nodeLabel node <> "." <> nameText v) payload) v rest
        Nothing -> Left [errorAt v (nameText v <> " is not a variant of " <> nodeLabel node)]
    Just (TypeTerm (TermName base))
      | Just (TypeSum _) <- Map.lookup (nameText base) (envTypes env) ->
          Left
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
      Left
        [ errorAt v (nodeLabel node <> " has no variants, so ." <> nameText v <> " is invalid")
        ]

-- | An element path, @L[x](...)@: @L@ is a keyed list type
-- (@Todos = [Todo by TodoId]@), and @x@ a named value of its key type.
-- The arguments are the element's: its factors when it is a product, or
-- else one argument headed by the element type, as for a variant
-- payload. The path is resolved like any other, but must be a single
-- name: from a variant, the list type is its argument
-- (@Ring.Points(Points[x])@).
checkElement
  :: Env -> Names -> Node -> Name -> [Name] -> Name -> [Pattern] -> [CheckError]
checkElement env names node h path key args = case resolve env node h path of
  Left errors -> errors
  Right (list, at)
    | not (null path) ->
        [ errorAt at $
            "an element path starts at a list type, not at a variant; "
              <> case nodeBody list of
                Just (TypeTerm (TermName base)) ->
                  "write "
                    <> nodeLabel list
                    <> "("
                    <> nameText base
                    <> "["
                    <> nameText key
                    <> "](...))"
                _ -> "write the path to the variant, then the list type as its argument"
        ]
    | Just (TypeTerm (TermList element (Just keyType))) <- nodeBody list ->
        checkKey (nodeLabel list) keyType <> checkElementArgs (nodeLabel list) element at
    | Just (TypeTerm (TermList element Nothing)) <- nodeBody list ->
        [ errorAt at $
            nodeLabel list
              <> " has no key, so ["
              <> nameText key
              <> "] can't pick an element; declare one, such as "
              <> nodeLabel list
              <> " = ["
              <> termKey element
              <> " by "
              <> fromMaybe "Id" (Map.lookup (nameText key) names)
              <> "]"
        ]
    | otherwise ->
        [ errorAt at $
            nodeLabel list
              <> " is not a list type; ["
              <> nameText key
              <> "] picks an element of a keyed list type, such as Todos = [Todo by TodoId]"
        ]
  where
    checkKey label keyType = case Map.lookup (nameText key) names of
      Nothing -> [unknownName key]
      Just k
        | k == nameText keyType -> []
        | otherwise ->
            [ errorAt key $
                nameText key
                  <> " has type "
                  <> k
                  <> ", but the key of "
                  <> label
                  <> " is "
                  <> nameText keyType
            ]
    checkElementArgs label element at = case element of
      TermName e
        | Just (TypeProduct _) <- Map.lookup (nameText e) (envTypes env)
        , Just n <- typeNode env (nameText e) ->
            checkArgs env names n at args
      _ ->
        checkArgs
          env
          names
          (Node ("an element of " <> label) (Just (TypeTerm element)))
          at
          args

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
  -- A list type is written bare, or picks an element with [x]. A list
  -- pattern is reported by 'checkListPlaces', and a name of the list
  -- fits where an inline list was written (also reported there).
  Just (TypeTerm (TermList _ _))
    | any (not . listOrName . bare) args ->
        [ errorAt at $
            nodeLabel node
              <> " is a list type and takes no arguments; pick an element with "
              <> nodeLabel node
              <> "[x](...)"
        ]
    where
      listOrName = \case
        PatternList _ _ -> True
        PatternName _ -> True
        _ -> False
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
  (TermName expected, PatternElement (h :| path) key args)
    | nameText h == nameText expected -> case typeNode env (nameText h) of
        Nothing -> []
        Just node -> checkElement env names node h path key args
  (TermList _ _, PatternList element key)
    | termKey term == termKey (TermList element key) -> []
  _ ->
    [ errorAt (patternHead arg) $
        "expected " <> termKey term <> " here, not " <> patternKey arg
    ]

-- ---------- Warnings ----------

-- | Where a type occurs inside @App@: the lists crossed on the way to it,
-- innermost first, and whether the type is the element of the innermost
-- list itself (@Todo@ in @[Todo]@).
data Place = Place [Crossed] Bool

-- | A list crossed on the way to a type: its element type, the name of
-- the list type when it has one (@Todos@ for @Todos = [Todo]@, but
-- 'Nothing' for an inline @[Todo]@), and its key type when it is keyed.
data Crossed = Crossed Text (Maybe Text) (Maybe Text)
  deriving stock (Eq, Ord)

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
            : maybe [] (goBody (Set.insert visit seen) lists name) (Map.lookup name (envTypes env))
      where
        visit = (name, take 1 lists)
    -- A type defined as a list (@Todos = [Todo]@) names that list.
    goBody seen lists name = \case
      TypeTerm term -> goTerm seen lists (Just name) term
      expr -> goExpr seen lists expr
    goExpr seen lists = \case
      TypeSum variants -> concat [goExpr seen lists p | Variant _ (Just p) <- variants]
      TypeProduct terms -> concatMap (goTerm seen lists Nothing) terms
      TypeTerm term -> goTerm seen lists Nothing term
    goTerm seen lists listName = \case
      TermName n -> goType seen lists False (nameText n)
      TermList element key -> goElement seen (crossed element listName key : lists) element
    goElement seen lists = \case
      TermName n -> goType seen lists True (nameText n)
      TermList element key -> goElement seen (crossed element Nothing key : lists) element
    crossed element listName key = Crossed (termKey element) listName (nameText <$> key)

-- | A transition on a part inside a list element changes one element, but
-- says which only when it picks the element by key: with an element path
-- on a keyed list (@Todos[id](...)@), or, in a list without a key,
-- written from the element, comparing a key with a named value
-- (@Todo(id * ...)@). Warns about the others, once per signature.
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
      Crossed element listName listKey : outer
        | not direct ->
            Just $
              "changes a "
                <> t
                <> " inside one "
                <> element
                <> " of a list, but doesn't say which "
                <> element
                <> "; to pick it, "
                <> pickHint element listName listKey (fromElement element)
        -- An element of a keyed list doesn't hold its key, so it can't be
        -- picked from the element.
        | isJust listKey || not (keyed args) ->
            Just $
              "changes one "
                <> t
                <> " of a list, but doesn't say which; to pick it, "
                <> pickHint element listName listKey (compareKey t)
        | Crossed outerElement outerList outerKey : _ <- outer ->
            Just $
              "picks a "
                <> t
                <> " by key, but not the "
                <> outerElement
                <> " it is in; to pick both, "
                <> case (outerList, outerKey, listName, listKey) of
                  (Just o, Just _, Just l, Just _) ->
                    "use element paths, such as " <> o <> "[x](" <> l <> "[y](...))"
                  _ -> "give both lists a type name and a key, and use element paths"
        | otherwise -> Nothing
      [] -> Nothing
    -- An element path when the list has a type name; otherwise the form
    -- written from the element.
    pickHint element listName listKey fallback = case (listName, listKey) of
      (Just list, Just _) -> "use an element path, such as " <> list <> "[id](...)"
      (Just list, Nothing) ->
        "give "
          <> list
          <> " a key ("
          <> list
          <> " = ["
          <> element
          <> " by Id]) and use an element path, such as "
          <> list
          <> "[id](...)"
      (Nothing, Just _) -> "give the list a type name and use an element path"
      (Nothing, Nothing) -> fallback
    fromElement element = "write the transition from " <> element <> " and " <> compareKey element
    compareKey element = "compare a key with a named value, such as " <> element <> "(id * ...)"
    firstJust = foldr (\m rest -> maybe rest Just m) Nothing

-- | The names a pattern uses (@x@), not the ones it gives (@#x@).
nameUses :: Pattern -> [Name]
nameUses = \case
  PatternName n -> [n]
  PatternNamed p _ -> nameUses p
  PatternPath _ args -> concatMap nameUses args
  PatternElement _ k args -> k : concatMap nameUses args
  PatternPrimed _ p -> nameUses p
  PatternList _ _ -> []

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

lineOf :: Name -> Text
lineOf = T.pack . show . unPos . sourceLine . namePos

-- | The name a type term is built on: @A@ for @A@, @[A]@ and @[[A]]@.
termName :: TypeTerm -> Name
termName = \case
  TermName n -> n
  TermList t _ -> termName t

-- | The key types of the keyed lists in a type term, outermost first.
termKeys :: TypeTerm -> [Name]
termKeys = \case
  TermName _ -> []
  TermList t key -> maybe id (:) key (termKeys t)

-- | How a factor is identified in a product: its type name, or the list
-- type written out (@[A]@, @[A by K]@).
termKey :: TypeTerm -> Text
termKey = \case
  TermName n -> nameText n
  TermList t key -> "[" <> termKey t <> maybe "" ((" by " <>) . nameText) key <> "]"

patternHead :: Pattern -> Name
patternHead = \case
  PatternPath (h :| _) _ -> h
  PatternElement (h :| _) _ _ -> h
  PatternList t _ -> termName t
  PatternPrimed _ p -> patternHead p
  PatternNamed p _ -> patternHead p
  PatternName n -> n

-- | The type a pattern is headed by: its first name, or its list type.
-- A prime or a naming doesn't change it: @A'@ and @A#x@ are headed by
-- @A@. For a name (@x@) it is the name itself; see 'argKey' for its type.
patternKey :: Pattern -> Text
patternKey = \case
  PatternPath (h :| _) _ -> nameText h
  PatternElement (h :| _) _ _ -> nameText h
  PatternList t key -> termKey (TermList t key)
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
