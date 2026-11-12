{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Tests for the language server: each one runs the server in this
-- process, opens a document in it with lsp-test, and reads the
-- diagnostics it publishes or the answer to a request.
module Main (main) where

import Control.Concurrent (forkIO, killThread)
import Control.Exception (bracket, handle)
import Control.Monad (void)
import Data.Bits (testBit)
import Data.List (mapAccumL, sort)
import Data.Text (Text)
import Data.Text qualified as T
import Language.LSP.Protocol.Types
import Language.LSP.Server (runServerWithHandles)
import Language.LSP.Test
import SumSpec.Lsp (serverDefinition)
import System.Exit (ExitCode)
import System.IO (hClose)
import System.Process (createPipe)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

main :: IO ()
main =
  defaultMain $
    testGroup
      "lsp"
      [ testCase "a valid spec has no errors" $ do
          diags <- diagnosticsOf "example/drone.sumspec"
          assertBool
            "no errors"
            (all ((/= Just DiagnosticSeverity_Error) . (._severity)) diags)
      , testCase "a parse error" $ do
          diags <- diagnosticsOfText "__atomics { }\n__events { }\n\nMode = A |\n"
          map summary diags
            @?= [(DiagnosticSeverity_Error, Range (Position 4 0) (Position 4 0))]
      , testCase "an error and a warning, with the range of their names" $ do
          diags <-
            diagnosticsOfText
              "__atomics { }\n__events { go }\n\nApp = A | B\n\n__init :: App.A\n\ngo :: App.A -> App.Nope\n"
          map summary diags
            @?= [ (DiagnosticSeverity_Warning, Range (Position 3 10) (Position 3 11))
                , (DiagnosticSeverity_Error, Range (Position 7 19) (Position 7 23))
                ]
      , testCase "the diagnostics follow an edit" $ do
          diags <- withServer $ do
            doc <- openDoc "example/todomvc.sumspec" "sumspec"
            _ <- waitForDiagnostics
            changeDoc
              doc
              [ TextDocumentContentChangeEvent
                  (InR (TextDocumentContentChangeWholeDocument "Broken ="))
              ]
            waitForDiagnostics
          map (._severity) diags @?= [Just DiagnosticSeverity_Error]
      , testGroup "recovery" recoveryTests
      , testGroup "outline" outlineTests
      , testGroup "definition" definitionTests
      , testCase "references to a type" $ do
          (withDecl, withoutDecl) <- withNav $ \doc ->
            (,)
              <$> getReferences doc (Position 4 13) True
              <*> getReferences doc (Position 4 13) False
          map (._range) withDecl
            @?= [range 4 13 16, range 6 0 3, range 8 25 28, range 10 20 23, range 10 32 35]
          map (._range) withoutDecl
            @?= [range 4 13 16, range 8 25 28, range 10 20 23, range 10 32 35]
      , testGroup "hover" hoverTests
      , testGroup "completion" completionTests
      , testCase "semantic tokens" $ do
          tokens <- withNav getSemanticTokens
          case tokens of
            InL t ->
              filter (\(l, _, _, _, _) -> l == 10) (decode t)
                @?= [ (10, 0, 4, "event", ["declaration"])
                    , (10, 5, 2, "type", [])
                    , (10, 7, 2, "variable", ["declaration"])
                    , (10, 10, 2, "operator", [])
                    , (10, 13, 3, "type", [])
                    , (10, 17, 2, "operator", [])
                    , (10, 20, 3, "type", [])
                    , (10, 24, 4, "enumMember", [])
                    , (10, 29, 2, "operator", [])
                    , (10, 32, 3, "type", [])
                    , (10, 36, 3, "enumMember", [])
                    , (10, 40, 1, "variable", [])
                    ]
            InR _ -> assertBool "no tokens" False
      ]
  where
    summary d = (maybe DiagnosticSeverity_Hint id d._severity, d._range)

-- | Two broken definitions among good ones: one error each, and the
-- requests still see the definitions that parse.
recoveryTests :: [TestTree]
recoveryTests =
  [ testCase "an error for each broken definition" $ do
      diags <- diagnosticsOfText broken
      map (\d -> (d._severity, d._range._start)) diags
        @?= [ (Just DiagnosticSeverity_Error, Position 4 9)
            , (Just DiagnosticSeverity_Error, Position 6 7)
            ]
  , testCase "the outline keeps the definitions that parse" $ do
      symbols <- withServer $ do
        doc <- createDoc "test.sumspec" "sumspec" broken
        _ <- waitForDiagnostics
        getDocumentSymbols doc
      fmap (map (\d -> (d._name, d._kind))) symbols
        @?= Right
          [ ("App", SymbolKind_Enum)
          , ("Mode", SymbolKind_Enum)
          , ("__init", SymbolKind_Constructor)
          , ("go", SymbolKind_Event)
          ]
  ]
  where
    broken =
      "__atomics { }\n__events { go }\n\nApp = A | B\nBroken = | X\nMode = On | Off\n\
      \Also = = Y\n\n__init :: App.A\n\ngo :: App.A -> App.B\n"

-- | The outline of the drone example.
outlineTests :: [TestTree]
outlineTests =
  [ testCase "a symbol for each atomic and definition" $ do
      symbols <- withServer $ do
        doc <- openDoc "example/drone.sumspec" "sumspec"
        getDocumentSymbols doc
      case symbols of
        Left _ -> assertBool "document symbols, not symbol information" False
        Right syms -> do
          let
            kinds = [(d._name, d._kind) | d <- syms]
            children name = [map (._name) cs | d <- syms, d._name == name, Just cs <- [d._children]]
          mapM_
            (\k -> assertBool (show k) (k `elem` kinds))
            [ ("BatteryCharge", SymbolKind_TypeParameter)
            , ("App", SymbolKind_Struct)
            , ("Page", SymbolKind_Enum)
            , ("MinTakeoffCharge", SymbolKind_Constant)
            , ("__init", SymbolKind_Constructor)
            , ("goToPlan", SymbolKind_Event)
            ]
          assertBool
            "Page lists its variants"
            (any (\cs -> "Home" `elem` cs && "Plan" `elem` cs) (children "Page"))
          assertBool
            "each symbol's name is inside its range"
            (and [inside d._selectionRange d._range | d <- syms])
  ]
  where
    inside (Range a b) (Range c d) = c <= a && b <= d

-- | Go to definition in 'nav', from a use to where it's defined.
definitionTests :: [TestTree]
definitionTests =
  [ testCase "a type" $ definitionOf (Position 4 6) ==> Just (range 5 0 4)
  , testCase "a variant in a path" $
      definitionOf (Position 10 25) ==> Just (range 6 6 10)
  , testCase "an __events entry" $ definitionOf (Position 1 11) ==> Just (range 10 0 4)
  , testCase "an annotation" $ definitionOf (Position 6 22) ==> Just (range 2 16 24)
  , testCase "a value, to its #x" $ definitionOf (Position 10 40) ==> Just (range 10 8 9)
  , testCase "nothing at an operator" $ definitionOf (Position 10 18) ==> Nothing
  ]
  where
    action ==> expected = action >>= (@?= expected)
    definitionOf pos = do
      result <- withNav (`getDefinitions` pos)
      pure $ case result of
        InL (Definition (InL location)) -> Just location._range
        _ -> Nothing

-- | Hover in 'described': each text must be in what it shows.
hoverTests :: [TestTree]
hoverTests =
  [ testCase "a type, with the comment above it" $
      hoverAt (Position 9 0) ["App = Mode * Sel", "The whole state."]
  , testCase "a variant in a path" $
      hoverAt (Position 15 19) ["Mode.Off", "Variant of `Mode`"]
  , testCase "a variant in an inline payload" $
      hoverAt (Position 10 23) ["Mode.Lit.Dim", "Variant of `Mode.Lit`"]
  , testCase "a constant" $ hoverAt (Position 13 0) ["Max = Id(3)"]
  , testCase "an annotation, with its comment" $
      hoverAt (Position 11 23) ["@control", "the widget that edits a value"]
  , testCase "an event, with its comment in __events" $
      hoverAt (Position 17 0) ["pick Id#i", "1 transition", "Picks an element."]
  , testCase "a value, with its type" $ hoverAt (Position 17 40) ["i : Id"]
  , testCase "nothing at an operator" $ do
      result <- withDescribed (`getHover` Position 17 10)
      result @?= Nothing
  ]
  where
    hoverAt pos expected = do
      result <- withDescribed (`getHover` pos)
      case result of
        Just (Hover (InL (MarkupContent _ text)) _) ->
          mapM_
            (\e -> assertBool (T.unpack (e <> " in: " <> text)) (e `T.isInfixOf` text))
            expected
        _ -> assertBool "a hover" False
    withDescribed session = withServer $ do
      doc <- createDoc "described.sumspec" "sumspec" described
      _ <- waitForDiagnostics
      session doc

-- | Completion, mostly on a line being typed after 'described', which
-- doesn't parse.
completionTests :: [TestTree]
completionTests =
  [ testCase "after @, the declared annotations" $
      typing "Extra = A | B @" ==> ["@control"]
  , testCase "after a sum and a dot, its variants" $
      typing "go :: App(Mode." ==> ["Lit", "Off", "On"]
  , testCase "through a newtype" $ typing "go :: Alias." ==> ["Lit", "Off", "On"]
  , testCase "in an inline payload" $ typing "go :: Mode.Lit." ==> ["Bright", "Dim"]
  , testCase "after a product and a dot, its factors" $
      typing "go :: App." ==> ["Mode", "Sel"]
  , testCase "after ::, the types and constants" $
      typing "go :: " ==> ["Alias", "App", "Id", "Max", "Mode", "Sel"]
  , testCase "in a transition, its values too" $
      completeAt (described <> "  :: Sel.One(") (Position 18 14)
        ==> ["Alias", "App", "Id", "Max", "Mode", "Sel", "i"]
  , testCase "in __events, the events not listed" $
      completeAt
        "__atomics { }\n__events {\n  \n}\nApp = A | B\n__init :: App.A\ngo :: App.A -> App.B\n"
        (Position 2 2)
        ==> ["go"]
  , testCase "at the start of a line, keywords and events not yet defined" $
      completeAt "__atomics { }\n__events { go }\nApp = A | B\ng" (Position 3 1)
        ==> ["__annotations", "__init", "go"]
  , testCase "nothing in a comment" $ typing "-- App." ==> []
  ]
  where
    action ==> expected = action >>= (@?= expected)
    typing line = completeAt (described <> line) (Position 18 (fromIntegral (T.length line)))
    completeAt text pos = withServer $ do
      doc <- createDoc "typing.sumspec" "sumspec" text
      _ <- waitForDiagnostics
      items <- getCompletions doc pos
      pure (sort [i._label | i <- items])

-- | A spec with comments, for hover and completion. Positions are
-- zero-based:
--
-- > 0  __atomics { Id }
-- > 1  __events {
-- > 2    pick  -- Picks an element.
-- > 4  __annotations {
-- > 5    @control  -- the widget that edits a value
-- > 8  -- The whole state.
-- > 9  App = Mode * Sel
-- > 10 Mode = On | Off | Lit (Dim | Bright)
-- > 11 Sel = None | One(Id) @control
-- > 12 Alias = Mode
-- > 13 Max = Id(3)
-- > 15 __init :: App(Mode.Off * Sel.None)
-- > 17 pick Id#i :: App => Sel.None -> Sel.One(i)
described :: Text
described =
  "__atomics { Id }\n__events {\n  pick  -- Picks an element.\n}\n\
  \__annotations {\n  @control  -- the widget that edits a value\n}\n\n\
  \-- The whole state.\nApp = Mode * Sel\nMode = On | Off | Lit (Dim | Bright)\n\
  \Sel = None | One(Id) @control\nAlias = Mode\nMax = Id(3)\n\n\
  \__init :: App(Mode.Off * Sel.None)\n\n\
  \pick Id#i :: App => Sel.None -> Sel.One(i)\n"

-- | A small spec for the navigation tests. Positions are zero-based:
--
-- > 0  __atomics { Id }
-- > 1  __events { pick }
-- > 2  __annotations { @control }
-- > 4  App = Mode * Sel
-- > 5  Mode = On | Off
-- > 6  Sel = None | One(Id) @control
-- > 8  __init :: App(Mode.Off * Sel.None)
-- > 10 pick Id#i :: App => Sel.None -> Sel.One(i)
nav :: Text
nav =
  "__atomics { Id }\n__events { pick }\n__annotations { @control }\n\n\
  \App = Mode * Sel\nMode = On | Off\nSel = None | One(Id) @control\n\n\
  \__init :: App(Mode.Off * Sel.None)\n\n\
  \pick Id#i :: App => Sel.None -> Sel.One(i)\n"

-- | Runs a session on 'nav', opened and diagnosed.
withNav :: (TextDocumentIdentifier -> Session a) -> IO a
withNav session = withServer $ do
  doc <- createDoc "nav.sumspec" "sumspec" nav
  _ <- waitForDiagnostics
  session doc

range :: UInt -> UInt -> UInt -> Range
range line start end = Range (Position line start) (Position line end)

-- | The tokens as (line, start, length, type, modifiers), from the
-- relative encoding LSP sends and the standard legend the server uses.
decode :: SemanticTokens -> [(UInt, UInt, UInt, Text, [Text])]
decode (SemanticTokens _ numbers) = snd (mapAccumL step (0, 0) (groups numbers))
  where
    SemanticTokensLegend types modifiers = defaultSemanticTokensLegend
    groups (a : b : c : d : e : rest) = (a, b, c, d, e) : groups rest
    groups _ = []
    step (line, start) (dLine, dStart, len, kind, mods) =
      let
        line' = line + dLine
        start' = if dLine == 0 then start + dStart else dStart
      in
        ( (line', start')
        ,
          ( line'
          , start'
          , len
          , types !! fromIntegral kind
          , [m | (i, m) <- zip [0 ..] modifiers, testBit (fromIntegral mods :: Int) i]
          )
        )

-- | The diagnostics the server publishes when this file is opened.
diagnosticsOf :: FilePath -> IO [Diagnostic]
diagnosticsOf file = withServer (openDoc file "sumspec" >> waitForDiagnostics)

-- | The diagnostics the server publishes when this text is opened.
diagnosticsOfText :: Text -> IO [Diagnostic]
diagnosticsOfText source =
  withServer (createDoc "test.sumspec" "sumspec" source >> waitForDiagnostics)

-- | Runs a session against a server running in this process.
withServer :: Session a -> IO a
withServer session = do
  (serverIn, clientOut) <- createPipe
  (clientIn, serverOut) <- createPipe
  bracket
    (forkIO (handle exited (void (server serverIn serverOut))))
    (\t -> killThread t >> mapM_ hClose [serverIn, serverOut, clientIn, clientOut])
    ( \_ ->
        runSessionWithHandles
          clientOut
          clientIn
          defaultConfig
          fullLatestClientCaps
          "."
          session
    )
  where
    server input output =
      runServerWithHandles mempty mempty input output serverDefinition
    -- The server exits the process on the client's exit notification;
    -- here it only ends its thread.
    exited :: ExitCode -> IO ()
    exited _ = pure ()
