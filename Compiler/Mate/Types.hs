{-# LANGUAGE OverloadedStrings #-}
module Compiler.Mate.Types
  ( ExceptionMap
  , RuntimeStackInfo(..)
  , StackDisp, GCPoint, GCPoints, GCSet, rootSet
  , JpcNpcMap
  , TrapPatcher, TrapPatcherEax
  , ExceptionHandler
  , WriteBackRegs(..)
  , CompiledMethod(..)
  , TrapMap, MethodMap, ClassMap, FieldMap, FieldTypeMap
  , StringMap, VirtualMap, InterfaceMap
  , InterfaceMethodMap
  , TrapCause(..)
  , StaticFieldInfo(..)
  , MethodInfo(..)
  , ClassInfo(..)
  , MateObjType(..)
  , setTrapMap, getTrapMap
  , setMethodMap, getMethodMap
  , setClassMap, getClassMap
  , setStringMap, getStringMap
  , setVirtualMap, getVirtualMap
  , setInterfaceMap, getInterfaceMap
  , setInterfaceMethodMap, getInterfaceMethodMap
  ) where

import Data.Int
import Data.Functor
import Data.Word
import qualified Data.Map as M
import qualified Data.ByteString.Lazy as B

import Data.IORef
import System.IO.Unsafe

import Harpy
import Foreign.C.Types

import JVM.ClassFile
import JVM.Assembler

import Compiler.Mate.Backend.NativeSizes


type ExceptionMap a = M.Map (a, a) [(B.ByteString, a)]
data RuntimeStackInfo = RuntimeStackInfo
  { rsiMethodname :: B.ByteString
  , rsiExceptionMap :: ExceptionMap NativeWord
  , rsiGCPoints :: GCPoints
  } deriving Show

type StackDisp = NativeWord -- stack displacement
-- TODO: replace list with Set?
type GCPoint = [StackDisp] -- information for one GC Point (e.g. `NEW')

-- a method can has several points in program where it calls the GC.
-- however, the stack layout can be different for each point
type GCPoints = M.Map NativeWord -- instruction pointer
                      GCPoint

-- at runtime, the GC can build a GCSet via stack walks
type GCSet = [(Word32 {- ebp -}, GCPoint)]

-- the rootSet contains all addresses of valids Java references (e.g. objects,
-- arrays, ... ?)
rootSet :: GCSet -> [Word32]
rootSet = concatMap (\(base, points) -> map (+base) points)

-- java byte code PC -> native PC
type JpcNpcMap = M.Map Int Word32

-- NativeWord = point of method call in generated code
-- MethodInfo = relevant information about callee
type TrapMap = M.Map NativeWord TrapCause

data WriteBackRegs = WriteBackRegs
  { wbEip :: CPtrdiff
  , wbEbp :: CPtrdiff
  , wbEsp :: CPtrdiff
  , wbEax :: CPtrdiff }
type TrapPatcher = WriteBackRegs -> CodeGen () () WriteBackRegs
type TrapPatcherEax = TrapPatcher
type ExceptionHandler = WriteBackRegs -> IO WriteBackRegs

data TrapCause
  = StaticMethod TrapPatcher -- for static calls
  | VirtualCall Bool MethodInfo (IO NativeWord) -- for invoke{interface,virtual}
  | InstanceOf TrapPatcherEax
  | ThrowException TrapPatcherEax
  | NewObject TrapPatcher
  | StaticField StaticFieldInfo
  | ObjectField TrapPatcher

data StaticFieldInfo = StaticFieldInfo {
  sfiClassName :: B.ByteString,
  sfiFieldName :: B.ByteString } deriving Show



data CompiledMethod = CompiledMethod {
  methodEntryPoint :: NativeWord,
  -- TODO(bernhard): remove exceptionmap?
  methodExceptionMap :: ExceptionMap NativeWord }
-- B.ByteString = name of method
type MethodMap = M.Map MethodInfo CompiledMethod

data MethodInfo = MethodInfo {
  methName :: B.ByteString,
  methClassName :: B.ByteString,
  methSignature :: MethodSignature
  } deriving (Eq, Ord)

instance Show MethodInfo where
  show (MethodInfo method c sig) =
    toString c ++ "." ++ toString method ++ "." ++ show sig



-- store information of loaded classes
type ClassMap = M.Map B.ByteString ClassInfo

data ClassInfo = ClassInfo {
  ciName :: B.ByteString,
  ciFile :: Class Direct,
  ciStaticMap :: FieldMap,
  ciStaticFieldTypeMap :: FieldTypeMap,
  ciFieldMap :: FieldMap,
  ciFieldTypeMap :: FieldTypeMap,
  ciMethodMap :: FieldMap,
  ciMethodBase :: NativeWord,
  ciInitDone :: Bool }


-- store field offsets in a map
type FieldMap = M.Map B.ByteString Int32

-- store field information per offset
type FieldTypeMap = M.Map Int32 (Field Direct)


-- java strings are allocated only once, therefore we
-- use a hashmap to store the address for a String
type StringMap = M.Map B.ByteString NativeWord


-- map "methodtable addr" to "classname"
-- we need that to identify the actual type
-- on the invokevirtual insn
type VirtualMap = M.Map NativeWord B.ByteString


-- store each parsed Interface upon first loading
type InterfaceMap = M.Map B.ByteString (Class Direct)

-- store offset for each <Interface><Method><Signature> pair
type InterfaceMethodMap = M.Map B.ByteString NativeWord

data MateObjType = ReferenceType | PrimitiveType deriving (Show,Eq)

{-
toString :: B.ByteString -> String
toString bstr = decodeString $ map (chr . fromIntegral) $ B.unpack bstr
-}


data MateCtx = MateCtx {
  ctxMethodMap :: MethodMap,
  ctxTrapMap :: TrapMap,
  ctxClassMap :: ClassMap,
  ctxVirtualMap :: VirtualMap,
  ctxStringMap :: StringMap,
  ctxInterfaceMap :: InterfaceMap,
  ctxInterfaceMethodMap :: InterfaceMethodMap }

emptyMateCtx :: MateCtx
emptyMateCtx = MateCtx M.empty M.empty M.empty M.empty M.empty M.empty M.empty

mateCtx :: IORef MateCtx
{-# NOINLINE mateCtx #-}
mateCtx = unsafePerformIO $ newIORef emptyMateCtx

setMap :: (MateCtx -> MateCtx) -> IO ()
setMap recordupdate = recordupdate <$> readIORef mateCtx >>= writeIORef mateCtx

setMethodMap :: MethodMap -> IO ()
setMethodMap m = setMap (\x -> x {ctxMethodMap = m})

getMethodMap :: IO MethodMap
getMethodMap = ctxMethodMap <$> readIORef mateCtx

setTrapMap :: TrapMap -> IO ()
setTrapMap m = setMap (\x -> x {ctxTrapMap = m})

getTrapMap :: IO TrapMap
getTrapMap = ctxTrapMap <$> readIORef mateCtx

setClassMap :: ClassMap -> IO ()
setClassMap m = setMap (\x -> x {ctxClassMap = m})

getClassMap :: IO ClassMap
getClassMap = ctxClassMap <$> readIORef mateCtx

setVirtualMap :: VirtualMap -> IO ()
setVirtualMap m = setMap (\x -> x {ctxVirtualMap = m})

getVirtualMap :: IO VirtualMap
getVirtualMap = ctxVirtualMap <$> readIORef mateCtx

setStringMap :: StringMap -> IO ()
setStringMap m = setMap (\x -> x {ctxStringMap = m})

getStringMap :: IO StringMap
getStringMap = ctxStringMap <$> readIORef mateCtx

setInterfaceMap :: InterfaceMap -> IO ()
setInterfaceMap m = setMap (\x -> x {ctxInterfaceMap = m})

getInterfaceMap :: IO InterfaceMap
getInterfaceMap = ctxInterfaceMap <$> readIORef mateCtx

setInterfaceMethodMap :: InterfaceMethodMap -> IO ()
setInterfaceMethodMap m = setMap (\x -> x {ctxInterfaceMethodMap = m})

getInterfaceMethodMap :: IO InterfaceMethodMap
getInterfaceMethodMap = ctxInterfaceMethodMap <$> readIORef mateCtx