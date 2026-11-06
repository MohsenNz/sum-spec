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

import Data.Char (digitToInt, isSpace)
import Data.Containers.ListUtils (nubOrdOn)
import Data.List (elemIndex, find, nub, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing, mapMaybe, maybeToList)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import SumSpec.Pretty (renderLiteral)
import SumSpec.Syntax
import Text.Megaparsec (SourcePos (..), initialPos, mkPos, sourcePosPretty, unPos)

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
-- that have no place in the source, such as a missing @__init@. The source is
-- the text the spec was parsed from, for the warnings about spacing. A
-- transition with shared paths (@=>@) is checked as its expanded form.
checkSpec :: FilePath -> Text -> Spec -> [CheckError]
checkSpec file source spec =
  sortOn (position . errorPos) . nubOrdOn key $
    concat
      [ checkHeaders spec
      , concatMap
          (checkBoundHeads env)
          (map snd rawInits <> concatMap eventPatterns rawEvents)
      , checkInit file env inits
      , checkTypeDefs env typeDefs
      , checkConsts env consts
      , checkEvents env spec events
      , checkTransitions env transitions
      , checkGuards env transitions
      , checkListPlaces typeDefs (map snd inits) transitions
      , warnListElements env root transitions
      , warnReachability env typeDefs (map snd (take 1 inits)) transitions
      , warnOverlaps env transitions
      , warnSuffixSpaces
          source
          ( mapMaybe eventInput rawEvents
              <> concat [[from, to] | Flat _ _ from to _ <- concatMap flatten rawEvents]
          )
      ]
  where
    position pos = (unPos (sourceLine pos), unPos (sourceColumn pos))
    -- A shared path is part of both sides, so a problem in it is found
    -- twice; it is reported once.
    key e = (position (errorPos e), errorSeverity e == Error, errorMessage e)
    typeDefs = [d | DefType d <- specDefinitions spec]
    consts = [c | DefConst c <- specDefinitions spec]
    rawEvents = [e | DefEvent e <- specDefinitions spec]
    rawInits = [(k, p) | DefInit k p <- specDefinitions spec]
    -- Every check but the spacing warning reads @Head(#n)@ as @Head(T#n)@.
    events = map (elaborateEvent env) rawEvents
    transitions = concatMap flatten events
    inits = [(k, elaborate env p) | (k, p) <- rawInits]
    -- The type of every state: the head type of the initial state.
    root = case inits of
      (_, p) : _ | isKnownType env (patternKey p) -> Just (patternKey p)
      _ -> Nothing
    env = mkEnv spec typeDefs consts

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

-- | The declared atomics, the defined types and the named constants. A type
-- or a constant defined twice keeps its first definition; the second is
-- reported as an error.
data Env = Env
  { envAtomics :: Map Text (Maybe Primitive)
  -- ^ The atomics, with the base of each.
  , envTypes :: Map Text TypeExpr
  , envConsts :: Map Text ConstDef
  -- ^ The named constants. They share their names with the types but are
  -- not types: 'isKnownType' does not see them.
  }

mkEnv :: Spec -> [TypeDef] -> [ConstDef] -> Env
mkEnv spec defs consts =
  Env
    { envAtomics =
        Map.fromList [(nameText (atomicName a), atomicBase a) | a <- specAtomics spec]
    , envTypes =
        Map.fromListWith
          (\_ first -> first)
          [(nameText (typeDefName d), typeDefBody d) | d <- defs]
    , envConsts =
        Map.fromListWith
          (\_ first -> first)
          [(nameText (constName c), c) | c <- consts]
    }

isKnownType :: Env -> Text -> Bool
isKnownType env name =
  Map.member name (envAtomics env) || Map.member name (envTypes env)

-- ---------- Headers and the initial state ----------

checkHeaders :: Spec -> [CheckError]
checkHeaders spec =
  [ errorAt n (nameText n <> " is listed twice in __atomics")
  | (n, _) <- repeats nameText (map atomicName (specAtomics spec))
  ]
    <> [ errorAt n (nameText n <> " is listed twice in __events")
       | (n, _) <- repeats nameText (specEvents spec)
       ]

-- | A spec has exactly one @__init :: P@. @P@ is a whole new state: there's
-- no old value and no input, so nothing in it takes a prime, a naming, a
-- name or an element path. Apart from those it's checked like a target.
-- See "Initial state" in spec-v1.md.
checkInit :: FilePath -> Env -> [(Name, Pattern)] -> [CheckError]
checkInit file env inits = case inits of
  [] ->
    [ errorAtPos
        (initialPos file)
        "no __init; every spec needs an initial state, such as __init :: App"
    ]
  _ ->
    [ errorAt k ("__init is written twice (first on line " <> lineOf first <> ")")
    | ((k, _), (first, _)) <- repeats (const "__init") inits
    ]
      <> concat [initValues p <> plain p | (_, p) <- inits]
  where
    -- A name or an element as the whole state is reported, and not
    -- checked further.
    plain p = case bare p of
      PatternName _ -> []
      PatternElement {} -> []
      q -> checkPattern env Map.empty (withoutValues q)
    initValues = \case
      PatternPrimed pos inner ->
        errorAtPos
          pos
          ( "the initial state has no old value, so nothing in it takes a prime ('); "
              <> "write "
              <> patternKey inner
              <> " without one"
          )
          : initValues inner
      PatternNamed inner n ->
        errorAt
          n
          ("the initial state takes no input, so it names no value; remove #" <> nameText n)
          : initValues inner
      PatternName n ->
        [ errorAt n $
            "the initial state takes no input, so there's no value named "
              <> nameText n
              <> " to use"
        ]
      PatternElement (h :| _) _ _ ->
        [ errorAt h $
            "the initial state takes no input, so an element path can't pick an element; "
              <> "write "
              <> nameText h
        ]
      PatternPath _ args -> concatMap initValues args
      PatternList _ _ -> []
      PatternBound _ -> []
    -- Drops what 'initValues' reports, so it isn't reported again.
    withoutValues = \case
      PatternPath names args ->
        PatternPath names [withoutValues (bare a) | a <- args, keep (bare a)]
      p -> p
    keep = \case
      PatternName _ -> False
      PatternElement {} -> False
      _ -> True

-- ---------- Type definitions ----------

checkTypeDefs :: Env -> [TypeDef] -> [CheckError]
checkTypeDefs env defs =
  [ errorAt n (nameText n <> " is defined twice (first on line " <> lineOf first <> ")")
  | (TypeDef n _, TypeDef first _) <- repeats (nameText . typeDefName) defs
  ]
    <> [ errorAt n (nameText n <> " is declared in __atomics and also defined")
       | TypeDef n _ <- defs
       , Map.member (nameText n) (envAtomics env)
       ]
    <> concatMap (checkTypeExpr env . typeDefBody) defs
    <> mapMaybe (newtypeCycle env) (firsts (nameText . typeDefName) defs)

-- | Named constants: each name is new, its type is known, and its value
-- fits that type.
checkConsts :: Env -> [ConstDef] -> [CheckError]
checkConsts env consts =
  [ errorAt n (nameText n <> " is defined twice (first on line " <> lineOf first <> ")")
  | (ConstDef n _ _, ConstDef first _ _) <- repeats (nameText . constName) consts
  ]
    <> concatMap clash (firsts (nameText . constName) consts)
    <> concatMap checkValue consts
  where
    clash c
      | Map.member (nameText n) (envTypes env) =
          [errorAt n (nameText n <> " is defined as a type and as a constant")]
      | Map.member (nameText n) (envAtomics env) =
          [ errorAt n (nameText n <> " is declared in __atomics and also defined as a constant")
          ]
      | otherwise = []
      where
        n = constName c
    checkValue (ConstDef _ ty value)
      | not (isKnownType env (nameText ty)) = [unknownType env ty]
      | otherwise = case value of
          ConstLiteral pos lit
            | literalFits (kindOf env (nameText ty)) lit -> []
            | otherwise ->
                [ errorAtPos pos $
                    nameText ty
                      <> " is "
                      <> describeKind (kindOf env (nameText ty))
                      <> ", so "
                      <> renderLiteral lit
                      <> " doesn't fit it"
                ]
          ConstVariant v -> case Map.lookup (nameText ty) (envTypes env) of
            Just (TypeSum variants) -> variantRefErrors variants ty v
            _ -> [notAnEnumeration "a constant variant" ty]

-- | Whether a literal fits a value of this kind: an integer an @__int@ or a
-- @__float@, a decimal only a @__float@, a string only a @__text@.
literalFits :: Kind -> Literal -> Bool
literalFits kind = \case
  LitInt _ -> kind `elem` [KInt, KFloat]
  LitDecimal _ -> kind == KFloat
  LitText _ -> kind == KText

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
  [ unknownType env n
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

-- | One transition with its event's name and input (then its source and
-- target): what most checks look at.
data Flat = Flat Name (Maybe Pattern) Pattern Pattern (Maybe Guard)

flatten :: Event -> [Flat]
flatten (Event n input transitions) =
  [ Flat n input (expand paths from) (expand paths to) (expandGuard paths <$> guard)
  | Transition paths from guard to <- NE.toList transitions
  ]

-- | A guard reads where the source's arguments go, so each pattern in it
-- gets the shared paths around it, as the source does: after @App =>@,
-- @Link.Off@ is @App(Link.Off)@.
expandGuard :: [Shared] -> Guard -> Guard
expandGuard paths = \case
  GuardPattern p -> GuardPattern (expand paths (p :| []))
  g@(GuardCompare {}) -> g
  GuardNot g -> GuardNot (expandGuard paths g)
  GuardAnd gs -> GuardAnd (fmap (expandGuard paths) gs)
  GuardOr gs -> GuardOr (fmap (expandGuard paths) gs)

-- | A side of a transition as one pattern: its shared paths put back
-- around it (@S1 => S2 => a * b@ is @S1(S2(a * b))@).
expand :: [Shared] -> NonEmpty Pattern -> Pattern
expand paths side = case reverse paths of
  [] -> NE.head side
  innermost : outer -> foldl (wrap . pure) (wrap (NE.toList side) innermost) outer
  where
    wrap args (Shared names key) =
      maybe (PatternPath names args) (\k -> PatternElement names k args) key

-- | Every event is listed in @__events@ and defined once, with all its
-- transitions; every listed event is defined. The input is checked once
-- per event, like a source: it's what the event brings, so it can name
-- values but not give new ones.
checkEvents :: Env -> Spec -> [Event] -> [CheckError]
checkEvents env spec events =
  [ errorAt n ("event " <> nameText n <> " is not listed in __events")
  | Event n _ _ <- firsts (nameText . eventName) events
  , nameText n `Set.notMember` listed
  ]
    <> [ errorAt n $
           "event "
             <> nameText n
             <> " is defined twice (first on line "
             <> lineOf first
             <> "); write all its transitions under one name, each starting with ::"
       | (Event n _ _, Event first _ _) <- repeats (nameText . eventName) events
       ]
    <> [ errorAt n ("event " <> nameText n <> " is listed in __events but has no transition")
       | n <- firsts nameText (specEvents spec)
       , nameText n `Set.notMember` defined
       ]
    <> concatMap checkInput (mapMaybe eventInput events)
  where
    listed = Set.fromList (map nameText (specEvents spec))
    defined = Set.fromList (map (nameText . eventName) events)
    checkInput input =
      checkPrimes Source input
        <> [ errorAt k "an element path goes on the source or target side, not in the input"
           | k <- elementKeys input
           ]
        -- An element in the input is reported above; its key can't be
        -- named anywhere the input could see it.
        <> [ e
           | null (elementKeys input)
           , e <-
               checkPattern env (Map.fromList [(nameText n, k) | (n, k) <- namings input]) input
           ]

checkTransitions :: Env -> [Flat] -> [CheckError]
checkTransitions env = concatMap checkTransition
  where
    checkTransition (Flat _ input from to _) =
      checkPrimes Source from
        <> checkPrimes Target to
        <> checkNamings input from to
        <> checkPattern env names from
        <> checkPattern env names to
        <> checkSides env names from to
        <> checkNewStatePrimes from to
      where
        names = Map.fromList [(nameText n, k) | (n, k) <- transitionNames input from]

-- | The two sides of a transition are states of the same type: they're
-- headed by the same type name (an element path by its list type). An
-- unknown type or name is reported elsewhere, so it isn't compared. See
-- "Arguments in state patterns" in spec-v1.md.
checkSides :: Env -> Names -> Pattern -> Pattern -> [CheckError]
checkSides env names from to =
  [ errorAt (patternHead to) $
      "the target is a state of "
        <> toKey
        <> ", but the source (line "
        <> lineOf (patternHead from)
        <> ") is a state of "
        <> fromKey
        <> "; both sides of a transition are states of the same type"
  | Just fromKey <- [argKey names from]
  , Just toKey <- [argKey names to]
  , isKnownType env fromKey
  , isKnownType env toKey
  , fromKey /= toKey
  ]

-- | A prime or a naming goes right after the pattern before it (@A'@,
-- @Text#t@). A space there is read the same, so it's only a warning. The
-- AST doesn't keep where the pattern before ends (it may end in @)@), so
-- this looks at the source character before the @'@ or @#@.
warnSuffixSpaces :: Text -> [Pattern] -> [CheckError]
warnSuffixSpaces source patterns =
  [ CheckError Warning pos message
  | p <- patterns
  , (pos, message) <- suffixes p
  , maybe True isSpace (charBefore sourceLines pos)
  ]
  where
    sourceLines = T.lines source
    suffixes = \case
      PatternPrimed pos inner -> (pos, primeMessage inner) : suffixes inner
      PatternNamed inner n -> (hashPos n, namingMessage inner n) : suffixes inner
      PatternPath _ args -> concatMap suffixes args
      PatternElement _ _ args -> concatMap suffixes args
      PatternList _ _ -> []
      PatternName _ -> []
      PatternBound _ -> []
    -- The @#@ is right before the name: no space can go between them.
    hashPos n =
      let pos = namePos n
      in  pos {sourceColumn = mkPos (unPos (sourceColumn pos) - 1)}
    primeMessage = \case
      PatternPath (n :| []) [] ->
        "a prime (') goes right after its name, with no space: write "
          <> nameText n
          <> "'"
      _ -> "a prime (') goes right after the pattern it marks, with no space"
    namingMessage inner n =
      "#"
        <> nameText n
        <> " goes right after the pattern it names, with no space"
        <> case inner of
          PatternPath (h :| []) [] -> ": write " <> nameText h <> "#" <> nameText n
          _ -> ""

-- | The character before a position on its line, or 'Nothing' at the start
-- of the line. Columns are counted as megaparsec counts them, with a tab
-- reaching the next multiple of 8, plus one.
charBefore :: [Text] -> SourcePos -> Maybe Char
charBefore sourceLines pos = case drop (unPos (sourceLine pos) - 1) sourceLines of
  line : _ -> go 1 Nothing (T.unpack line)
  [] -> Nothing
  where
    column = unPos (sourceColumn pos)
    go c previous rest
      | c >= column = previous
      | otherwise = case rest of
          [] -> Nothing
          x : xs -> go (next c x) (Just x) xs
    next c '\t' = ((c - 1) `div` 8 + 1) * 8 + 1
    next c _ = c + 1

-- | Where a part is in a state: the head type, then each variant, argument
-- head and element (@Todos[id]@) on the way down. Products are keyed by
-- type, so a part has the same position on both sides of a transition.
type Position = [Text]

-- | A prime marks a new value of a part that keeps its place, so it
-- doesn't go inside a new state: a variant on the target side that the
-- source doesn't fix. Nothing there has an old value to change. Other
-- misplaced primes are reported by 'checkPrimes', and sides of different
-- types by 'checkSides'. See "Source and target" in spec-v1.md.
checkNewStatePrimes :: Pattern -> Pattern -> [CheckError]
checkNewStatePrimes from to
  | patternKey from /= patternKey to = []
  | otherwise = go [] Nothing to
  where
    fixed = fixedVariants from
    -- @new@ is the enclosing new state, as written (@Page.Plan@).
    go at new = \case
      PatternPrimed pos (PatternPath (n :| []) []) ->
        [ errorAtPos pos $
            label
              <> " is a new state here (the source doesn't fix it), so "
              <> nameText n
              <> " has no old value to change; write "
              <> nameText n
              <> " without a prime ('), or leave it out"
        | Just label <- [new]
        ]
      PatternPrimed _ p -> go at new p
      PatternNamed p _ -> go at new p
      PatternPath (h :| path) args ->
        let
          steps = variantSteps at h path
          new' = case new of
            Just _ -> new
            Nothing -> snd <$> find ((`Set.notMember` fixed) . fst) steps
        in
          concatMap (go (lastPosition at h steps) new') args
      PatternElement (h :| _) key args ->
        concatMap (go (at <> [elementSegment h key]) new) args
      PatternList _ _ -> []
      PatternName _ -> []
      PatternBound _ -> []

-- | The variant positions a pattern writes: each variant of a dotted path,
-- at every depth.
fixedVariants :: Pattern -> Set Position
fixedVariants = go []
  where
    go at = \case
      PatternPath (h :| path) args ->
        let steps = variantSteps at h path
        in  Set.fromList (map fst steps)
              <> foldMap (go (lastPosition at h steps)) args
      PatternElement (h :| _) key args -> foldMap (go (at <> [elementSegment h key])) args
      PatternPrimed _ p -> go at p
      PatternNamed p _ -> go at p
      PatternList _ _ -> Set.empty
      PatternName _ -> Set.empty
      PatternBound _ -> Set.empty

-- | Each variant of the path @h.V1.V2@ at @at@: its position, and the path
-- up to it as written (@h.V1@).
variantSteps :: Position -> Name -> [Name] -> [(Position, Text)]
variantSteps at h path =
  [ ( at <> map nameText (h : vs)
    , T.intercalate "." (map nameText (h : vs))
    )
  | k <- [1 .. length path]
  , let vs = take k path
  ]

-- | The position a path ends at: its last variant, or its head type.
lastPosition :: Position -> Name -> [(Position, Text)] -> Position
lastPosition at h steps = case steps of
  [] -> at <> [nameText h]
  _ -> fst (last steps)

elementSegment :: Name -> Name -> Text
elementSegment h key = nameText h <> "[" <> nameText key <> "]"

-- | A list goes only as the whole body of a type definition, so every
-- list has a type name (@Points = [Point]@) and is written by it, in
-- patterns as well. A list's element is a type name too (@Row = [Cell]@
-- for a list of lists).
checkListPlaces :: [TypeDef] -> [Pattern] -> [Flat] -> [CheckError]
checkListPlaces defs inits transitions =
  concatMap (definitionLists . typeDefBody) defs
    <> concatMap patternLists inits
    <> concat
      [ concatMap patternLists (maybe [] pure i <> [from, to])
      | Flat _ i from to _ <- transitions
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
      PatternBound _ -> []

-- | The names a transition gives, with their types: in its input and on
-- its source side.
transitionNames :: Maybe Pattern -> Pattern -> [(Name, Text)]
transitionNames input from = concatMap namings input <> namings from

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
  PatternBound _ -> []

-- | The keys of the element paths in a pattern (@id@ in @Todos[id]@).
elementKeys :: Pattern -> [Name]
elementKeys = \case
  PatternElement _ k args -> k : concatMap elementKeys args
  PatternPath _ args -> concatMap elementKeys args
  PatternNamed p _ -> elementKeys p
  PatternPrimed _ p -> elementKeys p
  PatternList _ _ -> []
  PatternName _ -> []
  PatternBound _ -> []

-- | Where names may be given: once each, in the input or on the source
-- side, and only to a type pattern. On the target side a name is only
-- used, to set a value.
checkNamings :: Maybe Pattern -> Pattern -> Pattern -> [CheckError]
checkNamings input from to =
  [ errorAt n (nameText n <> " is named twice in this transition")
  | ((n, _), _) <- repeats (nameText . fst) (transitionNames input from)
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

-- | Every @P#x@ in a pattern, as @P@ and @x@.
named :: Pattern -> [(Pattern, Name)]
named = \case
  PatternNamed p n -> (p, n) : named p
  PatternPath _ args -> concatMap named args
  PatternElement _ _ args -> concatMap named args
  PatternPrimed _ p -> named p
  PatternList _ _ -> []
  PatternName _ -> []
  PatternBound _ -> []

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
  PatternBound _ -> []

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
    | Map.member name (envAtomics env) -> Just (Node name Nothing)
    | otherwise -> Nothing

-- ---------- Bare bindings ----------

-- | What @#n@ finds in the parentheses after a head.
data Bound
  = -- | One value, of this type.
    BoundValue Name
  | -- | No single value; the message says why.
    BoundNothing (Name -> Text)
  | -- | The head doesn't resolve, which 'checkPattern' reports.
    BoundUnresolved

-- | What a type or a variant holds. A newtype holds its base, so a newtype
-- of a newtype binds the next value, not the innermost.
nodeBound :: Node -> Bound
nodeBound node = case nodeBody node of
  Just (TypeTerm (TermName base)) -> BoundValue base
  Just (TypeTerm (TermList _ _)) ->
    BoundNothing $ \n ->
      label
        <> " is a list type, so it holds no single value; write "
        <> label
        <> "#"
        <> nameText n
  Just (TypeSum _) ->
    BoundNothing $ \_ ->
      label <> " is a sum, so it holds no single value; pick a variant with \".\""
  Just (TypeProduct factors) ->
    BoundNothing $ \n ->
      label
        <> " holds several parts, so #"
        <> nameText n
        <> " can't bind them; name a part, such as "
        <> label
        <> "("
        <> T.concat (take 1 (map termKey factors))
        <> "#"
        <> nameText n
        <> ")"
  Nothing ->
    BoundNothing $ \n ->
      label <> " holds no value inside it; write " <> label <> "#" <> nameText n
  where
    label = nodeLabel node

-- | What @#n@ finds after a path.
pathBound :: Env -> NonEmpty Name -> Bound
pathBound env (h :| path) = case typeNode env (nameText h) of
  Just node | Right (end, _) <- resolve env node h path -> nodeBound end
  _ -> BoundUnresolved

-- | What @#n@ finds after an element path. Like the arguments of an
-- element (see 'checkElement'), it is a product's factors, or else one
-- value of the element type.
elementBound :: Env -> NonEmpty Name -> Name -> Bound
elementBound env (h :| path) key = case nodeBody <$> typeNode env (nameText h) of
  Just (Just (TypeTerm (TermList element (Just _))))
    | null path -> case element of
        TermName e
          | Just body@(TypeProduct _) <- Map.lookup (nameText e) (envTypes env) ->
              nodeBound (Node label (Just body))
          | otherwise -> BoundValue e
        TermList _ _ -> nodeBound (Node label (Just (TypeTerm element)))
  _ -> BoundUnresolved
  where
    label = nameText h <> "[" <> nameText key <> "]"

-- | Reads @Head(#n)@ as @Head(T#n)@, where @T@ is what @Head@ holds, so no
-- other check needs to know the short form. A head that holds no single
-- value is reported by 'checkBoundHeads'; it becomes @Head#n@, so that @n@
-- is still a name and its uses aren't reported too.
elaborate :: Env -> Pattern -> Pattern
elaborate env = \case
  PatternPath names [PatternBound n] -> case pathBound env names of
    BoundValue base -> PatternPath names [explicit base n]
    _ -> PatternNamed (PatternPath names []) n
  PatternElement names key [PatternBound n] -> case elementBound env names key of
    BoundValue base -> PatternElement names key [explicit base n]
    _ -> PatternElement names key []
  PatternPath names args -> PatternPath names (map (elaborate env) args)
  PatternElement names key args -> PatternElement names key (map (elaborate env) args)
  PatternNamed p n -> PatternNamed (elaborate env p) n
  PatternPrimed pos p -> PatternPrimed pos (elaborate env p)
  p -> p
  where
    explicit base n = PatternNamed (PatternPath (Name (namePos n) (nameText base) :| []) []) n

elaborateEvent :: Env -> Event -> Event
elaborateEvent env event =
  event
    { eventInput = elaborate env <$> eventInput event
    , eventTransitions = transition <$> eventTransitions event
    }
  where
    transition t =
      t
        { transitionFrom = elaborate env <$> transitionFrom t
        , transitionGuard = guard <$> transitionGuard t
        , transitionTo = elaborate env <$> transitionTo t
        }
    guard = \case
      GuardPattern p -> GuardPattern (elaborate env p)
      g@(GuardCompare {}) -> g
      GuardNot g -> GuardNot (guard g)
      GuardAnd gs -> GuardAnd (guard <$> gs)
      GuardOr gs -> GuardOr (guard <$> gs)

-- | Every pattern written in an event.
eventPatterns :: Event -> [Pattern]
eventPatterns (Event _ input transitions) =
  maybeToList input
    <> concat
      [ NE.toList from <> foldMap guardPatterns guard <> NE.toList to
      | Transition _ from guard to <- NE.toList transitions
      ]

-- | @Head(#n)@ needs a head that holds one value.
checkBoundHeads :: Env -> Pattern -> [CheckError]
checkBoundHeads env = \case
  PatternPath names [PatternBound n] -> report n (pathBound env names)
  PatternElement names key [PatternBound n] -> report n (elementBound env names key)
  PatternPath _ args -> concatMap (checkBoundHeads env) args
  PatternElement _ _ args -> concatMap (checkBoundHeads env) args
  PatternNamed p _ -> checkBoundHeads env p
  PatternPrimed _ p -> checkBoundHeads env p
  _ -> []
  where
    report n = \case
      BoundNothing why -> [errorAt n (why n)]
      _ -> []

-- | The names a transition gives, with the type of each.
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
  PatternBound _ -> []
  PatternList term key -> checkTerm env (TermList term key)
  PatternPath (h :| path) args -> case typeNode env (nameText h) of
    Nothing -> [unknownType env h]
    Just node -> walk env names node h path args
  PatternElement (h :| path) key args -> case typeNode env (nameText h) of
    Nothing -> [unknownType env h]
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
           if Map.member key (envConsts env)
             then constantNotType key
             else
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

-- | Where a type occurs inside the root: the lists crossed on the way to it,
-- innermost first, and whether the type is the element of the innermost
-- list itself (@Todo@ in @[Todo]@).
data Place = Place [Crossed] Bool

-- | A list crossed on the way to a type: its element type, the name of
-- the list type when it has one (@Todos@ for @Todos = [Todo]@, but
-- 'Nothing' for an inline @[Todo]@), and its key type when it is keyed.
data Crossed = Crossed Text (Maybe Text) (Maybe Text)
  deriving stock (Eq, Ord)

-- | Every place of every type reachable from the root, the head type of
-- @__init@. A recursive type is followed again on a path only when it is
-- inside another list, so a tree's nodes are found both at the root and
-- inside @[Tree]@.
listPlaces :: Env -> Text -> Map Text [Place]
listPlaces env root =
  Map.fromListWith (flip (<>)) [(t, [p]) | (t, p) <- goType Set.empty [] False root]
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
-- (@Todo(id * ...)@). Warns about the others, once per transition. Without
-- a root (no @__init@), there are no places to warn about.
warnListElements :: Env -> Maybe Text -> [Flat] -> [CheckError]
warnListElements env root transitions =
  [ warningAt h (nameText n <> " " <> message)
  | Flat n _ from _ _ <- transitions
  , PatternPath (h :| _) args <- [bare from]
  , Just message <- [firstJust (map (problem (nameText h) args) (placesOf (nameText h)))]
  ]
  where
    places = maybe Map.empty (listPlaces env) root
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
  PatternBound _ -> []

-- | A variant, named by the type it belongs to and the path to it
-- (@PMode.ShowMission.List@). Variants are named by type, not by where
-- the type occurs, as a transition on a type applies wherever it occurs.
type Label = Text

-- | What a part a pattern leaves out means: on the target side it keeps
-- its value, but inside a new state (and in @__init@) it may have any
-- value.
data Fill = Keeps | AnyValue
  deriving stock (Eq)

-- | The variants and types of a value that may have any value: every
-- variant of the type, and of every type inside it.
anyType :: Env -> Text -> (Set Label, Set Text)
anyType env start = (foldMap labelsOf types, types)
  where
    types = close Set.empty [start]
    close seen = \case
      [] -> seen
      t : rest
        | Set.member t seen -> close seen rest
        | otherwise -> close (Set.insert t seen) (snd (contentsOf t) <> rest)
    labelsOf = Set.fromList . fst . contentsOf
    contentsOf t = maybe ([], []) (exprContents t) (Map.lookup t (envTypes env))

-- | The variants a type expression defines, under the label @prefix@, and
-- the types it names directly.
exprContents :: Label -> TypeExpr -> ([Label], [Text])
exprContents prefix = \case
  TypeSum variants ->
    mconcat
      [ ([label], []) <> maybe mempty (exprContents label) payload
      | Variant n payload <- variants
      , let label = prefix <> "." <> nameText n
      ]
  TypeProduct terms -> ([], concatMap termRefs terms)
  TypeTerm term -> ([], termRefs term)

-- | The types a term names: the type, or a list's element and key types.
termRefs :: TypeTerm -> [Text]
termRefs = \case
  TermName n -> [nameText n]
  TermList t key -> termRefs t <> map nameText (maybe [] pure key)

-- | The variants a pattern may put a value in, and the types it holds.
-- @fixed@ is the source's variant positions, which a target compares with
-- to find new states ('Nothing': nothing is a new state). A primed part, a
-- part left out of a new state, and a name (an input's value, or one
-- already there) may have any value. Errors are reported elsewhere, so a
-- pattern that doesn't fit its type adds nothing.
reach
  :: Env -> Names -> Maybe (Set Position) -> Fill -> Pattern -> (Set Label, Set Text)
reach env names fixed = goPattern []
  where
    goPattern at fill = \case
      PatternPrimed _ p -> anyOf (patternKey p)
      PatternNamed p _ -> goPattern at fill p
      PatternName n -> maybe mempty anyOf (Map.lookup (nameText n) names)
      PatternBound _ -> mempty
      PatternList _ _ -> mempty
      PatternPath (h :| path) args ->
        typeOnly (nameText h)
          <> walkVariants
            at
            fill
            (nameText h)
            (Map.lookup (nameText h) (envTypes env))
            h
            path
            args
      PatternElement (h :| _) key args ->
        typeOnly (nameText h) <> case Map.lookup (nameText h) (envTypes env) of
          Just (TypeTerm (TermList (TermName e) _)) ->
            let body = case Map.lookup (nameText e) (envTypes env) of
                  Just elementBody@(TypeProduct _) -> Just elementBody
                  _ -> Just (TypeTerm (TermName e))
            in  goNode (at <> [elementSegment h key]) fill (nameText e) body args
          _ -> mempty
    -- Follows the variants of the path @h.V1.V2@: each one is reached, and
    -- one the source doesn't fix starts a new state.
    walkVariants at fill label body h rest args = go fill label body [h] rest
      where
        go f l b seen = \case
          [] -> goNode (at <> map nameText seen) f l b args
          v : more -> case b of
            Just (TypeSum variants)
              | Just (Variant _ payload) <- find ((== nameText v) . nameText . variantName) variants ->
                  let
                    l' = l <> "." <> nameText v
                    seen' = seen <> [v]
                    f' = case fixed of
                      Just positions
                        | f == Keeps
                        , (at <> map nameText seen') `Set.notMember` positions ->
                            AnyValue
                      _ -> f
                  in
                    (Set.singleton l', mempty) <> go f' l' payload seen' more
            _ -> mempty
    -- The arguments at the end of a path, and what the left-out parts are.
    goNode at fill label body args = case body of
      Nothing -> mempty
      Just expr@(TypeSum _)
        | null args, fill == AnyValue -> anyExpr label expr
        | otherwise -> mempty
      Just (TypeProduct factors) ->
        let given = Map.fromList [(k, a) | a <- args, Just k <- [argKey names a]]
        in  mconcat
              [ case Map.lookup (termKey factor) given of
                  Just a -> goPattern at fill a
                  Nothing
                    | fill == AnyValue -> foldMap anyOf (termRefs factor)
                    | otherwise -> mempty
              | factor <- factors
              ]
      Just (TypeTerm term) -> case args of
        [a] -> goPattern at fill a
        []
          | fill == AnyValue -> foldMap anyOf (termRefs term)
        _ -> mempty
    anyExpr label expr =
      let (labels, refs) = exprContents label expr
      in  (Set.fromList labels, mempty) <> foldMap anyOf refs
    anyOf = anyType env
    typeOnly t = (mempty, Set.singleton t)

-- | Every variant the app can reach, and every type that holds a value:
-- from @__init@, then each transition on a type that holds a value, and
-- whose source's variants have all been reached, adds what its target
-- may put the app in, until nothing more is added. Parts of a source are
-- tested one by one, and names are ignored, so this may find more than
-- the app can really reach, never less.
reachable :: Env -> Pattern -> [Flat] -> (Set Label, Set Text)
reachable env initial transitions = go (reach env Map.empty Nothing AnyValue initial)
  where
    go found =
      let found' = found <> foldMap fire [t | t <- transitions, enabled found t]
      in  if found' == found then found else go found'
    enabled (labels, live) (Flat _ _ from _ _) =
      patternKey from `Set.member` live
        && sourceVariants env from `Set.isSubsetOf` labels
    fire (Flat _ input from to _) =
      reach
        env
        (Map.fromList [(nameText n, k) | (n, k) <- transitionNames input from])
        (Just (fixedVariants from))
        Keeps
        to

-- | The variants a source writes: a transition can happen only once all
-- of them have been reached.
sourceVariants :: Env -> Pattern -> Set Label
sourceVariants env = fst . reach env Map.empty Nothing Keeps

-- | The warnings found from what the app can reach (see 'reachable'):
--
-- * a variant the app never reaches: neither @__init@ nor a transition
--   that can happen puts it there. Only variants of the types inside the
--   root are reported, and only the outermost one: a variant inside an
--   unreached variant, or of a type that never holds a value, is left
--   out;
-- * a transition that can never happen: its source writes a variant that
--   is never reached (the outermost one is named), or its type never
--   holds a value.
warnReachability :: Env -> [TypeDef] -> [Pattern] -> [Flat] -> [CheckError]
warnReachability env defs inits transitions = case inits of
  [initial]
    | isKnownType env (patternKey initial) ->
        let
          (found, live) = reachable env initial transitions
          (inRoot, _) = anyType env (patternKey initial)
          unreached =
            [ warningAt n $
                label
                  <> " is never reached: neither __init nor any transition that can happen "
                  <> "puts the app there"
            | (label, n, parent) <- variantNames defs
            , label `Set.member` inRoot
            , label `Set.notMember` found
            , maybe (Set.member (T.takeWhile (/= '.') label) live) (`Set.member` found) parent
            ]
          dead =
            [ warningAt (patternHead from) $
                nameText n <> ": this transition can never happen: " <> reason
            | Flat n _ from _ _ <- transitions
            , Just reason <- [whyDead live (sourceVariants env from `Set.difference` found) from]
            ]
        in
          unreached <> dead
  _ -> []
  where
    whyDead live missing from =
      case sortOn (\l -> (T.count "." l, l)) (Set.toList missing) of
        label : _ -> Just ("its source needs " <> label <> ", which is never reached")
        []
          | isKnownType env (patternKey from)
          , patternKey from `Set.notMember` live ->
              Just ("no state holds a value of type " <> patternKey from)
          | otherwise -> Nothing

-- | Every variant defined, with its name and the variant it is inside
-- ('Nothing' for a variant of the type itself).
variantNames :: [TypeDef] -> [(Label, Name, Maybe Label)]
variantNames defs =
  concat
    [ go (nameText n) Nothing body | TypeDef n body <- firsts (nameText . typeDefName) defs
    ]
  where
    go prefix parent = \case
      TypeSum variants ->
        concat
          [ (label, n, parent) : maybe [] (go label (Just label)) payload
          | Variant n payload <- variants
          , let label = prefix <> "." <> nameText n
          ]
      _ -> []

-- | Two transitions of one event on the same type overlap when a state
-- can match both sources: no part of the sources picks different
-- variants. The spec doesn't say which one happens (gap 5 in
-- spec/efsm-gaps.md). Transitions on different types describe effects
-- on different parts, so they aren't compared. Names are ignored, so two
-- element paths are taken to pick the same element. Warns once per
-- transition, naming the first one it overlaps.
warnOverlaps :: Env -> [Flat] -> [CheckError]
warnOverlaps env transitions =
  [ warningAt (patternHead from) $
      nameText n
        <> ": this transition and the one on line "
        <> lineOf (patternHead earlierFrom)
        <> " can apply to the same state, and which one happens isn't said; "
        <> ( if isJust guard || isJust earlierGuard
               then "make their sources or guards exclude each other"
               else "give their sources different variants"
           )
  | (i, t@(Flat n _ from _ guard)) <- indexed
  , Just (Flat _ _ earlierFrom _ earlierGuard) <-
      [find (overlaps t) [e | (j, e) <- indexed, j < i]]
  ]
  where
    indexed = zip [0 :: Int ..] transitions
    overlaps t@(Flat n _ from _ g) u@(Flat m _ other _ h) =
      nameText n == nameText m
        && patternKey from == patternKey other
        && not (excludes (variantsOf from) (variantsOf other))
        && guardsMayHold env (transitionNameMap t, g) (transitionNameMap u, h)
    variantsOf = positionsOf

-- | The variant positions a pattern writes, with an element's key left out:
-- two element paths are taken to pick the same element.
positionsOf :: Pattern -> Set Position
positionsOf = Set.map (map dropKey) . fixedVariants
  where
    dropKey segment = T.takeWhile (/= '[') segment

-- | Two sets of variant positions exclude each other when a variant of one
-- and a variant of the other are at the same place and differ: their
-- positions share all but the last segment.
excludes :: Set Position -> Set Position -> Bool
excludes a b =
  or
    [ init pa == init pb && last pa /= last pb
    | pa <- Set.toList a
    , pb <- Set.toList b
    , not (null pa)
    , not (null pb)
    ]

-- | A guard in disjunctive form is a list of clauses, one of which must
-- hold. A clause holds in a state that has all the variants it requires,
-- matches none of the patterns it forbids (each given by the variants it
-- fixes), and satisfies its comparisons.
data Clause = Clause (Set Position) [Set Position] [Constraint]

-- | A comparison of a named value with a literal or a variant, kept to tell
-- whether two guards can hold together. A value is told apart by its name
-- and its type: two transitions of one event that use the same name with
-- the same type are taken to mean the same value.
data Constraint = Constraint (Text, Text) Domain CompareOp Value

-- | Whether a value has a next one (an integer, a variant) or lies in a
-- continuum.
data Domain = Discrete | Dense
  deriving stock (Eq)

data Value = VNum Rational | VText Text | VIdx Int
  deriving stock (Eq, Ord)

guardClauses :: Env -> Names -> Guard -> [Clause]
guardClauses env names = positive
  where
    positive = \case
      GuardPattern p -> [Clause (positionsOf p) [] []]
      GuardCompare op l r -> [Clause Set.empty [] (constraint op l r)]
      GuardNot g -> negative g
      GuardAnd gs -> foldr1 bothClauses (map positive (NE.toList gs))
      GuardOr gs -> concatMap positive (NE.toList gs)
    -- The clauses of @not g@, by De Morgan. The negation of a comparison is
    -- the opposite comparison.
    negative = \case
      GuardPattern p -> [Clause Set.empty [positionsOf p] []]
      GuardCompare op l r -> [Clause Set.empty [] (constraint (negateOp op) l r)]
      GuardNot g -> positive g
      GuardAnd gs -> concatMap negative (NE.toList gs)
      GuardOr gs -> foldr1 bothClauses (map negative (NE.toList gs))
    constraint op l r = maybeToList (comparisonConstraint env names op l r)

-- | The clauses of @a and b@ from those of @a@ and of @b@.
bothClauses :: [Clause] -> [Clause] -> [Clause]
bothClauses xs ys =
  [Clause (p <> q) (n <> m) (c <> d) | Clause p n c <- xs, Clause q m d <- ys]

negateOp :: CompareOp -> CompareOp
negateOp = \case
  OpEq -> OpNe
  OpNe -> OpEq
  OpLt -> OpGe
  OpLe -> OpGt
  OpGt -> OpLe
  OpGe -> OpLt

-- | The comparison with its sides swapped: @3 < c@ is @c > 3@.
swapOp :: CompareOp -> CompareOp
swapOp = \case
  OpLt -> OpGt
  OpLe -> OpGe
  OpGt -> OpLt
  OpGe -> OpLe
  op -> op

-- | A comparison of a named value with a literal or a variant, as a
-- constraint on that value. Anything else (two names, two literals) is
-- unknown, so it may hold.
comparisonConstraint
  :: Env -> Names -> CompareOp -> Operand -> Operand -> Maybe Constraint
comparisonConstraint env names op l r = case (l, r) of
  (OperandName n, other) -> build n op other
  (other, OperandName n) -> build n (swapOp op) other
  _ -> Nothing
  where
    build n o other = do
      key <- Map.lookup (nameText n) names
      (domain, value) <- operandValue env (kindOf env key) other
      pure (Constraint (nameText n, key) domain o value)

-- | The value a literal or a variant stands for, when it fits the kind of
-- the value it is compared with.
operandValue :: Env -> Kind -> Operand -> Maybe (Domain, Value)
operandValue env kind = \case
  OperandLiteral _ (LitInt i) -> case kind of
    KInt -> Just (Discrete, VNum (fromInteger i))
    KFloat -> Just (Dense, VNum (fromInteger i))
    _ -> Nothing
  OperandLiteral _ (LitDecimal t) -> case kind of
    KFloat -> Just (Dense, VNum (decimalValue t))
    _ -> Nothing
  OperandLiteral _ (LitText t) -> case kind of
    KText -> Just (Discrete, VText t)
    _ -> Nothing
  OperandVariant (h :| [])
    | Just c <- Map.lookup (nameText h) (envConsts env) ->
        operandValue env kind (constOperand c)
  OperandVariant (h :| [v])
    | KEnum <- kind
    , Just (TypeSum variants) <- Map.lookup (nameText h) (envTypes env)
    , Just i <- elemIndex (nameText v) (map (nameText . variantName) variants) ->
        Just (Discrete, VIdx i)
  _ -> Nothing

-- | The value a constant stands for, written as the operand it replaces.
constOperand :: ConstDef -> Operand
constOperand (ConstDef _ ty value) = case value of
  ConstLiteral pos lit -> OperandLiteral pos lit
  ConstVariant v -> OperandVariant (ty :| [v])

-- | The exact value of a decimal literal such as @-1.25@.
decimalValue :: Text -> Rational
decimalValue text =
  sign
    * (fromInteger (digits whole) + fromInteger (digits fraction) / 10 ^ T.length fraction)
  where
    (sign, unsigned) = case T.uncons text of
      Just ('-', rest) -> (-1, rest)
      _ -> (1, text)
    (whole, dotted) = T.breakOn "." unsigned
    fraction = T.drop 1 dotted
    digits = T.foldl' (\acc c -> acc * 10 + toInteger (digitToInt c)) 0

-- | Whether the comparisons can all hold. For each value, the bounds must
-- leave room (strict bounds on integers and variants tighten by one), an
-- equality must lie inside them and differ from every inequality, and two
-- equalities must agree.
consistent :: [Constraint] -> Bool
consistent cs = all holds (Map.elems grouped)
  where
    grouped = Map.fromListWith (<>) [(k, [c]) | c@(Constraint k _ _ _) <- cs]
    holds group = case eqs of
      [v] -> inRange v && v `notElem` nes
      _ : _ : _ -> False
      [] -> not emptyRange && not (excluded group)
      where
        discrete = or [d == Discrete | Constraint _ d _ _ <- group]
        bounds = [tighten discrete op v | Constraint _ _ op v <- group, op `notElem` [OpEq, OpNe]]
        los = [(v, op == OpGt) | (op, v) <- bounds, op `elem` [OpGt, OpGe]]
        his = [(v, op == OpLt) | (op, v) <- bounds, op `elem` [OpLt, OpLe]]
        eqs = nub [v | Constraint _ _ OpEq v <- group]
        nes = [v | Constraint _ _ OpNe v <- group]
        inRange v =
          all (\(l, strict) -> if strict then v > l else v >= l) los
            && all (\(h, strict) -> if strict then v < h else v <= h) his
        emptyRange = case (strongestLow los, strongestHigh his) of
          (Just (l, sl), Just (h, sh)) -> l > h || (l == h && (sl || sh))
          _ -> False
        excluded _ = case (strongestLow los, strongestHigh his) of
          (Just (l, _), Just (h, _))
            | discrete ->
                let vs = between l h
                in  not (null vs)
                      && length (take (length nes + 1) vs) <= length nes
                      && all (`elem` nes) vs
          _ -> False
    -- The strongest lower bound is the largest, and the strongest upper
    -- bound the smallest; at a tie, a strict bound wins.
    strongestLow = strongest (>)
    strongestHigh = strongest (<)
    strongest beats bs = case bs of
      [] -> Nothing
      _ ->
        Just
          . foldr1
            ( \(a, sa) (b, sb) -> if beats a b then (a, sa) else if beats b a then (b, sb) else (a, sa || sb)
            )
          $ bs
    -- A strict bound on a discrete value is the next value, non-strict.
    tighten discrete op v
      | discrete, OpGt <- op = (OpGe, step 1 v)
      | discrete, OpLt <- op = (OpLe, step (-1) v)
      | otherwise = (op, v)
    step n = \case
      VNum r -> VNum (r + n)
      VIdx i -> VIdx (i + round n)
      v -> v
    between a b = case (a, b) of
      (VNum l, VNum h) -> map (VNum . fromInteger) [ceiling l .. floor h]
      (VIdx l, VIdx h) -> map VIdx [l .. h]
      _ -> []

-- | Whether two guards can hold in one state. No guard always holds. Two
-- clauses can hold together unless the variants they require pick
-- different variants of one place, one forbids a pattern whose variants
-- the other already requires, or their comparisons leave no value. It
-- does not notice that several forbidden patterns together can cover every
-- variant of a place, so it may find an overlap that is not one.
guardsMayHold :: Env -> (Names, Maybe Guard) -> (Names, Maybe Guard) -> Bool
guardsMayHold env (names1, g) (names2, h) =
  any satisfiable (bothClauses (clausesOf names1 g) (clausesOf names2 h))
  where
    clausesOf names = maybe [Clause Set.empty [] []] (guardClauses env names)
    satisfiable (Clause p n cs) =
      not (excludes p p) && all (not . (`Set.isSubsetOf` p)) n && consistent cs

-- ---------- Guards ----------

-- | The names a transition can use: the ones its input and its source
-- bind, with the type of each.
transitionNameMap :: Flat -> Names
transitionNameMap (Flat _ input from _ _) =
  Map.fromList [(nameText n, k) | (n, k) <- transitionNames input from]

-- | A guard is read where the source is, so each pattern in it (already
-- expanded with the shared paths, see 'expandGuard') describes the same
-- part of the state as the source: it is headed by the source's type.
-- It may use a name the transition binds (an element path @Files[p]@, a
-- value in a comparison), but binds none. A comparison needs two values of
-- one type, or a value and a literal or variant that fit it. Apart from
-- that it is checked like any pattern. See "Guards" in spec-v1.md.
checkGuards :: Env -> [Flat] -> [CheckError]
checkGuards env transitions =
  concat
    [ concatMap (atom names from) (guardPatterns g)
        <> concatMap (checkPrimes Source) (guardPatterns g)
        <> [ errorAt n $
               "a guard binds no value, so #"
                 <> nameText n
                 <> " names nothing; name the value in the input or on the source side"
           | (_, n) <- concatMap named (guardPatterns g)
           ]
        <> concat [checkComparison env names op l r | (op, l, r) <- guardComparisons g]
    | t@(Flat _ _ from _ (Just g)) <- transitions
    , let names = transitionNameMap t
    ]
  where
    atom names from = \case
      PatternList term _ ->
        [ errorAt (termName term) $
            "a guard describes a state, not a list type; write the name of the list's type"
        ]
      p
        | isKnownType env (patternKey p)
        , isKnownType env (patternKey from)
        , patternKey p /= patternKey from ->
            [ errorAt (patternHead p) $
                "a guard describes the same part of the state as the source, so it starts with "
                  <> patternKey from
                  <> ", not "
                  <> patternKey p
                  <> "; to look at a wider part, start the transition with a shared path "
                  <> "that holds both, as P => ..."
            ]
        | otherwise -> checkPattern env names p

guardPatterns :: Guard -> [Pattern]
guardPatterns = \case
  GuardPattern p -> [p]
  GuardCompare {} -> []
  GuardNot g -> guardPatterns g
  GuardAnd gs -> concatMap guardPatterns (NE.toList gs)
  GuardOr gs -> concatMap guardPatterns (NE.toList gs)

guardComparisons :: Guard -> [(CompareOp, Operand, Operand)]
guardComparisons = \case
  GuardPattern _ -> []
  GuardCompare op l r -> [(op, l, r)]
  GuardNot g -> guardComparisons g
  GuardAnd gs -> concatMap guardComparisons (NE.toList gs)
  GuardOr gs -> concatMap guardComparisons (NE.toList gs)

-- | What a value is, as far as a comparison goes. A type resolves through
-- newtypes to an atomic with a base, to a sum without payloads (an
-- enumeration, ordered by the order of its variants), to an atomic with no
-- base (equality only), or to something that can't be compared.
data Kind = KInt | KFloat | KText | KEnum | KOpaque | KOther
  deriving stock (Eq)

kindOf :: Env -> Text -> Kind
kindOf env = go Set.empty
  where
    go seen name
      | name `Set.member` seen = KOther
      | Just base <- Map.lookup name (envAtomics env) = case base of
          Nothing -> KOpaque
          Just PrimInt -> KInt
          Just PrimFloat -> KFloat
          Just PrimText -> KText
      | otherwise = case Map.lookup name (envTypes env) of
          Just (TypeTerm (TermName next)) -> go (Set.insert name seen) (nameText next)
          Just (TypeSum variants) | all (isNothing . variantPayload) variants -> KEnum
          _ -> KOther

describeKind :: Kind -> Text
describeKind = \case
  KInt -> "an __int"
  KFloat -> "a __float"
  KText -> "a __text"
  KEnum -> "an enumeration"
  KOpaque -> "an atomic with no base"
  KOther -> "neither a number, text nor an enumeration"

-- | One side of a comparison, resolved.
data CmpSide = CmpSide
  { sideAt :: SourcePos
  , sideText :: Text
  -- ^ As written, for messages.
  , sideType :: Maybe Text
  -- ^ The type of a value or of a variant; a literal has none.
  , sideKind :: SideKind
  }

data SideKind = OfType Kind | LiteralInt | LiteralDecimal | LiteralText

resolveSide :: Env -> Names -> Operand -> Either [CheckError] CmpSide
resolveSide env names = \case
  OperandName n -> case Map.lookup (nameText n) names of
    Nothing -> Left [unknownName n]
    Just key -> Right (CmpSide (namePos n) (nameText n) (Just key) (OfType (kindOf env key)))
  OperandLiteral pos lit -> Right $ CmpSide pos (renderLiteral lit) Nothing $ case lit of
    LitInt _ -> LiteralInt
    LitDecimal _ -> LiteralDecimal
    LitText _ -> LiteralText
  OperandVariant (h :| [])
    | Just c <- Map.lookup (nameText h) (envConsts env) ->
        let ty = nameText (constType c)
        in  case kindOf env ty of
              -- An unknown type, or one with no values to compare: the
              -- constant's own definition reports the problem.
              KOther -> Left []
              kind -> Right (CmpSide (namePos h) (nameText h) (Just ty) (OfType kind))
  OperandVariant (h :| rest) -> case (Map.lookup (nameText h) (envTypes env), rest) of
    (Just (TypeSum variants), [v]) -> case variantRefErrors variants h v of
      [] ->
        Right
          ( CmpSide
              (namePos h)
              (nameText h <> "." <> nameText v)
              (Just (nameText h))
              (OfType KEnum)
          )
      errors -> Left errors
    _
      | isKnownType env (nameText h) -> Left [notAnEnumeration "a variant to compare" h]
      | Map.member (nameText h) (envConsts env) ->
          Left [errorAt h (nameText h <> " is a constant, so it has no variants")]
      | otherwise -> Left [unknownType env h]

-- | The problems with @Type.Variant@ used as a value, where @Type@ is a sum:
-- it must have no payload, and the variant must be one of its.
variantRefErrors :: [Variant] -> Name -> Name -> [CheckError]
variantRefErrors variants h v
  | any (isJust . variantPayload) variants =
      [ errorAt
          h
          (nameText h <> " has variants with a payload, so its variants can't be compared")
      ]
  | nameText v `notElem` map (nameText . variantName) variants =
      [errorAt v (nameText v <> " is not a variant of " <> nameText h)]
  | otherwise = []

notAnEnumeration :: Text -> Name -> CheckError
notAnEnumeration what h =
  errorAt h $
    what
      <> " is written Type.Variant, where Type is a sum without payloads; "
      <> nameText h
      <> " is not"

-- | A comparison of two values of one type, or of a value and a literal or
-- variant that fits it. The ordering operators need numbers or an
-- enumeration; @==@ and @!=@ also take text and atomics.
checkComparison :: Env -> Names -> CompareOp -> Operand -> Operand -> [CheckError]
checkComparison env names op l r =
  case (resolveSide env names l, resolveSide env names r) of
    (Left e1, Left e2) -> e1 <> e2
    (Left e, _) -> e
    (_, Left e) -> e
    (Right a, Right b) -> case relate a b of
      [] -> concatMap order [a, b]
      errors -> errors
  where
    ordering = op `elem` [OpLt, OpLe, OpGt, OpGe]
    relate a b = case (sideType a, sideType b) of
      (Just ta, Just tb)
        | ta /= tb ->
            [ errorAtPos (sideAt b) $
                "cannot compare "
                  <> sideText a
                  <> " (a "
                  <> ta
                  <> ") with "
                  <> sideText b
                  <> " (a "
                  <> tb
                  <> "); they are different types"
            ]
      _ -> fits a b <> fits b a
    -- A literal fits a value whose kind has that kind of literal.
    fits typed lit = case (sideKind typed, sideKind lit) of
      (OfType k, LiteralInt) | k `notElem` [KInt, KFloat] -> mismatch typed lit "the integer"
      (OfType k, LiteralDecimal) | k /= KFloat -> mismatch typed lit "the decimal"
      (OfType k, LiteralText) | k /= KText -> mismatch typed lit "the text"
      (LiteralText, LiteralInt) -> literals typed lit
      (LiteralText, LiteralDecimal) -> literals typed lit
      (LiteralInt, LiteralText) -> literals typed lit
      (LiteralDecimal, LiteralText) -> literals typed lit
      _ -> []
    mismatch typed lit what =
      [ errorAtPos (sideAt lit) $
          describeSide typed
            <> ", so it can't be compared with "
            <> what
            <> " "
            <> sideText lit
      ]
    literals a b =
      [errorAtPos (sideAt b) ("cannot compare " <> sideText a <> " with " <> sideText b)]
    order side = case sideKind side of
      OfType k
        | ordering
        , k `notElem` [KInt, KFloat, KEnum] ->
            [ errorAtPos (sideAt side) $
                "ordering needs a number or an enumeration, but " <> describeSide side
            ]
        | k == KOther ->
            [ errorAtPos (sideAt side) $
                describeSide side <> ", which can't be compared"
            ]
      LiteralText
        | ordering ->
            [ errorAtPos
                (sideAt side)
                "ordering needs a number or an enumeration, but this is text"
            ]
      _ -> []
    describeSide side = case (sideType side, sideKind side) of
      (Just ty, OfType k) -> sideText side <> " is a " <> ty <> " (" <> describeKind k <> ")"
      _ -> sideText side

-- ---------- Helpers ----------

errorAt :: Name -> Text -> CheckError
errorAt = errorAtPos . namePos

errorAtPos :: SourcePos -> Text -> CheckError
errorAtPos = CheckError Error

warningAt :: Name -> Text -> CheckError
warningAt = CheckError Warning . namePos

unknownType :: Env -> Name -> CheckError
unknownType env n
  | Map.member (nameText n) (envConsts env) = errorAt n (constantNotType (nameText n))
  | otherwise =
      errorAt n $
        "unknown type " <> nameText n <> "; declare it in __atomics or define it"

constantNotType :: Text -> Text
constantNotType name =
  name <> " is a constant, not a type; it can only be compared in a guard"

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
  PatternBound n -> n

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
  PatternBound n -> nameText n

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
