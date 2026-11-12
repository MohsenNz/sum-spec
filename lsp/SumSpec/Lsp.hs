{-# LANGUAGE OverloadedStrings #-}

-- | The SumSpec language server, run as @sumspec lsp@ over stdio.
--
-- It publishes diagnostics each time a document is opened, changed or
-- saved, and answers the outline, go to definition, references, hover,
-- completion and semantic highlighting. Each request parses the document as it is in
-- the editor; a document with parse errors still gives the definitions
-- that parsed. See docs/lsp.md.
module SumSpec.Lsp
  ( runLanguageServer
  , serverDefinition
  , diagnose
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Functor ((<&>))
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as T
import Language.LSP.Diagnostics (partitionBySource)
import Language.LSP.Protocol.Message
import Language.LSP.Protocol.Types
import Language.LSP.Server
import Language.LSP.VFS (virtualFileText, virtualFileVersion)
import SumSpec
  ( CheckError (..)
  , Severity (..)
  , Spec
  , checkSpec
  , model
  , parseSpec
  , parseSpecPartial
  )
import SumSpec.Lsp.Completion (completions)
import SumSpec.Lsp.Hover (hover)
import SumSpec.Lsp.Index (Occurrence (..), occurrenceAt, occurrencesWith, symbols)
import SumSpec.Lsp.Position (nameRange, tokenRange)
import SumSpec.Lsp.Tokens (encodeSemanticTokens, semanticTokens)
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
    , options =
        defaultOptions
          { optTextDocumentSync = Just sync
          , optCompletionTriggerCharacters = Just ".@"
          }
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
-- notification handlers only say when to diagnose it again.
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
    , requestHandler SMethod_TextDocumentDocumentSymbol $ \req respond -> do
        let TRequestMessage _ _ _ (DocumentSymbolParams _ _ (TextDocumentIdentifier uri)) = req
        result <- document uri
        respond . Right $ case result of
          Just (source, spec) -> InR (InL (symbols source spec))
          Nothing -> InR (InR Null)
    , requestHandler SMethod_TextDocumentDefinition $ \req respond -> do
        let TRequestMessage _ _ _ (DefinitionParams (TextDocumentIdentifier uri) pos _ _) = req
        result <- document uri
        respond . Right $ case result of
          Just (source, spec)
            | Just occ <- occurrenceAt source pos (occurrencesWith (model spec) spec)
            , Just target <- occTarget occ ->
                InL (Definition (InL (Location uri (nameRange source target))))
          _ -> InR (InR Null)
    , requestHandler SMethod_TextDocumentReferences $ \req respond -> do
        let
          TRequestMessage _ _ _ (ReferenceParams (TextDocumentIdentifier uri) pos _ _ context) = req
          ReferenceContext includeDeclaration = context
        result <- document uri
        respond . Right $ case result of
          Just (source, spec)
            | occs <- occurrencesWith (model spec) spec
            , Just occ <- occurrenceAt source pos occs
            , Just target <- occTarget occ ->
                InL
                  [ Location uri (nameRange source (occName o))
                  | o <- occs
                  , occTarget o == Just target
                  , includeDeclaration || not (occDefinition o)
                  ]
          _ -> InR Null
    , requestHandler SMethod_TextDocumentSemanticTokensFull $ \req respond -> do
        let TRequestMessage _ _ _ (SemanticTokensParams _ _ (TextDocumentIdentifier uri)) = req
        result <- document uri
        respond . Right $ case result of
          Just (source, spec)
            | occs <- occurrencesWith (model spec) spec
            , Right tokens <- encodeSemanticTokens (semanticTokens source occs) ->
                InL tokens
          _ -> InR Null
    , requestHandler SMethod_TextDocumentHover $ \req respond -> do
        let TRequestMessage _ _ _ (HoverParams (TextDocumentIdentifier uri) pos _) = req
        result <- document uri
        respond . Right $ case result of
          Just (source, spec)
            | m <- model spec
            , Just occ <- occurrenceAt source pos (occurrencesWith m spec)
            , Just h <- hover source spec m occ ->
                InL h
          _ -> InR Null
    , requestHandler SMethod_TextDocumentCompletion $ \req respond -> do
        let TRequestMessage _ _ _ (CompletionParams (TextDocumentIdentifier uri) pos _ _ _) = req
        result <- document uri
        respond . Right $ case result of
          Just (source, spec) -> InL (completions source spec (model spec) pos)
          Nothing -> InR (InR Null)
    ]

-- | The document at this URI, as it is in the editor now, with the spec
-- parsed from it: only the definitions that parse, when some don't.
-- 'Nothing' when the document isn't open or its header doesn't parse.
document :: Uri -> LspM () (Maybe (Text, Spec))
document uri =
  getVirtualFile (toNormalizedUri uri) <&> \file -> do
    source <- virtualFileText <$> file
    case parseSpecPartial (uriPath uri) source of
      Left _ -> Nothing
      Right (spec, _) -> Just (source, spec)

-- | The file path of a URI, for error messages; the URI itself when it
-- isn't a file.
uriPath :: Uri -> FilePath
uriPath uri = maybe (T.unpack (getUri uri)) id (uriToFilePath uri)

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
        (partitionBySource (diagnose (uriPath uri) (virtualFileText file)))

maxDiagnostics :: Int
maxDiagnostics = 100

-- | The diagnostics of a document: every parse error, or else every error
-- and warning of the checker. While the document has parse errors, the
-- checker isn't run: its errors would be about the definitions missing.
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
