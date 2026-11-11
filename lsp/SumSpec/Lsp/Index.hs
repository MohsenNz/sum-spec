{-# LANGUAGE LambdaCase #-}

-- | Every name written in a spec, what it names and where that is
-- defined: the index behind the outline, go to definition, references
-- and semantic highlighting.
--
-- It works on a spec that may not type-check, or that holds only the
-- definitions that parsed, so a name that doesn't resolve is kept, with
-- no target.
module SumSpec.Lsp.Index
  ( Kind (..)
  , Occurrence (..)
  , occurrences
  , occurrenceAt
  , symbols
  ) where

import Data.Foldable (toList)
import Data.List (find, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as M
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Language.LSP.Protocol.Types
  ( DocumentSymbol (..)
  , Position (..)
  , Range (..)
  , SymbolKind (..)
  )
import SumSpec.Lsp.Position (inRange, nameRange, sourcePosition, utf16)
import SumSpec.Syntax
import Text.Megaparsec (SourcePos (..), unPos)

-- | What a name names.
data Kind
  = KType
  | KVariant
  | KEvent
  | KAnnotation
  | -- | A named constant.
    KConst
  | -- | A value named in a transition: @#x@, and the @x@ that uses it.
    KValue
  deriving stock (Eq, Show)

-- | A name as written in the spec.
data Occurrence = Occurrence
  { occName :: Name
  , occKind :: Kind
  , occDefinition :: Bool
  -- ^ Whether this is where the name is defined.
  , occTarget :: Maybe Name
  -- ^ The name where it is defined (itself, for a definition), or
  -- 'Nothing' when it doesn't resolve.
  }
  deriving stock (Eq, Show)

-- | The names a spec defines, by text. When a name is defined twice (an
-- error the checker reports), the first one wins.
data Env = Env
  { envTypes :: Map Text (Name, Maybe TypeExpr)
  -- ^ Every type, with its body; an atomic has none.
  , envConsts :: Map Text Name
  , envVariants :: Map Text [(Name, Maybe TypeExpr)]
  -- ^ Every variant, inline payloads included, with its payload.
  , envEvents :: Map Text Name
  , envAnnotations :: Map Text Name
  }

environment :: Spec -> Env
environment spec =
  Env
    { envTypes =
        firsts $
          [(atomicName a, (atomicName a, Nothing)) | a <- specAtomics spec]
            <> [(typeDefName t, (typeDefName t, Just (typeDefBody t))) | DefType t <- defs]
    , envConsts = firsts [(constName c, constName c) | DefConst c <- defs]
    , envVariants =
        M.fromListWith
          (flip (<>))
          [ (nameText (variantName v), [(variantName v, variantPayload v)])
          | DefType t <- defs
          , v <- variants (typeDefBody t)
          ]
    , envEvents = firsts [(eventName e, eventName e) | DefEvent e <- defs]
    , envAnnotations = firsts [(n, n) | n <- fromMaybe [] (specAnnotations spec)]
    }
  where
    defs = specDefinitions spec
    firsts entries = M.fromListWith (\_ old -> old) [(nameText n, x) | (n, x) <- entries]
    variants = \case
      TypeSum vs -> concatMap (\v -> v : maybe [] variants (variantPayload v)) vs
      _ -> []

-- | Every name in the spec, in source order.
occurrences :: Spec -> [Occurrence]
occurrences spec =
  sortOn (position . occName) $
    [define KType (atomicName a) | a <- specAtomics spec]
      <> [use KEvent n (M.lookup (nameText n) (envEvents env)) | n <- specEvents spec]
      <> [define KAnnotation n | n <- fromMaybe [] (specAnnotations spec)]
      <> concatMap (definition env) (specDefinitions spec)
  where
    env = environment spec
    position p = (sourceLine (namePos p), sourceColumn (namePos p))

-- | The occurrence under the cursor, if any.
occurrenceAt :: Text -> Position -> [Occurrence] -> Maybe Occurrence
occurrenceAt source cursor =
  find (inRange cursor . nameRange source . occName)

define :: Kind -> Name -> Occurrence
define kind n = Occurrence n kind True (Just n)

use :: Kind -> Name -> Maybe Name -> Occurrence
use kind n = Occurrence n kind False

definition :: Env -> Definition -> [Occurrence]
definition env = \case
  DefType (TypeDef n annotations body) ->
    define KType n : map (annotation env) annotations <> typeExpr env body
  DefConst (ConstDef n t constant) ->
    define KConst n
      : typeUse env t
      : case constant of
        ConstLiteral _ _ -> []
        ConstVariant v -> [fst (segment env (typeBody env t) v)]
  DefInit _ p -> pattern env [] p
  DefEvent (Event n input transitions) ->
    define KEvent n
      : maybe [] (pattern env []) input
        <> concatMap (transition env inputs) transitions
    where
      inputs = maybe [] (bindings env) input

typeExpr :: Env -> TypeExpr -> [Occurrence]
typeExpr env = \case
  TypeSum vs ->
    concat
      [ define KVariant (variantName v)
          : maybe [] (typeExpr env) (variantPayload v)
            <> map (annotation env) (variantAnnotations v)
      | v <- vs
      ]
  TypeProduct fs ->
    concat
      [ term env (factorTerm f) <> map (annotation env) (factorAnnotations f)
      | f <- fs
      ]
  TypeTerm t -> term env t

term :: Env -> TypeTerm -> [Occurrence]
term env = \case
  TermName n -> [typeUse env n]
  TermList t key -> term env t <> map (typeUse env) (toList key)

typeUse :: Env -> Name -> Occurrence
typeUse env n = use KType n (fst <$> M.lookup (nameText n) (envTypes env))

annotation :: Env -> Annotation -> Occurrence
annotation env (Annotation n _) =
  use KAnnotation n (M.lookup (nameText n) (envAnnotations env))

-- | The names a transition can use: the input's, then each source's.
type Scope = [Name]

value :: Scope -> Name -> Occurrence
value scope n = use KValue n (find ((== nameText n) . nameText) scope)

-- | The values a pattern names, in order.
bindings :: Env -> Pattern -> [Name]
bindings env p = [occName o | o <- pattern env [] p, occKind o == KValue, occDefinition o]

transition :: Env -> Scope -> Transition -> [Occurrence]
transition env inputs (Transition shared branches) =
  concat [fst (path env p) <> map (value outer) (toList key) | Shared p key <- shared]
    <> concatMap branch branches
  where
    outer = inputs <> concatMap (concatMap (bindings env) . branchFrom) branches
    branch (Branch from guard to annotations) =
      concatMap (pattern env scope) from
        <> maybe [] (guardOcc env scope) guard
        <> concatMap (pattern env scope) to
        <> map (annotation env) annotations
      where
        scope = inputs <> concatMap (bindings env) from

guardOcc :: Env -> Scope -> Guard -> [Occurrence]
guardOcc env scope = \case
  GuardPattern p -> pattern env scope p
  GuardCompare _ a b -> operand a <> operand b
  GuardIn a list -> operand a <> [value scope list]
  GuardNot g -> guardOcc env scope g
  GuardAnd gs -> concatMap (guardOcc env scope) gs
  GuardOr gs -> concatMap (guardOcc env scope) gs
  where
    operand = \case
      OperandName n -> [value scope n]
      OperandLiteral _ _ -> []
      OperandVariant p -> fst (path env p)

expr :: Env -> Scope -> Expr -> [Occurrence]
expr env scope = \case
  ExprName n -> [value scope n]
  ExprLit _ _ -> []
  ExprConst n -> [use KConst n (M.lookup (nameText n) (envConsts env))]
  ExprBin _ _ a b -> expr env scope a <> expr env scope b

pattern :: Env -> Scope -> Pattern -> [Occurrence]
pattern env scope = \case
  PatternPath p args -> fst (path env p) <> concatMap self args
  PatternElement p key args ->
    fst (path env p) <> [value scope key] <> concatMap self args
  PatternList t key -> term env t <> map (typeUse env) (toList key)
  PatternName n -> [value scope n]
  PatternNamed p x -> self p <> [define KValue x]
  PatternBound x -> [define KValue x]
  PatternAlts p alts ->
    let (os, here) = path env p in os <> concatMap (alternative env scope here) alts
  PatternPrimed _ p -> self p
  PatternExpr e -> expr env scope e
  where
    self = pattern env scope

-- | An alternative of @S.{...}@, written from @S@: its path starts at the
-- type @S@ is at. Its arguments are patterns of their own.
alternative :: Env -> Scope -> Here -> Pattern -> [Occurrence]
alternative env scope here = \case
  PatternPath p args -> fst (segments env here (toList p)) <> concatMap (pattern env scope) args
  PatternAlts p alts ->
    let (os, here') = segments env here (toList p)
    in  os <> concatMap (alternative env scope here') alts
  PatternNamed p x -> alternative env scope here p <> [define KValue x]
  PatternPrimed _ p -> alternative env scope here p
  p -> pattern env scope p

-- | The type a path is at: the body of a named type, or an inline payload.
-- 'Nothing' when it isn't known.
type Here = Maybe TypeExpr

typeBody :: Env -> Name -> Here
typeBody env n = M.lookup (nameText n) (envTypes env) >>= snd

-- | Resolves a path from left to right. The head is a type, or a constant
-- when it names one; each later name is resolved by 'segment'.
path :: Env -> NonEmpty Name -> ([Occurrence], Here)
path env (h :| rest) = (o : os, here')
  where
    (o, here) = case M.lookup (nameText h) (envTypes env) of
      Just (d, body) -> (use KType h (Just d), body)
      Nothing -> case M.lookup (nameText h) (envConsts env) of
        Just d -> (use KConst h (Just d), Nothing)
        Nothing -> case uniqueVariant env h of
          Just (d, payload) -> (use KVariant h (Just d), payload)
          Nothing -> (use KType h Nothing, Nothing)
    (os, here') = segments env here rest

segments :: Env -> Here -> [Name] -> ([Occurrence], Here)
segments _ here [] = ([], here)
segments env here (n : ns) = (o : os, here'')
  where
    (o, here') = segment env here n
    (os, here'') = segments env here' ns

-- | A name after a dot: a variant of the sum the path is at; else a type
-- of that name; else the one variant with that name in the spec.
segment :: Env -> Here -> Name -> (Occurrence, Here)
segment env here n =
  case variantOf (10 :: Int) here of
    Just (d, payload) -> (use KVariant n (Just d), payload)
    Nothing -> case M.lookup (nameText n) (envTypes env) of
      Just (d, body) -> (use KType n (Just d), body)
      Nothing -> case uniqueVariant env n of
        Just (d, payload) -> (use KVariant n (Just d), payload)
        Nothing -> (use KVariant n Nothing, Nothing)
  where
    -- Follows newtypes (T = A) to the sum, a few at most, as they may
    -- form a cycle.
    variantOf depth = \case
      Just (TypeSum vs) ->
        listToMaybe
          [ (variantName v, variantPayload v)
          | v <- vs
          , nameText (variantName v) == nameText n
          ]
      Just (TypeTerm (TermName t)) | depth > 0 -> variantOf (depth - 1) (typeBody env t)
      _ -> Nothing

uniqueVariant :: Env -> Name -> Maybe (Name, Maybe TypeExpr)
uniqueVariant env n = case M.lookup (nameText n) (envVariants env) of
  Just [v] -> Just v
  _ -> Nothing

-- | The outline: every atomic and definition, in source order. A sum
-- lists its variants. A definition's range runs from its name to its
-- last line that isn't blank or only a comment.
symbols :: Text -> Spec -> [DocumentSymbol]
symbols source spec =
  [ symbol
      SymbolKind_TypeParameter
      (atomicName a)
      (nameRange source (atomicName a))
      Nothing
  | a <- specAtomics spec
  ]
    <> zipWith outline defs (map Just (drop 1 starts) <> [Nothing])
  where
    defs = specDefinitions spec
    starts = map (namePos . defName) defs
    sourceLines = T.lines source
    outline d next = case d of
      DefType t ->
        symbol
          (typeKind (typeDefBody t))
          (typeDefName t)
          (full (typeDefName t) next)
          (variantSymbols (typeDefBody t))
      DefConst c -> symbol SymbolKind_Constant (constName c) (full (constName c) next) Nothing
      DefEvent e -> symbol SymbolKind_Event (eventName e) (full (eventName e) next) Nothing
      DefInit n _ -> symbol SymbolKind_Constructor n (full n next) Nothing
    typeKind = \case
      TypeSum _ -> SymbolKind_Enum
      TypeProduct _ -> SymbolKind_Struct
      TypeTerm _ -> SymbolKind_Class
    variantSymbols = \case
      TypeSum vs ->
        Just
          [ symbol
              SymbolKind_EnumMember
              (variantName v)
              (nameRange source (variantName v))
              Nothing
          | v <- vs
          ]
      _ -> Nothing
    full n next = Range (sourcePosition source (namePos n)) (Position lastLine lastChar)
      where
        first = unPos (sourceLine (namePos n)) - 1
        stop = maybe (length sourceLines) (\p -> unPos (sourceLine p) - 1) next
        content l = not (T.null l') && not (T.isPrefixOf (T.pack "--") l')
          where
            l' = T.strip l
        lastLine' =
          maybe first fst $
            find
              (content . snd)
              (reverse (zip [first ..] (take (stop - first) (drop first sourceLines))))
        lastLine = fromIntegral (max first lastLine')
        lastChar = case drop lastLine' sourceLines of
          l : _ -> utf16 l
          [] -> 0
    symbol kind n range children =
      DocumentSymbol
        { _name = nameText n
        , _detail = Nothing
        , _kind = kind
        , _tags = Nothing
        , _deprecated = Nothing
        , _range = range
        , _selectionRange = nameRange source n
        , _children = children
        }

defName :: Definition -> Name
defName = \case
  DefType t -> typeDefName t
  DefConst c -> constName c
  DefEvent e -> eventName e
  DefInit n _ -> n
