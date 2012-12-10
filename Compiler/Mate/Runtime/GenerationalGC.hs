{-# OPTIONS_GHC -fno-warn-orphans #-}
module Compiler.Mate.Runtime.GenerationalGC where

import Foreign
import qualified Foreign.Marshal.Alloc as Alloc
import Control.Monad.State
import qualified Data.Map as M
import Data.Map(Map)
import qualified Data.Set as S

import Compiler.Mate.Runtime.BlockAllocation
import Compiler.Mate.Runtime.GC
import Compiler.Mate.Debug
import Compiler.Mate.Runtime.MemoryManager
import Compiler.Mate.Flags
import qualified Compiler.Mate.Runtime.StackTrace as T

maxGen :: Int
maxGen = 2 -- means 0,1,2

instance AllocationManager GcState where
    initMemoryManager = initGen
    mallocBytesT = mallocBytesGen
    performCollection = collectGen
    collectLoh = error "not implemented yet"
    heapSize = error "heap size in GenGC not implemented"
    validRef = error "valid ref in GenGC not implemented"

initGen :: Int -> IO GcState
initGen _ = return  GcState { generations = map (const generation) [0..maxGen],
                              allocs = 0,
                              allocatedBytes = 0 ,
                              loh = S.empty}
    where generation = GenState { freeBlocks = [], 
                                  activeBlocks = M.empty,
                                  collections = 0 }


mallocBytesGen :: GenInfo -> Int -> StateT GcState IO (Ptr b)
mallocBytesGen _ size' = 
    if size' > loThreshhold  
      then allocateLoh size'
      else do 
            current <- get
            (ptr,current') <- liftIO $ runBlockAllocator size' current 
            put $ current' { allocs = 1 + allocs current' }
            return ptr

allocateLoh :: Int -> StateT GcState IO (Ptr b)
allocateLoh size' = do
    current <- get
    let currentLoh = loh current
    ptr <- liftIO $ Alloc.mallocBytes size'
    put $ current { loh = S.insert (ptrToIntPtr ptr) currentLoh }
    liftIO $ printfGc $ printf "LOH: allocated %d bytes in loh %s" size' (show ptr)
    return ptr

collectLohTwoSpace :: (RefObj a) => [a] -> StateT GcState IO ()
collectLohTwoSpace xs = do
    current <- get
    intptrs <- liftIO $ mapM getIntPtr xs
    let oldLoh = loh current
    let newSet = S.fromList intptrs
    let toRemove = oldLoh `S.difference` newSet
    liftIO $ printfGc $ printf "objs in loh: %d" (S.size oldLoh)
    liftIO $ printfGc $ printf "old loh: %s" (show $ showRefs $ S.toList oldLoh)
    liftIO $ printfGc $ printf "to remove: %s" (show $ showRefs $ S.toList toRemove) 
    liftIO $ mapM (free . intPtrToPtr) (S.toList toRemove)
    put current { loh = newSet }

-- given an element in generation x -> where to evaucuate to
sourceGenToTargetGen :: Int -> Int 
sourceGenToTargetGen 0 = 1
sourceGenToTargetGen 1 = 2
sourceGenToTargetGen 2 = 2
sourceGenToTargetGen x = error $ "source object is in strange generation: " ++ show x

collectGen :: (RefObj b) => Map b RefUpdateAction -> StateT GcState IO ()
collectGen roots = do
    cnt <- liftM allocs get
    --performCollectionGen (calculateGeneration cnt) roots
    performCollectionGen Nothing roots

calculateGeneration :: Int -> Maybe Int
calculateGeneration x | x < 5 = Nothing
                      | x < 10 = Just 0
                      | x < 15 = Just 1
                      | otherwise = Just 2

performCollectionGen :: (RefObj b) => Maybe Int -> Map b RefUpdateAction  -> StateT GcState IO ()
performCollectionGen Nothing _ = logGcT "skipping GC. not necessary atm. tune gc settings if required"
performCollectionGen (Just generation) roots = do
   logGcT $ printf "!!! runn gen%d collection" generation
   let rootList = map fst $ M.toList roots
   logGcT $ printf  "rootSet: %s\n " (show rootList)
   performCollectionGen' generation rootList
   logGcT "patch gc roots.."
   liftIO $ patchGCRoots roots
   logGcT "all done \\o/"

performCollectionGen' :: (RefObj b) => Int -> [b] -> StateT GcState IO ()
performCollectionGen' generation roots = return ()


buildPatchAction :: [T.StackDescription] -> [IntPtr] -> IO (Map (Ptr b) RefUpdateAction)
buildPatchAction [] _ = return M.empty
buildPatchAction stack roots = do
       let rootsOnStack = roots ++ concatMap T.candidates stack 
       rootCandidates <- mapM dereference rootsOnStack
       let realRoots = filter ((/= 0) . snd) rootCandidates
       return $ foldr buildRootPatcher2 M.empty realRoots


buildRootPatcher2 :: (IntPtr,IntPtr) -> Map (Ptr b) RefUpdateAction -> Map (Ptr b) RefUpdateAction
buildRootPatcher2 (ptr,obj) = M.insertWith both ptr' patch 
  where patch newLocation = do printfGc $ printf "patch new ref: 0x%08x on stackloc: 0x%08x .. " 
                                 (fromIntegral newLocation :: Int) (fromIntegral ptr :: Int)
                               poke (intPtrToPtr ptr) newLocation  
                               printfPlain "=>patched.\n"
        ptr' = intPtrToPtr obj

        both newPatch oldPatch newLocation = do newPatch newLocation
                                                oldPatch newLocation




