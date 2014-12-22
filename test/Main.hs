{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE OverloadedStrings    #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Main where

import Control.Applicative
import Data.Serialize
import Network.Bruce.Protocol
import Test.QuickCheck
import Test.Tasty
import Test.Tasty.QuickCheck

import qualified Data.ByteString.Lazy as LB

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Protocol"
    [ testProperty "decode . encode = Right" encodeDecodeMessage
    ]

encodeDecodeMessage :: Message -> Property
encodeDecodeMessage m = decode (encode m) === Right m

instance Arbitrary Message where
    arbitrary = Message
        <$> (Topic     <$> arbitrary)
        <*> (Timestamp <$> arbitrary)
        <*> (Payload   <$> arbitrary)
        <*> arbitrary
        <*> arbitrary `suchThat` (/= Just LB.empty)

instance Arbitrary Partition where
    arbitrary = oneof
        [ pure AnyPartition
        , PartitionKey <$> arbitrary
        ]

instance Arbitrary LB.ByteString where
    arbitrary = LB.pack <$> arbitrary
