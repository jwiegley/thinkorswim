{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Data.Split where

import Data.Default
import Data.List (foldl')
import Control.Lens

data Split a
    = Some
        { _used :: a
        , _kept :: a
        }
    | All a
    | None a
    deriving (Eq, Ord, Show)

makePrisms ''Split

instance Functor Split where
    fmap f (Some u k) = Some (f u) (f k)
    fmap f (All u)    = All (f u)
    fmap f (None k)   = None (f k)

_Splits :: Traversal (Split a) (Split b) a b
_Splits f (Some u k) = Some <$> f u <*> f k
_Splits f (All u)    = All <$> f u
_Splits f (None k)   = None <$> f k

_SplitUsed :: Traversal' (Split a) a
_SplitUsed f (Some u k) = Some <$> f u <*> pure k
_SplitUsed f (All u)    = All <$> f u
_SplitUsed _ (None k)   = pure $ None k

_SplitKept :: Traversal' (Split a) a
_SplitKept f (Some u k) = Some u <$> f k
_SplitKept _ (All u)    = pure $ All u
_SplitKept f (None k)   = None <$> f k

keepAll :: Split a -> [a]
keepAll (Some x y) = [x, y]
keepAll (All x)    = [x]
keepAll (None y)   = [y]

isFullTransfer :: (Maybe a, Split t) -> Bool
isFullTransfer (Nothing, All _) = True
isFullTransfer _ = False

data Applied v a = Applied
    { _value :: v
    , _dest  :: Split a
    , _src   :: Split a
    }
    deriving (Eq, Ord, Show)

makeClassy ''Applied

nothingApplied :: Default v => a -> a -> Applied v a
nothingApplied x y = Applied def (None x) (None y)

data Considered b a = Considered
    { _fromList    :: [b]
    , _newList     :: [a]
    , _fromElement :: Maybe a
    }
    deriving (Eq, Show)

makeClassy ''Considered

newConsidered :: Considered b a
newConsidered = Considered
    { _fromList    = []
    , _newList     = []
    , _fromElement = Nothing
    }

-- Given a list, and an element, determine the following three data:
--
-- - A revised version of the input list, based on that element
-- - Elements derived from the input list that become new outputs
-- - The fragments of the original element
consider :: (a -> a -> Applied v a) -> (v -> a -> b) -> [a] -> a
         -> Considered b a
consider f mk lst el =
    result & fromList    %~ reverse
           & newList     %~ reverse
           & fromElement .~ remaining
  where
    (remaining, result) = foldl' go (Just el, newConsidered) lst

    go (Nothing, c) x = (Nothing, c & newList %~ (x:))
    go (Just z,  c) x =
        ( _src^?_SplitKept
        , c & fromList    %~ maybe id ((:) . mk _value) (_dest^?_SplitUsed)
            & newList     %~ maybe id (:) (_dest^?_SplitKept)
        )
      where
        Applied {..} = f x z