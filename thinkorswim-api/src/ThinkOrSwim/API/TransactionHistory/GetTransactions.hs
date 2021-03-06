{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module ThinkOrSwim.API.TransactionHistory.GetTransactions where

import Control.Applicative
import Control.Lens
import Control.Monad.State
import Data.Aeson hiding ((.=))
import Data.Amount
import Data.Default
import Data.Int
import Data.List (sortBy)
import Data.Map (Map)
import Data.Ord
import Data.Semigroup hiding (Option, option)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time
import Data.Time.Format.ISO8601
import Data.Utils
import System.IO.Unsafe
import qualified Text.PrettyPrint as P
import Text.PrettyPrint hiding ((<+>), (<>))
import Text.Show.Pretty
import Prelude hiding (Double, Float)

data FixedIncome
  = FixedIncome
      { _bondInterestRate :: Amount 2,
        _bondMaturityDate :: UTCTime
      }
  deriving (Eq, Ord, Show)

makeLenses ''FixedIncome

data PutCall
  = Put
  | Call
  deriving (Eq, Ord, Show, Enum, Bounded)

makePrisms ''PutCall

instance FromJSON PutCall where
  parseJSON = withText "putCall" $ \t ->
    case t of
      "PUT" -> pure Put
      "CALL" -> pure Call
      _ -> fail $ "putCall unexpected: " ++ T.unpack t

data Option
  = Option
      { _description :: Text,
        _putCall :: PutCall,
        _strikePrice :: Maybe (Amount 2),
        _expirationDate :: UTCTime,
        _underlyingSymbol :: Text
      }
  deriving (Eq, Ord, Show)

makeLenses ''Option

data CashEquivalent
  = CashMoneyMarket
  deriving (Eq, Ord, Show, Enum, Bounded)

makeLenses ''CashEquivalent

instance FromJSON CashEquivalent where
  parseJSON = withText "cashEquivalent" $ \t ->
    case t of
      "MONEY_MARKET" -> pure CashMoneyMarket
      _ -> fail $ "cashEquivalent unexpected: " ++ T.unpack t

data AssetType
  = Equity
  | MutualFund
  | OptionAsset Option
  | FixedIncomeAsset FixedIncome
  | CashEquivalentAsset CashEquivalent
  deriving (Eq, Ord, Show)

makePrisms ''AssetType

assetKind :: AssetType -> Text
assetKind = \case
  Equity -> "Equity"
  MutualFund -> "MutualFund"
  OptionAsset _ -> "Option"
  FixedIncomeAsset _ -> "FixedIncome"
  CashEquivalentAsset _ -> "CashEquivalent"

data Instrument
  = Instrument
      { _assetType :: AssetType,
        _symbol :: Text,
        _cusip :: Text
      }
  deriving (Eq, Ord, Show)

makeLenses ''Instrument

instance FromJSON Instrument where
  parseJSON = withObject "instrument" $ \obj -> do
    _assetTypeText <- obj .: "assetType"
    _cusip <- obj .: "cusip"
    _symbol <- obj .:? "symbol" .!= ""
    -- _bondInterestRate     <- obj .:? "bondInterestRate"
    -- _bondMaturityDate     <- obj .:? "bondMaturityDate"
    -- _description          <- obj .:? "description"
    -- _putCall              <- obj .:? "putCall"
    -- _optionStrikePrice    <- obj .:? "optionStrikePrice"
    -- _optionExpirationDate <- obj .:? "optionExpirationDate"
    -- _underlyingSymbol     <- obj .:? "underlyingSymbol"

    _assetType <- case _assetTypeText of
      "EQUITY" -> pure Equity
      "MUTUAL_FUND" -> pure MutualFund
      "OPTION" ->
        fmap OptionAsset $
          Option
            <$> obj .:? "description" .!= ""
            <*> obj .:? "putCall" .!= Call
            <*> obj .:? "optionStrikePrice"
            <*> obj .: "optionExpirationDate"
            <*> obj .:? "underlyingSymbol" .!= ""
      "FIXED_INCOME" ->
        fmap FixedIncomeAsset $
          FixedIncome
            <$> obj .: "bondInterestRate"
            <*> obj .: "bondMaturityDate"
      "CASH_EQUIVALENT" ->
        CashEquivalentAsset
          <$> obj .: "type"
      _ -> fail $ "assetType unexpected: " ++ T.unpack _assetTypeText
    pure Instrument {..}

data PositionEffect
  = Open
  | Close
  | Automatic
  deriving (Eq, Ord, Show, Enum, Bounded)

makePrisms ''PositionEffect

instance FromJSON PositionEffect where
  parseJSON = withText "positionEffect" $ \t ->
    case t of
      "OPENING" -> pure Open
      "CLOSING" -> pure Close
      "AUTOMATIC" -> pure Automatic
      _ -> fail $ "positionEffect unexpected: " ++ T.unpack t

data Instruction
  = Buy
  | Sell
  deriving (Eq, Ord, Show, Enum, Bounded)

makePrisms ''Instruction

instance FromJSON Instruction where
  parseJSON = withText "instruction" $ \t ->
    case t of
      "BUY" -> pure Buy
      "SELL" -> pure Sell
      _ -> fail $ "instruction unexpected: " ++ T.unpack t

type AccountId = Int32

data TransactionItem
  = TransactionItem
      { _transactionInstrument :: Maybe Instrument,
        _positionEffect :: Maybe PositionEffect,
        _instruction :: Maybe Instruction,
        -- , _parentChildIndicator  :: Maybe Text
        -- , _parentOrderKey        :: Maybe Int32
        _cost :: Amount 6,
        _price :: Maybe (Amount 6),
        _amount :: Maybe (Amount 6),
        _accountId :: AccountId
      }
  deriving (Eq, Ord, Show)

makeLenses ''TransactionItem

instance FromJSON TransactionItem where
  parseJSON = withObject "transactionItem" $ \obj -> do
    _transactionInstrument <- obj .:? "instrument"
    _positionEffect <- obj .:? "positionEffect"
    _instruction <- obj .:? "instruction"
    -- _parentChildIndicator  <- obj .:? "parentChildIndicator"
    -- _parentOrderKey        <- obj .:? "parentOrderKey"
    _cost <- obj .: "cost"
    _price <- obj .:? "price"
    _amount <- obj .:? "amount"
    _accountId <- obj .: "accountId"
    pure TransactionItem {..}

data Fees
  = Fees
      { _rFee :: Amount 2,
        _additionalFee :: Amount 2,
        _cdscFee :: Amount 2,
        _regFee :: Amount 2,
        _otherCharges :: Amount 2,
        _commission :: Amount 2,
        _optRegFee :: Amount 2,
        _secFee :: Amount 2
      }
  deriving (Eq, Ord, Show)

makeLenses ''Fees

instance Semigroup Fees where
  x <> y =
    Fees
      { _rFee = x ^. rFee + y ^. rFee,
        _additionalFee = x ^. additionalFee + y ^. additionalFee,
        _cdscFee = x ^. cdscFee + y ^. cdscFee,
        _regFee = x ^. regFee + y ^. regFee,
        _otherCharges = x ^. otherCharges + y ^. otherCharges,
        _commission = x ^. commission + y ^. commission,
        _optRegFee = x ^. optRegFee + y ^. optRegFee,
        _secFee = x ^. secFee + y ^. secFee
      }

instance Monoid Fees where
  mempty =
    Fees
      { _rFee = 0.0,
        _additionalFee = 0.0,
        _cdscFee = 0.0,
        _regFee = 0.0,
        _otherCharges = 0.0,
        _commission = 0.0,
        _optRegFee = 0.0,
        _secFee = 0.0
      }
  mappend = (<>)

instance FromJSON Fees where
  parseJSON = withObject "fees" $ \obj -> do
    _rFee <- obj .: "rFee"
    _additionalFee <- obj .: "additionalFee"
    _cdscFee <- obj .: "cdscFee"
    _regFee <- obj .: "regFee"
    _otherCharges <- obj .: "otherCharges"
    _commission <- obj .: "commission"
    _optRegFee <- obj .: "optRegFee"
    _secFee <- obj .: "secFee"
    pure Fees {..}

data AchStatus
  = Approved
  | Rejected
  | Cancel
  | Error_
  deriving (Eq, Ord, Show, Enum, Bounded)

makePrisms ''AchStatus

instance FromJSON AchStatus where
  parseJSON = withText "achStatus" $ \t ->
    case t of
      "Approved" -> pure Approved
      "Rejected" -> pure Rejected
      "Cancel" -> pure Cancel
      "Error" -> pure Error_
      _ -> fail $ "achStatus unexpected: " ++ T.unpack t

data TransactionType
  = Trade
  | ReceiveAndDeliver
  | DividendOrInterest
  | AchReceipt
  | AchDisbursement
  | CashReceipt
  | CashDisbursement
  | ElectronicFund
  | WireOut
  | WireIn
  | Journal
  | Memorandum
  | MarginCall
  | MoneyMarket
  | SmaAdjustment
  deriving (Eq, Ord, Show, Enum, Bounded)

makePrisms ''TransactionType

instance FromJSON TransactionType where
  parseJSON = withText "transactionType" $ \t ->
    case t of
      "TRADE" -> pure Trade
      "RECEIVE_AND_DELIVER" -> pure ReceiveAndDeliver
      "DIVIDEND_OR_INTEREST" -> pure DividendOrInterest
      "ACH_RECEIPT" -> pure AchReceipt
      "ACH_DISBURSEMENT" -> pure AchDisbursement
      "CASH_RECEIPT" -> pure CashReceipt
      "CASH_DISBURSEMENT" -> pure CashDisbursement
      "ELECTRONIC_FUND" -> pure ElectronicFund
      "WIRE_OUT" -> pure WireOut
      "WIRE_IN" -> pure WireIn
      "JOURNAL" -> pure Journal
      "MEMORANDUM" -> pure Memorandum
      "MARGIN_CALL" -> pure MarginCall
      "MONEY_MARKET" -> pure MoneyMarket
      "SMA_ADJUSTMENT" -> pure SmaAdjustment
      _ -> fail $ "transactionType unexpected: " ++ T.unpack t

type TransactionId = Int64

data TransactionSubType
  = AdrFee -- AF
  | BuyTrade -- BY
  | FreeBalanceInterestAdjustment -- CA
  | TransferFromCashAccount -- CI
  | CloseShortPosition -- CS
  | DirectDeposit -- DD
  | TransferFromFuturesAccount -- FI
  | TransferToFuturesAccount -- FO
  | OffCycleInterest -- IO
  | SecuritiesInterestIncome -- IS
  | InternalTransfer -- IT
  | MiscellaneousJournalEntry -- JN
  | MarkToMarket -- MK
  | ForeignTaxWithheld -- ND
  | OptionAssignment -- OA
  | OptionExpiration -- OX
  | CashAlternativesPurchase -- PM
  | QualifiedDividend -- QF
  | Rebate -- RB
  | BondsRedemption -- RE
  | CashAlternativesRedemption -- RM
  | SellTrade -- SL
  | ShortSale -- SS
  | TradeCorrection -- TC
  | TransferIn -- TI
  | WireIncoming -- WI
  | TransferFromForexAccount -- XI
  | TransferToForexAccount -- XO
  deriving (Eq, Ord, Enum, Bounded)

makePrisms ''TransactionSubType

instance Default TransactionSubType where
  def = BuyTrade

instance Show TransactionSubType where
  show = \case
    AdrFee -> "AF" -- "ADR FEE"
    BuyTrade -> "BY" -- "BUY TRADE"
    FreeBalanceInterestAdjustment -> "CA" -- "FREE BALANCE INTEREST ADJUSTMENT"
    TransferFromCashAccount -> "CI" -- "ACH TRANSER FROM CASH ACCOUNT"
    CloseShortPosition -> "CS" -- "CLOSE SHORT POSITION"
    DirectDeposit -> "DD" -- "ACH DIRECT DEPOSIT"
    TransferFromFuturesAccount -> "FI" -- "TRANSFER FROM FUTURES ACCOUNT"
    TransferToFuturesAccount -> "FO" -- "TRANSFER TO FUTURES ACCOUNT"
    OffCycleInterest -> "IO" -- "OFF-CYCLE INTEREST"
    SecuritiesInterestIncome -> "IS" -- "INTEREST INCOME - SECURITIES"
    InternalTransfer -> "IT" -- "INTERNAL TRANSFER BETWEEN ACCOUNTS OR ACCOUNT TYPES"
    MiscellaneousJournalEntry -> "JN" -- "MISCELLANEOUS JOURNAL ENTRY"
    MarkToMarket -> "MK" -- "MARK TO THE MARKET"
    ForeignTaxWithheld -> "ND" -- "FOREIGN TAX WITHHELD"
    OptionAssignment -> "OA" -- "OPTION ASSIGNMENT"
    OptionExpiration -> "OX" -- "REMOVAL OF OPTION DUE TO EXPIRATION"
    CashAlternativesPurchase -> "PM" -- "CASH ALTERNATIVES PURCHASE"
    QualifiedDividend -> "QF" -- "QUALIFIED DIVIDEND"
    Rebate -> "RB" -- "REBATE"
    BondsRedemption -> "RE" -- "BONDS - REDEMPTION"
    CashAlternativesRedemption -> "RM" -- "CASH ALTERNATIVES REDEMPTION"
    SellTrade -> "SL" -- "SELL TRADE"
    ShortSale -> "SS" -- "SHORT SALE"
    TradeCorrection -> "TC" -- "TRADE CORRECTION"
    TransferIn -> "TI" -- "TRANSFER OF SECURITY OR OPTION IN"
    WireIncoming -> "WI" -- "WIRE INCOMING"
    TransferFromForexAccount -> "XI" -- "TRANSFER FROM FOREX ACCOUNT"
    TransferToForexAccount -> "XO" -- "TRANSFER TO FOREX ACCOUNT"

instance FromJSON TransactionSubType where
  parseJSON = withText "transactionSubType" $ \t ->
    case t of
      "AF" -> pure AdrFee
      "BY" -> pure BuyTrade
      "CA" -> pure FreeBalanceInterestAdjustment
      "CI" -> pure TransferFromCashAccount
      "CS" -> pure CloseShortPosition
      "DD" -> pure DirectDeposit
      "FI" -> pure TransferFromFuturesAccount
      "FO" -> pure TransferToFuturesAccount
      "IO" -> pure OffCycleInterest
      "IS" -> pure SecuritiesInterestIncome
      "IT" -> pure InternalTransfer
      "JN" -> pure MiscellaneousJournalEntry
      "MK" -> pure MarkToMarket
      "ND" -> pure ForeignTaxWithheld
      "OA" -> pure OptionAssignment
      "OX" -> pure OptionExpiration
      "PM" -> pure CashAlternativesPurchase
      "QF" -> pure QualifiedDividend
      "RB" -> pure Rebate
      "RE" -> pure BondsRedemption
      "RM" -> pure CashAlternativesRedemption
      "SL" -> pure SellTrade
      "SS" -> pure ShortSale
      "TC" -> pure TradeCorrection
      "TI" -> pure TransferIn
      "WI" -> pure WireIncoming
      "XI" -> pure TransferFromForexAccount
      "XO" -> pure TransferToForexAccount
      _ -> fail $ "transactionSubType unexpected: " ++ T.unpack t

data TransactionInfo t
  = TransactionInfo
      { _transactionId :: TransactionId,
        _transactionSubType :: TransactionSubType,
        _transactionDate :: UTCTime,
        _transactionItem_ :: TransactionItem,
        _transactionDescription :: Text
      }
  deriving (Eq, Ord, Show)

makeLenses ''TransactionInfo

data Transaction
  = Transaction
      { _transactionInfo_ :: TransactionInfo Transaction,
        _fees_ :: Fees,
        _accruedInterest :: Maybe (Amount 2),
        _achStatus :: Maybe AchStatus,
        _cashBalanceEffectFlag :: Bool,
        _transactionOrderDate :: Maybe UTCTime,
        _netAmount :: Amount 2,
        _dayTradeBuyingPowerEffect :: Maybe (Amount 2),
        _requirementReallocationAmount :: Maybe (Amount 2),
        _sma :: Maybe (Amount 2),
        _transactionOrderId :: Maybe Text,
        _settlementDate :: Day,
        _subAccount :: Text,
        _clearingReferenceNumber :: Maybe Text,
        _type_ :: TransactionType
      }
  deriving (Eq, Ord, Show)

makeLenses ''Transaction

instance FromJSON Transaction where
  parseJSON = withObject "transaction" $ \obj -> do
    _transactionItem_ <- obj .: "transactionItem"
    _transactionId <- obj .: "transactionId"
    _transactionSubType <- obj .: "transactionSubType"
    _transactionDate <- obj .: "transactionDate"
    _transactionDescription <- obj .: "description"
    let _transactionInfo_ = TransactionInfo {..}
    _accruedInterest <- obj .:? "accruedInterest"
    _achStatus <- obj .:? "achStatus"
    _cashBalanceEffectFlag <- obj .:? "cashBalanceEffectFlag" .!= False
    _transactionOrderDate <- obj .:? "orderDate"
    _netAmount <- obj .: "netAmount"
    _fees_ <- obj .: "fees"
    _dayTradeBuyingPowerEffect <- obj .:? "dayTradeBuyingPowerEffect"
    _requirementReallocationAmount <- obj .:? "requirementReallocationAmount"
    _sma <- obj .:? "sma"
    _transactionOrderId <- obj .:? "orderId"
    _settlementDate <- iso8601ParseM =<< obj .: "settlementDate"
    _subAccount <- obj .: "subAccount"
    _clearingReferenceNumber <- obj .:? "clearingReferenceNumber"
    _type_ <- obj .: "type"
    pure Transaction {..}

data Order
  = Order
      { _transactions :: [Transaction],
        _orderId :: Text,
        _orderType :: TransactionType,
        _orderDate :: UTCTime,
        _orderDescription :: Text,
        _orderAccountId :: AccountId
      }
  deriving (Eq, Ord, Show)

makeLenses ''Order

type CUSIPMap = Map Text Instrument

type OrderId = Text

type OrdersMap = Map OrderId Order

type SettlementList = [(Day, Either Transaction OrderId)]

data TransactionHistory
  = TransactionHistory
      { _allTransactions :: [Transaction],
        _cusipMap :: CUSIPMap,
        _ordersMap :: OrdersMap,
        _settlementList :: SettlementList
      }
  deriving (Eq, Ord, Show)

makeLenses ''TransactionHistory

newTransactionHistory :: TransactionHistory
newTransactionHistory =
  TransactionHistory
    { _allTransactions = [],
      _cusipMap = mempty,
      _ordersMap = mempty,
      _settlementList = []
    }

instance FromJSON TransactionHistory where
  parseJSON v@(Array _) =
    processTransactions
      <$> parseJSON (unsafePerformIO $ encodeFile "data.json" v >> pure v)
  parseJSON v = error $ "Unexpected transaction history value: " ++ show v

-- Some transactions refer to an instrument, but only by the CUSIP id. It can
-- happen when an options position is closed by assignment, for example. This
-- cleanup pass restores the missing information for that instrument, and as a
-- conesquence builds a complete mapping of CUSIP -> Instrument for all
-- observed instruments.
--
-- Transformations performed on the data from TD Ameritrade:
--
-- 1. Infer missing data
--    a. symbol information lookup
--
-- 2. Coalesce multiple executions into orders
--
-- 3. Calculate capital gains on closing orders
--    a. P/L agaisnt opening price
--    b. wash sale rule

processTransactions :: [Transaction] -> TransactionHistory
processTransactions xs = (`execState` newTransactionHistory) $ do
  prepare xs
  allTransactions %= Prelude.reverse
  settlementList %= Prelude.reverse
  ordersMap . traverse . transactions %= orderTransactions
  where
    prepare =
      mapM_ check
        . sortBy
          ( comparing (^? transactionInfo_ . transactionDate)
              <> comparing (^? xunderlying)
          )
        <=< mapM findNames
          . filter
            ( \t ->
                t ^. xsubType
                  `notElem` [ InternalTransfer,
                              TradeCorrection
                            ]
            )
          . Prelude.reverse
    findNames :: Transaction -> State TransactionHistory Transaction
    findNames t = case t ^. xinstr of
      Nothing -> pure t
      Just inst -> case inst ^. symbol of
        "" -> preuse (cusipMap . ix (inst ^. cusip)) >>= \case
          Nothing -> error $ "Unknown CUSIP: " ++ T.unpack (inst ^. cusip)
          Just inst' -> pure $ t & xinstr ?~ inst'
        _sym -> do
          cusipMap . at (inst ^. cusip) ?= inst
          pure t
    check :: Transaction -> State TransactionHistory ()
    check t
      | Just "" <- t ^? xinstr . _Just . symbol =
        error $ "Symbol has no name: " ++ ppShow t
      | otherwise = do
        allTransactions %= (t :)
        let sd = t ^. settlementDate
        case t ^? xorderIdAndDate of
          Just (oid, date) -> use (ordersMap . at oid) >>= \case
            Nothing -> do
              ordersMap . at oid
                ?= Order
                  { _transactions = [t],
                    _orderId = oid,
                    _orderType = t ^. type_,
                    _orderDate = date,
                    _orderDescription = t ^. xdesc,
                    _orderAccountId = t ^. xaccount
                  }
              settlementList %= ((sd, Right oid) :)
            Just _ ->
              ordersMap . ix oid . transactions %= (t :)
          _ -> settlementList %= ((sd, Left t) :)

------------------------------------------------------------------------------

xorderIdAndDate :: Traversal' Transaction (OrderId, UTCTime)
xorderIdAndDate = zipped xbaseOrderId xorderDate

xfees :: Traversal' Transaction (Amount 2)
xfees f t =
  let r = f (t ^. fees_ . regFee)
      o = f (t ^. fees_ . otherCharges)
      c = f (t ^. fees_ . commission)
   in liftA3 (,,) r o c <&> \(r', o', c') ->
        t & fees_ . regFee .~ r'
          & fees_ . otherCharges .~ o'
          & fees_ . commission .~ c'

xbaseOrderId :: Traversal' Transaction Text
xbaseOrderId = transactionOrderId . traverse . splitOn "." . index 0

xorderDate :: Traversal' Transaction UTCTime
xorderDate = transactionOrderDate . each

xtype :: Lens' Transaction TransactionType
xtype = type_

xsubType :: Lens' Transaction TransactionSubType
xsubType = transactionInfo_ . transactionSubType

xid :: Lens' Transaction Int64
xid = transactionInfo_ . transactionId

xdate :: Lens' Transaction UTCTime
xdate = transactionInfo_ . transactionDate

xdesc :: Lens' Transaction Text
xdesc = transactionInfo_ . transactionDescription

xitem :: Lens' Transaction TransactionItem
xitem = transactionInfo_ . transactionItem_

xcost :: Lens' Transaction (Amount 6)
xcost = xitem . cost

xprice :: Traversal' Transaction (Amount 6)
xprice = xitem . price . traverse

xaccount :: Lens' Transaction AccountId
xaccount = xitem . accountId

xamount :: Lens' Transaction (Amount 6)
xamount f t = t & xitem . amount . non 0 %%~ f

xinstr :: Lens' Transaction (Maybe Instrument)
xinstr = xitem . transactionInstrument

xinstruction :: Lens' Transaction (Maybe Instruction)
xinstruction = xitem . instruction

xeffect :: Lens' Transaction (Maybe PositionEffect)
xeffect = xitem . positionEffect

xasset :: Traversal' Transaction AssetType
xasset = xinstr . each . assetType

xoption :: Traversal' Transaction Option
xoption = xinstr . each . assetType . _OptionAsset

xsymbol :: Getter Transaction (Maybe Text)
xsymbol f t = case t ^. xinstr of
  Nothing -> t <$ f Nothing
  -- error $ "Transaction instrument missing for XId " ++ show (t^.xid)
  Just inst -> case inst ^. symbol of
    " " -> t <$ f (Just (inst ^. cusip))
    s -> t <$ f (Just s)

xcusip :: Getter Transaction (Maybe Text)
xcusip f s = s <$ f (s ^? xinstr . _Just . cusip)

xunderlying :: Getter Transaction (Maybe Text)
xunderlying f s =
  s <$ f (s ^? xinstr . each . failing (assetType . _OptionAsset . underlyingSymbol) symbol)

instance Render Transaction where
  rendered t =
    text (T.unpack (t ^. xsymbol . non "")) P.<> space
      P.<> tshow (t ^. xsubType)
      P.<> space
      P.<> tshow (t ^. xamount)
      P.<> space
      P.<> "@@"
      P.<> space
      P.<> tshow
        ( if t ^. xamount == 0
            then 0
            else t ^. xcost / t ^. xamount
        )
      P.<> space
      P.<> doubleQuotes (rendered (t ^. xdate))
      P.<> space
      P.<> tshow (t ^. xid)

------------------------------------------------------------------------------

infixr 7 <+>

(<+>) :: (Applicative m, Num a) => m a -> m a -> m a
(<+>) = liftA2 (+)

-- Given an order and all the execution transactions that make it up, find the
-- "aggregate" transactions that make it up. For example, if an order for 200
-- shares is executed as four purchases orders of 50 count each, from the
-- point of view of the order, this is one transaction, even if from the point
-- of view of the broker it is four.
orderTransactions :: [Transaction] -> [Transaction]
orderTransactions =
  contractList mergeTransactions
    . sortBy (comparing (^? xasset) <> comparing (^? xdate))

mergeTransactionItems ::
  TransactionItem ->
  TransactionItem ->
  Maybe TransactionItem
mergeTransactionItems x y = do
  guard conditions
  pure TransactionItem {..}
  where
    conditions =
      x ^. accountId == y ^. accountId
        -- These three could certainly be different, such as when assigning
        -- an option by closing out the short put and buying the equity, but
        -- in that case we simply don't merge the transactions.
        && x ^. price == y ^. price
        && x ^. transactionInstrument == y ^. transactionInstrument
        && x ^. instruction == y ^. instruction
        && x ^. positionEffect == y ^. positionEffect
    _accountId = x ^. accountId
    _amount = x ^. amount <+> y ^. amount
    _cost = x ^. cost + y ^. cost
    _instruction = x ^. instruction
    _positionEffect = x ^. positionEffect
    _price = x ^. price
    _transactionInstrument = x ^. transactionInstrument

mergeTransactionInfos ::
  TransactionInfo t ->
  TransactionInfo t ->
  Maybe (TransactionInfo t)
mergeTransactionInfos x y = do
  guard conditions
  _transactionItem_ <-
    mergeTransactionItems (x ^. transactionItem_) (y ^. transactionItem_)
  pure TransactionInfo {..}
  where
    conditions =
      x ^. transactionId /= y ^. transactionId
        && x ^. transactionDescription == y ^. transactionDescription
        && x ^. transactionSubType == y ^. transactionSubType
    _transactionDescription = x ^. transactionDescription
    _transactionSubType = x ^. transactionSubType
    -- jww (2020-04-05): Here is where we discard information when coalescing
    -- multiple transactions into an order.
    _transactionId =
      getMax $
        Max (x ^. transactionId)
          <> Max (y ^. transactionId)
    _transactionDate =
      getMax $
        Max (x ^. transactionDate)
          <> Max (y ^. transactionDate)

mergeTransactions :: Transaction -> Transaction -> Maybe Transaction
mergeTransactions x y = do
  _orderId <- x ^? xbaseOrderId
  yid <- y ^? xbaseOrderId
  guard $ _orderId == yid
  guard conditions
  _transactionInfo_ <-
    mergeTransactionInfos (x ^. transactionInfo_) (y ^. transactionInfo_)
  pure Transaction {..}
  where
    conditions =
      x ^. achStatus == y ^. achStatus
        && x ^. cashBalanceEffectFlag == y ^. cashBalanceEffectFlag
        && x ^. clearingReferenceNumber == y ^. clearingReferenceNumber
        && x ^. transactionOrderId == y ^. transactionOrderId
        && x ^. transactionOrderDate == y ^. transactionOrderDate
        && x ^. settlementDate == y ^. settlementDate
        && x ^. subAccount == y ^. subAccount
        && x ^. type_ == y ^. type_
    _accruedInterest = x ^. accruedInterest <+> y ^. accruedInterest
    _achStatus = x ^. achStatus
    _cashBalanceEffectFlag = x ^. cashBalanceEffectFlag
    _clearingReferenceNumber = x ^. clearingReferenceNumber
    _dayTradeBuyingPowerEffect =
      x ^. dayTradeBuyingPowerEffect
        <+> y ^. dayTradeBuyingPowerEffect
    _fees_ = x ^. fees_ <> y ^. fees_
    _netAmount = x ^. netAmount + y ^. netAmount
    _transactionOrderId = x ^. transactionOrderId
    _transactionOrderDate = x ^. transactionOrderDate
    _requirementReallocationAmount =
      x ^. requirementReallocationAmount
        <+> y ^. requirementReallocationAmount
    _settlementDate = x ^. settlementDate
    _sma = x ^. sma <+> y ^. sma
    _subAccount = x ^. subAccount
    _type_ = x ^. type_

orderFromTransaction :: Transaction -> Order
orderFromTransaction t = Order {..}
  where
    _transactions = [t]
    _orderId = T.pack . show $ t ^. xid
    _orderType = t ^. xtype
    _orderDate = t ^. xdate
    _orderDescription = t ^. xdesc
    _orderAccountId = t ^. xaccount
