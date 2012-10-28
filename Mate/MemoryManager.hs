{-# LANGUAGE ExistentialQuantification #-}
module Mate.MemoryManager   
    ( evacuateList 
    ,  AllocationManager(..)
    , TwoSpace(..)
    , initTwoSpace
    , mallocBytes'
    , switchSpaces
    , RefUpdateAction
    , validRef'
    , buildGCAction )   where

import qualified Foreign.Marshal.Alloc as Alloc
import Foreign.Ptr
import Foreign.Marshal.Utils
import Foreign.Storable

import Text.Printf
import Control.Monad.State
import Control.Applicative
import qualified Data.Map as M

import Mate.Debug
import Mate.GC hiding (size)
import qualified Mate.StackTrace as T
import qualified Mate.JavaObjectsGC as Obj
import qualified Mate.GC as GC

type RefUpdateAction = IntPtr -> IO () -- the argument is the new location of the refobj
type RootSet a = M.Map (Ptr a) RefUpdateAction

class AllocationManager a where
  
  -- | allocates n bytes in current space to space (may be to space or gen0 space)
  mallocBytesT :: Int -> StateT a IO (Ptr b)
  
  -- | performs full gc and which is reflected in mem managers state
  performCollection :: (RefObj b) => M.Map b RefUpdateAction ->  StateT a IO ()

  heapSize :: StateT a IO Int

  validRef :: IntPtr -> StateT a IO Bool

data TwoSpace = TwoSpace { fromBase :: IntPtr, 
                           toBase   :: IntPtr, 
                           fromHeap :: IntPtr, 
                           toHeap   :: IntPtr,
                           fromExtreme :: IntPtr,
                           toExtreme   :: IntPtr }

instance AllocationManager TwoSpace where
  mallocBytesT = mallocBytes'
  performCollection = performCollection'
  
  heapSize = do space <- get
                return $ fromIntegral $ toHeap space - fromIntegral (toBase space)

  validRef ptr = liftM (validRef' ptr) get


performCollection' :: (RefObj a) => M.Map a RefUpdateAction -> StateT TwoSpace IO ()
performCollection' roots = do modify switchSpaces
                              newState <- get
                              let rootList = map fst $ M.toList roots
                              lift (putStrLn "rootSet: " >> print rootList)
                              lift (performCollectionIO newState rootList)
                              lift $ patchGCRoots roots

patchGCRoots :: (RefObj a) => M.Map a RefUpdateAction -> IO ()
patchGCRoots roots = mapM_ fixRef $ M.toList roots
  where fixRef (obj,fixupAction) = getNewRef obj >>= getIntPtr >>= fixupAction
                        
-- [todo hs] this is slow. merge phases to eliminate list with refs
performCollectionIO :: (AllocationManager b, RefObj a) => b -> [a] -> IO ()
performCollectionIO manager refs' = do lifeRefs <- liftM concat $ mapM (markTree'' marked mark []) refs'
                                       evacuateList lifeRefs manager
                                       patchAllRefs lifeRefs                       


buildGCAction :: AllocationManager a => [T.StackDescription] -> Int -> StateT a IO (Ptr a)
buildGCAction [] size = mallocBytesT (size + Obj.gcAllocationOffset)
buildGCAction stack size = do roots <- filterM checkRef (concatMap T.possibleRefs stack)
                              performCollection $ foldr buildRootPatcher M.empty roots
                              mallocBytesT (size + Obj.gcAllocationOffset)
  where --checkRef :: IntPtr -> StateT a IO Bool
        checkRef intPtr = lift (dereference intPtr) >>= validRef
        dereference :: IntPtr -> IO IntPtr
        dereference intPtr = do printf "deref stacklocation: 0x%08x\n" (fromIntegral intPtr :: Int)
                                ref <- peek $ intPtrToPtr intPtr :: IO IntPtr
                                printf "deref location: "
                                print $ intPtrToPtr ref
                                return ref


buildRootPatcher :: IntPtr -> RootSet a -> RootSet a
buildRootPatcher ptr = M.insertWith (>>) ptr' patch 
  where patch = poke ptr' 
        ptr' = intPtrToPtr ptr

switchSpaces :: TwoSpace -> TwoSpace
switchSpaces old = old { fromHeap = toHeap old,
                         toHeap = fromBase old, 
                         fromBase = toBase old,
                         toBase = fromBase old,
                         fromExtreme = toExtreme old,
                         toExtreme = fromExtreme old }


mallocBytes' :: Int -> StateT TwoSpace IO (Ptr b)
mallocBytes' bytes = do state' <- get
                        let end = toHeap state' + fromIntegral bytes
                            
                            base = fromIntegral $ toBase state'
                            extreme = fromIntegral $ toExtreme state'
                            heap = fromIntegral $ toHeap state'
                            used = heap - base
                            capacity = extreme - base
                        if end <= toExtreme state' 
                          then liftIO (logAllocation bytes used capacity) >> alloc state' end 
                          else 
                               failNoSpace used capacity
  where alloc :: TwoSpace -> IntPtr -> StateT TwoSpace IO (Ptr b)
        alloc state' end = do let ptr = toHeap state'
                              put $ state' { toHeap = end } 
                              liftIO (putStrLn $ "Allocated obj: " ++ show (intPtrToPtr ptr))
                              liftIO (return $ intPtrToPtr ptr)
        failNoSpace :: Integer -> Integer -> a
        failNoSpace usage fullSize = 
            error $ printf "no space left in two space (mallocBytes'). Usage: %d/%d" usage fullSize
        
        logAllocation :: Int -> Integer -> Integer -> IO ()
        --logAllocation _ _ _ = return ()
        logAllocation fullSize usage capacity = printf "alloc size: %d (%d/%d)\n" fullSize usage capacity
                          


evacuate' :: (RefObj a, AllocationManager b) => [a] -> StateT b IO ()
evacuate' =  mapM_ evacuate'' 

evacuate'' :: (RefObj a, AllocationManager b) => a -> StateT b IO ()
evacuate'' obj = do (size',payload') <- liftIO ((,) <$> GC.size obj <*> getIntPtr obj)
                    -- malloc in TwoSpace
                    newPtr <- mallocBytesT size'
                    --liftIO (putStrLn ("evacuating: " ++ show obj ++ " and set: " ++ show newPtr ++ " size: " ++ show size'))
                    -- copy data over and leave notice
                    liftIO (copyBytes newPtr (intPtrToPtr payload') size' >> 
                            setNewRef obj (cast newPtr))

evacuateList :: (RefObj a, AllocationManager b) => [a] -> b -> IO ()
evacuateList objs = evalStateT (evacuate' objs) 

validRef' :: IntPtr -> TwoSpace -> Bool
validRef' ptr twoSpace = (fromBase twoSpace <= ptr) && (ptr <= toExtreme twoSpace)


initTwoSpace :: Int -> IO TwoSpace
initTwoSpace size' =  do printfStr $ printf "initializing TwoSpace memory manager with %d bytes.\n" size'
                         fromSpace <- Alloc.mallocBytes (size' * 2)
                         let toSpace   = fromSpace `plusPtr` size'
                         if fromSpace /= nullPtr && toSpace /= nullPtr 
                            then return $ buildToSpace fromSpace toSpace
                            else error "Could not initialize TwoSpace memory manager (malloc returned null ptr)\n"
   where buildToSpace from to = let fromBase' = ptrToIntPtr from
                                    toBase' = ptrToIntPtr to
                                    fromExtreme' = ptrToIntPtr $ from `plusPtr` size'
                                    toExtreme' = ptrToIntPtr $ to `plusPtr` size'
                                in TwoSpace { fromBase = fromBase', toBase = toBase',
                                              fromHeap = fromBase', toHeap = toBase',
                                              fromExtreme = fromExtreme', toExtreme = toExtreme' }

