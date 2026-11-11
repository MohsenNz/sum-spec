{-# LANGUAGE OverloadedStrings #-}

-- | The SumSpec language server, run as @sumspec lsp@ over stdio.
--
-- For now it publishes diagnostics only: the parse error, or the errors
-- and warnings of the checker, each time a document is opened, changed or
-- saved. See docs/lsp.md for the plan.
module SumSpec.Lsp
  ( runLanguageServer
  , serverDefinition
  , diagnose
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as T
import Language.LSP.Diagnostics (partitionBySource)
import Language.LSP.Protocol.Message
import Language.LSP.Protocol.Types
import Language.LSP.Server
import Language.LSP.VFS (virtualFileText, virtualFileVersion)
import SumSpec (CheckError (..), Severity (..), checkSpec, parseSpec)
import SumSpec.Lsp.Position (tokenRange)
import Text.Megaparsec
  ( ParseErrorBundle (..)
  , attachSourcePos
  , errorOffset
  , parseErrorTextPretty
  )

-- | Runs the server on stdin and stdout; returns the exit code.
runLanguageServer :: IO Int
runLanguageServer = runServer serverDefinition

serverDefinition :: ServerDefinition ()
serverDefinition =
  ServerDefinition
    { parseConfig = \_ _ -> Right ()
    , onConfigChange = \_ -> pure ()
    , defaultConfig = ()
    , configSection = "sumspec"
    , doInitialize = \env _ -> pure (Right env)
    , staticHandlers = const handlers
    , interpretHandler = \env -> Iso (runLspT env) liftIO
    , options = defaultOptions {optTextDocumentSync = Just sync}
    }
  where
    sync =
      TextDocumentSyncOptions
        { _openClose = Just True
        , _change = Just TextDocumentSyncKind_Incremental
        , _willSave = Nothing
        , _willSaveWaitUntil = Nothing
        , _save = Just (InR (SaveOptions (Just False)))
        }

-- | The library keeps every open document in its virtual file system; the
-- handlers only say when to diagnose it again.
handlers :: Handlers (LspM ())
handlers =
  mconcat
    [ notificationHandler SMethod_Initialized $ \_ -> pure ()
    , notificationHandler SMethod_TextDocumentDidOpen $ \msg ->
        let
          TNotificationMessage _ _ (DidOpenTextDocumentParams doc) = msg
          TextDocumentItem uri _ _ _ = doc
        in
          publish uri
    , notificationHandler SMethod_TextDocumentDidChange $ \msg ->
        let
          TNotificationMessage _ _ (DidChangeTextDocumentParams doc _) = msg
          VersionedTextDocumentIdentifier uri _ = doc
        in
          publish uri
    , notificationHandler SMethod_TextDocumentDidSave $ \msg ->
        let
          TNotificationMessage _ _ (DidSaveTextDocumentParams doc _) = msg
          TextDocumentIdentifier uri = doc
        in
          publish uri
    , notificationHandler SMethod_TextDocumentDidClose $ \msg ->
        let
          TNotificationMessage _ _ (DidCloseTextDocumentParams doc) = msg
          TextDocumentIdentifier uri = doc
        in
          publishDiagnostics maxDiagnostics (toNormalizedUri uri) Nothing mempty
    , notificationHandler SMethod_WorkspaceDidChangeConfiguration $ \_ -> pure ()
    , notificationHandler SMethod_SetTrace $ \_ -> pure ()
    ]

-- | Diagnoses the document at this URI, as it is in the editor now.
publish :: Uri -> LspM () ()
publish uri = do
  let nuri = toNormalizedUri uri
  getVirtualFile nuri >>= \case
    Nothing -> pure ()
    Just file ->
      publishDiagnostics
        maxDiagnostics
        nuri
        (Just (virtualFileVersion file))
        (partitionBySource (diagnose path (virtualFileText file)))
  where
    path = maybe (T.unpack (getUri uri)) id (uriToFilePath uri)

maxDiagnostics :: Int
maxDiagnostics = 100

-- | The diagnostics of a document: its parse error, or else every error
-- and warning of the checker.
diagnose :: FilePath -> Text -> [Diagnostic]
diagnose path source = case parseSpec path source of
  Left bundle ->
    [ diagnostic DiagnosticSeverity_Error pos (T.strip (T.pack (parseErrorTextPretty e)))
    | (e, pos) <-
        NE.toList . fst $
          attachSourcePos errorOffset (bundleErrors bundle) (bundlePosState bundle)
    ]
  Right spec ->
    [ diagnostic (severity (errorSeverity e)) (errorPos e) (errorMessage e)
    | e <- checkSpec path source spec
    ]
  where
    severity = \case
      Error -> DiagnosticSeverity_Error
      Warning -> DiagnosticSeverity_Warning
    diagnostic sev pos message =
      Diagnostic
        { _range = tokenRange source pos
        , _severity = Just sev
        , _code = Nothing
        , _codeDescription = Nothing
        , _source = Just "sumspec"
        , _message = message
        , _tags = Nothing
        , _relatedInformation = Nothing
        , _data_ = Nothing
        }
