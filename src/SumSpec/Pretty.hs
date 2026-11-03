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
      <> block "__atomics" atomics
      <> [""]
      <> block "__events" events
      <> [""]
      <> map renderDefinition defs
  where
    block keyword names =
      [keyword <> " {"] <> map (("  " <>) . nameText) names <> ["}"]

renderDefinition :: Definition -> Text
renderDefinition = \case
  DefType (TypeDef name body) -> nameText name <> " = " <> renderTypeExpr body
  DefTransition (Transition name input from to) ->
    nameText name
      <> maybe "" ((" " <>) . renderPattern) input
      <> " :: "
      <> renderPattern from
      <> " -> "
      <> renderPattern to

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
