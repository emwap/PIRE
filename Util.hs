module Util where

{- 
 - Utility functions for generating code.
-}

import Control.Monad.State
import qualified Data.Map as Map



type Gen a = State Env a

data Env = Env 
          { varCount     :: Int             -- Variable counter
          , code         :: [String]        -- Accumulated code
          , iDepth       :: Int             -- Indent depth
          , kernelFile   :: FilePath        -- Name of the file containing kernels
          , kernelCode   :: [String]        -- Accumulated kernel code
          , paramCounter :: Int             -- Kernel parameter counter
          , paramMap     :: Map.Map Int Int -- Mapping allocations in Host -> Kernel params.
          , hostAllocMap :: Map.Map Int Int -- Mapping Kernel Params -> Host allocations
          }

extractCode :: Gen a -> Env -> [String]
extractCode g e = code $ execState g e

line :: String -> Gen ()
line s = modify $ \env -> env{code = code env ++ 
                                      lines
                                        (concat (replicate (iDepth env) " ") ++ s)}


indent :: Int -> Gen ()
indent i = modify $ \env -> env{iDepth = iDepth env + i}


unindent :: Int -> Gen ()
unindent i = modify $ \env -> env{iDepth = iDepth env - i}

getVar :: Gen Int
getVar = gets varCount

incVar :: Gen Int
incVar = do
  d <- getVar
  modify $ \env -> env{varCount = varCount env + 1}
  return d

getParamCounter :: Gen Int
getParamCounter = gets paramCounter

incParamCounter :: Gen Int
incParamCounter = do
  d <- getParamCounter
  modify $ \env -> env{paramCounter = paramCounter env + 1}
  return d


getParamMap :: Gen (Map.Map Int Int)
getParamMap = gets paramMap

addKernelParam :: Int -> Gen Int
addKernelParam hostAllocId = do
  new <- incParamCounter
  modify $ \env -> env {paramMap =  Map.insert hostAllocId new (paramMap env)}
  modify $ \env -> env {hostAllocMap =  Map.insert new hostAllocId (hostAllocMap env)}
  
  return new

lookupKernelParam :: Int -> Gen (Maybe Int)
lookupKernelParam hostAllocId = do
  m <- getParamMap
  return $ Map.lookup hostAllocId m

lookupHostAlloc :: Int -> Gen (Maybe Int)
lookupHostAlloc kernParam = do
  m <- gets hostAllocMap
  return $ Map.lookup kernParam m


printMap :: Gen a -> IO ()
printMap g = do
  let e = execState g emptyEnv
      m = Map.toList (paramMap e)
      m' = map (\(h,k) -> "mem" ++ show h ++ " is mapped to arr" ++  show k ++ "\n") m
  putStrLn $ concat m'
  let m2 = Map.toList (hostAllocMap e)
      m2' = map (\(k,h) -> "arr" ++ show k ++ " is mapped to mem" ++  show h ++ "\n") m2
  putStrLn $ concat m2'

  


emptyEnv :: Env
emptyEnv = Env 0 [] 0 "kernels.cl" [] 0 Map.empty Map.empty


------------------------------------------------------------
-- Kernels

getKernelFile :: Gen String
getKernelFile = gets kernelFile


lineK :: String -> Gen ()
lineK s = modify $ \env -> env {kernelCode = kernelCode env ++ [s]}

extractCodeK :: Gen a -> Env -> [String]
extractCodeK g e = kernelCode $ execState g e
