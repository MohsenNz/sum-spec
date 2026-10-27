-- | The abstract syntax of SumSpec v1 (see spec/grammar.ebnf).
--
-- The AST is what the parser produces and the type checker consumes.
-- Every name carries the position where it was written, so the checker
-- can report errors at the right place.
module SumSpec.Syntax
  ( Spec (..)
  , Definition (..)
  , TypeDef (..)
  , TypeExpr (..)
  , Variant (..)
  , TypeTerm (..)
  , Transition (..)
  , Pattern (..)
  , Name (..)
  ) where

import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Text.Megaparsec (SourcePos)

-- | A whole spec: the two header blocks, then the definitions in source order.
data Spec = Spec
  { specAtomics :: [Name]
  -- ^ Names declared in @__atomics { ... }@.
  , specTxs :: [Name]
  -- ^ Names declared in @__txs { ... }@.
  , specDefinitions :: [Definition]
  }
  deriving stock (Eq, Show)

data Definition
  = DefType TypeDef
  | DefTransition Transition
  deriving stock (Eq, Show)

-- | @T = expr@
data TypeDef = TypeDef
  { typeDefName :: Name
  , typeDefBody :: TypeExpr
  }
  deriving stock (Eq, Show)

data TypeExpr
  = -- | @V1 | V2 A | ...@, at least two variants.
    TypeSum [Variant]
  | -- | @A * B * ...@, at least two factors.
    TypeProduct [TypeTerm]
  | -- | A single term: a newtype (@T = A@) or a list (@T = [A]@).
    TypeTerm TypeTerm
  deriving stock (Eq, Show)

-- | @V@ or @V payload@. A payload written in parentheses is any type
-- expression; a bare payload is a 'TypeTerm'.
data Variant = Variant
  { variantName :: Name
  , variantPayload :: Maybe TypeExpr
  }
  deriving stock (Eq, Show)

data TypeTerm
  = TermName Name
  | -- | @[T]@
    TermList TypeTerm
  deriving stock (Eq, Show)

-- | @t :: from -> to@
data Transition = Transition
  { transitionName :: Name
  , transitionFrom :: Pattern
  , transitionTo :: Pattern
  }
  deriving stock (Eq, Show)

data Pattern
  = -- | A path such as @Page.Plan@, with the arguments written in
    -- parentheses after it. No parentheses means no arguments.
    PatternPath (NonEmpty Name) [Pattern]
  | -- | @[T]@: any list of @T@.
    PatternList TypeTerm
  deriving stock (Eq, Show)

-- | An identifier and where it was written.
data Name = Name
  { namePos :: SourcePos
  , nameText :: Text
  }
  deriving stock (Eq, Show)
