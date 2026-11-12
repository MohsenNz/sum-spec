{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A resolved model of a spec: every name it defines, what each one is,
-- and how a path such as @Page.Plan.Draft@ resolves.
--
-- The checker reads the spec through it: facts about the spec live
-- here, judgements and their messages in "SumSpec.Check". The rule for a
-- name after a dot is 'step', the one place it is written: the checker
-- follows it, reporting a 'StepError' in its own words. The rest of the model is lenient. It is built from any spec,
-- one that doesn't type-check or that holds only the definitions that
-- parsed; 'resolvePath' tries more when 'step' finds nothing, and keeps a
-- name that doesn't resolve as 'RefUnknown'. When a name is defined
-- twice (an error the checker reports), the first definition wins. The
-- language server and code generators read the spec through it.
module SumSpec.Model
  ( Model (..)
  , TypeInfo (..)
  , TypeShape (..)
  , VariantInfo (..)
  , EventInfo (..)
  , Ref (..)
  , StepError (..)
  , Here
  , model
  , typeShape
  , typeBodyOf
  , isType
  , underlying
  , step
  , steps
  , variantsAt
  , variantEntry
  , resolvePath
  , resolveFrom
  , variantOwnerPath
  , variantPath
  , renderModel
  ) where

import Data.Foldable (toList)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as M
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Set qualified as S
import Data.Text (Text)
import Data.Text qualified as T
import SumSpec.Syntax

data Model = Model
  { modelAtomics :: Map Text Atomic
  -- ^ The types declared in @__atomics@.
  , modelTypeDefs :: Map Text TypeDef
  -- ^ The types defined with @T = ...@.
  , modelTypes :: Map Text TypeInfo
  -- ^ Every type: the atomics, then the definitions. A name that is
  -- both is the atomic.
  , modelVariants :: Map Text [VariantInfo]
  -- ^ Every variant by its name, inline payloads included, in source
  -- order. A name may belong to several sums.
  , modelConsts :: Map Text ConstDef
  , modelEvents :: Map Text EventInfo
  -- ^ The events defined, whether listed in @__events@ or not.
  , modelAnnotations :: Map Text Name
  -- ^ The annotations declared in @__annotations@.
  , modelRoot :: Maybe Name
  -- ^ The head of the first @__init@, the type of every state.
  }

data TypeInfo = TypeInfo
  { typeInfoName :: Name
  , typeInfoShape :: TypeShape
  , typeInfoAnnotations :: [Annotation]
  , typeInfoBody :: Maybe TypeExpr
  -- ^ 'Nothing' for an atomic.
  }

-- | What kind of type a type is.
data TypeShape
  = ShapeAtomic (Maybe Primitive)
  | ShapeSum [Variant]
  | ShapeProduct [Factor]
  | -- | @T = A@: another name for @A@.
    ShapeNewtype Name
  | -- | @T = [A]@ or @T = [A by K]@.
    ShapeList TypeTerm (Maybe Name)

data VariantInfo = VariantInfo
  { variantInfo :: Variant
  , variantOwner :: Name
  -- ^ The type whose definition holds the variant.
  , variantParents :: [Name]
  -- ^ The variants it is nested in, outermost first: @[Landed]@ for
  -- @Spot@ in @Flying = Landed (Spot | Field)@.
  }

data EventInfo = EventInfo
  { eventInfo :: Event
  , eventListed :: Bool
  -- ^ Whether @__events@ lists it.
  }

-- | What a name in a path refers to.
data Ref
  = RefType Name
  | RefVariant VariantInfo
  | RefConst ConstDef
  | RefUnknown

-- | The type a path is at: the body of a named type, or an inline
-- payload. 'Nothing' when it isn't known, or is an atomic.
type Here = Maybe TypeExpr

model :: Spec -> Model
model spec =
  Model
    { modelAtomics = atomics
    , modelTypeDefs = typeDefs
    , modelTypes =
        M.union
          (M.map atomicInfo atomics)
          (M.map defInfo typeDefs)
    , modelVariants =
        M.fromListWith
          (flip (<>))
          [ (nameText (variantName (variantInfo v)), [v])
          | DefType t <- defs
          , v <- nested (typeDefName t) [] (typeDefBody t)
          ]
    , modelConsts = firsts constName [c | DefConst c <- defs]
    , modelEvents =
        firsts
          (eventName . eventInfo)
          [EventInfo e (nameText (eventName e) `S.member` listed) | DefEvent e <- defs]
    , modelAnnotations = firsts id (fromMaybe [] (specAnnotations spec))
    , modelRoot = listToMaybe [headName p | DefInit _ p <- defs]
    }
  where
    defs = specDefinitions spec
    atomics = firsts atomicName (specAtomics spec)
    typeDefs = firsts typeDefName [t | DefType t <- defs]
    listed = S.fromList (map nameText (specEvents spec))
    atomicInfo a = TypeInfo (atomicName a) (ShapeAtomic (atomicBase a)) [] Nothing
    defInfo t =
      TypeInfo
        (typeDefName t)
        (typeShape (typeDefBody t))
        (typeDefAnnotations t)
        (Just (typeDefBody t))
    nested owner parents = \case
      TypeSum vs ->
        concat
          [ VariantInfo v owner parents
              : maybe [] (nested owner (parents <> [variantName v])) (variantPayload v)
          | v <- vs
          ]
      _ -> []
    headName = \case
      PatternPath (h :| _) _ -> h
      PatternElement (h :| _) _ _ -> h
      PatternAlts (h :| _) _ -> h
      PatternNamed p _ -> headName p
      PatternPrimed _ p -> headName p
      PatternList t _ -> termHead t
      PatternName n -> n
      PatternBound n -> n
      PatternExpr e -> exprHead e
    termHead = \case
      TermName n -> n
      TermList t _ -> termHead t
    exprHead = \case
      ExprName n -> n
      ExprConst n -> n
      ExprLit pos _ -> Name pos ""
      ExprBin _ _ a _ -> exprHead a

-- | The first entry for each name.
firsts :: (a -> Name) -> [a] -> Map Text a
firsts key xs = M.fromListWith (\_ old -> old) [(nameText (key x), x) | x <- xs]

typeShape :: TypeExpr -> TypeShape
typeShape = \case
  TypeSum vs -> ShapeSum vs
  TypeProduct fs -> ShapeProduct fs
  TypeTerm (TermName n) -> ShapeNewtype n
  TypeTerm (TermList t key) -> ShapeList t key

-- | The body of the type with this name; 'Nothing' for an atomic or an
-- unknown name.
typeBodyOf :: Model -> Name -> Here
typeBodyOf m n = M.lookup (nameText n) (modelTypes m) >>= typeInfoBody

-- | Whether a type of this name is declared or defined. A constant is not
-- a type.
isType :: Model -> Text -> Bool
isType m n = M.member n (modelTypes m)

-- | The type a name stands for once newtypes (@T = A@) are followed: the
-- first type on the way that isn't a newtype. 'Nothing' for an unknown
-- name, or for newtypes that lead back to one already seen.
underlying :: Model -> Text -> Maybe TypeInfo
underlying m = go S.empty
  where
    go seen n
      | n `S.member` seen = Nothing
      | otherwise = case M.lookup n (modelTypes m) of
          Just TypeInfo {typeInfoShape = ShapeNewtype next} ->
            go (S.insert n seen) (nameText next)
          t -> t

-- | Why a name after a dot is not a variant where the path is.
data StepError
  = -- | The path is at a sum with no variant of that name.
    NotAVariant
  | -- | The path is at a newtype of this sum (@T = S@). It carries the
    -- sum's variants but has none of its own: they're written @T(S.V)@.
    NewtypeOfSum Name
  | -- | The path is at a type without variants: a product, a list, an
    -- atomic, a newtype of one of those, or a variant without a payload.
    NoVariants

-- | The language's rule for a name after a dot: a variant of the sum the
-- path is at, and nothing else. After it, the path is at the variant's
-- payload. The checker reports a 'StepError' in its own words; the
-- lenient 'resolveFrom' tries more on one.
step :: Model -> Here -> Name -> Either StepError (VariantInfo, Here)
step m here n = case here of
  Just (TypeSum vs) -> case find ((== nameText n) . nameText . variantName) vs of
    Just v -> Right (variantEntry m v, variantPayload v)
    Nothing -> Left NotAVariant
  Just (TypeTerm (TermName base))
    | Just (TypeSum _) <- typeDefBody <$> M.lookup (nameText base) (modelTypeDefs m) ->
        Left (NewtypeOfSum base)
  _ -> Left NoVariants

-- | 'step' along the names after a dot, from where the path is; the first
-- that is not a variant there stops it.
steps :: Model -> Here -> [Name] -> Either (Name, StepError) Here
steps _ here [] = Right here
steps m here (n : ns) = case step m here n of
  Right (_, here') -> steps m here' ns
  Left err -> Left (n, err)

-- | The variants a name after a dot may be, by 'step': those of the sum
-- the path is at. Empty when it isn't at a sum.
variantsAt :: Model -> Here -> [VariantInfo]
variantsAt m = \case
  Just (TypeSum vs) -> map (variantEntry m) vs
  _ -> []

-- | The model's entry for a variant of the spec: the same name at the
-- same place.
variantEntry :: Model -> Variant -> VariantInfo
variantEntry m v =
  fromMaybe (VariantInfo v (variantName v) []) $
    find
      ((== variantName v) . variantName . variantInfo)
      (M.findWithDefault [] (nameText (variantName v)) (modelVariants m))

-- | Resolves a path from left to right, leniently, so that a path the
-- checker rejects still finds what it most likely means. The head is a
-- type, else a constant, else the one variant with that name in the
-- spec; each later name is resolved by 'resolveFrom'. Gives what each
-- name refers to, and the type the whole path is at.
resolvePath :: Model -> NonEmpty Name -> ([(Name, Ref)], Here)
resolvePath m (h :| rest) = ((h, ref) : refs, here')
  where
    (ref, here) = case M.lookup (nameText h) (modelTypes m) of
      Just t -> (RefType (typeInfoName t), typeInfoBody t)
      Nothing -> case M.lookup (nameText h) (modelConsts m) of
        Just c -> (RefConst c, Nothing)
        Nothing -> case uniqueVariant m h of
          Just v -> (RefVariant v, variantPayload (variantInfo v))
          Nothing -> (RefUnknown, Nothing)
    (refs, here') = resolveFrom m here rest

-- | Resolves the names after a dot, leniently. Each one is what 'step'
-- finds; when that is nothing, a variant of the sum behind newtypes
-- (@T = S@, a few at most, as they may form a cycle); else a type of that
-- name; else the one variant with that name in the spec. After a
-- variant, the path is at its payload.
resolveFrom :: Model -> Here -> [Name] -> ([(Name, Ref)], Here)
resolveFrom _ here [] = ([], here)
resolveFrom m here (n : ns) = ((n, ref) : refs, here'')
  where
    (ref, here') = case step m here n of
      Right (v, payload) -> (RefVariant v, payload)
      Left _ -> case find ((== nameText n) . variantText) (behindNewtypes here) of
        Just v -> (RefVariant v, variantPayload (variantInfo v))
        Nothing -> case M.lookup (nameText n) (modelTypes m) of
          Just t -> (RefType (typeInfoName t), typeInfoBody t)
          Nothing -> case uniqueVariant m n of
            Just v -> (RefVariant v, variantPayload (variantInfo v))
            Nothing -> (RefUnknown, Nothing)
    (refs, here'') = resolveFrom m here' ns
    behindNewtypes = \case
      Just (TypeTerm (TermName t)) -> variantsAt m (underlying m (nameText t) >>= typeInfoBody)
      _ -> []

variantText :: VariantInfo -> Text
variantText = nameText . variantName . variantInfo

uniqueVariant :: Model -> Name -> Maybe VariantInfo
uniqueVariant m n = case M.lookup (nameText n) (modelVariants m) of
  Just [v] -> Just v
  _ -> Nothing

-- | The path of the sum a variant belongs to: @Flying.Landed@ for @Spot@
-- in @Flying = Landed (Spot | Field)@.
variantOwnerPath :: VariantInfo -> Text
variantOwnerPath v = T.intercalate "." (map nameText (variantOwner v : variantParents v))

-- | The path of a variant: @Flying.Landed.Spot@ for @Spot@ in
-- @Flying = Landed (Spot | Field)@.
variantPath :: VariantInfo -> Text
variantPath v = variantOwnerPath v <> "." <> variantText v

-- | The model as text, one entry per line: for tests, and to read.
renderModel :: Model -> Text
renderModel m =
  T.unlines $
    ["types"]
      <> [ "  " <> name <> " : " <> shape (typeInfoShape t)
         | (name, t) <- M.toList (modelTypes m)
         ]
      <> ["variants"]
      <> [ "  " <> name <> " : " <> variantOwnerPath v
         | (name, vs) <- M.toList (modelVariants m)
         , v <- vs
         ]
      <> ["constants"]
      <> [ "  " <> name <> " : " <> nameText (constType c)
         | (name, c) <- M.toList (modelConsts m)
         ]
      <> ["events"]
      <> [ "  "
             <> name
             <> " : "
             <> count
               (sum (map (length . transitionBranches) (toList (eventTransitions (eventInfo e)))))
             <> (if eventListed e then "" else ", not listed")
         | (name, e) <- M.toList (modelEvents m)
         ]
      <> ["annotations"]
      <> ["  @" <> name | name <- M.keys (modelAnnotations m)]
      <> ["root " <> maybe "none" nameText (modelRoot m)]
  where
    shape = \case
      ShapeAtomic base -> "atomic" <> maybe "" ((" " <>) . primitiveWord) base
      ShapeSum vs -> "sum of " <> T.intercalate ", " (map (nameText . variantName) vs)
      ShapeProduct fs -> "product of " <> T.intercalate ", " (map (term . factorTerm) fs)
      ShapeNewtype n -> "newtype of " <> nameText n
      ShapeList t key -> "list of " <> term t <> maybe "" ((" by " <>) . nameText) key
    term = \case
      TermName n -> nameText n
      TermList t key -> "[" <> term t <> maybe "" ((" by " <>) . nameText) key <> "]"
    count k = T.pack (show k) <> if k == 1 then " transition" else " transitions"
