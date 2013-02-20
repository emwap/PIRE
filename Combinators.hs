{-# LANGUAGE GADTs #-}

module Combinators where

-- A small combinator library

import PIRE
import GenOCL
import Util

import Prelude hiding (zipWith)



-----------------------------------------------------------------------------
-- Building blocks

{- How things works:
 - The arrays passed to dualPar' describe the arrays in the host program, i.e.
 - how the arrays are initialized.

 - The "internal arrays", i.e. those that are arguments in the functions of AllocNew
 - are the ones used in the kernels.
 - These should probably be separated more clearly.
 
 - Note also: quite unspecified behavior when using arrays of differing length.
-}

-- TODO change p ~ Pushable later


zipWith :: (p ~ Pull) => Type -> (Expr -> Expr -> Expr) -> Array p Expr -> Array p Expr -> Program
zipWith t f arr1 arr2 = AllocNew (TPointer t) len arr1 $ \loc1 kernelArray1 -> 
                          AllocNew (TPointer t) len arr2 $ \_    kernelArray2 ->
                            par (Num 0) len $
                              \e -> loc1 (f (pull (doit kernelArray1) e) (pull (doit kernelArray2) e))
  where len  = min (size arr1) (size arr2) 



-----------------------------------------------------------------------------
-- Example programs

-- ElementWise vector multiplication
vecMul :: Program
vecMul = zipWith TInt (.*) vec1 vec2
  where len  = Num 10
        vec1 = Array len (Pull (.* (Num 2)))
        vec2 = Array len (Pull (.+ (Num 1)))






example :: Gen ()
example = setupHeadings >> setupOCL >> gen vecMul >> setupPrint "mem1" 10 >> setupEnd

------------------------------------------------------------
-- helpers

showProg :: Gen () -> IO ()
showProg prog = putStr $ unlines $ (extractCode prog emptyEnv) ++ (extractCodeK prog emptyEnv)


toFile :: Gen () -> FilePath -> IO ()
toFile prog path = writeFile path (unlines $ extractCode prog emptyEnv) >>
                   writeFile (kernelFile emptyEnv) (unlines $ extractKernelCode prog emptyEnv)








--forLoop2' :: Type -> (Expr -> Expr -> Expr) -> Array2 Pull Expr -> Array2 Pull Expr -> Program  
--forLoop2' t f input1 input2 = AllocDim t len input1 $ \loc1 iarr1 ->
--                               AllocDim t len input2 $ \_    iarr2 -> 
--                                nestFor (dim input1) (toInt len) $
--                                    \e -> loc1 e -- e should be all of the loop vars
--                                              (f (pull (theData iarr1) e) (pull (theData iarr2) e))
--  where len = min (arrSize input1) (arrSize input1)
--
---- TODO introduce padding if (length mod dim != 0)?
--nestFor :: DIM -> Int -> (Expr -> Program) -> Program
--nestFor d totalLength = nestFor' d (d-1) totalLength
--  where 
--    nestFor' :: DIM -> Int -> Int -> (Expr -> Program) -> Program
--    nestFor' d ctr totalLength innerMost = for (Num 0) (Num $ totalLength `div` d) 
--                (\e -> if ctr == 0 then innerMost e else nestFor' d (ctr - 1) totalLength innerMost)
--

                                                          
--vecMul2 = forLoop2' TInt (.*) arr1 arr2
--  where arr1 = Array2 (Num 10) (Pull (.* (Num 3))) 2
--        arr2 = Array2 (Num 10) (Pull (.* (Num 4))) 2
