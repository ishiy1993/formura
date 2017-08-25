{- |
Copyright   : (c) Takayuki Muranushi, 2015
License     : MIT
Maintainer  : muranushi@gmail.com
Stability   : experimental

ZipList treated as mathematical vectors, to deal with multidimensionality in stencil computation.
-}

{-# LANGUAGE DeriveDataTypeable, DeriveFunctor, DeriveFoldable, DeriveTraversable, TypeFamilies #-}

module Formura.Vec where

import           Control.Lens
import qualified Data.Aeson as J
import           Data.Data
import           Data.List (intercalate)
import           Data.Monoid

-- | The maximal dimension formura can handle
formuraMaxDimension :: Int
formuraMaxDimension = 26

data Vec a = Vec { getVec :: [a] } | PureVec a
           deriving (Read, Functor, Traversable, Typeable, Data)
instance Foldable Vec where
  foldMap m (Vec xs) = foldMap m xs
  foldMap m (PureVec x) = foldMap m $ replicate formuraMaxDimension x

instance J.ToJSON a => J.ToJSON (Vec a) where
  toJSON (Vec xs) = J.toJSON xs

instance J.FromJSON a => J.FromJSON (Vec a) where
  parseJSON j = Vec <$> J.parseJSON j

type instance Index (Vec a) = Int
type instance IxValue (Vec a) = a
instance Ixed (Vec a) where
  ix i =
       let myIso :: Iso' (Vec a) [a]
           myIso = iso back Vec

           back (PureVec x) = replicate formuraMaxDimension x
           back (Vec xs) = xs
       in myIso . ix i

instance Show a => Show (Vec a) where
  show (Vec xs) = "(" ++ (intercalate "," $ map show xs) ++ ")"
  show (PureVec x) = "(" ++ show x ++ "..)"

instance Eq a => Eq (Vec a) where
  a == b = and $ liftVec2 (==) a b

instance Ord a => Ord (Vec a) where
  compare a b = foldr (<>) EQ $ liftVec2 compare a b

instance Applicative Vec where
    pure x = PureVec x
    PureVec f <*> PureVec x = PureVec $ f x
    PureVec f <*> Vec xs    = Vec $ fmap f xs
    Vec fs <*> PureVec x    = Vec $ fmap ($ x) fs
    Vec fs <*> Vec xs = Vec (zipWith id fs xs)

instance Num a => Num (Vec a) where
  (+) = liftVec2 (+)
  (-) = liftVec2 (-)
  (*) = liftVec2 (*)
  abs   = fmap abs
  signum = fmap signum
  negate = fmap negate
  fromInteger = pure . fromInteger

instance Fractional a => Fractional (Vec a) where
  (/) = liftVec2 (/)
  recip = fmap recip
  fromRational = pure .fromRational

liftVec2 :: (a -> b -> c) -> Vec a -> Vec b -> Vec c
liftVec2 f (PureVec x) (PureVec y) = PureVec $ f x y
liftVec2 f (PureVec x) (Vec ys   ) = Vec $ fmap (f x) ys
liftVec2 f (Vec xs   ) (PureVec y) = Vec $ fmap (flip f y) xs
liftVec2 f (Vec xs   ) (Vec ys   ) = let n = max (length xs) (length ys) in
  Vec $ take n $ zipWith f xs ys
