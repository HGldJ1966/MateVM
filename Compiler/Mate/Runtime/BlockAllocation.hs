{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
module Compiler.Mate.Runtime.BlockAllocation where

import Foreign hiding ((.&.),unsafePerformIO)
import System.IO.Unsafe(unsafePerformIO)
import Control.Monad
import Control.Monad.Trans
import Control.Monad.State
import Control.Monad.Identity
import Test.QuickCheck hiding ((.&.))

import qualified Data.Sequence as Q
import Data.Sequence ((|>),(<|))
import Data.IORef
import Text.Printf
import qualified Data.Map as M
import Data.Map(Map,(!))
import Data.Set(Set)
import qualified Data.Set as S
import Compiler.Mate.Flags
import Compiler.Mate.Debug
import qualified Compiler.Mate.Runtime.GC as GC

blockSize :: Int
blockSize = 1 `shift` blockSizePowerOfTwo

data Block = Block { beginPtr :: !IntPtr
                   , endPtr   :: !IntPtr
                   , freePtr  :: !IntPtr
                   } deriving (Eq)

instance Show Block where
    show x = printf "Begin: 0x%08x, End: 0x%08x, FreePtr: 0x%08x" (fromIntegral $ beginPtr x :: Int) (fromIntegral $ endPtr x :: Int) (fromIntegral $ freePtr x :: Int)

-- Maps number of free bytes to a set of blocks with this
-- amount of free memory
type Blocks = Map Int [Block]

data GenState = GenState { freeBlocks :: [Block]
                         , activeBlocks :: Blocks
                         , collections :: !Int
                         , generation :: Int
                         } deriving (Show,Eq)

data GcState = GcState { generations :: Map Int GenState, 
                         allocs :: Int,
                         allocatedBytes :: Int,
                         loh :: Set IntPtr,
                         allocState :: AllocC
                       } deriving (Eq,Show)

generation0 :: GcState -> GenState
generation0 s = generations s !0

type Generation = Int

class Monad m => Alloc a m | a -> m where
    alloc ::  Generation -> Int -> StateT a m Block 
    release :: Block -> StateT a m ()

type GenStateT m a = StateT GenState (StateT a m)
type GcStateT m a = StateT GcState (StateT a m) 

-- This is the mock allocator
data AllocM = AllocM { freeS :: IntPtr } deriving (Eq)
instance Show AllocM where
    show x = printf "freeS: 0x%08x" (fromIntegral $ freeS x :: Int)

type AllocMT a = StateT AllocM Identity a

-- | allocates memory within a generation
allocGen :: Alloc a m => Int -> GenStateT m a (Ptr b)
allocGen size = do
    -- let's see if there is some free memory in our blocks
    -- as heuristics, take the one with the most free memory
    current <- get
    let possibleBlocks = activeBlocks current
        biggestBlockM = M.maxViewWithKey (M.filter (not . null) possibleBlocks)
    case biggestBlockM of                          
      Just ((space,block:rest),smallBlocks) -> 
        if space >= size
          then do --awesome. we got a block which is big enough
                  let (ptr,block') = allocateInBlock block size
                  let active' = M.insert space rest smallBlocks
                      active'' = M.insertWith (++) (freeSpace block') [block'] active'
                  put current { activeBlocks = active'' }
                  return ptr 
          else do
                allocateInFreshBlock (tracePipe ("current blocks:" ++ show possibleBlocks) size)
      _ -> tracePipe ("noActiveBlocks!!" ++ show possibleBlocks ++ "WIGH M:" ++ show biggestBlockM) $ allocateInFreshBlock size

freeSpace :: Block -> Int
freeSpace Block { freePtr = free', endPtr = end } = fromIntegral $ end - free'

allocateInFreshBlock :: Alloc a m => Int -> GenStateT m a (Ptr b)
allocateInFreshBlock size = do
    current <- get
    freeBlock <- case freeBlocks current of
                 [] -> lift $ alloc blockSize (generation current) -- make a block
                 (x:xs) -> do --reuse idle block
                              put current { freeBlocks = xs }
                              return x
    let (ptr,block) = allocateInBlock freeBlock size
    activateBlock block
    return ptr

activateBlock :: Monad m => Block -> GenStateT m a ()
activateBlock b = do
    current <- get
    let active = activeBlocks current
    put current { activeBlocks = M.insertWith (++) (freeSpace b) [b] active }

allocateInBlock :: Block -> Int -> (Ptr b, Block)
allocateInBlock b@(Block { freePtr = free', endPtr = end }) size = 
    if freePtr' > end
      then error $ "allocateInBlock has insufficient space. wtf" ++ (show b) ++ " with alloc size: " ++ (show size)
      else (intPtrToPtr free', b { freePtr = freePtr' })
  where freePtr' = free' + fromIntegral size


-- | allocates memory in generation 0
allocGen0 :: Alloc a m => GC.GenInfo -> Int -> GcStateT m a (Ptr b)
allocGen0 gen size = 
    if size > blockSize 
      then  error $ "tried to allocate superhuge object in gen0 (" ++ show size ++ " bytes)"
      else do
            let targetGenIndex = GC.targetGen gen
            targetGen <- liftM (\x -> generations x!targetGenIndex) get
            (ptr, newState) <- lift $ runStateT (allocGen size) targetGen
            c <- get
            put $ c { generations = M.insert targetGenIndex newState (generations c) }
            return ptr


emptyAllocM :: AllocM
emptyAllocM = AllocM { freeS = 0 }

instance Alloc AllocM Identity where
    alloc _ = mkBlockM
    release _ = return ()

data AllocIO = AllocIO deriving Show
type AllocIOT a = StateT AllocIO IO a

instance Alloc AllocIO IO where
    alloc _ = mkBlockIO
    release = releaseBlockIO 

currentFreePtrM ::  AllocMT IntPtr
currentFreePtrM = liftM freeS get 

mkBlockM :: Int -> AllocMT Block
mkBlockM size = do 
  start <- currentFreePtrM
  let end = start + fromIntegral size
  put AllocM { freeS = end + 1 } -- in reality do padding here
  return Block { beginPtr = start, endPtr = end, freePtr = start }

mkBlockIO :: Int -> AllocIOT Block
mkBlockIO size = do
  ptr <- liftIO $ mallocBytes size
  let block = Block { beginPtr = ptrToIntPtr ptr,
                      endPtr = ptrToIntPtr $ ptr `plusPtr` size,
                      freePtr = ptrToIntPtr ptr }  
  liftIO $ printfGc $ printf "made block: %s\n" (show block)
  return block
                        
releaseBlockIO :: Block -> AllocIOT ()
releaseBlockIO = liftIO . freeBlock
  where action = return . intPtrToPtr . beginPtr
        freeBlock = (freeDbg =<<) . action
        freeDbg ptr = do
                        printfGc $ printf "releaseBlock free ptr: %s" (show ptr)
                        free ptr

freeGen :: GenState -> AllocIOT ()
freeGen = mapM_ (mapM_ releaseBlockIO . snd) . M.toList . activeBlocks

freeGens :: [GenState] -> AllocIOT ()
freeGens = mapM_ freeGen 

freeGensIO :: [GenState] -> IO ()
freeGensIO xs = evalStateT (freeGens xs) AllocIO

blockAdresses :: Num a => a -> [(a,a)]
blockAdresses k = iterate next first
    where first = (0,k-1)
          next (l,u) = (l+k,u+k)

emptyGenState ::  GenState
emptyGenState = GenState { freeBlocks = [], activeBlocks = M.empty, collections = 0, generation = 0 }

mkGenState :: Int -> GenState
mkGenState n = GenState { freeBlocks = [], activeBlocks = M.empty, collections = 0, generation = n }


gcState1 ::  GcState
gcState1 = GcState { generations = M.insert 0 emptyGenState M.empty, allocs = 0, allocatedBytes = 0, loh = S.empty, 
                     allocState = error "not implemented" }

mkGcState ::  GenState -> GcState
mkGcState s = GcState { generations = M.insert 0 s M.empty, allocs = 0, allocatedBytes = 0, loh = S.empty, allocState = error "not implemented"}


runBlockAllocator :: Int -> GcState -> IO (Ptr b, GcState)
runBlockAllocator size current = evalStateT allocT AllocIO
    where allocT = runStateT (allocGen0 GC.mkGen0 size) current

runBlockAllocatorC :: GC.GenInfo -> Int -> StateT GcState IO (Ptr b)
runBlockAllocatorC gen size = do
    current <- get
    let m = runStateT (allocGen0 gen size) current
    ((ptr,gcState),allocState') <- liftIO $ runStateT m (allocState current)
    put gcState { allocState = allocState' }
    return ptr


data AllocC = AllocC { freeBlocksC :: Q.Seq Block } 
                deriving (Show,Eq)

instance Alloc AllocC IO where
    alloc = allocC
    release = releaseC


mkAllocC :: Int -> IO AllocC
mkAllocC 0 = return AllocC { freeBlocksC = Q.empty }
mkAllocC n = do
    printfGc $ printf "heapSize = %d * blockSize = %d => %d\n" n blockSize (n*blockSize)
    let size' = n * blockSize
    ptr <- mallocBytes size'
    let intPtr = ptrToIntPtr ptr
    printfGc $ printf "allocated cached block memory: %s\n" (show ptr)
    let begin = shift (shift intPtr (-blockSizePowerOfTwo)) blockSizePowerOfTwo
    printfGc $ printf "starting at: 0x%08x\n" (fromIntegral begin :: Int)
    printfGc $ printf "ending at: 0x%08x\n" (fromIntegral  begin + size' :: Int)
    let allBlockBegins = [begin,begin+fromIntegral blockSize..begin + fromIntegral size']
    let allBlocks = [Block { beginPtr = x+4, endPtr = x+fromIntegral size', freePtr = x+4} | x <- allBlockBegins]
    return AllocC { freeBlocksC = Q.fromList allBlocks } -- all is free
  

allocC :: Generation -> Int -> StateT AllocC IO Block
allocC gen _ = do
    current <- get
    if Q.null (freeBlocksC current) 
      then error "out of heap memory!"
      else do
        let block = Q.index (freeBlocksC current) 0 
        writeGenToBlock block gen
        liftIO $ modifyIORef activeBlocksCnt (+ (1))
        activeOnes <- liftIO  $ readIORef activeBlocksCnt
        liftIO $ printfGc $ printf "activated a block %d\n" activeOnes
        put current { freeBlocksC = Q.drop 1 (freeBlocksC current) }
        --liftIO $ printfGc $ printf "we got free blocks: %s" (show $ length xs)
        return block { freePtr = beginPtr block }

writeGenToBlock :: Block -> Generation -> StateT AllocC IO ()
writeGenToBlock block gen = 
    liftIO $ poke (intPtrToPtr $ beginPtr block - 4) gen


releaseC :: Block -> StateT AllocC IO ()
releaseC b = do
    current' <- get
    liftIO $ modifyIORef activeBlocksCnt (+ (-1))
    activeOnes <- liftIO  $ readIORef activeBlocksCnt
    liftIO $ printfGc $ printf "released a block %d\n" activeOnes
    put current' { freeBlocksC = freeBlocksC current' |> b }

activeBlocksCnt :: IORef Int
activeBlocksCnt = unsafePerformIO $ newIORef 0

freeGensIOC :: [GenState] -> StateT GcState IO ()
freeGensIOC xs = do 
    current <- get
    let blocksToDispose = concatMap ( concatMap snd . M.toList . activeBlocks ) xs
    (_,s) <- liftIO $ runStateT (mapM_ releaseC blocksToDispose) (allocState current)
    put current { allocState = s }
    return ()

--dont be too frightened here. cornholio
runTest :: StateT GcState (StateT AllocM Identity) (Ptr a) -> GcState -> AllocM -> ((Ptr a, GcState), AllocM)
runTest x gcState allocState' = let allocation = runStateT x gcState
                                    resultT = runStateT allocation allocState'
                                    result = runIdentity resultT
                                in result


test1 ::  ((Ptr b, GcState), AllocM)
test1 = let x = runStateT (allocGen0 GC.mkGen0 12) gcState1
            y = runStateT x emptyAllocM
        in runIdentity y

test2 ::  IO ((Ptr b, GcState), AllocIO)
test2 = let x = runStateT (allocGen0 GC.mkGen0 12) gcState1
            y = runStateT x AllocIO
        in y

int2Ptr :: Int -> Ptr b
int2Ptr = intPtrToPtr . fromIntegral

emptyTest :: Int -> Property
emptyTest x = let ((ptr,_),_) = runTest (allocGen0 GC.mkGen0 x) start emptyAllocM 
              in x <= blockSize ==> ptr == int2Ptr 0
    where start = mkGcState  
                     GenState { freeBlocks = [], activeBlocks = M.empty, collections = 0, generation = 0} 
{-
test3 ::  Property
test3 = let ((ptr,gcS),_) = runTest (allocGen0 GC.mkGen0 12) start emptyAllocM 
        in True ==> ptr == int2Ptr 0xc && (freeBlocks . head . generations) gcS == [] 
    where aBlock = Block { beginPtr = 0x0, endPtr = 0x400, freePtr = 0xc }
          start = mkGcState  
                     GenState { freeBlocks = [aBlock], activeBlocks = M.empty, collections = 0, generation = 0 } 

test4 ::  Property
test4 = let ((ptr,gcS),_) = runTest (allocGen0 GC.mkGen0 12) start emptyAllocM 
        in True ==> ptr == int2Ptr 0x401 && (freeBlocks . head . generations) gcS == [] 
    where aBlock = Block { beginPtr = 0x0, endPtr = 0x400, freePtr = 0x400 }
          aBlock2 = Block { beginPtr = 0x401, endPtr = 0x800, freePtr = 0x401 }
          active' = M.insert (freeSpace aBlock) [aBlock] M.empty
          active'' = M.insert (freeSpace aBlock2) [aBlock2] active'
          start = mkGcState  
                     GenState { freeBlocks = [], activeBlocks = active'', collections = 0, generation = 0 } 

test5 ::  Int -> Property
test5 s = let ((ptr,gcS),_) = runTest (allocGen0 GC.mkGen0 s) start AllocM { freeS = 0x801 }
          in s > 1 && s < blockSize ==> ptr == int2Ptr 0x801 && (length . M.toList . activeBlocks . head . generations) gcS == 3
    where aBlock = Block { beginPtr = 0x0, endPtr = 0x400, freePtr = 0x400 }
          aBlock2 = Block { beginPtr = 0x401, endPtr = 0x800, freePtr = 0x7FF }
          active' = M.insertWith (++) (freeSpace aBlock) [aBlock] M.empty
          active'' = M.insertWith (++) (freeSpace aBlock2) [aBlock2] active'
          start = mkGcState  
                     GenState { freeBlocks = [], activeBlocks = active'', collections = 0, generation = 0 } 
-}
