{-# LANGUAGE FlexibleInstances, GADTs, StandaloneDeriving #-}
module Language.IR.Backend where

{- The IR just before the code generation. -}

import Compiler.Hoopl
import Control.Lens

import Language.IR.Frontend
  (VarName, Uniop, Binop, Triop, onlyOneLabel)

type Offset = [Int]
data VarDecl = VarDecl {varType :: String, varHalo :: (Offset,Offset), varName :: String}
           deriving (Eq, Show)

data Expr = Lit Rational
          | Load VarName
          | Shift Offset Expr
          | Uniop Uniop Expr
          | Binop Binop Expr Expr
          | Triop Triop Expr Expr Expr
                   deriving (Eq, Show)

data RExpr = RLoad VarName
  deriving (Eq, Show)

data Proc = Proc { name :: String, decls :: [VarDecl], body :: Graph (Insn ()) C C }

data Insn a e x where
  Entry  :: a -> [VarName]              -> Insn a C O
  Assign :: a -> RExpr -> Expr          -> Insn a O O
  Return :: a -> [Expr]                 -> Insn a O C
deriving instance (Show r) =>  Show (Insn r e x)

attribute :: Lens (Insn a1 e x) (Insn a2 e x) a1 a2
attribute f (Entry a1 vs) = fmap (\a2 -> Entry a2 vs) (f a1)
attribute f (Assign a1 r e) = fmap (\a2 -> Assign a2 r e) (f a1)
attribute f (Return a1 e) = fmap (\a2 -> Return a2 e) (f a1)


instance NonLocal (Insn a) where
  entryLabel (Entry _ _) = onlyOneLabel
  successors (Return _ _) = []
