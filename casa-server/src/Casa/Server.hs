{-# OPTIONS_GHC -fno-warn-type-defaults #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Casa content-addressable storage archive server.

module Casa.Server
  ( App(App)
  , resourcesApp
  , Widget
  ) where

import           Casa.Types
import           Control.Applicative
import qualified Data.Attoparsec.Binary as Atto.B
import qualified Data.Attoparsec.ByteString as Atto.B
import           Data.ByteString (ByteString)
import qualified Data.ByteString as S
import qualified Data.ByteString.Builder as S
import           Data.Conduit
import           Data.Conduit.Attoparsec
import qualified Data.Conduit.List as CL
import           Data.Foldable
import           Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import           Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NE
import           Data.Maybe
import           Data.String
import           Data.Text (Text)
import qualified Data.Text as T
import           Yesod

--------------------------------------------------------------------------------
-- Constants

maxRequestableKeys :: Int
maxRequestableKeys = 2

--------------------------------------------------------------------------------
-- Types

-- | Server app.
data App = App

instance Yesod App where
  maximumContentLength _ _ = Just (1024 * 20)
  makeSessionBackend _ = return Nothing

-- | A blob of binary content.
newtype Blob =
  Blob
    { unBlob :: ByteString
    }
     deriving (Read, Eq, Show, IsString)

instance ToTypedContent Blob where
  toTypedContent = TypedContent "application/octet-stream" . toContent

instance ToContent Blob where
  toContent (Blob bytes) =
    ContentBuilder (S.byteString bytes) (Just (S.length bytes))

blobToBuilder :: Blob -> S.Builder
blobToBuilder = S.byteString . unBlob

--------------------------------------------------------------------------------
-- Routes

mkYesod "App" [parseRoutesNoCheck|
  /batch BatchBlobsR POST
  /#BlobKey SingleBlobR GET
|]

--------------------------------------------------------------------------------
-- Handlers

-- | Get a single blob in a web interface.
getSingleBlobR :: BlobKey -> Handler Blob
getSingleBlobR blobKey =
  case HM.lookup blobKey hardCodedKeys of
    Nothing -> notFound
    Just blob -> pure blob

-- | Get a batch of blobs.
postBatchBlobsR :: Handler TypedContent
postBatchBlobsR = do
  keys <- hashesFromBody
  -- We can later replace this with a call to a database.
  let results =
        mapMaybe
          (\(key, len) ->
             fmap
               (key, )
               (do blob <- HM.lookup key hardCodedKeys
                   if S.length (unBlob blob) == len
                     then pure blob
                     else Nothing))
          (toList keys)
  -- We return a stream of key+blob pairs in binary format. The client
  -- knows how long the hash should be and how long the blob should be
  -- based on the hash.
  pure
    (TypedContent
       "application/octet-stream"
       (ContentSource
          (CL.sourceList
             (concatMap
                (\(blobKey, blob) ->
                   [ Chunk (blobKeyToBuilder blobKey <> blobToBuilder blob)
                     -- Do we want to flush after every file?
                   , Flush
                   ])
                results))))

--------------------------------------------------------------------------------
-- Hard-coded example keys

hardCodedKeys :: HashMap BlobKey Blob
hardCodedKeys =
  HM.fromList
    [ ( partialKey
          "334d016f755cd6dc58c53a86e183882f8ec14f52fb05345887c8a5edd42c87b7"
      , "Hello!")
    , ( partialKey
          "514b6bb7c846ecfb8d2d29ef0b5c79b63e6ae838f123da936fe827fda654276c"
      , "World!")
    ]

--------------------------------------------------------------------------------
-- Input reader

-- | Read the list of hashes from the body.
hashesFromBody ::
     (MonadHandler m)
  => m (NonEmpty (BlobKey, Int))
hashesFromBody = do
  result <-
    runConduit
      (rawRequestBody .|
       sinkParserEither (manyUpToN maxRequestableKeys keyValueParser))
  case result of
    Left err ->
      invalidArgs
        ["Invalid blob keys, parse error: " <> T.pack (errorMessage err)]
    Right keys -> do
      case NE.nonEmpty keys of
        Nothing -> invalidArgs ["No keys provided."]
        Just nonEmpty -> pure nonEmpty
  where
    keyValueParser =
      (,) <$> blobKeyBinaryParser <*> fmap fromIntegral Atto.B.anyWord64be

-- | Many occurences up to N.
manyUpToN :: Int -> Atto.B.Parser a -> Atto.B.Parser [a]
manyUpToN n m = do
  v <- fmap Just m <|> fmap (const Nothing) Atto.B.endOfInput
  case v of
    Nothing -> pure []
    Just x ->
      case n of
        0 -> fail "Max keys reached."
        _ -> fmap (x :) (manyUpToN (n - 1) m)

--------------------------------------------------------------------------------
-- Debugging/dev

-- | Make a partial key.
partialKey :: Text -> BlobKey
partialKey = either error id . blobKeyHexParser
{-# DEPRECATED partialKey "This is just for debugging." #-}