{-|
Module      : Language.Formura.Desugar
Description : formura desugar
Copyright   : (c) Takayuki Muranushi, 2015
License     : MIT
Maintainer  : muranushi@gmail.com
Stability   : experimental

Desugar formura program.
-}

{-# LANGUAGE RankNTypes #-}


module Formura.Desugar where

import Control.Lens
import Data.Data
import Data.Foldable (toList)
import Data.Generics.Schemes(everywhere)
import Data.Maybe (fromMaybe)

import Formura.Vec
import Formura.Syntax


mapEverywhere :: (Data a, Data b) => (b->b) -> a -> a
mapEverywhere f = everywhere (caster f)
  where
    caster :: (Typeable a) => (a -> a) -> (forall b. Typeable b => b -> b)
    caster f x = fromMaybe x ((cast =<<) $ f <$> cast x)


desugar :: Program -> IO Program
desugar prog = do
  let dim :: Int
      dim = head $ [n | DimensionDeclaration n <- prog ^.programSpecialDeclarations] ++
            [error "no dimension declaration found."]
  let
      modifyTypeExpr :: TypeExpr -> TypeExpr
      modifyTypeExpr (GridType xs x) = GridType (Vec $ take dim $ toList xs ++ repeat 0) x
      modifyTypeExpr x = x

      modifyLExpr :: LExpr -> LExpr
      modifyLExpr (Grid v_npk x) = Grid (Vec $ take dim $ toList v_npk ++ repeat 0 ) x
      modifyLExpr x = x

      modifyRExpr :: RExpr -> RExpr
      modifyRExpr (Grid v_npk x) = Grid (Vec $ take dim $ toList v_npk ++ repeat 0 ) x
      modifyRExpr x = x

  return $ mapEverywhere modifyTypeExpr $
    mapEverywhere modifyLExpr $
    mapEverywhere modifyRExpr $
    prog
