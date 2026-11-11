{-# LANGUAGE OverloadedStrings #-}

-- | Prints an AST back as SumSpec source in a canonical layout: one
-- definition per line, single spaces around operators, and parentheses
-- only around payloads that are sums or products.
--
-- Parsing the output gives the same AST again, apart from positions.
module SumSpec.Pretty
  ( renderSpec
  , renderLiteral
  , renderArith
  , renderValue
  ) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as T
import SumSpec.Syntax
import SumSpec.Version (renderVersion)

renderSpec :: Spec -> Text
renderSpec (Spec version atomics events annotations defs) =
  T.unlines $
    maybe [] (\v -> ["__version " <> T.pack (renderVersion v), ""]) version
      <> block "__atomics" (map renderAtomic atomics)
      <> [""]
      <> block "__events" (map nameText events)
      <> [""]
      <> maybe
        []
        (\ns -> block "__annotations" (map (("@" <>) . nameText) ns) <> [""])
        annotations
      <> map renderDefinition defs
  where
    block keyword names =
      [keyword <> " {"] <> map ("  " <>) names <> ["}"]

renderAtomic :: Atomic -> Text
renderAtomic (Atomic name base) =
  nameText name <> maybe "" ((" = " <>) . primitiveWord) base

renderDefinition :: Definition -> Text
renderDefinition = \case
  DefType (TypeDef name notes body) ->
    nameText name <> renderAnnotations notes <> " = " <> renderTypeExpr body
  DefConst (ConstDef name ty value) ->
    nameText name <> " = " <> nameText ty <> case value of
      ConstLiteral _ lit -> "(" <> renderLiteral lit <> ")"
      ConstVariant v -> "." <> nameText v
  DefEvent (Event name input transitions) ->
    heading
      <> T.intercalate
        indent
        (map renderTransition (NE.toList transitions))
    where
      heading = nameText name <> maybe "" ((" " <>) . renderPattern) input <> " "
      indent = "\n" <> T.replicate (T.length heading) " "
      -- One branch goes on the line of its shared paths; several go one
      -- per line, each @=>@ under the @::@.
      renderTransition (Transition paths branches) = case (paths, branches) of
        ([], b :| _) -> ":: " <> renderBranch b
        (_, b :| []) -> ":: " <> shared <> " => " <> renderBranch b
        _ ->
          ":: "
            <> shared
            <> T.concat [indent <> "=> " <> renderBranch b | b <- NE.toList branches]
        where
          shared = T.intercalate " / " (map renderShared paths)
      renderBranch (Branch from guard to notes) =
        renderSide from
          <> maybe "" ((" // " <>) . renderGuard) guard
          <> " -> "
          <> renderSide to
          <> renderAnnotations notes
      renderSide = renderArguments . NE.toList
      renderShared (Shared names key) =
        T.intercalate "." (map nameText (NE.toList names))
          <> maybe "" (\k -> "[" <> nameText k <> "]") key
  DefInit _ p -> "__init :: " <> renderPattern p

-- | A guard with the fewest parentheses its precedence allows: @not@ binds
-- tighter than @and@, and @and@ tighter than @or@.
renderGuard :: Guard -> Text
renderGuard = \case
  GuardOr operands -> T.intercalate " or " (map renderGuard (NE.toList operands))
  guard -> renderConjunct guard
  where
    renderConjunct = \case
      GuardAnd operands -> T.intercalate " and " (map renderNegated (NE.toList operands))
      guard -> renderNegated guard
    renderNegated = \case
      GuardNot inner -> "not " <> renderNegated inner
      GuardPattern p -> renderPattern p
      GuardCompare op l r -> renderOperand l <> " " <> compareWord op <> " " <> renderOperand r
      GuardIn l ys -> renderOperand l <> " in " <> nameText ys
      guard -> "(" <> renderGuard guard <> ")"

renderOperand :: Operand -> Text
renderOperand = \case
  OperandName name -> nameText name
  OperandLiteral _ lit -> renderLiteral lit
  OperandVariant names -> T.intercalate "." (map nameText (NE.toList names))

renderLiteral :: Literal -> Text
renderLiteral = \case
  LitInt n -> T.pack (show n)
  LitDecimal text -> text
  LitText text -> "\"" <> text <> "\""

renderTypeExpr :: TypeExpr -> Text
renderTypeExpr = \case
  TypeSum variants -> T.intercalate " | " (map renderVariant variants)
  TypeProduct factors -> T.intercalate " * " (map renderFactor factors)
  TypeTerm term -> renderTerm term

renderVariant :: Variant -> Text
renderVariant (Variant name p notes) =
  nameText name <> maybe "" ((" " <>) . renderPayload) p <> renderAnnotations notes
  where
    renderPayload = \case
      TypeTerm term -> renderTerm term
      expr -> "(" <> renderTypeExpr expr <> ")"

renderFactor :: Factor -> Text
renderFactor (Factor term notes) = renderTerm term <> renderAnnotations notes

-- | Annotations after what they belong to, each with a space before it.
-- They go on one line: the arguments stop at the same characters when
-- they're read back.
renderAnnotations :: [Annotation] -> Text
renderAnnotations = T.concat . map render
  where
    render (Annotation name args) =
      " @" <> nameText name <> (if T.null args then "" else " " <> args)

renderTerm :: TypeTerm -> Text
renderTerm = \case
  TermName name -> nameText name
  TermList term key -> renderList term key

-- | @[T]@, or @[T by K]@ for a keyed list.
renderList :: TypeTerm -> Maybe Name -> Text
renderList term key = "[" <> renderTerm term <> maybe "" ((" by " <>) . nameText) key <> "]"

renderPattern :: Pattern -> Text
renderPattern = \case
  PatternPath names args ->
    renderPath names <> renderArgs args
  PatternElement names key args ->
    renderPath names <> "[" <> nameText key <> "]" <> renderArgs args
  PatternList term key -> renderList term key
  PatternName name -> nameText name
  PatternNamed p name -> renderPattern p <> "#" <> nameText name
  PatternBound name -> "#" <> nameText name
  PatternAlts names alts ->
    renderPath names
      <> ".{"
      <> T.intercalate " | " (map renderPattern (NE.toList alts))
      <> "}"
  PatternPrimed _ p -> renderPattern p <> "'"
  PatternExpr e -> renderArith e
  where
    renderPath = T.intercalate "." . map nameText . NE.toList
    renderArgs [] = ""
    renderArgs args = "(" <> renderArguments args <> ")"

-- | Arguments joined by "*". Beside other arguments, a computed value is
-- written in parentheses, so its "+" and "-" don't read as joining them.
renderArguments :: [Pattern] -> Text
renderArguments = \case
  [arg] -> renderPattern arg
  args -> T.intercalate " * " (map factor args)
  where
    factor = \case
      PatternExpr e@ExprBin {} -> "(" <> renderExpr 0 e <> ")"
      p -> renderPattern p

-- | An expression where a pattern goes, with the parentheses its
-- structure needs. A multiplication at the top is kept in parentheses:
-- without them, @n * 2@ there is read as two arguments, which the checker
-- reads as a multiplication only under a head that holds one value.
renderArith :: Expr -> Text
renderArith = \case
  e@(ExprBin OpMul _ _ _) -> "(" <> renderExpr 0 e <> ")"
  e -> renderExpr 0 e

-- | An expression on its own, as in a message: @n * 2@.
renderValue :: Expr -> Text
renderValue = renderExpr 0

-- | An expression, with the parentheses its structure needs: "*" binds tighter than "+" and "-", and both group from the
-- left, so a right operand of the same precedence is parenthesized.
renderExpr :: Int -> Expr -> Text
renderExpr outer = \case
  ExprName n -> nameText n
  ExprLit _ lit -> renderLiteral lit
  ExprConst c -> nameText c
  ExprBin op _ left right ->
    let
      p = precedence op
      body = renderExpr p left <> " " <> arithWord op <> " " <> renderExpr (p + 1) right
    in
      if p < outer then "(" <> body <> ")" else body
  where
    precedence = \case
      OpMul -> 7
      _ -> 6
