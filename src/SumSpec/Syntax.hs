{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The abstract syntax of SumSpec v1 (see spec/grammar.ebnf).
--
-- The AST is what the parser produces and the type checker consumes.
-- Every name carries the position where it was written, so the checker
-- can report errors at the right place.
module SumSpec.Syntax
  ( Spec (..)
  , Definition (..)
  , TypeDef (..)
  , ConstDef (..)
  , ConstValue (..)
  , TypeExpr (..)
  , Atomic (..)
  , Primitive (..)
  , primitiveWord
  , Variant (..)
  , TypeTerm (..)
  , Factor (..)
  , Annotation (..)
  , Event (..)
  , Transition (..)
  , Branch (..)
  , Guard (..)
  , CompareOp (..)
  , compareWord
  , Operand (..)
  , Literal (..)
  , Expr (..)
  , ArithOp (..)
  , arithWord
  , Shared (..)
  , ElementKey (..)
  , keyName
  , keyList
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
  , specAtomics :: [Atomic]
  -- ^ Types declared in @__atomics { ... }@.
  , specEvents :: [Name]
  -- ^ Names declared in @__events { ... }@.
  , specAnnotations :: Maybe [Name]
  -- ^ Names declared in @__annotations { ... }@, without the @\@@;
  -- 'Nothing' without the block.
  , specDefinitions :: [Definition]
  }
  deriving stock (Eq, Show)

data Definition
  = DefType TypeDef
  | DefEvent Event
  | -- | @__init :: P@: the initial state, @P@. Its head type is the root,
    -- the type of every state. The name is the @__init@ keyword, for its
    -- position.
    DefInit Name Pattern
  | -- | @T = A(15)@ or @T = A.B@: a named constant.
    DefConst ConstDef
  deriving stock (Eq, Show)

-- | @T = expr@
data TypeDef = TypeDef
  { typeDefName :: Name
  , typeDefAnnotations :: [Annotation]
  -- ^ The annotations of the type: after its name (@T \@a = ...@), or
  -- after the body of a newtype or a list (@T = A \@a@).
  , typeDefBody :: TypeExpr
  }
  deriving stock (Eq, Show)

-- | @C = T(literal)@ or @C = T.V@: a named constant, a fixed value with a
-- name. Its type is @T@. It is a value, not a type: a side of a
-- comparison in a guard.
data ConstDef = ConstDef
  { constName :: Name
  , constType :: Name
  , constValue :: ConstValue
  }
  deriving stock (Eq, Show)

data ConstValue
  = -- | @T(15)@: a literal, with the position it starts at.
    ConstLiteral SourcePos Literal
  | -- | @T.V@: the variant @V@ of the sum @T@.
    ConstVariant Name
  deriving stock (Eq, Show)

data TypeExpr
  = -- | @V1 | V2 A | ...@, at least two variants.
    TypeSum [Variant]
  | -- | @A * B * ...@, at least two factors.
    TypeProduct [Factor]
  | -- | A single term: a newtype (@T = A@) or a list (@T = [A]@).
    TypeTerm TypeTerm
  deriving stock (Eq, Show)

-- | A type declared in @__atomics@: a leaf with no members. @Port = __int@
-- gives it a base, the kind of value it holds; a bare name is opaque and
-- each target supplies it.
data Atomic = Atomic
  { atomicName :: Name
  , atomicBase :: Maybe Primitive
  }
  deriving stock (Eq, Show)

-- | The built-in base types, written @__int@, @__float@ and @__text@.
data Primitive = PrimInt | PrimFloat | PrimText
  deriving stock (Bounded, Enum, Eq, Show)

-- | How a primitive is written in a spec.
primitiveWord :: Primitive -> Text
primitiveWord = \case
  PrimInt -> "__int"
  PrimFloat -> "__float"
  PrimText -> "__text"

-- | @V@ or @V payload@. A payload written in parentheses is any type
-- expression; a bare payload is a 'TypeTerm'.
data Variant = Variant
  { variantName :: Name
  , variantPayload :: Maybe TypeExpr
  , variantAnnotations :: [Annotation]
  -- ^ The annotations after the variant and its payload.
  }
  deriving stock (Eq, Show)

-- | A factor of a product, with the annotations after it.
data Factor = Factor
  { factorTerm :: TypeTerm
  , factorAnnotations :: [Annotation]
  }
  deriving stock (Eq, Show)

-- | @\@name args@: metadata for the target. SumSpec checks only that the
-- name is declared in @__annotations@; the arguments are opaque text.
data Annotation = Annotation
  { annotationName :: Name
  -- ^ The name without the @\@@, at the position of the @\@@.
  , annotationArgs :: Text
  -- ^ The arguments as written, with comments dropped, each run of
  -- whitespace made one space, and no space at the ends. Empty when
  -- there are none.
  }
  deriving stock (Eq, Show)

data TypeTerm
  = TermName Name
  | -- | @[T]@, or @[T by K]@ with the key type @K@: a list whose elements
    -- are identified by a unique key, which isn't part of the element. The
    -- checker allows a list only as the whole body of a type definition.
    TermList TypeTerm (Maybe Name)
  deriving stock (Eq, Show)

-- | @t X :: from -> to :: from -> to ...@: the event @t@, its optional
-- input @X@, and its transitions, in order. An event is defined once.
data Event = Event
  { eventName :: Name
  , eventInput :: Maybe Pattern
  -- ^ The input, @X@: a pattern headed by a type, never a 'PatternName'.
  -- Its names are visible in every transition.
  , eventTransitions :: NonEmpty Transition
  }
  deriving stock (Eq, Show)

-- | @:: from -> to@, or shared paths and their branches: what one @::@
-- writes. @:: S1 / S2 => a * b -> c => d -> e@ is two transitions,
-- @S1(S2(a * b)) -> S1(S2(c))@ and @S1(S2(d)) -> S1(S2(e))@.
data Transition = Transition
  { transitionShared :: [Shared]
  -- ^ The paths written once after @::@, outermost first.
  , transitionBranches :: NonEmpty Branch
  -- ^ One branch per transition, each after @=>@. Without a shared path
  -- there is exactly one.
  }
  deriving stock (Eq, Show)

-- | One transition under the shared paths of a 'Transition'.
data Branch = Branch
  { branchFrom :: NonEmpty Pattern
  -- ^ The source. Without a shared path it is one pattern; after one,
  -- it is the arguments of the innermost shared path.
  , branchGuard :: Maybe Guard
  -- ^ The condition after @//@, before @->@: the transition applies only
  -- while it holds.
  , branchTo :: NonEmpty Pattern
  -- ^ The target, written like the source.
  , branchAnnotations :: [Annotation]
  -- ^ The annotations after the target.
  }
  deriving stock (Eq, Show)

-- | A condition on the current state, built from patterns. An 'And' or an
-- 'Or' has at least two operands.
data Guard
  = -- | The current state matches this pattern. The checker requires it to
    -- be headed by the root type.
    GuardPattern Pattern
  | -- | @left op right@: a comparison of two values. See 'Operand'.
    GuardCompare CompareOp Operand Operand
  | -- | @x in ys@: the value @x@ is in the list named @ys@.
    GuardIn Operand Name
  | GuardNot Guard
  | GuardAnd (NonEmpty Guard)
  | GuardOr (NonEmpty Guard)
  deriving stock (Eq, Show)

data CompareOp = OpEq | OpNe | OpLt | OpLe | OpGt | OpGe
  deriving stock (Eq, Show)

-- | How a comparison operator is written.
compareWord :: CompareOp -> Text
compareWord = \case
  OpEq -> "=="
  OpNe -> "!="
  OpLt -> "<"
  OpLe -> "<="
  OpGt -> ">"
  OpGe -> ">="

-- | One side of a comparison.
data Operand
  = -- | @x@: a value named in the input or on the source side.
    OperandName Name
  | -- | A literal, with the position it starts at.
    OperandLiteral SourcePos Literal
  | -- | @Type.Variant@: a variant of a sum without payloads.
    OperandVariant (NonEmpty Name)
  deriving stock (Eq, Show)

data Literal
  = LitInt Integer
  | -- | A decimal, as written (@1.50@ stays @1.50@).
    LitDecimal Text
  | -- | A string, without the quotes.
    LitText Text
  deriving stock (Eq, Show)

-- | A value computed in a target: names the transition binds, literals,
-- named constants, and @+ - *@. Parentheses aren't kept; the printer
-- writes those the structure needs.
data Expr
  = -- | @x@: a value named in the input or on the source side.
    ExprName Name
  | -- | A literal, with the position it starts at.
    ExprLit SourcePos Literal
  | -- | @C@: a named constant.
    ExprConst Name
  | -- | @a op b@, with the position of the operator.
    ExprBin ArithOp SourcePos Expr Expr
  deriving stock (Eq, Show)

data ArithOp = OpAdd | OpSub | OpMul
  deriving stock (Eq, Show)

-- | How an arithmetic operator is written.
arithWord :: ArithOp -> Text
arithWord = \case
  OpAdd -> "+"
  OpSub -> "-"
  OpMul -> "*"

-- | @P =>@ or @L[x] =>@: a path, with an optional element key, that both
-- sides of a transition share. It takes no arguments, prime or naming.
data Shared = Shared (NonEmpty Name) (Maybe ElementKey)
  deriving stock (Eq, Show)

-- | What is in the brackets of an element path.
data ElementKey
  = -- | @L[x]@: the one element whose key is the named value @x@.
    KeyOne Name
  | -- | @L[#x in xs]@: every element whose key is in the list @xs@, each
    -- of which must match; @x@ names the key of each.
    KeyIn Name Name
  | -- | @L[#x]@: each element that matches; the others keep their
    -- values. @x@ names the key of each.
    KeyEach Name
  deriving stock (Eq, Show)

-- | The name in the brackets: @x@ in @[x]@, @[#x in xs]@ and @[#x]@.
keyName :: ElementKey -> Name
keyName = \case
  KeyOne x -> x
  KeyIn x _ -> x
  KeyEach u -> u

-- | @xs@ in @[#x in xs]@.
keyList :: ElementKey -> Maybe Name
keyList = \case
  KeyIn _ xs -> Just xs
  _ -> Nothing

data Pattern
  = -- | A path such as @Page.Plan@, with the arguments written in
    -- parentheses after it. No parentheses means no arguments.
    PatternPath (NonEmpty Name) [Pattern]
  | -- | @L[x]@: the element of the keyed list type @L@ whose key equals
    -- the named value @x@, with the element's arguments after it; or
    -- @L[#x in xs]@, each element whose key is in @xs@; or @L[#x]@, each
    -- element that matches. The path is the list type; the checker
    -- allows only one name.
    PatternElement (NonEmpty Name) ElementKey [Pattern]
  | -- | @[T]@ or @[T by K]@: any list of that type. The parser reads it;
    -- the checker reports it, since a list is written by its type name.
    PatternList TypeTerm (Maybe Name)
  | -- | @x@: the value named @x@ in this transition.
    PatternName Name
  | -- | @P#x@: matches @P@ and names its value @x@. The name is the one
    -- after the @#@.
    PatternNamed Pattern Name
  | -- | @#x@, the whole argument of @Head(#x)@: names the one value inside
    -- @Head@ without writing its type. The checker reads it as the explicit
    -- @Head(T#x)@.
    PatternBound Name
  | -- | @S.{A | B(...)}@: the sum at the path @S@ is one of these
    -- variants. Each alternative is written from @S@: a path with its
    -- arguments, or more alternatives (@Flying.{X | Y}@ for an inline
    -- payload). There are at least two. The checker expands a source into
    -- one transition per alternative, and a guard pattern into an @or@.
    PatternAlts (NonEmpty Name) (NonEmpty Pattern)
  | -- | A pattern followed by a prime, @A'@: a new value, set by the
    -- transition. The position is the prime's. The parser accepts a prime
    -- after any pattern; the checker allows it only on a bare type name on
    -- the target side.
    PatternPrimed SourcePos Pattern
  | -- | A value computed by the transition, such as @n + 1@ or @0@. The
    -- parser gives a lone name as 'PatternName', never as an expression.
    -- The checker allows it only on the target side and in @__init@.
    PatternExpr Expr
  deriving stock (Eq, Show)

-- | An identifier and where it was written.
data Name = Name
  { namePos :: SourcePos
  , nameText :: Text
  }
  deriving stock (Eq, Show)
