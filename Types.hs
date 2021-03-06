module Types where

data Type = TInt | TArray Type | TPointer Type
  deriving Eq

instance Show Type where
  show TInt = "int"
  show (TArray t) = show t ++ "[]"
  show (TPointer t) = show t ++ "*"


