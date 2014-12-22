{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- | Implementation of the @Bruce@ binary protocol.
--
-- cf. <https://github.com/tagged/bruce/blob/master/doc/sending_messages.md>
module Network.Bruce.Protocol
    ( -- * Protocol Types
      Message   (..)
    , Topic     (..)
    , Timestamp (..)
    , Payload   (..)
    , Partition (..)

      -- * Partial decoding, e.g. when reading from a socket
    , decodeSize
    , decodeBody
    ) where

import Control.Applicative
import Control.Monad
import Data.ByteString.Lazy (ByteString)
import Data.Int
import Data.Maybe (fromMaybe)
import Data.Serialize
import Data.String

import qualified Data.ByteString.Lazy as B

-------------------------------------------------------------------------------
-- Types

-- | A @bruce@ protocol message.
data Message = Message
    { messageTopic     :: !Topic
    , messageTimestamp :: !Timestamp
    , messagePayload   :: !Payload
    , messagePartition :: !Partition
    , messageKey       :: !(Maybe ByteString)
    } deriving (Eq, Show)

instance Serialize Message where
    put = encodeMessage
    get = decodeMessage

-- | The Kafka topic that the message is targeted at.
newtype Topic = Topic
    { unTopic :: ByteString }
    deriving (Eq, IsString, Show)

-- | The timestamp for the message, represented as milliseconds
-- since the epoch (January 1 1970 12:00am UTC).
newtype Timestamp = Timestamp
    { unTimestamp :: Int64 }
    deriving (Eq, Num, Ord, Show)

-- | The message payload.
newtype Payload = Payload
    { unPayload :: ByteString }
    deriving (Eq, IsString, Show)

-- | The partition selection strategy for a 'Message'.
-- ...
data Partition
    = AnyPartition
    | PartitionKey !Int32
    deriving (Eq, Show)

-------------------------------------------------------------------------------
-- Encoding

encodeMessage :: Putter Message
encodeMessage m =
    let m' = runPutLazy (encodeBody m)
    in encodeSize m' >> putLazyByteString m'

encodeSize :: Putter ByteString
encodeSize = put . (+4) . len32

encodeBody :: Putter Message
encodeBody m = do
    encodeApiKey msgType
    encodeApiVersion (Version 0)
    encodeFlags (Flags 0)
    encodePartition (messagePartition m)
    encodeTopic (messageTopic m)
    encodeTimestamp (messageTimestamp m)
    encodeKey (messageKey m)
    encodePayload (messagePayload m)
  where
    msgType = case messagePartition m of
        AnyPartition   -> AnyPartitionType
        PartitionKey _ -> PartitionKeyType

encodeApiKey :: Putter MessageType
encodeApiKey AnyPartitionType = put (256 :: Int16)
encodeApiKey PartitionKeyType = put (257 :: Int16)

encodeApiVersion :: Putter Version
encodeApiVersion (Version v) = put v

encodeFlags :: Putter Flags
encodeFlags (Flags f) = put f

encodePartition :: Putter Partition
encodePartition AnyPartition     = return ()
encodePartition (PartitionKey k) = put k

encodeTopic :: Putter Topic
encodeTopic (Topic t) = put (len16 t) >> putLazyByteString t

encodeTimestamp :: Putter Timestamp
encodeTimestamp (Timestamp t) = put t

encodeKey :: Putter (Maybe ByteString)
encodeKey (Just k) = put (len32 k) >> putLazyByteString k
encodeKey Nothing  = put (0 :: Int32)

encodePayload :: Putter Payload
encodePayload (Payload p) = put (len32 p) >> putLazyByteString p

-------------------------------------------------------------------------------
-- Decoding

decodeMessage :: Get Message
decodeMessage = label "message" $ do
    s <- decodeSize
    b <- getBytes (fromIntegral s)
    either fail return (runGet decodeBody b)

-- | Decode an 'Int32' representing the size of a (following) message body.
decodeSize :: Get Int32
decodeSize = label "size" $
    subtract 4 <$> get

decodeBody :: Get Message
decodeBody = do
    ak <- decodeApiKey
    av <- decodeApiVersion
    _  <- decodeFlags
    pk <- case (ak, av) of
        (AnyPartitionType, Version 0) -> return Nothing
        (PartitionKeyType, Version 0) -> Just <$> get
        _                             -> fail $
            "Unexpected (key, version): " ++ show (ak, av)
    tp <- decodeTopic
    ts <- decodeTimestamp
    mk <- decodeKey
    pl <- decodePayload
    let pt = fromMaybe AnyPartition (PartitionKey <$> pk)
    return $ Message tp ts pl pt mk

decodeApiKey :: Get MessageType
decodeApiKey = label "api-key" $ do
    k <- get :: Get Int16
    case k of
        256 -> return AnyPartitionType
        257 -> return PartitionKeyType
        _   -> fail $ "Unexpected message type: " ++ show k

decodeApiVersion :: Get Version
decodeApiVersion = label "api-version" $
    Version <$> get

decodeFlags :: Get Flags
decodeFlags = label "flags" $ do
    f <- Flags <$> get
    unless (f == noFlags) $
        fail $ "Unexpected flags: " ++ show f
    return f

decodeTopic :: Get Topic
decodeTopic = label "topic" $ do
    len <- get :: Get Int16
    Topic <$> getLazyByteString (fromIntegral len)

decodeTimestamp :: Get Timestamp
decodeTimestamp = label "timestamp" $
    Timestamp <$> get

decodeKey :: Get (Maybe ByteString)
decodeKey = label "key" $ do
    len <- get :: Get Int32
    if len == 0
        then return Nothing
        else Just <$> getLazyByteString (fromIntegral len)

decodePayload :: Get Payload
decodePayload = label "payload" $ do
    len <- get :: Get Int32
    Payload <$> getLazyByteString (fromIntegral len)

-------------------------------------------------------------------------------
-- Utilities

data MessageType = AnyPartitionType | PartitionKeyType
    deriving (Eq, Show)

newtype Version = Version Int16
    deriving (Eq, Show)

newtype Flags = Flags Int16
    deriving (Eq, Show)

noFlags :: Flags
noFlags = Flags 0

len16 :: ByteString -> Int16
len16 = fromIntegral . B.length

len32 :: ByteString -> Int32
len32 = fromIntegral . B.length
