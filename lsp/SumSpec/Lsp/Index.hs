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
  , occurrencesWith
  , occurrenceAt
  , symbols
  ) where

import Data.Foldable (toList)
import Data.List (find, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as M
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Language.LSP.Protocol.Types
  ( DocumentSymbol (..)
  , Position (..)
  , Range (..)
  , SymbolKind (..)
  )
import SumSpec.Lsp.Position (inRange, nameRange, sourcePosition, utf16)
import SumSpec.Model
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

-- | Every name in the spec, in source order.
occurrences :: Spec -> [Occurrence]
occurrences spec = occurrencesWith (model spec) spec

-- | 'occurrences', with the spec's model already built.
occurrencesWith :: Model -> Spec -> [Occurrence]
occurrencesWith env spec =
  sortOn (position . occName) $
    [define KType (atomicName a) | a <- specAtomics spec]
      <> [ use KEvent n (eventName . eventInfo <$> M.lookup (nameText n) (modelEvents env))
         | n <- specEvents spec
         ]
      <> [define KAnnotation n | n <- fromMaybe [] (specAnnotations spec)]
      <> concatMap (definition env) (specDefinitions spec)
  where
    position p = (sourceLine (namePos p), sourceColumn (namePos p))

-- | The occurrence under the cursor, if any.
occurrenceAt :: Text -> Position -> [Occurrence] -> Maybe Occurrence
occurrenceAt source cursor =
  find (inRange cursor . nameRange source . occName)

define :: Kind -> Name -> Occurrence
define kind n = Occurrence n kind True (Just n)

use :: Kind -> Name -> Maybe Name -> Occurrence
use kind n = Occurrence n kind False

definition :: Model -> Definition -> [Occurrence]
definition env = \case
  DefType (TypeDef n annotations body) ->
    define KType n : map (annotation env) annotations <> typeExpr env body
  DefConst (ConstDef n t constant) ->
    define KConst n
      : typeUse env t
      : case constant of
        ConstLiteral _ _ -> []
        ConstVariant v -> fst (segments env (typeBodyOf env t) [v])
  DefInit _ p -> pattern env [] p
  DefEvent (Event n input transitions) ->
    define KEvent n
      : maybe [] (pattern env []) input
        <> concatMap (transition env inputs) transitions
    where
      inputs = maybe [] (bindings env) input

typeExpr :: Model -> TypeExpr -> [Occurrence]
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

term :: Model -> TypeTerm -> [Occurrence]
term env = \case
  TermName n -> [typeUse env n]
  TermList t key -> term env t <> map (typeUse env) (toList key)

typeUse :: Model -> Name -> Occurrence
typeUse env n = use KType n (typeInfoName <$> M.lookup (nameText n) (modelTypes env))

annotation :: Model -> Annotation -> Occurrence
annotation env (Annotation n _) =
  use KAnnotation n (M.lookup (nameText n) (modelAnnotations env))

-- | The names a transition can use: the input's, then each source's.
type Scope = [Name]

value :: Scope -> Name -> Occurrence
value scope n = use KValue n (find ((== nameText n) . nameText) scope)

-- | The values a pattern names, in order.
bindings :: Model -> Pattern -> [Name]
bindings env p = [occName o | o <- pattern env [] p, occKind o == KValue, occDefinition o]

transition :: Model -> Scope -> Transition -> [Occurrence]
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

guardOcc :: Model -> Scope -> Guard -> [Occurrence]
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

expr :: Model -> Scope -> Expr -> [Occurrence]
expr env scope = \case
  ExprName n -> [value scope n]
  ExprLit _ _ -> []
  ExprConst n -> [use KConst n (constName <$> M.lookup (nameText n) (modelConsts env))]
  ExprBin _ _ a b -> expr env scope a <> expr env scope b

pattern :: Model -> Scope -> Pattern -> [Occurrence]
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
alternative :: Model -> Scope -> Here -> Pattern -> [Occurrence]
alternative env scope here = \case
  PatternPath p args -> fst (segments env here (toList p)) <> concatMap (pattern env scope) args
  PatternAlts p alts ->
    let (os, here') = segments env here (toList p)
    in  os <> concatMap (alternative env scope here') alts
  PatternNamed p x -> alternative env scope here p <> [define KValue x]
  PatternPrimed _ p -> alternative env scope here p
  p -> pattern env scope p

-- | The occurrences of a path, and the type it is at (see 'resolvePath').
-- A head that doesn't resolve is taken for a type; a later name, for a
-- variant.
path :: Model -> NonEmpty Name -> ([Occurrence], Here)
path env p = case resolvePath env p of
  (h : rest, here) -> (refOcc KType h : map (refOcc KVariant) rest, here)
  ([], here) -> ([], here)

segments :: Model -> Here -> [Name] -> ([Occurrence], Here)
segments env here ns =
  let (refs, here') = resolveFrom env here ns in (map (refOcc KVariant) refs, here')

refOcc :: Kind -> (Name, Ref) -> Occurrence
refOcc unknown (n, ref) = case ref of
  RefType d -> use KType n (Just d)
  RefVariant v -> use KVariant n (Just (variantName (variantInfo v)))
  RefConst c -> use KConst n (Just (constName c))
  RefUnknown -> use unknown n Nothing

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
