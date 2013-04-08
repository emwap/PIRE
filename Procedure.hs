{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE GADTs #-}

module Procedure where

import Expr
import Program
import Types

import Data.Typeable
import Data.Monoid

-- Note that a procedure has return type unit (e.g. void).

data Proc a where
  Nil       :: Proc a
  BasicProc :: Proc a -> Proc a
  ProcBody  :: Program a -> Proc a
  -- Give just a name since we don't know whether we want to just write or just read 
  -- to it beforehand (and thus can't make it a Loc or an Expr).
  OutParam  :: Type -> (Name -> Name -> Proc a) -> Proc a -- TODO remove the extra Name (was argc equivalent)
  NewParam  :: Type -> (Name -> Name -> Proc a) -> Proc a
  deriving (Typeable)

instance Monoid (Proc a) where
  mempty      = BasicProc Nil
  mappend     = chainP

chainP :: Proc a -> Proc a -> Proc a
chainP Nil              b = b
chainP (BasicProc p) (BasicProc q) = BasicProc (mappend p q)
chainP (BasicProc p) b             = BasicProc (mappend p b)
chainP a (BasicProc b)             = BasicProc (mappend a b)
chainP (ProcBody p) (ProcBody q) = ProcBody (p .>> q)
chainP a@(ProcBody prg) b = mappend b a
chainP (OutParam t   k) b = OutParam t (\n1 n2 -> mappend (k n1 n2) b)
chainP (NewParam t   k) b = NewParam t (\n1 n2 -> mappend (k n1 n2) b)



emptyProc :: Proc ()
emptyProc = BasicProc (OutParam (TPointer TInt) $ \out _ -> NewParam (TPointer TInt) $ \p1 p1c ->
              ProcBody $ for (Num 0) (var p1c) $ \e -> Assign out [e] (Index p1 [e]) ) 


