{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}

module ThinkOrSwim.Convert (convertTransactions) where

import           Control.Applicative
import           Control.Lens
import           Control.Monad.State
import           Data.Amount
import           Data.Ledger as L
import qualified Data.Map as M
import           Data.Maybe (isNothing)
import           Data.Text as T
import           Data.Text.Lens
import           Data.Time
import           Data.Time.Format.ISO8601
import           Prelude hiding (Float, Double, (<>))
import           ThinkOrSwim.API.TransactionHistory.GetTransactions as API
import           ThinkOrSwim.Fixup
import           ThinkOrSwim.Gains
import           ThinkOrSwim.Options (Options)
import           ThinkOrSwim.Types

convertTransactions
    :: Options
    -> GainsKeeperState API.TransactionSubType API.Transaction
    -> TransactionHistory
    -> [L.Transaction API.TransactionSubType API.Order
                     API.Transaction L.LotAndPL]
convertTransactions opts st hist = (`evalState` st) $
    Prelude.mapM (convertTransaction opts (hist^.ordersMap))
                 (hist^.settlementList)

getOrder :: OrdersMap -> Either API.Transaction API.OrderId -> API.Order
getOrder _ (Left t)    = orderFromTransaction t
getOrder m (Right oid) = m^?!ix oid

convertTransaction
    :: Options
    -> OrdersMap
    -> (Day, Either API.Transaction API.OrderId)
    -> State (GainsKeeperState API.TransactionSubType API.Transaction)
            (L.Transaction API.TransactionSubType API.Order
                           API.Transaction L.LotAndPL)
convertTransaction opts m (sd, getOrder m -> o) = do
    let _actualDate    = sd
        _effectiveDate = Nothing
        _code          = o^.orderId
        _payee         = o^.orderDescription
        _xactMetadata  =
            M.empty & at "Type"   ?~ T.pack (show (o^.orderType))
                    & at "Symbol" .~ case underlying of "" -> Nothing; s -> Just s
        _provenance    = o
    _postings <- Prelude.concat <$>
        mapM (convertPostings opts (T.pack (show (o^.orderAccountId))))
             (o^.transactions)
    fixupTransaction L.Transaction {..}
  where
    underlying
        | Prelude.all (== Prelude.head xs) (Prelude.tail xs) = Prelude.head xs
        | otherwise =
              error $ "Transaction deals with various symbols: " ++ show xs
        where
            xs = Prelude.map (^.baseSymbol) (o^.transactions)

convertPostings
    :: Options
    -> Text
    -> API.Transaction
    -> State (GainsKeeperState API.TransactionSubType API.Transaction)
            [L.Posting API.TransactionSubType API.Transaction L.LotAndPL]
convertPostings _ _ t
    | t^.transactionInfo_.transactionSubType == TradeCorrection = pure []
convertPostings opts actId t = posts <$>
    maybe (pure []) (gainsKeeper opts maybeNet t) (t^.item.API.amount)
  where
    posts cs
        = [ post L.Fees True (DollarAmount (t^.fees_.regFee))
          | t^.fees_.regFee /= 0 ]
       ++ [ post L.Charges True (DollarAmount (t^.fees_.otherCharges))
          | t^.fees_.otherCharges /= 0 ]
       ++ [ post L.Commissions True (DollarAmount (t^.fees_.commission))
          | t^.fees_.commission /= 0 ]

       ++ (flip Prelude.concatMap cs $ \pl ->
            [ post act False (CommodityAmount pl)
                  & postMetadata %~ meta
                  & postMetadata.at "Effect" %~
                        (<|> Just (if pl^.plLoss == 0
                                   then "Opening"
                                   else "Closing"))
            | pl^.plKind /= Rounding ])

       ++ [ case t^.item.API.price of
                Just _              -> cashPost
                Nothing | isPriced  -> cashPost
                        | otherwise -> post act False NoAmount
          | case t^.item.API.price of
                Just _  -> isPriced
                Nothing -> not fromEquity ]
       ++ [ post OpeningBalances False NoAmount
          | isNothing (t^.item.API.amount) || fromEquity ]
      where
        post = newPosting

    meta m = m
        & at "XType"       ?~ T.pack (show subtyp)
        & at "XId"         ?~ T.pack (show (t^.xactId))
        & at "XDate"       ?~ T.pack (iso8601Show (t^.xactDate))
        & at "Instruction" .~ t^?item.instruction._Just.to show.packed
        & at "Effect"      .~ t^?item.positionEffect._Just.to show.packed
        & at "CUSIP"       .~ t^?instrument_._Just.cusip
        & at "Instrument"  .~ t^?instrument_._Just.assetType.to assetKind
        & at "Side"        .~ t^?option'.putCall.to show.packed
        & at "Strike"      .~ t^?option'.strikePrice._Just.to thousands.packed
        & at "Expiration"  .~ t^?option'.expirationDate.to (T.pack . iso8601Show)
        & at "Contract"    .~ t^?option'.description

    act = case atype of
        Just API.Equity              -> Equities actId
        Just MutualFund              -> Equities actId
        Just (OptionAsset _)         -> Options  actId
        Just (FixedIncomeAsset _)    -> Bonds actId
        Just (CashEquivalentAsset _) -> MoneyMarkets actId
        Nothing                      -> OpeningBalances

    atype      = t^?instrument_._Just.assetType
    subtyp     = t^.transactionInfo_.transactionSubType
    isPriced   = t^.netAmount /= 0 || subtyp `elem` [ OptionExpiration ]
    direct     = cashXact || isNothing (t^.item.API.amount) || fromEquity
    maybeNet   = if direct then Nothing else Just (t^.netAmount)
    fromEquity = subtyp `elem` [ TransferOfSecurityOrOptionIn ]
    cashXact   = subtyp `elem` [ CashAlternativesPurchase
                          , CashAlternativesRedemption ]

    cashPost = newPosting (Cash actId) False $
        if t^.netAmount == 0
        then NoAmount
        else DollarAmount (t^.netAmount)
