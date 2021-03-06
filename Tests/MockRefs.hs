module Tests.MockRefs where

import Mate.GC
import Mate.TwoSpaceAllocator

import Foreign.Ptr
import Foreign.Marshal.Alloc
import Foreign.Marshal.Array
import Foreign.Storable
import GHC.Int
import Text.Printf
import System.IO.Unsafe(unsafePerformIO)
import Data.IORef
import qualified Data.Map as M

import Control.Monad
import Control.Monad.State

import Test.QuickCheck 
import Test.QuickCheck.Monadic 

import Mate.Debug
import Data.List

instance AllocationManager TwoSpace where
  mallocBytesT = mallocBytes'
  performCollection m = performCollectionIO (map fst $ M.toList m)
  
  heapSize = do space <- get
                return $ fromIntegral $ toHeap space - fromIntegral (toBase space)

  validRef ptr = liftM (validRef' ptr) get

-- [todo hs] this is slow. merge phases to eliminate list with refs
performCollectionIO :: RefObj a => [a] -> StateT TwoSpace IO ()
performCollectionIO refs' = do 
    liftIO $ printfGc "before mark\n"
    let objFilter obj = return True
    lifeRefs <- liftIO $ liftM (nub . concat) $ mapM (markTree'' objFilter mark refs') refs'
    liftIO $ printfGc "marked\n"
    liftIO $ mapM printRef lifeRefs
    liftIO $ printfGc "go evacuate!\n"
    evacuate' lifeRefs 
    lift $ printfGc "eacuated. patching..\n"
    memoryManager <- get
    lift $ patchAllRefs (getIntPtr >=> return . flip validRef' memoryManager) lifeRefs 
    lift $ printfGc "patched.\n"    

instance RefObj (Ptr a) where
  getIntPtr   = return . ptrToIntPtr
  size a      = fmap ((+ fieldsOff) . (*4) . length) (refs a)
  refs        = unpackRefs . castPtr
  marked      = markedRef
  mark        = markRef (0x1::Int32)
  unmark      = markRef (0x0::Int32)
  setNewRef   = setNewRefPtr
  patchRefs   = patchRefsPtr
  cast = castPtr
  getNewRef ptr = peekByteOff ptr newRefOff
  allocationOffset _ = 0
  printRef = printRef'

idOff           = 0x0
numberOfObjsOff = 0x4
markedOff = 0x8
newRefOff = 0xC
fieldsOff = 0x10

unpackRefs :: Ptr Int32 -> IO [Ptr b]
unpackRefs ptr = do  --dereference number of objs; mark field skipped via fieldsOffset
                    numberOfObjs <- peekByteOff ptr numberOfObjsOff :: IO Int32
                    mapM (peekElemOff (ptr `plusPtr` fieldsOff)) [0..fromIntegral $ numberOfObjs-1]

markedRef :: Ptr a -> IO Bool
markedRef ptr = liftM ((/=0) . fromIntegral) (peekByteOff ptr markedOff :: IO Int32)

markRef :: Int32 -> Ptr a -> IO ()
markRef val ptr = pokeByteOff ptr markedOff val

setNewRefPtr :: Ptr a -> Ptr a -> IO ()
setNewRefPtr ptr = pokeByteOff ptr newRefOff 

patchRefsPtr :: Ptr a -> [Ptr a] -> IO ()
patchRefsPtr ptr = pokeArray (ptr `plusPtr` fieldsOff) 

printRef' :: Ptr a -> IO ()
printRef' ptr = do printf "obj 0x%08x\n" =<< (peekByteOff ptr idOff :: IO Int32)
                   printf "children 0x%08x\n" =<< (peekByteOff ptr numberOfObjsOff :: IO Int32)                  
                   printf "marked 0x%08x\n" =<< (peekByteOff ptr markedOff :: IO Int32) 
                   printf "payload 0x%08x\n" =<< (liftM fromIntegral (getIntPtr ptr) :: IO Int32)
                   printf "newRef 0x%08x\n" =<< (peekByteOff ptr newRefOff :: IO Int32)
                   printChildren ptr
                   putStrLn ""

printChildren :: Ptr a -> IO ()
printChildren ptr = do children <- refs ptr
                       putStrLn $ "children" ++ show children


printTree :: Ptr a -> IO ()
printTree = traverseIO printRef'

emptyObj id  = do mem <- mallocBytes 0x10
                  putStrLn $ "my memory: "  ++ show mem
                  let self = fromIntegral (ptrToIntPtr mem)
                  pokeArray mem [0,0,0::Int32,0]
                  return mem

twoRefs = do mem <- mallocBytes 0x18
             -- idOfObj; numberofObj; marked waste memory Int32
             pokeArray mem [0::Int32,2,0,0]
             obj1 <- emptyObj 1
             obj2 <- emptyObj 2
             pokeByteOff mem 0x10 obj1
             pokeByteOff mem 0x14 obj2
             return mem

cyclR = do mem <- mallocBytes 0x1C
           pokeArray mem [0::Int32,3,0,0]
           obj1 <- emptyObj 1
           obj2 <- emptyObj 2
           pokeByteOff mem 0x10 obj1
           pokeByteOff mem 0x14 obj2
           pokeByteOff mem 0x18 mem
           return mem

test objr = do twoRefs <- objr
               putStrLn "initial:\n" 
               printTree twoRefs
               lifeRefs <- markTree'' marked mark [] twoRefs
               putStrLn "life refs: \n"
               print lifeRefs
               --forM lifeRefs printRef'
               putStrLn "after marking\n"
               printTree twoRefs
               markTree'' (liftM not . marked) unmark [] twoRefs
               putStrLn "after unmarking\n"
               printTree twoRefs

{-
patchAllRefs :: (RefObj a) => a -> IO a
patchAllRefs obj = do markTree'' patchAndCheckMark unmark [] obj
                      getNewRef obj
 where patchAndCheckMark :: a -> IO Bool
       patchAndCheckMark a = undefined
-}

testEvacuation objr = do ref <- objr
                         lifeRefs <- markTree'' marked mark [] ref
                         putStrLn "initial objectTree"
                         printTree ref
                         mem <- initTwoSpace 0x10000
                         (_,mem') <- runStateT (evacuate' lifeRefs) mem
                         print lifeRefs
                         putStrLn "oldObjectTree: "
                         printTree ref
                         patchAllRefs (\x -> return True) lifeRefs
                         newRef <- getNewRef ref 
                         putStrLn "resulting objectTree"
                         printTree newRef
                         

createMemoryManager :: Property
createMemoryManager = monadicIO $ run f >>= (assert . (==0))
  where f :: IO Int
        f = do twoSpace <- initTwoSpace 0x10000
               evalStateT heapSize twoSpace


createObject :: Int -> IO (Ptr a)
createObject children = do mem <- mallocBytes (0x10 + 0x4 * children)
                           pokeArray mem [0,fromIntegral children,0::Int32,0]
                           fields <- replicateM children (createObject 0)
                           pokeArray (mem `plusPtr` fieldsOff) (fields :: [Ptr Int32])
                           return $ cast mem 

data ObjectTree = Node [ObjectTree] deriving Show

instance Arbitrary ObjectTree where
  arbitrary = resize 8 ( sized $ \n ->
                                     do empty <- choose (0,100) :: Gen Int-- [True,False]
                                        if empty < 80 then return $ Node []
                                         else do k <- choose (1,n)
                                                 liftM Node $ sequence [ arbitrary | _ <- [1..k] ] )

createObjects :: ObjectTree -> IO (Ptr a)
createObjects (Node xs)  = do let children = length xs
                              mem <- mallocBytes (0x10 + 0x4 * children)
                              pokeArray mem [0,fromIntegral children,0::Int32,0]
                              fields <- mapM createObjects xs
                              pokeArray (mem `plusPtr` fieldsOff) (fields :: [Ptr Int32])
                              return $ cast mem 


testObjectTree :: ObjectTree -> Property
testObjectTree objTree = monadicIO $ run f >>= (assert . (==0))
  where f :: IO Int
        f = do root <- createObjects objTree
               twoSpace <- initTwoSpace 0x10000
               let collection = performCollection (M.insert root (\_ -> return ()) M.empty)
               runStateT collection twoSpace
               evalStateT heapSize twoSpace

testObjectTree' :: IO (ObjectTree -> Property)
testObjectTree' = do
  memoryManager <- initTwoSpace 0x105000
  ref <- newIORef memoryManager
  return ( \objTree -> monadicIO $ run (f ref objTree) ) -- what was assert ==0 about?
  where f :: IORef TwoSpace -> ObjectTree -> IO Int
        f memRef objTree = do 
           root <- createObjects objTree
           twoSpace <- readIORef memRef
           let collection = performCollection (M.insert root (\_ -> return ()) M.empty)
           (space,twoSpace') <- runStateT (collection  >> heapSize) twoSpace
           writeIORef memRef twoSpace'
           --printf "quickcheck performed another iteration. space usage: %d" space
           return space

testGC :: IO ()
testGC = testObjectTree' >>= quickCheck
