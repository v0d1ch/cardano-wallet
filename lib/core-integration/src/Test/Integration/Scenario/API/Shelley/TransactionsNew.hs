{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

{- HLINT ignore "Use head" -}

module Test.Integration.Scenario.API.Shelley.TransactionsNew
    ( spec
    ) where

import Prelude

import Cardano.Mnemonic
    ( mnemonicToText )
import Cardano.Wallet.Api.Types
    ( ApiCoinSelectionInput (..)
    , ApiCoinSelectionOutput (..)
    , ApiConstructTransaction
    , ApiFee (..)
    , ApiSignedTransaction
    , ApiStakePool
    , ApiT (..)
    , ApiWallet
    , DecodeAddress
    , DecodeStakeAddress
    , EncodeAddress (..)
    , WalletStyle (..)
    )
import Cardano.Wallet.Primitive.AddressDerivation
    ( PaymentAddress )
import Cardano.Wallet.Primitive.AddressDerivation.Icarus
    ( IcarusKey )
import Cardano.Wallet.Primitive.Types.Address
    ( Address (..) )
import Control.Monad.IO.Unlift
    ( MonadIO (..), MonadUnliftIO (..), liftIO )
import Control.Monad.Trans.Resource
    ( runResourceT )
import Data.Generics.Internal.VL.Lens
    ( view, (^.) )
import Data.Maybe
    ( isJust )
import Data.Proxy
    ( Proxy (..) )
import Data.Quantity
    ( Quantity (..) )
import Data.Text
    ( Text )
import Numeric.Natural
    ( Natural )
import Test.Hspec
    ( SpecWith, describe, pendingWith )
import Test.Hspec.Expectations.Lifted
    ( shouldBe, shouldNotBe, shouldSatisfy )
import Test.Hspec.Extra
    ( it )
import Test.Integration.Framework.DSL
    ( Context (..)
    , Headers (..)
    , Payload (..)
    , arbitraryStake
    , arbitraryStake
    , emptyWallet
    , expectErrorMessage
    , expectField
    , expectResponseCode
    , expectSuccess
    , fixtureMultiAssetWallet
    , fixturePassphrase
    , fixtureWallet
    , fixtureWalletWith
    , getFromResponse
    , json
    , listAddresses
    , minUTxOValue
    , pickAnAsset
    , request
    , rewardWallet
    , unsafeRequest
    , verify
    )
import Test.Integration.Framework.TestData
    ( errMsg403Fee
    , errMsg403InvalidConstructTx
    , errMsg403MinUTxOValue
    , errMsg403NotDelegating
    , errMsg403NotEnoughMoney
    , errMsg403OutputsAlreadyCovered
    , errMsg404NoSuchPool
    )

import qualified Cardano.Wallet.Api.Link as Link
import qualified Cardano.Wallet.Primitive.Types.TokenMap as W
import qualified Data.List.NonEmpty as NE
import qualified Data.Text as T
import qualified Network.HTTP.Types.Status as HTTP

spec :: forall n.
    ( DecodeAddress n
    , DecodeStakeAddress n
    , EncodeAddress n
    , PaymentAddress n IcarusKey
    ) => SpecWith Context
spec = describe "NEW_SHELLEY_TRANSACTIONS" $ do
    it "TRANS_NEW_CREATE_01a - Empty payload is not allowed" $ \ctx -> runResourceT $ do
        wa <- fixtureWallet ctx
        let emptyPayload = Json [json|{}|]

        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shelley wa) Default emptyPayload
        verify rTx
            [ expectResponseCode HTTP.status403
            , expectErrorMessage errMsg403InvalidConstructTx
            ]

    it "TRANS_NEW_CREATE_01b - Validity interval only is not allowed" $ \ctx -> runResourceT $ do
        wa <- fixtureWallet ctx
        let validityInterval = Json [json|{
                "validity_interval": {
                    "invalid_before": {
                      "quantity": 10,
                      "unit": "second"
                    },
                    "invalid_hereafter": {
                      "quantity": 50,
                      "unit": "second"
                    }
                  }
                }|]

        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shelley wa) Default validityInterval
        verify rTx
            [ expectResponseCode HTTP.status403
            , expectErrorMessage errMsg403InvalidConstructTx
            ]

    it "TRANS_NEW_CREATE_01c - No payload is bad request" $ \ctx -> runResourceT $ do
        wa <- fixtureWallet ctx

        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shelley wa) Default Empty
        verify rTx
            [ expectResponseCode HTTP.status400
            ]

    it "TRANS_NEW_CREATE_02 - Only metadata" $ \ctx -> runResourceT $ do
        wa <- fixtureWallet ctx
        let metadata = Json [json|{ "metadata": { "1": { "string": "hello" } } }|]
        let expectedFee = 1129500

        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shelley wa) Default metadata
        verify rTx
            [ expectResponseCode HTTP.status202
            , expectField (#coinSelection . #metadata) (`shouldSatisfy` isJust)
            , expectField (#fee . #getQuantity) (`shouldBe` expectedFee)
            ]
        -- TODO: sign and submit tx,
        --       check metadata presence on submitted tx,
        --       make sure only fee is deducted from fixtureWallet

    it "TRANS_NEW_CREATE_03a - Withdrawal from self" $ \ctx -> runResourceT $ do
        (wa, _) <- rewardWallet ctx
        let withdrawal = Json [json|{ "withdrawal": "self" }|]
        let expectedFee = 139500
        -- let withdrawalAmt = 1000000000000

        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shelley wa) Default withdrawal
        verify rTx
            [ expectResponseCode HTTP.status202
            , expectField (#coinSelection . #metadata) (`shouldBe` Nothing)
            , expectField (#fee . #getQuantity) (`shouldBe` expectedFee)
            , expectField (#coinSelection . #withdrawals) (`shouldSatisfy` (not . null))
            ]
        -- TODO: sign and submit tx,
        --       check that reward account is 0,
        --       make sure wallet balance is increased by withdrawalAmt - fee

    it "TRANS_NEW_CREATE_03b - Withdrawal from external wallet" $ \ctx -> runResourceT $ do
        (_, mw) <- rewardWallet ctx
        wa <- fixtureWallet ctx
        let withdrawal = Json [json|{ "withdrawal": #{mnemonicToText mw} }|]
        let expectedFee = 1139500
        -- let withdrawalAmt = 1000000000000

        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shelley wa) Default withdrawal
        verify rTx
            [ expectResponseCode HTTP.status202
            , expectField (#coinSelection . #metadata) (`shouldBe` Nothing)
            , expectField (#fee . #getQuantity) (`shouldBe` expectedFee)
            , expectField (#coinSelection . #withdrawals) (`shouldSatisfy` (not . null))
            ]
        -- TODO: sign and submit tx,
        --       check that reward account is 0 on external rewardWallet,
        --       make sure wa wallet balance is increased by withdrawalAmt - fee

    it "TRANS_NEW_CREATE_04a - Single Output Transaction" $ \ctx -> runResourceT $ do
        -- constructing Tx
        let initialAmt = 3 * minUTxOValue (_mainEra ctx)
        wa <- fixtureWalletWith @n ctx [initialAmt]
        wb <- emptyWallet ctx
        let amt = (minUTxOValue (_mainEra ctx) :: Natural)

        (destAddr, constrPayload) <- liftIO $ mkTxPayload ctx wb amt

        (_, ApiFee (Quantity feeMin) _ _ _) <- unsafeRequest ctx
            (Link.getTransactionFeeOld @'Shelley wa) constrPayload
        rConstrTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shelley wa) Default constrPayload
        verify rConstrTx
            [ expectSuccess
            , expectResponseCode HTTP.status202
            , expectField (#fee . #getQuantity) (`shouldBe` feeMin)
            ]
        let filterInitialAmt =
                filter (\(ApiCoinSelectionInput _ _ _ _ amt' _) -> amt' == Quantity initialAmt)
        let coinSelInputs = filterInitialAmt $ NE.toList $
                getFromResponse (#coinSelection . #inputs) rConstrTx
        length coinSelInputs `shouldBe` 1

        let coinSelOutputs = getFromResponse (#coinSelection . #outputs) rConstrTx
        coinSelOutputs `shouldBe`
            [ApiCoinSelectionOutput destAddr (Quantity amt) (ApiT W.empty)]

        -- signing tx
        let serializedTx = getFromResponse #transaction rConstrTx
        let signPayload = Json [json|{
              "transaction": #{serializedTx},
              "passphrase": #{fixturePassphrase}
          }|]
        rSignTx <- request @ApiSignedTransaction ctx
            (Link.signTransaction @'Shelley wa) Default signPayload
        verify rSignTx
            [ expectSuccess
            , expectResponseCode HTTP.status202
            ]

        -- and send it in two steps

    it "TRANS_NEW_CREATE_04b - Cannot spend less than minUTxOValue" $ \ctx -> runResourceT $ do
        wa <- fixtureWallet ctx
        wb <- emptyWallet ctx
        let amt = minUTxOValue (_mainEra ctx) - 1

        (_,payload) <- liftIO $ mkTxPayload ctx wb amt

        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shelley wa) Default payload
        verify rTx
            [ expectResponseCode HTTP.status403
            , expectErrorMessage errMsg403MinUTxOValue
            ]

    it "TRANS_NEW_CREATE_04c - Can't cover fee" $ \ctx -> runResourceT $ do
        wa <- fixtureWalletWith @n ctx [minUTxOValue (_mainEra ctx) + 1]
        wb <- emptyWallet ctx

        (_,payload) <- liftIO $ mkTxPayload ctx wb (minUTxOValue (_mainEra ctx))

        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shelley wa) Default payload
        verify rTx
            [ expectResponseCode HTTP.status403
            , expectErrorMessage errMsg403Fee
            ]

    it "TRANS_NEW_CREATE_04d - Not enough money" $ \ctx -> runResourceT $ do
        let minUTxOValue' = minUTxOValue (_mainEra ctx)
        let (srcAmt, reqAmt) = (minUTxOValue', 2 * minUTxOValue')
        wa <- fixtureWalletWith @n ctx [srcAmt]
        wb <- emptyWallet ctx

        (_,payload) <- liftIO $ mkTxPayload ctx wb reqAmt

        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shelley wa) Default payload
        verify rTx
            [ expectResponseCode HTTP.status403
            , expectErrorMessage errMsg403NotEnoughMoney
            ]

    it "TRANS_NEW_CREATE_04d - Not enough money emptyWallet" $ \ctx -> runResourceT $ do
        wa <- emptyWallet ctx
        wb <- emptyWallet ctx

        (_,payload) <- liftIO $ mkTxPayload ctx wb (minUTxOValue (_mainEra ctx))

        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shelley wa) Default payload
        verify rTx
            [ expectResponseCode HTTP.status403
            , expectErrorMessage errMsg403NotEnoughMoney
            ]

    it "TRANS_NEW_CREATE_04e- Multiple Output Tx to single wallet" $ \ctx -> runResourceT $ do

        liftIO $ pendingWith "Missing outputs on response - to be fixed in ADP-985"

        wa <- fixtureWallet ctx
        wb <- emptyWallet ctx
        addrs <- listAddresses @n ctx wb

        let amt = minUTxOValue (_mainEra ctx) :: Natural
        let destination1 = (addrs !! 1) ^. #id
        let destination2 = (addrs !! 2) ^. #id
        let payload = Json [json|{
                "payments": [{
                    "address": #{destination1},
                    "amount": {
                        "quantity": #{amt},
                        "unit": "lovelace"
                    }
                },
                {
                    "address": #{destination2},
                    "amount": {
                        "quantity": #{amt},
                        "unit": "lovelace"
                    }
                }]
            }|]

        (_, ApiFee (Quantity feeMin) _ _ _) <- unsafeRequest ctx
            (Link.getTransactionFeeOld @'Shelley wa) payload
        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shelley wa) Default payload
        verify rTx
            [ expectSuccess
            , expectResponseCode HTTP.status202
            , expectField (#coinSelection . #inputs) (`shouldSatisfy` (not . null))
            , expectField (#coinSelection . #outputs) (`shouldSatisfy` (not . null))
            , expectField (#coinSelection . #change) (`shouldSatisfy` (not . null))
            , expectField (#fee . #getQuantity) (`shouldBe` feeMin)
            ]
        -- TODO: now we should sign it and send it in two steps,
        --       make sure it is delivered
        --       make sure balance is updated accordingly on src and dst wallets

    it "TRANS_NEW_ASSETS_CREATE_01a - Multi-asset tx with Ada" $ \ctx -> runResourceT $ do

        liftIO $ pendingWith "Missing outputs on response - to be fixed in ADP-985"

        wa <- fixtureMultiAssetWallet ctx
        wb <- emptyWallet ctx
        ra <- request @ApiWallet ctx (Link.getWallet @'Shelley wa) Default Empty
        let (_, Right wal) = ra

        -- pick out an asset to send
        let assetsSrc = wal ^. #assets . #total . #getApiT
        assetsSrc `shouldNotBe` mempty
        let val = minUTxOValue (_mainEra ctx) <$ pickAnAsset assetsSrc

        -- create payload
        addrs <- listAddresses @n ctx wb
        let destination = (addrs !! 1) ^. #id
        let amt = 2 * minUTxOValue (_mainEra ctx)
        payload <- mkTxPayloadMA @n destination amt [val]

        --construct transaction
        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shelley wa) Default payload
        verify rTx
            [ expectSuccess
            , expectResponseCode HTTP.status202
            , expectField (#coinSelection . #inputs) (`shouldSatisfy` (not . null))
            , expectField (#coinSelection . #outputs) (`shouldSatisfy` (not . null))
            , expectField (#coinSelection . #change) (`shouldSatisfy` (not . null))
            ]
        -- TODO: now we should sign it and send it in two steps
        --       make sure it is delivered
        --       make sure balance is updated accordingly on src and dst wallets

    it "TRANS_NEW_ASSETS_CREATE_01b - Multi-asset tx with not enough Ada" $ \ctx -> runResourceT $ do
        wa <- fixtureMultiAssetWallet ctx
        wb <- emptyWallet ctx
        ra <- request @ApiWallet ctx (Link.getWallet @'Shelley wa) Default Empty
        let (_, Right wal) = ra

        -- pick out an asset to send
        let assetsSrc = wal ^. #assets . #total . #getApiT
        assetsSrc `shouldNotBe` mempty
        let val = minUTxOValue (_mainEra ctx) <$ pickAnAsset assetsSrc

        -- create payload
        addrs <- listAddresses @n ctx wb
        let destination = (addrs !! 1) ^. #id
        let amt = minUTxOValue (_mainEra ctx)
        payload <- mkTxPayloadMA @n destination amt [val]

        --construct transaction
        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shelley wa) Default payload
        verify rTx
            [ expectResponseCode HTTP.status403
            , expectErrorMessage "Some outputs have ada values that are too small."
            ]

    it "TRANS_NEW_ASSETS_CREATE_01c - Multi-asset tx without Ada" $ \ctx -> runResourceT $ do

        liftIO $ pendingWith "Missing outputs on response - to be fixed in ADP-985"

        wa <- fixtureMultiAssetWallet ctx
        wb <- emptyWallet ctx
        ra <- request @ApiWallet ctx (Link.getWallet @'Shelley wa) Default Empty
        let (_, Right wal) = ra

        -- pick out an asset to send
        let assetsSrc = wal ^. #assets . #total . #getApiT
        assetsSrc `shouldNotBe` mempty
        let val = minUTxOValue (_mainEra ctx) <$ pickAnAsset assetsSrc

        -- create payload
        addrs <- listAddresses @n ctx wb
        let destination = (addrs !! 1) ^. #id
        let amt = 0
        payload <- mkTxPayloadMA @n destination amt [val]

        --construct transaction
        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shelley wa) Default payload
        verify rTx
            [ expectSuccess
            , expectResponseCode HTTP.status202
            , expectField (#coinSelection . #inputs) (`shouldSatisfy` (not . null))
            , expectField (#coinSelection . #outputs) (`shouldSatisfy` (not . null))
            , expectField (#coinSelection . #change) (`shouldSatisfy` (not . null))
            ]
        -- TODO: now we should sign it and send it in two steps
        --       make sure it is delivered
        --       make sure balance is updated accordingly on src and dst wallets

    it "TRANS_NEW_ASSETS_CREATE_01d - Multi-asset tx with not enough assets" $ \ctx -> runResourceT $ do
        wa <- fixtureMultiAssetWallet ctx
        wb <- emptyWallet ctx
        ra <- request @ApiWallet ctx (Link.getWallet @'Shelley wa) Default Empty
        let (_, Right wal) = ra

        let minUTxOValue' = minUTxOValue (_mainEra ctx)

        -- pick out an asset to send
        let assetsSrc = wal ^. #assets . #total . #getApiT
        assetsSrc `shouldNotBe` mempty
        let val = (minUTxOValue' * minUTxOValue') <$ pickAnAsset assetsSrc

        -- create payload
        addrs <- listAddresses @n ctx wb
        let destination = (addrs !! 1) ^. #id
        let amt = 0
        payload <- mkTxPayloadMA @n destination amt [val]

        --construct transaction
        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shelley wa) Default payload
        verify rTx
            [ expectResponseCode HTTP.status403
            , expectErrorMessage errMsg403NotEnoughMoney
            ]

    it "TRANS_NEW_JOIN_01a - Can join stakepool" $ \ctx -> runResourceT $ do

        liftIO $ pendingWith "Deposit is empty but should not - to be fixed in ADP-985"

        wa <- fixtureWallet ctx
        pool:_ <- map (view #id) . snd <$> unsafeRequest
            @[ApiStakePool]
            ctx (Link.listStakePools arbitraryStake) Empty

        let delegation = Json [json|{
                "delegations": [{
                    "join": {
                        "pool": #{pool},
                        "stake_key_index": "0H"
                    }
                }]
            }|]
        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shelley wa) Default delegation
        verify rTx
            [ expectResponseCode HTTP.status202
            , expectField (#coinSelection . #deposits) (`shouldSatisfy` (not . null))
            ]
        -- TODO: sign/submit tx and verify pool is joined

    it "TRANS_NEW_JOIN_01b - Invalid pool id" $ \ctx -> runResourceT $ do

        wa <- fixtureWallet ctx

        let invalidPoolId = T.replicate 32 "1"
        let delegation = Json [json|{
                "delegations": [{
                    "join": {
                        "pool": #{invalidPoolId},
                        "stake_key_index": "0H"
                    }
                }]
            }|]
        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shelley wa) Default delegation
        verify rTx
            [ expectResponseCode HTTP.status400
            , expectErrorMessage "Invalid stake pool id"
            ]

    it "TRANS_NEW_JOIN_01b - Absent pool id" $ \ctx -> runResourceT $ do

        liftIO $ pendingWith "No errMsg404NoSuchPool is returned - to be fixed in ADP-985"

        wa <- fixtureWallet ctx
        let absentPoolId = "pool1mgjlw24rg8sp4vrzctqxtf2nn29rjhtkq2kdzvf4tcjd5pl547k"
        let delegation = Json [json|{
                "delegations": [{
                    "join": {
                        "pool": #{absentPoolId},
                        "stake_key_index": "0H"
                    }
                }]
            }|]
        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shelley wa) Default delegation
        verify rTx
            [ expectResponseCode HTTP.status404
            , expectErrorMessage (errMsg404NoSuchPool (absentPoolId))
            ]

    it "TRANS_NEW_QUIT_01 - Cannot quit if not joined" $ \ctx -> runResourceT $ do

        liftIO $ pendingWith "No errMsg403NotDelegating is returned - to be fixed in ADP-985"

        wa <- fixtureWallet ctx
        let delegation = Json [json|{
                "delegations": [{
                    "quit": {
                        "stake_key_index": "0H"
                    }
                }]
            }|]
        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shelley wa) Default delegation
        verify rTx
            [ expectResponseCode HTTP.status403
            , expectErrorMessage errMsg403NotDelegating
            ]

    it "TRANS_NEW_VALIDITY_INTERVAL_01a - Validity interval with second" $ \ctx -> runResourceT $ do
        wa <- fixtureWallet ctx
        wb <- emptyWallet ctx
        addrs <- listAddresses @n ctx wb
        let destination = (addrs !! 1) ^. #id
        let amt = minUTxOValue (_mainEra ctx)

        let payload = Json [json|{
                "payments": [{
                    "address": #{destination},
                    "amount": {
                        "quantity": #{amt},
                        "unit": "lovelace"
                    }
                }],
                "validity_interval": {
                    "invalid_before": {
                      "quantity": 0,
                      "unit": "second"
                    },
                    "invalid_hereafter": {
                      "quantity": 500,
                      "unit": "second"
                    }
                  }
                }|]

        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shelley wa) Default payload
        verify rTx
            [ expectResponseCode HTTP.status202
            ]
        -- TODO: sign/submit tx

    it "TRANS_NEW_VALIDITY_INTERVAL_01b - Validity interval with slot" $ \ctx -> runResourceT $ do
        wa <- fixtureWallet ctx

        let payload = Json [json|{
                "withdrawal": "self",
                "validity_interval": {
                    "invalid_before": {
                      "quantity": 0,
                      "unit": "slot"
                    },
                    "invalid_hereafter": {
                      "quantity": 500,
                      "unit": "slot"
                    }
                  }
                }|]

        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shelley wa) Default payload
        verify rTx
            [ expectResponseCode HTTP.status202
            ]
        -- TODO: sign/submit tx

    it "TRANS_NEW_VALIDITY_INTERVAL_02 - Validity interval second should be >= 0" $ \ctx -> runResourceT $ do

        liftIO $ pendingWith "Accepted but should be 403 - to be fixed in ADP-985"

        wa <- fixtureWallet ctx

        let payload = Json [json|{
                "withdrawal": "self",
                "validity_interval": {
                    "invalid_before": {
                      "quantity": -1,
                      "unit": "second"
                    },
                    "invalid_hereafter": {
                      "quantity": -1,
                      "unit": "second"
                    }
                  }
                }|]

        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shelley wa) Default payload
        verify rTx
            [ expectResponseCode HTTP.status403
            ]

    it "TRANS_NEW_VALIDITY_INTERVAL_02 - Validity interval slot should be >= 0" $ \ctx -> runResourceT $ do

        liftIO $ pendingWith "Returns 400, I think it should be 403 - to be fixed in ADP-985"

        wa <- fixtureWallet ctx

        let payload = Json [json|{
                "withdrawal": "self",
                "validity_interval": {
                    "invalid_before": {
                      "quantity": -1,
                      "unit": "slot"
                    },
                    "invalid_hereafter": {
                      "quantity": -1,
                      "unit": "slot"
                    }
                  }
                }|]

        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shelley wa) Default payload
        verify rTx
            [ expectResponseCode HTTP.status403
            ]

    it "TRANS_NEW_VALIDITY_INTERVAL_02 - Validity interval 'unspecified'" $ \ctx -> runResourceT $ do

        liftIO $ pendingWith
          "Currently throws: \
          \parsing ApiValidityBound object failed, \
          \expected Object, but encountered String \
          \- to be fixed in ADP-985"

        wa <- fixtureWallet ctx

        let payload = Json [json|{
                "withdrawal": "self",
                "validity_interval": {
                    "invalid_before": "unspecified",
                    "invalid_hereafter": "unspecified"
                  }
                }|]

        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shelley wa) Default payload
        verify rTx
            [ expectResponseCode HTTP.status202
            ]

    it "TRANS_NEW_CREATE_MULTI_TX - Tx including payments, delegation, metadata, withdrawals, validity_interval" $ \ctx -> runResourceT $ do

        wa <- fixtureWallet ctx
        wb <- emptyWallet ctx
        addrs <- listAddresses @n ctx wb

        let amt = minUTxOValue (_mainEra ctx) :: Natural
        let destination1 = (addrs !! 1) ^. #id
        let destination2 = (addrs !! 2) ^. #id
        pool:_ <- map (view #id) . snd <$> unsafeRequest
            @[ApiStakePool]
            ctx (Link.listStakePools arbitraryStake) Empty

        let payload = Json [json|{
                "payments": [{
                    "address": #{destination1},
                    "amount": {
                        "quantity": #{amt},
                        "unit": "lovelace"
                    }
                },
                {
                    "address": #{destination2},
                    "amount": {
                        "quantity": #{amt},
                        "unit": "lovelace"
                    }
                }],
                "delegations": [{
                    "join": {
                        "pool": #{pool},
                        "stake_key_index": "0H"
                    }
                }],
                "withdrawal": "self",
                "metadata": { "1": { "string": "hello" } },
                "validity_interval": {
                    "invalid_before": {
                      "quantity": 0,
                      "unit": "second"
                    },
                    "invalid_hereafter": {
                      "quantity": 500,
                      "unit": "second"
                    }
                  }
            }|]

        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shelley wa) Default payload
        verify rTx
            [ expectSuccess
            , expectResponseCode HTTP.status202
            , expectField (#coinSelection . #inputs) (`shouldSatisfy` (not . null))
            -- , expectField (#coinSelection . #outputs) (`shouldSatisfy` (not . null))
            -- , expectField (#coinSelection . #deposit) (`shouldSatisfy` (not . null))
            , expectField (#coinSelection . #change) (`shouldSatisfy` (not . null))
            ]
        -- TODO: now we should sign it and send it in two steps,
        --       make sure it is delivered
        --       make sure balance is updated accordingly on src and dst wallets
        --       make sure delegation cerificates are inserted
        --       make sure metadata is on chain
  -- TODO:
  -- minting
  -- update with sign / submit tx where applicable
  -- end to end join pool and get rewards

    it "TRANS_NEW_BALANCE_01a - multiple-output transaction with all covering inputs present" $ \ctx -> runResourceT $ do
        -- constructing source wallet
        let initialAmt = minUTxOValue (_mainEra ctx)
        wa <- fixtureWalletWith @n ctx [initialAmt]

        -- the tx involes two outputs :
        -- 999978
        -- 999978
        -- results in two changes
        -- 49998927722
        -- 49998927722
        -- incurs the fee of
        -- 144600
        -- and involves one input
        -- 100000000000
        let serializedTxHex =
                "84a600818258200eaa33be8780935ca5a7c1e628a2d54402446f96236c\
                \a8f1770e07fa22ba8648000d80018482583901a65f0e7aea387adbc109\
                \123a571cfd8d0d139739d359caaf966aa5b9a062de6ec013404d4f9909\
                \877d452fc57dfe4f8b67f94e0ea1e8a0ba1a000f422a82583901ac9a56\
                \280ec283eb7e12146726bfe68dcd69c7a85123ce2f7a10e7afa062de6e\
                \c013404d4f9909877d452fc57dfe4f8b67f94e0ea1e8a0ba1a000f422a\
                \825839011a2f2f103b895dbe7388acc9cc10f90dc4ada53f46c841d2ac\
                \44630789fc61d21ddfcbd4d43652bf05c40c346fa794871423b65052d7\
                \614c1b0000000ba42b176a82583901c59701fee28ad31559870ecd6ea9\
                \2b143b1ce1b68ccb62f8e8437b3089fc61d21ddfcbd4d43652bf05c40c\
                \346fa794871423b65052d7614c1b0000000ba42b176a021a000234d803\
                \198ceb0e80a0f5f6" :: Text
        let balancePayload = Json [json|{
              "transaction": { "cborHex" : #{serializedTxHex}, "description": "", "type": "Tx AlonzoEra" },
              "signatories": [],
              "inputs": [
                  { "txIn" : "0eaa33be8780935ca5a7c1e628a2d54402446f96236ca8f1770e07fa22ba8648#0"
                  , "txOut" :
                      { "value" : { "lovelace": 100000000000 }
                      , "address": "addr1vx0d0kyppx3qls8laq5jvpq0qa52d0gahm8tsyj2jpg0lpg4ue9lt"
                      }
                  }]
          }|]
        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.balanceTransaction @'Shelley wa) Default balancePayload
        verify rTx
            [ expectResponseCode HTTP.status403
            , expectErrorMessage errMsg403OutputsAlreadyCovered
            ]

    it "TRANS_NEW_BALANCE_01b - incorrect cbor - not hex-encoded" $ \ctx -> runResourceT $ do
        let initialAmt = minUTxOValue (_mainEra ctx)
        wa <- fixtureWalletWith @n ctx [initialAmt]

        let serializedTx = "84a600818gfrddd" :: Text
        let balancePayload = Json [json|{
              "transaction": { "cborHex" : #{serializedTx}, "description": "", "type": "Tx AlonzoEra" },
              "signatories": [],
              "inputs": []
          }|]
        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.balanceTransaction @'Shelley wa) Default balancePayload
        verify rTx
            [ expectErrorMessage "Error in $: Parse error. Expecting Base16-encoded format." ]

    it "TRANS_NEW_BALANCE_01c - incorrect cbor - hex-encoded but cannot deserialize into sealedTx" $ \ctx -> runResourceT $ do
        let initialAmt = minUTxOValue (_mainEra ctx)
        wa <- fixtureWalletWith @n ctx [initialAmt]

        let serializedTx = "84a6008180000000000000" :: Text
        let balancePayload = Json [json|{
              "transaction": { "cborHex" : #{serializedTx}, "description": "", "type": "Tx AlonzoEra" },
              "signatories": [],
              "inputs": []
          }|]
        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.balanceTransaction @'Shelley wa) Default balancePayload
        verify rTx
            [ expectErrorMessage "Error in $: cborHex seems to be not deserializing correctly due to DecoderErrorDeserialiseFailure 'Shelley Tx' (DeserialiseFailure 5 'expected bytes'" ]

    it "TRANS_NEW_BALANCE_01d - single-output transaction with missing covering inputs" $ \ctx -> runResourceT $ do
        -- constructing source wallet
        let initialAmt = 110_000_000_000
        let inpAmt = minUTxOValue (_mainEra ctx)
        wa <- fixtureWalletWith @n ctx [initialAmt]

        let serializedTx =
                "84a600818258200eaa33be8780935ca5a7c1e628a2d54402446f96236ca8f1\
                \770e07fa22ba86480d0d800182825839010acce4f85ade867308f048fe4516\
                \c0383b38cc04602ea6f7a6a1e75f29450899547b0e4bb194132452d45fea30\
                \212aebeafc69bca8744ea61a002dc67e8258390110a9b4666ba80e4878491d\
                \1ac20465c9893a8df5581dc705770626203d4d23fe6a7acdda5a1b41f56100\
                \f02bfa270a3c560c4e55cf8312331b00000017484721ca021a0001ffb80319\
                \8d280e80a0f5f6" :: Text
        let balancePayload = Json [json|{
              "transaction": { "cborHex" : #{serializedTx}, "description": "", "type": "Tx AlonzoEra" },
              "signatories": [],
              "inputs": [
                  { "txIn" : "0eaa33be8780935ca5a7c1e628a2d54402446f96236ca8f1770e07fa22ba8648#13"
                  , "txOut" :
                      { "value" : { "lovelace": #{inpAmt} }
                      , "address": "addr1vxtlefx3dd5ga5d3cqcfycxsc5tv20txpx7qlmlt2kwnfds2mywcr"
                      }
                  }]
          }|]
        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.balanceTransaction @'Shelley wa) Default balancePayload
        verify rTx
            [ expectSuccess
            , expectResponseCode HTTP.status202
            , expectField (#coinSelection . #inputs) (`shouldSatisfy` (not . null))
            ]
  where
    -- Construct a JSON payment request for the given quantity of lovelace.
    mkTxPayload
        :: MonadUnliftIO m
        => Context
        -> ApiWallet
        -> Natural
        -> m ((ApiT Address, Proxy n), Payload)
    mkTxPayload ctx wDest amt = do
        addrs <- listAddresses @n ctx wDest
        let destination = (addrs !! 1) ^. #id
        return (destination, Json [json|{
                "payments": [{
                    "address": #{destination},
                    "amount": {
                        "quantity": #{amt},
                        "unit": "lovelace"
                    }
                  }]
                }|])
    -- Like mkTxPayload, except that assets are included in the payment.
    -- Asset amounts are specified by ((PolicyId Hex, AssetName Hex), amount).
    mkTxPayloadMA
        :: forall l m.
            ( DecodeAddress l
            , DecodeStakeAddress l
            , EncodeAddress l
            , MonadUnliftIO m
            )
        => (ApiT Address, Proxy l)
        -> Natural
        -> [((Text, Text), Natural)]
        -> m Payload
    mkTxPayloadMA destination coin val = do
        let assetJson ((pid, name), q) = [json|{
                    "policy_id": #{pid},
                    "asset_name": #{name},
                    "quantity": #{q}
                }|]
        return $ Json [json|{
                "payments": [{
                    "address": #{destination},
                    "amount": {
                        "quantity": #{coin},
                        "unit": "lovelace"
                    },
                    "assets": #{map assetJson val}
                }]
            }|]
