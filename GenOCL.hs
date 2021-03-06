{-# LANGUAGE StandaloneDeriving #-}

module GenOCL where

import Util
import Program
import Procedure
import Types
import Expr
import Gen
import Analysis

--import Control.Monad.State
import Control.Monad.RWS
import Data.List
import qualified Data.Map as M
-----------------------------------------------------------------------------
-- Show Instances

instance Show (Program a) where
  show p = unlines $ hostCode w
    where (_,w) = evalRWS (gen p) () emptyEnv

-----------------------------------------------------------------------------

instance GenCode (Program a) where
  gen = genProg

genProg :: Program a -> Gen ()

genProg (BasicProc p) = do 
                           i <- incVar
                           indent 2
                           setupHeadings
                           when (isParallel p) setupOCL
                           gen $ removeDupBasicProg p
                           unindent 2
                           ps <- fmap (intercalate ", " . filter (not . null)) (gets params)
                           tell $ mempty {procHead = ["void " ++ "f" ++ show i ++ "(" ++ ps ++ ") {"]}
                           tell $ mempty {post = ["}"]}
genProg (OutParam t p) = do i <- incVar
                            addParam $ show t ++ " out" ++ show i
                            --addParam $ show TInt ++ " out" ++ show i ++ "c"
                            gen $ p ("out" ++ show i)
genProg (InParam t p) = do i <- incVar
                           addParam $ show t ++ " arg" ++ show i
                           unless (t == TInt ) $ addParam $ show TInt ++ " arg" ++ show i ++ "c"
                           gen $ p ("arg" ++ show i)


genProg Skip = line ""

genProg (Assign name es e) = line $ show name --(Index name es) 
                          ++ concat [ "[" ++ show i ++ "]" | i <- es ]
                          ++ " = " ++ show e ++ ";"

genProg (Statement e) = line $ show e ++ ";"

genProg (p1 :>> p2) = gen p1 >> gen p2

genProg (If c p1 Skip) = do line $ "if( " ++ show c ++ " ) {"
                            indent 2
                            gen p1
                            unindent 2
                            line "}"
genProg (If c p1 p2) = do line $ "if( " ++ show c ++ " ) { "
                          indent 2
                          gen p1
                          unindent 2
                          line "else { "
                          indent 2
                          gen p2
                          unindent 2
                          line "}"
genProg (Par start end f) = do let tid        = "tid"
                                   localSize  = "localSize"
                                   globalSize = "globalSize"
                                   f' = parForUnwind (f (var tid .+ ((var localSize) .* (var "ix")))) tid

                                   params = grabKernelParams f' 
                                   parameters = concat $ intersperse ", "
                                      [ (case t of TPointer _ -> "__global " ++ show t; a -> show a) ++ " " ++ n
                                      | (n,t) <- params
                                      ]

                               kerName <- fmap ((++) "k" . show) incVar
                               lineK $ "__kernel void " ++ kerName ++ "( " ++ parameters ++ " ) {"
                               kindent 2

                               lineK $ show TInt ++ " " ++  tid ++ " = " ++ "get_global_id(0)" ++ ";"
                               lineK $ show TInt ++ " " ++ localSize ++ " = " ++ "get_local_size(0);" 
                               lineK $ show TInt ++ " " ++ globalSize ++ " = " ++ "get_global_size(0);" 
                               lineK $ "if(" ++ tid ++ " < " ++ localSize ++ ") {"
                               kindent 2
                               lineK $ "for(int ix = 0; ix < " ++ globalSize ++ "/" ++ localSize ++ "; ix++) {"
                               kindent 2
                               genK f' $ map fst params
                               kunindent 2
                               lineK "}"
                               kunindent 2
                               lineK "}"
                               runOCL kerName
                               setupOCLMemory params end kerName
                               launchKernel end (Num 1024) kerName
                               modify $ \env -> env {kernelCounter = kernelCounter env + 1}
--                               readOCL (grabKernelReadBacks f') end

                               kunindent 2
                               lineK "}"

genProg (For e1 e2 p) = do i <- newLoopVar
                           --line $ show TInt ++ " " ++ i ++ ";"
                           line $ "for(" ++ show TInt ++ " " ++ i ++ " = " ++ show e1 ++ "; " 
                               ++ i ++ " < " ++ show e2 ++ "; "
                               ++ i ++ "++) {"
                           indent 2
                           gen $ p (var i)
                           unindent 2
                           line "}"

genProg (Alloc t f) | t == TInt = error $ "Alloc on a scalar of type " ++ show t ++ ". Try Decl?"
                    | otherwise = 
                    do d <- incVar
                       let m = "mem" ++ show d
                           c = m ++ "c"
                           tc = case t of TPointer a -> a; a -> a
                           k Host dim = Assign (var c) [] (head dim) .>>
                                        Statement $ var $ show t ++ " " ++ m ++ " = ("
                                        ++ show t ++ ") " ++ "malloc(sizeof(" ++ show tc ++ ") * " ++ c ++ ")"
                           k DevGlobal dim = Assign (var c) [] (head dim) .>>
                                             Assign (var $ "cl_mem " ++ m) [] $ Call (var "clCreateBuffer")
                                               [ var "context"
                                               , var "CL_MEM_READ_WRITE"
                                               , BinOp $ Mul (var c) $ Call (var "sizeof") [var $ show tc]
                                               , var "NULL"
                                               , var "NULL"
                                               ]
  

                       line $ show tc ++ " " ++ c ++ ";"
                       gen $ f m c k
                       --line $ "free(" ++ m ++ ");"

--genProg (Alloc t dim f) = do d <- incVar
--                             let m = "mem" ++ show d
--                                 c = m ++ "c"
--                                 t' = case t of TPointer a -> a; a -> a;
--                             nestForAlloc dim m t
--                             line $ show t' ++ " " ++ c ++ ";" -- print size variable
--                             gen $ f m c 
                             --line $ "free(" ++ m ++ ");\n"

genProg (Decl t f)     = do d <- incVar
                            let m = "mem" ++ show d
                            line $ show t ++ " " ++ m ++ ";"
                            gen $ f m

-- Code gen in kernel code   
genK :: Program a -> [Name] -> Gen ()
genK Skip           ns = return ()
genK (Assign name es e) ns = lineK $ (show name)
                       ++ concat [ "[" ++ show i ++ "]" | i <- es ]
                       ++ " = " ++ show (derefScalar e ns) ++ ";"
genK (p1 :>> p2)   ns = genK p1 ns >> genK p2 ns
genK (If c p1 Skip) ns = do lineK $ "if(" ++ show (derefScalar c ns) ++ ") {"
                            kindent 2
                            genK p1 ns
                            kunindent 2
                            lineK "}"
genK (If c p1 p2) ns = do lineK $ "if(" ++ show (derefScalar c ns) ++ ") { "
                          kindent 2
                          genK p1 ns
                          kunindent 2
                          lineK "else { "
                          kindent 2
                          genK p2 ns
                          kunindent 2
                          lineK "}"
genK (For e1 e2 p) ns   = do i <- newLoopVar
                             --lineK $ show TInt ++ " " ++ i ++ ";"
                             lineK $ "for(" ++ show TInt ++ i ++ " = " ++ show (derefScalar e1 ns) ++ "; " 
                                 ++ i ++ " < " ++ show (derefScalar e2 ns) ++ "; "
                                 ++ i ++ "++ ) {"
                             kindent 2
                             genK (p (var i)) ns
                             kunindent 2
                             lineK "}"
genK (Par start end f) ns = genK (For start end f) ns
genK (Decl t f)        ns = do d <- incVar
                               let m = "mem" ++ show d
                               lineK $ show t ++ " " ++ m ++ ";"
                               genK (f m) (m:ns)

genK (Alloc t f) ns = error "Alloc in Kernel code not allowed"
                       -- do argName <- fmap ((++) "mem" . show) incVar
                       --   lineK $ "// Alloc in Kernel"
                       --   genK $ f argName (argName ++ "c")



-----------------------------------------------------------------------------
-- Other things that may need revising.

setupOCLMemory :: Parameters -> Size -> Name -> Gen ()
setupOCLMemory ps sz kn = do
--    createBuffers sz kn ps
--    copyBuffers sz ps
    setKernelArgs kn ps

createBuffers :: Size -> Name -> Parameters -> Gen ()
createBuffers sz kn = mapM_ go
  where
    go (n,TPointer t) = do
      nameUsed <- nameExists n
      let prefix = if nameUsed then "" else "cl_mem "
          obj    = n ++ "_obj"
      line $ intercalate ", " [ prefix ++ obj ++ " = clCreateBuffer(context, CL_MEM_READ_WRITE"
                              , show sz ++ "*sizeof(" ++ show t ++ "), NULL, NULL);"
                              ]
      addUsedVar n
    go _ = return ()

copyBuffers :: Size -> Parameters -> Gen ()
copyBuffers sz = mapM_ go
  where
    go (n,TPointer t) =
      line $ intercalate ", "
        [ "clEnqueueWriteBuffer(command_queue"
        , n ++ "_obj"
        , "CL_TRUE, 0"
        , show sz ++ "*sizeof(" ++ show t ++ ")"
        , n
        , "0, NULL, NULL);"
        ]
    go _ = return ()

setKernelArgs :: Name -> Parameters -> Gen ()
setKernelArgs kn = zipWithM_ go [0..]
  where
    setarg i (n,t) = line $ "clSetKernelArg(" ++ kn ++ ", " ++ i ++ ", sizeof(" ++ t ++ "), &" ++ n ++ ");"
    go i (n,t) = setarg (show i) $ case t of TPointer _ -> (n,"cl_mem")
                                             _          -> (n,show t)

runOCL :: Name -> Gen ()
runOCL kname = do
            modify $ \env -> env{kernelNames = [kname] ++ kernelNames env}
            tell $ mempty {pre = ["static cl_kernel " ++ kname ++ ";"]}
            tell $ mempty {initBlock = ["  " ++ kname ++ " = " ++ "clCreateKernel(program, \"" ++ kname ++ "\", NULL);"]}
            --kcount <- gets kernelCounter -- we can reuse declared openCL objects
            --line $ (if kcount <= 0 then "cl_program " else "") ++ "program = clCreateProgramWithSource(context, 1, (const char **)&source_str, " ++
            --       "(const size_t *)&source_size, NULL);"
           -- line "clBuildProgram(program, 1, &device_id, NULL, NULL, NULL);"
            --line $ (if kcount <= 0 then "cl_kernel " else "") ++ "kernel = clCreateKernel(program, \"" ++ kname ++ "\", NULL);" 

--launchKernel :: Int -> Int -> Gen ()
launchKernel :: Expr -> Expr -> Name -> Gen ()
launchKernel global local kerName = do
  kcount <- gets kernelCounter
  line $ (if kcount <= 0 then "size_t " else "") ++ "global_item_size = " ++ show global ++ ";"
  line $ (if kcount <= 0 then "size_t " else "") ++ "local_item_size = "  ++ show local ++ ";"
  line $ "clEnqueueNDRangeKernel(command_queue, " ++ kerName ++ ", 1, NULL, &global_item_size, &local_item_size, 0, NULL, NULL);"

--readOCL :: Name -> Type -> Size -> Gen () 
readOCL :: Parameters -> Size -> Gen () 
readOCL []            _  = return ()
readOCL ((n,t):xs) sz | n `elem` reservedNames = readOCL xs sz
                      | otherwise = 
                        let s = sz
                        in do line $ "clEnqueueReadBuffer(command_queue, " ++ n ++ "_obj" ++ ", CL_TRUE, 0, " ++
                                show s ++ "*sizeof(" ++ removePointers t ++ "), " ++ n ++ ", 0, NULL, NULL);\n\n"
                              readOCL xs sz
                                
------------------------------------------------------------
-- Extras

setupHeadings :: Gen ()
setupHeadings = do tell $ mempty {pre = ["#include <stdio.h>"]}
                   tell $ mempty {pre = ["#include <stdlib.h>"]}
                   tell $ mempty {pre = ["#ifdef __APPLE__"
                                        ,"#include <OpenCL/opencl.h>"
                                        ,"#else"
                                        ,"#include <CL/cl.h>"
                                        ,"#endif"]}
                   tell $ mempty {pre = ["#include <math.h>"]} -- note: remember to link math. -lm
                   tell $ mempty {pre = ["#include <time.h>"]}
                   tell $ mempty {pre = ["#include <string.h>"]} 
                   tell $ mempty {pre = ["#include \"feldspar_c99.h\""]}
                   tell $ mempty {pre = ["#define MAX_SOURCE_SIZE (0x100000)\n"]}
                   tell $ mempty {pre = ["#ifdef __APPLE__"]}
                   tell $ mempty {pre = ["#include <sys/time.h>"]}
                   tell $ mempty {pre = ["double getRealTime() {"]}
                   tell $ mempty {pre = ["  struct timeval tv;"]}
                   tell $ mempty {pre = ["  gettimeofday(&tv,0);"]}
                   tell $ mempty {pre = ["  return (double)tv.tv_sec+1.0e-6*(double)tv.tv_usec;"]}
                   tell $ mempty {pre = ["}                                                    "]}
                   tell $ mempty {pre = ["#else                                                "]}
                   tell $ mempty {pre = ["double getRealTime() {                               "]}
                   tell $ mempty {pre = ["  struct timespec timer;                             "]}
                   tell $ mempty {pre = ["  clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &timer);   "]}
                   tell $ mempty {pre = ["  return (double)timer.tv_sec+1.0e-9*(double)timer.tv_nsec;"]}
                   tell $ mempty {pre = ["}"]}
                   tell $ mempty {pre = ["#endif\n"]}

setupOCLStatics :: Gen ()
setupOCLStatics = do tell $ mempty {pre = ["static cl_program program;"]}
                     tell $ mempty {pre = ["static cl_device_id device_id = NULL;"]}
                     tell $ mempty {pre = ["static cl_command_queue command_queue;"]}
                     tell $ mempty {pre = ["static cl_context context;"]}
                     tell $ mempty {pre = ["static char* source_str;"]}
                     tell $ mempty {pre = ["static size_t source_size;"]}
setupEnd :: Gen ()
setupEnd = line "return 0;" >> unindent 2 >> line "}"


setupInit :: Gen ()
setupInit = do
  tell $ mempty {initBlock = ["  FILE *fp = NULL;"]}
  tell $ mempty {initBlock = ["  fp = fopen( \"kernels.cl\" , \"r\");"]}
  tell $ mempty {initBlock = ["  source_str = (char*) malloc(MAX_SOURCE_SIZE);"]}
  tell $ mempty {initBlock = ["  source_size = fread( source_str, 1, MAX_SOURCE_SIZE, fp);"]}
  tell $ mempty {initBlock = ["  fclose( fp );"]}
  tell $ mempty {initBlock = ["  cl_platform_id platform_id = NULL;"]}
  tell $ mempty {initBlock = ["  cl_uint ret_num_devices;"]}
  tell $ mempty {initBlock = ["  cl_uint ret_num_platforms;"]}
  tell $ mempty {initBlock = ["  clGetPlatformIDs(1, &platform_id, &ret_num_platforms);"]}
  tell $ mempty {initBlock = ["  clGetDeviceIDs(platform_id, CL_DEVICE_TYPE_DEFAULT, 1, &device_id, &ret_num_devices);"]}
  tell $ mempty {initBlock = ["  context = clCreateContext(NULL, 1, &device_id, NULL, NULL, NULL);"]}
  tell $ mempty {initBlock = ["  command_queue = clCreateCommandQueue(context, device_id, 0, NULL);"]}
  tell $ mempty {initBlock = ["  program = clCreateProgramWithSource(context, 1, (const char **)&source_str, (const size_t *)&source_size, NULL);"]}
  tell $ mempty {initBlock = ["  clBuildProgram(program, 1, &device_id, NULL, NULL, NULL);"]}
  --tell $ mempty {initBlock = ["  kernel = clCreateKernel(program, \"k6\", NULL);"]}



setupOCL :: Gen ()
setupOCL = do setupOCLStatics
              setupInit
             -- let fp     = "fp"
             --     srcStr = "source_str"
             --     srcSize = "source_size"
             -- kernels <- getKernelFile

             -- line $ "FILE *" ++ fp ++ " = NULL;"
             -- line $ "char* " ++ srcStr ++ ";"
             -- line $ fp ++ " = fopen( \"" ++ kernels ++ "\" , \"r\");"
             -- line $ srcStr ++ " = (char*) malloc(MAX_SOURCE_SIZE);"
             -- line $ "size_t " ++ srcSize ++ " = fread( " ++ srcStr ++ ", " ++ "1, " ++
             --                   "MAX_SOURCE_SIZE, " ++ fp ++ ");"
             -- line $ "fclose( " ++ fp ++ " );"
             -- 
             -- let platformID   = "platform_id"
             --     deviceID     = "device_id"
             --     numDevices   = "ret_num_devices"
             --     numPlatforms = "ret_num_platforms"
             --     context      = "context"
             --     queue        = "command_queue"
             --     
             -- line $ "cl_platform_id " ++ platformID ++ " = NULL;"
             -- line $ "cl_device_id " ++ deviceID ++ " = NULL;"
             -- line $ "cl_uint " ++ numDevices ++ ";"
             -- line $ "cl_uint " ++ numPlatforms ++ ";"
             -- line $ "clGetPlatformIDs(1, &" ++ platformID ++ ", &" ++ numPlatforms ++ ");"
             -- line $ "clGetDeviceIDs(" ++ platformID ++ ", CL_DEVICE_TYPE_DEFAULT, 1, " ++
             --        "&" ++ deviceID ++ ", &" ++ numDevices ++ ");"
             -- line $ "cl_context " ++ context ++ " = clCreateContext(NULL, 1, &" ++ deviceID ++ ", NULL, NULL, NULL);"
             -- line $ "cl_command_queue " ++ queue ++ " = clCreateCommandQueue(" ++ context ++ 
             --        ", " ++ deviceID ++ ", 0, NULL);"
             -- line "\n\n"

