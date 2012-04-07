{-# LANGUAGE OverloadedStrings #-}
module Mate.X86CodeGen where

import Data.Binary
import Data.Int
import Data.List
import Data.Maybe
import qualified Data.Map as M
import qualified Data.ByteString.Lazy as B

import Foreign
import Foreign.Ptr
import Foreign.C.Types

import Text.Printf

import qualified JVM.Assembler as J
import JVM.Assembler hiding (Instruction)

import Harpy
import Harpy.X86Disassembler

import Mate.BasicBlocks

test_01, test_02, test_03 :: IO ()
test_01 = testCase "./tests/Fib.class" "fib"
test_02 = testCase "./tests/While.class" "f"
test_03 = testCase "./tests/While.class" "g"

testCase :: String -> B.ByteString -> IO ()
testCase cf method = do
      hmap <- parseMethod cf method
      printMapBB hmap
      case hmap of
        Nothing -> putStrLn "sorry, no code generation"
        Just hmap -> do
              let ebb = emitFromBB hmap
              (_, Right ((entry, bbstarts), disasm)) <- runCodeGen ebb () ()
              let int_entry = ((fromIntegral $ ptrToIntPtr entry) :: Int)
              printf "disasm:\n"
              mapM_ (putStrLn . showAtt) disasm
              printf "basicblocks addresses:\n"
              let b = map (\(x,y) -> (x,y + int_entry)) $ M.toList bbstarts
              mapM_ (\(x,y) -> printf "\tBasicBlock %2d starts at 0x%08x\n" x y) b

type EntryPoint = Ptr Word8
type EntryPointOffset = Int
type PatchInfo = (BlockID, EntryPointOffset)

type BBStarts = M.Map BlockID Int

type CompileInfo = (EntryPoint, BBStarts)

emitFromBB :: MapBB -> CodeGen e s (CompileInfo, [Instruction])
emitFromBB hmap =  do
        llmap <- sequence [newNamedLabel ("bb_" ++ show x) | (x,_) <- M.toList hmap]
        let lmap = zip (Prelude.fst $ unzip $ M.toList hmap) llmap
        ep <- getEntryPoint
        push ebp
        mov ebp esp
        bbstarts <- efBB (0,(hmap M.! 0)) M.empty lmap
        mov esp ebp
        pop ebp
        ret
        d <- disassemble
        return ((ep, bbstarts), d)
  where
  getLabel :: BlockID -> [(BlockID, Label)] -> Label
  getLabel _ [] = error "label not found!"
  getLabel i ((x,l):xs) = if i==x then l else getLabel i xs

  efBB :: (BlockID, BasicBlock) -> BBStarts -> [(BlockID, Label)] -> CodeGen e s (BBStarts)
  efBB (bid, bb) bbstarts lmap =
        if M.member bid bbstarts then
          return bbstarts
        else do
          bb_offset <- getCodeOffset
          let bbstarts' = M.insert bid bb_offset bbstarts
          defineLabel $ getLabel bid lmap
          mapM emit $ code bb
          case successor bb of
            Return -> return bbstarts'
            OneTarget t -> do
              efBB (t, hmap M.! t) bbstarts' lmap
            TwoTarget t1 t2 -> do
              bbstarts'' <- efBB (t1, hmap M.! t1) bbstarts' lmap
              efBB (t2, hmap M.! t2) bbstarts'' lmap
    -- TODO(bernhard): also use metainformation
    -- TODO(bernhard): implement `emit' as function which accepts a list of
    --                 instructions, so we can use patterns for optimizations
    where
    emit :: J.Instruction -> CodeGen e s ()
    emit (ICONST_1) = push (1 :: Word32)
    emit (ICONST_2) = push (2 :: Word32)
    emit (ILOAD_ x) = do
        push (Disp (cArgs_ x), ebp)
    emit (ISTORE_ x) = do
        pop eax
        mov (Disp (cArgs_ x), ebp) eax
    emit IADD = do pop ebx; pop eax; add eax ebx; push eax
    emit ISUB = do pop ebx; pop eax; sub eax ebx; push eax
    emit (IINC x imm) = do
        add (Disp (cArgs x), ebp) (s8_w32 imm)

    emit (IF_ICMP cond _) = do
        pop eax -- value2
        pop ebx -- value1
        cmp eax ebx -- intel syntax is swapped (TODO(bernhard): test that plz)
        let sid = case successor bb of TwoTarget _ t -> t
        let l = getLabel sid lmap
        case cond of
          C_EQ -> je  l; C_NE -> jne l
          C_LT -> jl  l; C_GT -> jg  l
          C_GE -> jge l; C_LE -> jle l

    emit (IF cond _) = do
        pop eax -- value1
        cmp eax (0 :: Word32) -- TODO(bernhard): test that plz
        let sid = case successor bb of TwoTarget _ t -> t
        let l = getLabel sid lmap
        case cond of
          C_EQ -> je  l; C_NE -> jne l
          C_LT -> jl  l; C_GT -> jg  l
          C_GE -> jge l; C_LE -> jle l

    emit (GOTO _ ) = do
        let sid = case successor bb of OneTarget t -> t
        jmp $ getLabel sid lmap

    emit IRETURN = do pop eax
    emit _ = do cmovbe eax eax -- dummy

  cArgs x = (8 + 4 * (fromIntegral x))
  cArgs_ x = (8 + 4 * case x of I0 -> 0; I1 -> 1; I2 -> 2; I3 -> 3)

  -- sign extension from w8 to w32 (over s8)
  --   unfortunately, hs-java is using Word8 everywhere (while
  --   it should be Int8 actually)
  s8_w32 :: Word8 -> Word32
  s8_w32 w8 = fromIntegral s8
    where s8 = (fromIntegral w8) :: Int8