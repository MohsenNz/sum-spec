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
import SumSpec.Version (LanguageVersion)
import Text.Megaparsec (SourcePos)

-- | A whole spec: the optional version header, the two header blocks, then
-- the definitions in source order.
data Spec = Spec
  { specVersion :: Maybe LanguageVersion
  -- ^ The version in @__version 1.0@; 'Nothing' without a header, which
  -- means 'SumSpec.Version.defaultVersion'.
  , specAtomics :: [Name]
  -- ^ Names declared in @__atomics { ... }@.
  , specEvents :: [Name]
  -- ^ Names declared in @__events { ... }@.
  , specDefinitions :: [Definition]
  }
  deriving stock (Eq, Show)

data Definition
  = DefType TypeDef
  | DefTransition Transition
  | -- | @__init :: P@: the initial state, @P@. Its head type is the root,
    -- the type of every state. The name is the @__init@ keyword, for its
    -- position.
    DefInit Name Pattern
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
  | -- | @[T]@, or @[T by K]@ with the key type @K@: a list whose elements
    -- are identified by a unique key, which isn't part of the element. The
    -- checker allows a list only as the whole body of a type definition.
    TermList TypeTerm (Maybe Name)
  deriving stock (Eq, Show)

-- | @t :: from -> to@, or @t X :: from -> to@ with an input: one transition
-- of the event @t@. An event may have several transitions.
data Transition = Transition
  { transitionEvent :: Name
  -- ^ The event's name, @t@.
  , transitionInput :: Maybe Pattern
  -- ^ The input, @X@ in @t X :: ...@: a pattern headed by a type, never a
  -- 'PatternName'.
  , transitionFrom :: Pattern
  , transitionTo :: Pattern
  }
  deriving stock (Eq, Show)

data Pattern
  = -- | A path such as @Page.Plan@, with the arguments written in
    -- parentheses after it. No parentheses means no arguments.
    PatternPath (NonEmpty Name) [Pattern]
  | -- | @L[x]@: the element of the keyed list type @L@ whose key equals
    -- the named value @x@, with the element's arguments after it. The
    -- path is the list type; the checker allows only one name.
    PatternElement (NonEmpty Name) Name [Pattern]
  | -- | @[T]@ or @[T by K]@: any list of that type. The parser reads it;
    -- the checker reports it, since a list is written by its type name.
    PatternList TypeTerm (Maybe Name)
  | -- | @x@: the value named @x@ in this transition.
    PatternName Name
  | -- | @P#x@: matches @P@ and names its value @x@. The name is the one
    -- after the @#@.
    PatternNamed Pattern Name
  | -- | A pattern followed by a prime, @A'@: a new value, set by the
    -- transition. The position is the prime's. The parser accepts a prime
    -- after any pattern; the checker allows it only on a bare type name on
    -- the target side.
    PatternPrimed SourcePos Pattern
  deriving stock (Eq, Show)

-- | An identifier and where it was written.
data Name = Name
  { namePos :: SourcePos
  , nameText :: Text
  }
  deriving stock (Eq, Show)
