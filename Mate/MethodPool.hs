{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ForeignFunctionInterface #-}
module Mate.MethodPool where

import Data.Binary
import Data.String.Utils
import qualified Data.Map as M
import qualified Data.Set as S
import System.Plugins

import Text.Printf

import Foreign.Ptr
import Foreign.C.Types
import Foreign.C.String

import JVM.ClassFile

import Harpy
import Harpy.X86Disassembler

import Mate.BasicBlocks
import Mate.Types
import Mate.X86CodeGen
import Mate.Utilities
import Mate.ClassPool


foreign import ccall "dynamic"
   code_void :: FunPtr (IO ()) -> (IO ())


foreign export ccall getMethodEntry :: CUInt -> Ptr () -> Ptr () -> IO CUInt
getMethodEntry :: CUInt -> Ptr () -> Ptr () -> IO CUInt
getMethodEntry signal_from ptr_mmap ptr_tmap = do
  mmap <- ptr2mmap ptr_mmap
  tmap <- ptr2tmap ptr_tmap

  let w32_from = fromIntegral signal_from
  let mi = tmap M.! w32_from
  case mi of
    (MI mi'@(MethodInfo method cm sig)) -> do
      case M.lookup mi' mmap of
        Nothing -> do
          cls <- getClassFile cm
          printf "getMethodEntry(from 0x%08x): no method \"%s\" found. compile it\n" w32_from (show mi')
          let mm = lookupMethod method cls
          case mm of
            Just mm' -> do
                let flags = methodAccessFlags mm'
                case S.member ACC_NATIVE flags of
                  False -> do
                    hmap <- parseMethod cls method
                    printMapBB hmap
                    case hmap of
                      Just hmap' -> do
                        entry <- compileBB hmap' mi'
                        return $ fromIntegral $ ((fromIntegral $ ptrToIntPtr entry) :: Word32)
                      Nothing -> error $ (show method) ++ " not found. abort"
                  True -> do
                    let symbol = (replace "/" "_" $ toString cm) ++ "__" ++ (toString method) ++ "__" ++ (replace "(" "_" (replace ")" "_" $ toString $ encode sig))
                    printf "native-call: symbol: %s\n" symbol
                    nf <- loadNativeFunction symbol
                    let w32_nf = fromIntegral nf
                    let mmap' = M.insert mi' w32_nf mmap
                    mmap2ptr mmap' >>= set_methodmap
                    return nf
            Nothing -> error $ (show method) ++ " not found. abort"
        Just w32 -> return (fromIntegral w32)
    _ -> error $ "getMethodEntry: no trapInfo. abort"

-- TODO(bernhard): UBERHAX.  ghc patch?
foreign import ccall safe "lookupSymbol"
   c_lookupSymbol :: CString -> IO (Ptr a)

loadNativeFunction :: String -> IO (CUInt)
loadNativeFunction sym = do
        _ <- loadRawObject "ffi/native.o"
        -- TODO(bernhard): WTF
        resolveObjs (return ())
        ptr <- withCString sym c_lookupSymbol
        if (ptr == nullPtr)
          then error $ "dyn. loading of \"" ++ sym ++ "\" failed."
          else return $ fromIntegral $ ptrToIntPtr ptr

-- t_01 :: IO ()
-- t_01 = do
--   (entry, _) <- testCase "./tests/Fib.class" "fib"
--   let int_entry = ((fromIntegral $ ptrToIntPtr entry) :: Word32)
--   let mmap = M.insert ("fib" :: String) int_entry M.empty
--   mapM_ (\(x,y) -> printf "%s at 0x%08x\n" x y) $ M.toList mmap
--   mmap2ptr mmap >>= set_mmap
--   demo_mmap -- access Data.Map from C

initMethodPool :: IO ()
initMethodPool = do
  mmap2ptr M.empty >>= set_methodmap
  tmap2ptr M.empty >>= set_trapmap
  classmap2ptr M.empty >>= set_classmap

compileBB :: MapBB -> MethodInfo -> IO (Ptr Word8)
compileBB hmap methodinfo = do
  mmap <- get_methodmap >>= ptr2mmap
  tmap <- get_trapmap >>= ptr2tmap

  -- TODO(bernhard): replace parsing with some kind of classpool
  cls <- getClassFile (cName methodinfo)
  let ebb = emitFromBB (methName methodinfo) cls hmap
  (_, Right ((entry, _, _, new_tmap), disasm)) <- runCodeGen ebb () ()
  let w32_entry = ((fromIntegral $ ptrToIntPtr entry) :: Word32)

  let mmap' = M.insert methodinfo w32_entry mmap
  let tmap' = M.union tmap new_tmap -- prefers elements in cmap
  mmap2ptr mmap' >>= set_methodmap
  tmap2ptr tmap' >>= set_trapmap

  printf "disasm:\n"
  mapM_ (putStrLn . showAtt) disasm
  -- UNCOMMENT NEXT LINE FOR GDB FUN
  -- _ <- getLine
  -- (1) start it with `gdb ./mate' and then `run <classfile>'
  -- (2) on getLine, press ctrl+c
  -- (3) `br *0x<addr>'; obtain the address from the disasm above
  -- (4) `cont' and press enter
  return entry


executeFuncPtr :: Ptr Word8 -> IO ()
executeFuncPtr entry = code_void $ ((castPtrToFunPtr entry) :: FunPtr (IO ()))
