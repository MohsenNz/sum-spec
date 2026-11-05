{-# LANGUAGE OverloadedStrings #-}

-- | Prints an AST back as SumSpec source in a canonical layout: one
-- definition per line, single spaces around operators, and parentheses
-- only around payloads that are sums or products.
--
-- Parsing the output gives the same AST again, apart from positions.
module SumSpec.Pretty
  ( renderSpec
  ) where

import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as T
import SumSpec.Syntax
import SumSpec.Version (renderVersion)

renderSpec :: Spec -> Text
renderSpec (Spec version atomics events defs) =
  T.unlines $
    maybe [] (\v -> ["__version " <> T.pack (renderVersion v), ""]) version
      <> block "__atomics" (map renderAtomic atomics)
      <> [""]
      <> block "__events" (map nameText events)
      <> [""]
      <> map renderDefinition defs
  where
    block keyword names =
      [keyword <> " {"] <> map ("  " <>) names <> ["}"]

renderAtomic :: Atomic -> Text
renderAtomic (Atomic name base) =
  nameText name <> maybe "" ((" = " <>) . primitiveWord) base

renderDefinition :: Definition -> Text
renderDefinition = \case
  DefType (TypeDef name body) -> nameText name <> " = " <> renderTypeExpr body
  DefEvent (Event name input transitions) ->
    heading
      <> T.intercalate
        ("\n" <> T.replicate (T.length heading) " ")
        (map renderTransition (NE.toList transitions))
    where
      heading = nameText name <> maybe "" ((" " <>) . renderPattern) input <> " "
      renderTransition (Transition paths from guard to) =
        ":: "
          <> T.concat [renderShared p <> " => " | p <- paths]
          <> renderSide from
          <> maybe "" ((" // " <>) . renderGuard) guard
          <> " -> "
          <> renderSide to
      renderSide = T.intercalate " * " . map renderPattern . NE.toList
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
      guard -> "(" <> renderGuard guard <> ")"

renderTypeExpr :: TypeExpr -> Text
renderTypeExpr = \case
  TypeSum variants -> T.intercalate " | " (map renderVariant variants)
  TypeProduct terms -> T.intercalate " * " (map renderTerm terms)
  TypeTerm term -> renderTerm term

renderVariant :: Variant -> Text
renderVariant (Variant name p) = nameText name <> maybe "" ((" " <>) . renderPayload) p
  where
    renderPayload = \case
      TypeTerm term -> renderTerm term
      expr -> "(" <> renderTypeExpr expr <> ")"

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
  PatternPrimed _ p -> renderPattern p <> "'"
  where
    renderPath = T.intercalate "." . map nameText . NE.toList
    renderArgs [] = ""
    renderArgs args = "(" <> T.intercalate " * " (map renderPattern args) <> ")"
