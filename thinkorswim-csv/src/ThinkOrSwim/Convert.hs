{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}

module ThinkOrSwim.Convert where

{-
module ThinkOrSwim.Convert (convertOrders) where

import           Control.Applicative
import           Control.Lens
import           Control.Monad.State
import           Data.Amount
import           Data.Coerce
import           Data.Foldable
import qualified Data.Ledger as L
import           Data.Ledger hiding (symbol, quantity, cost, price)
import           Data.Map (Map)
import qualified Data.Map as M
import           Data.Maybe (catMaybes, isNothing)
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Text.Lens
import           Data.Time
import           Data.Time.Format.ISO8601
import           Prelude hiding (Float, Double, (<>))
import           Text.PrettyPrint
import qualified ThinkOrSwim.API.TransactionHistory.GetTransactions as API
import           ThinkOrSwim.API.TransactionHistory.GetTransactions hiding (symbol, cost)
import           ThinkOrSwim.Event
import           ThinkOrSwim.Options (Options)

convertOrders
    :: Options
    -> TransactionHistory
    -> State (GainsKeeperState API.Transaction)
            [L.Transaction API.TransactionSubType API.Order L.CommodityLot]
convertOrders opts hist =
    catMaybes <$>
        Prelude.mapM (convertOrder opts (hist^.ordersMap))
                     (hist^.settlementList)

getOrder :: OrdersMap -> Either API.Transaction API.OrderId -> API.Order
getOrder _ (Left t)    = orderFromTransaction t
getOrder m (Right oid) = m^?!ix oid

convertOrder
    :: Options
    -> OrdersMap
    -> (Day, Either API.Transaction API.OrderId)
    -> State (GainsKeeperState API.Transaction)
            (Maybe (L.Transaction API.TransactionSubType
                                  API.Order L.CommodityLot))
convertOrder opts m (sd, getOrder m -> o) = do
    let _actualDate    = sd
        _effectiveDate = Nothing
        _code          = o^.orderId
        _payee         = o^.orderDescription
        _xactMetadata  =
            M.empty & at "Type"   ?~ T.pack (show (o^.orderType))
                    & at "Symbol" .~ base
        _provenance    = o
    _postings <- Prelude.concat <$>
        mapM (convertPostings opts (T.pack (show (o^.orderAccountId))))
             (o^.transactions)
    pure $ case _postings of
        [] -> Nothing
        _  -> Just L.Transaction {..}
  where
    base | Prelude.all (== Prelude.head xs) (Prelude.tail xs) = Prelude.head xs
         | otherwise =
               error $ "Transaction deals with various symbols: " ++ show xs
        where
            xs = Prelude.map (^.xunderlying) (o^.transactions)

convertPostings
    :: Options
    -> Text
    -> API.Transaction
    -> State (GainsKeeperState API.Transaction)
            [L.Posting API.TransactionSubType L.CommodityLot]
convertPostings _ _ t | t^.xsubType == TradeCorrection = pure []
convertPostings opts actId t = do
    events <- gainsKeeper opts t
    pure $ case events of
        [] -> []
        xs -> roundPostings (posts xs)
  where
    posts cs
        = [ newPosting L.Fees True (DollarAmount (t^.fees_.regFee))
          | t^.fees_.regFee /= 0 ]
       ++ [ newPosting L.Charges True (DollarAmount (t^.fees_.otherCharges))
          | t^.fees_.otherCharges /= 0 ]
       ++ [ newPosting L.Commissions True (DollarAmount (t^.fees_.commission))
          | t^.fees_.commission /= 0 ]

       ++ concatMap (postingFromAction actId) cs

       ++ [ case t^?xprice of
                Just _              -> cashPost
                Nothing | isPriced  -> cashPost
                        | otherwise -> newPosting act False NullAmount
          | case t^?xprice of
                Just _  -> isPriced
                Nothing -> not fromEquity ]
       ++ [ newPosting OpeningBalances False NullAmount
          | isNothing (t^?xamount) || fromEquity ]

    act          = transactionAccount actId t
    isPriced     = t^.netAmount /= 0 || t^.xsubType `elem` [ OptionExpiration ]
    fromEquity   = t^.xsubType `elem` [ TransferIn ]
    -- cashXact     = subtyp `elem` [ CashAlternativesPurchase
    --                         , CashAlternativesRedemption ]
    -- direct       = cashXact || not (has xamount t) || fromEquity
    -- maybeNet     = if direct then Nothing else Just (t^.netAmount)

    cashPost = newPosting (Cash actId) False $
        if t^.netAmount == 0
        then NullAmount
        else DollarAmount (t^.netAmount)

    roundPostings ps =
        let slip = - sumPostings ps
        in ps ++ [ newPosting L.RoundingError False (DollarAmount slip)
                 | slip /= 0 && abs slip < 0.02 ]

-- The idea of this function is to replicate what Ledger will calculate the
-- sum to be, so that if there's any discrepancy we can add a rounding
-- adjustment to pass the balancing check.
sumPostings :: [L.Posting API.TransactionSubType L.CommodityLot] -> Amount 2
sumPostings = foldl' go 0
  where
    norm = normalizeAmount mpfr_RNDNA

    cst l | l^.isVirtual = 0
          | l^.L.account == L.RoundingError = 0
          | Just n <- l^?L.amount._DollarAmount = norm n
          | Just q <- l^?L.amount._CommodityAmount.L.quantity,
            Just n <- l^?L.amount._CommodityAmount.L.cost.each =
              let n' | q < 0     = -n
                     | otherwise = n
              in norm (coerce n')
          | otherwise = 0

    go acc pl = acc + cst pl

transactionAccount :: Text -> API.Transaction -> L.Account
transactionAccount actId t = case t^?xasset of
    Just API.Equity              -> Equities actId
    Just MutualFund              -> Equities actId
    Just (OptionAsset _)         -> Options  actId
    Just (FixedIncomeAsset _)    -> Bonds actId
    Just (CashEquivalentAsset _) -> MoneyMarkets actId
    Nothing                      -> OpeningBalances

mkCommodityLot :: Lot API.Transaction
               -> CommodityLot API.TransactionSubType
mkCommodityLot t = newCommodityLot @API.TransactionSubType
    & instrument   .~ instr
    & L.quantity   .~ t^.quantity.coerced
    & L.symbol     .~ t^.symbol.non "???"
    & L.cost       ?~ t^.cost.coerced.to abs
    & purchaseDate ?~ utctDay (t^.time)
    & L.note       ?~ T.pack (render (renderRefList (t^.trail)))
    & L.price      .~ fmap (* (if isOption t then 100 else 1))
                           (t^?item.xprice.coerced)

  where
    instr = case t^?item.xasset of
        Just API.Equity           -> L.Equity
        Just MutualFund           -> L.Equity
        Just (OptionAsset _)      -> L.Option
        Just (FixedIncomeAsset _) -> L.Bond
        Just (CashEquivalentAsset
              CashMoneyMarket)    -> L.MoneyMarket
        Nothing                   -> error "Unexpected"

postingFromAction
    :: Text
    -> Action (Lot API.Transaction)
    -> [L.Posting API.TransactionSubType L.CommodityLot]
postingFromAction actId act = case act of
    OpenPosition disp _ o ->
        openPos disp o & each.postMetadata %~ metadata act o
    ClosePosition disp c ->
        posClosed disp c & each.postMetadata %~ metadata act c

    WashLoss g ->
        [ newPosting CapitalWashLoss False (DollarAmount (g^.cost.coerced)) ]
    WashDeferred g ->
        [ newPosting CapitalWashLossDeferred False MetadataOnly
            & postMetadata.at "WashDeferred" ?~
                ("$" ++ show (g^.cost.to negate))^.packed ]

    CapitalGain disp g _ ->
        [ newPosting
            (case disp of LongTerm    -> CapitalGainLong
                          ShortTerm   -> CapitalGainShort
                          Collectible -> CapitalGainCollectible)
            False (DollarAmount (g^.coerced.to negate)) ]
    CapitalLoss disp g _ ->
        [ newPosting
            (case disp of LongTerm    -> CapitalLossLong
                          ShortTerm   -> CapitalLossShort
                          Collectible -> CapitalLossCollectible)
            False (DollarAmount (g^.coerced.to negate)) ]

    RoundTransaction rnd ->
        [ newPosting L.RoundingError False (DollarAmount rnd) ]

    Unrecognized t ->
        [ newPosting Unknown False
            (case t^.cost.coerced of
                 n | n == 0    -> NullAmount
                   | otherwise -> DollarAmount n) ]
          & each.postMetadata %~ metadata act t

    _ -> []
    -- _ -> error $ "Failed to convert event: " ++ render (rendered act)
  where
    openPos disp o =
        [ newPosting (transactionAccount actId (o^.item)) False
            (CommodityAmount $ mkCommodityLot o
               & L.quantity %~ case disp of Long -> id; Short -> negate) ]
    posClosed disp c =
        [ newPosting (transactionAccount actId (c^.item)) False
            (CommodityAmount $ mkCommodityLot c
               & L.quantity %~ case disp of Long -> id; Short -> negate
               & L.price    .~
                   if isOptionAssignment c
                   then Just 0
                   else fmap (* (if isOption c then 100 else 1))
                             (c^?item.xprice.coerced)) ]

metadata :: Action (Lot API.Transaction)
         -> Lot API.Transaction
         -> Map Text Text
         -> Map Text Text
metadata act x m = m
    & at "XId"          ?~ T.pack (show (x^.item.xid))
    & at "XType"        ?~ T.pack (show (x^.item.xsubType))
    & at "XDate"        ?~ T.pack (iso8601Show (x^.item.xdate))
    & at "Instruction"  .~ x^?item.xinstruction._Just.to show.packed
    & at "CUSIP"        .~ x^.item.xcusip
    & at "Instrument"   .~ x^?item.xasset.to assetKind
    & at "Side"         .~ x^?item.xoption.putCall.to show.packed
    & at "Strike"       .~ x^?item.xoption.strikePrice._Just.to thousands.packed
    & at "Expiration"   .~ x^?item.xoption.expirationDate.to (T.pack . iso8601Show)
    & at "Contract"     .~ x^?item.xoption.description
    & at "Effect"       .~ (effectDesc act <|>
                            x^?item.xitem.positionEffect.each.to show.packed)
  where
    effectDesc = \case
        OpenPosition disp _ _ -> Just $ T.pack $ "Open " ++ show disp
        ClosePosition disp _  -> Just $ T.pack $ "Close " ++ show disp
        _ -> Nothing

-}
