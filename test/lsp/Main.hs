{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Tests for the language server: each one runs the server in this
-- process, opens a document in it with lsp-test, and reads the
-- diagnostics it publishes.
module Main (main) where

import Control.Concurrent (forkIO, killThread)
import Control.Exception (bracket, handle)
import Control.Monad (void)
import Data.Text (Text)
import Language.LSP.Protocol.Types
import Language.LSP.Server (runServerWithHandles)
import Language.LSP.Test
import SumSpec.Lsp (serverDefinition)
import System.Exit (ExitCode)
import System.IO (hClose)
import System.Process (createPipe)
import Test.Tasty (defaultMain, testGroup)
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
      ]
  where
    summary d = (maybe DiagnosticSeverity_Hint id d._severity, d._range)

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
