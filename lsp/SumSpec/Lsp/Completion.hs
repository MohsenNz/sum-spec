{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Completion. The line being typed seldom parses, so what to offer
-- comes from the text before the cursor; the names offered come from the
-- model of the definitions that do parse.
module SumSpec.Lsp.Completion
  ( completions
  ) where

import Data.Char (isAlphaNum)
import Data.List (nub)
import Data.List.NonEmpty (nonEmpty)
import Data.Map.Strict qualified as M
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Language.LSP.Protocol.Types
  ( CompletionItem (..)
  , CompletionItemKind (..)
  , MarkupContent (..)
  , MarkupKind (..)
  , Position (..)
  , type (|?) (..)
  )
import SumSpec.Lsp.Hover (docComment)
import SumSpec.Model
import SumSpec.Syntax
import Text.Megaparsec (initialPos)

-- | What to offer at the cursor.
data Context
  = -- | After @\@@: the declared annotations.
    AfterAt
  | -- | After @P.@: what the path @P@ is at. The names of @P@.
    AfterDot [Text]
  | -- | Inside one of the header blocks, by its keyword.
    InBlock Text
  | -- | A new definition at the start of a line.
    LineStart
  | -- | A type, a constant, or a value of the transition.
    Anywhere
  | -- | In a comment or a string: nothing.
    Nowhere

-- | The completion items at this position of the source.
completions :: Text -> Spec -> Model -> Position -> [CompletionItem]
completions source spec m (Position line character) =
  case context before blocks of
    Nowhere -> []
    AfterAt ->
      [ item CompletionItemKind_Property ("@" <> name) name Nothing (doc n)
      | (name, n) <- M.toList (modelAnnotations m)
      ]
    AfterDot p -> fromMaybe [] $ do
      names <- nonEmpty [Name (initialPos "") t | t <- p]
      let (refs, here) = resolvePath m names
      if any (isUnknown . snd) refs then Nothing else Just (members here)
    InBlock "__events" ->
      [ item CompletionItemKind_Event name name Nothing (doc (eventName (eventInfo e)))
      | (name, e) <- M.toList (modelEvents m)
      , not (eventListed e)
      ]
    InBlock _ -> []
    LineStart ->
      [ item CompletionItemKind_Keyword k k Nothing Nothing
      | k <- ["__init", "__annotations"]
      ]
        <> [ item CompletionItemKind_Event name name (Just "listed in __events") Nothing
           | n <- specEvents spec
           , let name = nameText n
           , name `M.notMember` modelEvents m
           ]
    Anywhere -> types <> constants <> values
  where
    sourceLines = T.lines source
    lineNo = fromIntegral line
    current = fromMaybe "" (lookup lineNo (zip [0 ..] sourceLines))
    before = takeUtf16 (fromIntegral character) current
    blocks = reverse (take lineNo sourceLines)
    doc n = docComment source (namePos n)
    isUnknown = \case
      RefUnknown -> True
      _ -> False
    members here = case here of
      Just (TypeProduct fs) ->
        [ typeItem t
        | TermName n <- map factorTerm fs
        , Just t <- [M.lookup (nameText n) (modelTypes m)]
        ]
      _ ->
        [ item
            CompletionItemKind_EnumMember
            (nameText (variantName (variantInfo v)))
            (nameText (variantName (variantInfo v)))
            (Just ("variant of " <> variantOwnerPath v))
            (doc (variantName (variantInfo v)))
        | v <- variantsAt m here
        ]
    types = map typeItem (M.elems (modelTypes m))
    typeItem t =
      item
        (typeKind (typeInfoShape t))
        (nameText (typeInfoName t))
        (nameText (typeInfoName t))
        (Just (shapeWord (typeInfoShape t)))
        (doc (typeInfoName t))
    constants =
      [ item CompletionItemKind_Constant name name (Just (nameText (constType c))) Nothing
      | (name, c) <- M.toList (modelConsts m)
      ]
    -- The values named so far in the definition being written: each
    -- @#x@ from the line where it starts (in column 1) to the cursor. Read
    -- from the text, as the definition being written seldom parses.
    values =
      [ item CompletionItemKind_Variable x x (Just "value") Nothing
      | x <- nub (concatMap namings (reverse (before : current')))
      ]
    current'
      | startsDefinition current = []
      | otherwise = case break startsDefinition blocks of
          (inside, start : _) -> inside <> [start]
          (inside, []) -> inside
    startsDefinition l = case T.uncons l of
      Just (c, _) -> c /= ' ' && c /= '\t' && not ("--" `T.isPrefixOf` l)
      Nothing -> False
    namings l =
      [ x
      | chunk <- drop 1 (T.splitOn "#" (fst (T.breakOn "--" l)))
      , let x = T.takeWhile isNameChar chunk
      , not (T.null x)
      ]
    item kind label insert detail documentation =
      CompletionItem
        { _label = label
        , _labelDetails = Nothing
        , _kind = Just kind
        , _tags = Nothing
        , _detail = detail
        , _documentation = InR . MarkupContent MarkupKind_Markdown <$> documentation
        , _deprecated = Nothing
        , _preselect = Nothing
        , _sortText = Nothing
        , _filterText = if label == insert then Nothing else Just insert
        , _insertText = if label == insert then Nothing else Just insert
        , _insertTextFormat = Nothing
        , _insertTextMode = Nothing
        , _textEdit = Nothing
        , _textEditText = Nothing
        , _additionalTextEdits = Nothing
        , _commitCharacters = Nothing
        , _command = Nothing
        , _data_ = Nothing
        }

-- | What the text before the cursor asks for. The lines above it say
-- whether it's inside a header block.
context :: Text -> [Text] -> Context
context before above
  | "--" `T.isInfixOf` before = Nowhere
  | odd (T.count "\"" before) = Nowhere
  | Just block <- openBlock (code before : map code above) = InBlock block
  | "@" `T.isPrefixOf` word = AfterAt
  | T.any (== '.') word = AfterDot (init (T.splitOn "." word))
  | T.all isNameChar before = LineStart
  | otherwise = Anywhere
  where
    word = T.takeWhileEnd (\c -> isNameChar c || c == '.' || c == '@') before
    code = fst . T.breakOn "--"
    -- The innermost header block still open: scanning up, a "}" closes
    -- it first.
    openBlock = \case
      [] -> Nothing
      l : ls
        | "}" `T.isInfixOf` l -> Nothing
        | Just k <- blockKeyword l -> Just k
        | otherwise -> openBlock ls
    blockKeyword l =
      case [k | k <- ["__atomics", "__events", "__annotations"], opens k l] of
        k : _ -> Just k
        [] -> Nothing
    opens k l = k `T.isInfixOf` l && "{" `T.isInfixOf` snd (T.breakOn k l)

isNameChar :: Char -> Bool
isNameChar c = isAlphaNum c || c == '_' || c == '\''

typeKind :: TypeShape -> CompletionItemKind
typeKind = \case
  ShapeAtomic _ -> CompletionItemKind_TypeParameter
  ShapeSum _ -> CompletionItemKind_Enum
  ShapeProduct _ -> CompletionItemKind_Struct
  ShapeNewtype _ -> CompletionItemKind_Class
  ShapeList _ _ -> CompletionItemKind_Class

shapeWord :: TypeShape -> Text
shapeWord = \case
  ShapeAtomic base -> "atomic" <> maybe "" ((" " <>) . primitiveWord) base
  ShapeSum _ -> "sum"
  ShapeProduct _ -> "product"
  ShapeNewtype n -> "newtype of " <> nameText n
  ShapeList _ _ -> "list"

-- | The first characters of a line, up to an LSP character offset, which
-- counts UTF-16 code units.
takeUtf16 :: Int -> Text -> Text
takeUtf16 n = T.pack . go n . T.unpack
  where
    go k (c : cs)
      | k > 0 = c : go (k - if fromEnum c > 0xFFFF then 2 else 1) cs
    go _ _ = []
