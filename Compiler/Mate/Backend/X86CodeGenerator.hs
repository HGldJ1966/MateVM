{-# LANGUAGE GADTs #-}
module Compiler.Mate.Backend.X86CodeGenerator
  ( compileLinear
  , handleExceptionPatcher
  , call32Eax
  , push32RelEax
  , mov32RelEbxEax
  , compileStateInit
  ) where

import Prelude hiding (and)

import qualified Data.Set as S
import qualified Data.Map as M
import qualified Data.ByteString.Lazy as B
import Data.Int
import Data.Word
import Data.List hiding (and)
import Data.Binary.IEEE754

import Control.Applicative hiding ((<*>))
import Control.Monad

import Foreign hiding (xor)
import Foreign.C.Types

import JVM.Assembler hiding (Instruction)
import JVM.ClassFile hiding (methodName)
import Data.Binary
import Data.BinaryState

import Harpy
import Harpy.X86Disassembler

import qualified Compiler.Hoopl as H
import Compiler.Hoopl hiding (Label)
import Compiler.Mate.Frontend hiding (ptrSize, classf)
import Compiler.Mate.Backend.NativeSizes
import Compiler.Mate.Runtime.ClassHierarchy
import Compiler.Mate.Runtime.JavaObjects
import Compiler.Mate.Runtime.ClassPool
import Compiler.Mate.Runtime.MethodPool

import Compiler.Mate.Debug
import Compiler.Mate.Types
import Compiler.Mate.Utilities


foreign import ccall "&mallocObjectGC_stackstrace"
  mallocObjectAddr :: FunPtr (CPtrdiff -> CPtrdiff -> Int -> IO CPtrdiff)


compileStateInit :: Class Direct -> B.ByteString -> CompileState
compileStateInit cls m = CompileState
    { floatConsts = M.empty
    , traps = M.empty
    , classf = cls
    , methodName = m }

data CompileState = CompileState
  { floatConsts :: M.Map Label Float
  , traps :: TrapMap
  , classf :: Class Direct
  , methodName :: B.ByteString }

i32tow32 :: Int32 -> Word32
i32tow32 = fromIntegral

compileLinear :: M.Map Int32 H.Label -> [LinearIns HVar]
              -> CodeGen e CompileState ([Instruction], NativeWord, TrapMap)
compileLinear lbls linsn = do
  -- TODO(bernhard): don't jump around in the code... wtf dude!
  pushExceptionMap <- newNamedLabel "pushExceptionMap"
  stacksetup <- newNamedLabel "stacksetup"
  ep <- fromIntegral <$> ptrToIntPtr <$> getEntryPoint
  -- entry sequence
  push ebp
  jmp pushExceptionMap
  stacksetup @@ mov ebp esp
  let stackalloc = 0x300 :: Word32 -- TODO
  sub esp stackalloc
  bblabels <- forM (M.elems lbls) $ \h -> do
                l <- newNamedLabel ("Label: " ++ show h)
                return (h, l)
  let lmap :: M.Map H.Label Label
      lmap = M.fromList bblabels
  let retseq = do mov esp ebp; pop ebp; pop ebp; ret
  let compileIns (Fst (IRLabel h)) = defineLabel $ lmap M.! h
      compileIns (Mid ins) = girEmitOO ins
      compileIns (Lst ins) = case ins of
        -- TODO: signed values
        IRIfElse jcmp src1 src2 h1 h2 -> do
          let l1 = lmap M.! h1
          let l2 = lmap M.! h2
          case (src1, src2) of -- attention: swap args
            (HIReg s1, HIReg s2) -> do
              cmp s2 s1
            (SpillIReg d1, HIReg s2) -> do
              cmp s2 (d1, ebp)
            (SpillIReg d1, SpillIReg d2) -> do
              mov eax (d2, ebp)
              cmp eax (d1, ebp)
            (SpillRReg d1, SpillRReg d2) -> do
              mov eax (d2, ebp)
              cmp eax (d1, ebp)
            (HIConstant c, HIReg s1) -> do
              cmp s1 (i32tow32 c)
            (HIReg s1, HIConstant c) -> do
              mov eax (i32tow32 c)
              cmp eax s1
            (SpillIReg d1, HIConstant c) -> do
              mov eax (i32tow32 c)
              cmp eax (d1, ebp)
            (HIConstant c, SpillIReg s1) -> do
              cmp (s1, ebp) (i32tow32 c)
            x -> error $ "IRifelse: not impl. yet" ++ show x
          case jcmp of
            C_EQ -> je  l1; C_NE -> jne l1
            C_LT -> jl  l1; C_GT -> jg  l1
            C_GE -> jge l1; C_LE -> jle l1
          jmp l2
        IRJump h -> jmp (lmap M.! h)
        IRReturn Nothing -> retseq
        IRReturn (Just (HIReg r)) -> do mov eax r; retseq
        IRReturn (Just (HIConstant c)) -> do mov eax (i32tow32 c); retseq
        IRReturn (Just (SpillIReg d)) -> do
          let src = (d, ebp)
          mov eax src
          retseq
        IRReturn (Just (SpillRReg d)) -> do
          let src = (d, ebp)
          mov eax src
          retseq
        IRReturn (Just (HFReg r)) -> do
          movss xmm7 r
          retseq
        IRReturn x -> error $ "IRReturn: impl. me: " ++ show x
  forM_ linsn $ \ins -> do
    newNamedLabel ("ir: " ++ show ins) >>= defineLabel
    compileIns ins
  let exmap :: ExceptionMap Word32
      exmap = M.empty -- TODO
  mname <- methodName <$> getState
  let rsi = RuntimeStackInfo mname exmap
  sptr_rsi <- liftIO $
    (fromIntegral . ptrToIntPtr . castStablePtrToPtr) <$> newStablePtr rsi
  defineLabel pushExceptionMap
  push (sptr_rsi :: Word32)
  jmp stacksetup
  floatconstants <- M.toList <$> floatConsts <$> getState
  forM_ floatconstants $ \(l, f) -> do
    defineLabel l
    emit32 (floatToWord f)
  nop; nop; nop; nop -- just some NOPs to fix up the disasm
  d <- disassemble
  tm <- traps <$> getState
  return (d, ep, tm)

i322w32 :: Int32 -> Word32
i322w32 = fromIntegral

girEmitOO :: MateIR HVar O O -> CodeGen e CompileState ()
girEmitOO (IROp And dst' src1' src2') = do
    ge dst' src1' src2'
  where
    ge :: HVar -> HVar -> HVar -> CodeGen e CompileState ()
    ge (SpillIReg d) (HIConstant c1) (HIConstant c2) = do
      let c = i32tow32 (c1 .&. c2)
      mov (d, ebp) c
    ge (SpillIReg d) (SpillIReg s1) (HIConstant c2) = do
      let dst = (d, ebp)
      mov eax (i32tow32 c2)
      and eax (s1, ebp)
      mov dst eax
    ge x y z = error $ printf "emit: irop: and: %s = %s && %s" (show x) (show y) (show z)
girEmitOO (IROp Add dst' src1' src2') =
    ge dst' src1' src2'
  where
    ge :: HVar -> HVar -> HVar -> CodeGen e CompileState ()
    ge (HIReg dst) (HIReg src1) (HIReg src2)
        | dst == src1 = add src1 src2
        | dst == src2 = add src2 src1
        | otherwise = do mov dst src1; add dst src2
    ge dst (HIConstant c1) (HIConstant c2) = do
      let ci = i32tow32 (c1 + c2)
      case dst of
        HIReg d -> mov d ci
        SpillIReg d -> mov (d, ebp) ci
        SpillRReg d -> mov (d, ebp) ci
        x -> error $ "emit: op: add: dst + const + const: " ++ show x
    ge (HIReg dst) (HIConstant c1) (HIReg src2) = do
      mov dst src2
      when (c1 /= 0) $ add dst (fromIntegral c1 :: Word32)
    ge (HIReg dst) (HIConstant c1) (SpillIReg disp) = do
      let src2 = (disp, ebp)
      mov dst src2
      when (c1 /= 0) $ add dst (fromIntegral c1 :: Word32)
    ge dst@(HIReg _) src1@(HIConstant _) (SpillRReg dr) = do
      ge dst src1 (SpillIReg dr)
    ge (HIReg dst) (SpillIReg disp) (HIReg src2) = do
      let src1 = (disp, ebp)
      mov dst src2
      add dst src1
    ge (HIReg dst) (SpillIReg s1) (SpillIReg s2) = do
      let src1 = (s1, ebp)
      let src2 = (s2, ebp)
      mov dst src2
      add dst src1
    ge (HIReg dst) src1 c1@(HIConstant _) = ge (HIReg dst) c1 src1
    ge (HIReg dst) src1 spill@(SpillIReg _) = ge (HIReg dst) spill src1
    ge (HIReg dst) spill@(SpillIReg _) src2 = ge (HIReg dst) src2 spill
    ge (SpillIReg disp) (HIReg src1) (HIReg src2) = do
      let dst = (disp, ebp)
      mov dst src1
      add dst src2
    ge (SpillIReg disp) (HIReg src1) (SpillIReg s2) = do
      let dst = (disp, ebp)
      let src2 = (s2, ebp)
      mov eax src2
      add eax src1
      mov dst eax
    ge (SpillIReg disp) (SpillIReg s1) (SpillIReg s2) = do
      let src1 = (s1, ebp)
      let src2 = (s2, ebp)
      let dst = (disp, ebp)
      mov eax src2
      add eax src1
      mov dst eax
    ge dst@(SpillIReg _) src1@(SpillIReg _) src2@(HIReg _) = do
      ge dst src2 src1
    ge (SpillIReg disp) (HIReg src1) (HIConstant c) = do
      let dst = (disp, ebp)
      mov dst src1
      when (c /= 0) $ add dst (i32tow32 c)
    ge dst@(SpillIReg _) src1@(HIConstant _) src2@(HIReg _) = do
      ge dst src2 src1
    ge (SpillIReg disp) (SpillIReg src1) (HIConstant c) = do
      let dst = (disp, ebp)
      let s1 = (src1, ebp)
      if c == 0
        then do
          mov eax s1
          mov dst eax
        else do
          mov eax s1
          mov dst (i32tow32 c)
          add dst eax
    ge dst@(SpillIReg _) (SpillRReg src1) c@(HIConstant _) = do
      ge dst (SpillIReg src1) c
    ge dst@(SpillIReg _) c@(HIConstant _) src@(SpillIReg _) = do
      ge dst src c
    ge (SpillRReg disp) o1@(HIReg _) o2@(HIConstant _) = do
      ge (SpillIReg disp) o1 o2
    ge (SpillRReg disp) (SpillRReg src1) o2 = do
      ge (SpillIReg disp) (SpillIReg src1) o2

    ge (HFReg dst) (HFReg src1) (HFReg src2) = do
      movss dst src2
      addss dst src1
    ge (HFReg dst) (HFConstant c1) (HFConstant c2) = do
      let f = c1 + c2
      c <- newNamedLabel ("float constant: " ++ show f)
      s <- getState
      setState (s { floatConsts = M.insert c f (floatConsts s)})
      movss dst c
    ge (HFReg dst) (HFReg src) (HFConstant 0) =
      movss dst src
    ge (HFReg dst) (HFReg src) (HIConstant 0) =
      movss dst src
    ge (SpillFReg d) c1@(HFConstant _) c2@(HFConstant _) = do
      let dst = (d, ebp)
      ge (HFReg xmm7) c1 c2
      movss dst xmm7
    ge (SpillFReg d) (HFReg src) (HFConstant 0) = do
      let dst = (d, ebp)
      movss dst src
    ge (HFReg dst) (SpillFReg d) (HFConstant 0) = do
      let src = (d, ebp)
      movss dst src
    ge p1 p2 p3 = error $ "girEmit (add): " ++ show p1 ++ ", " ++ show p2 ++ ", " ++ show p3
girEmitOO (IROp Sub dst' src1' src2') = do
    ge dst' src1' src2'
  where
    ge :: HVar -> HVar -> HVar -> CodeGen e s ()
    ge (HIReg dst) (HIReg src1) (HIReg src2) = do
      mov dst src2; sub dst src1
    ge (HIReg dst) (HIConstant i32) (HIReg src2) = do
      mov dst src2; sub dst (i322w32 i32)
    ge (HIReg dst) (HIConstant i32) (SpillIReg s2) = do
      let src2 = (s2, ebp)
      mov dst src2; sub dst (i322w32 i32)
    ge (HIReg dst) (HIReg src1) (SpillIReg s2) = do
      let src2 = (s2, ebp)
      mov dst src2
      sub dst src1
    ge (HIReg dst) (SpillIReg s1) (SpillIReg s2) = do
      let src1 = (s1, ebp)
      let src2 = (s2, ebp)
      mov dst src2
      sub dst src1
    ge (HIReg dst) (SpillIReg s1) (HIReg src2) = do
      let src1 = (s1, ebp)
      mov dst src2
      sub dst src1
    ge (SpillIReg d) (HIConstant c) (HIReg src2) = do
      let dst = (d, ebp)
      mov dst src2
      sub dst (i32tow32 c)
    ge (SpillIReg d) (HIConstant c) (SpillIReg s2) = do
      let dst = (d, ebp)
      let src2 = (s2, ebp)
      mov eax src2
      sub eax (i32tow32 c)
      mov dst eax
    ge (SpillIReg d) (HIReg src1) (HIReg src2) = do
      let dst = (d, ebp)
      mov dst src2
      sub dst src1
    ge (SpillIReg d) (SpillIReg s1) (HIReg src2) = do
      let dst = (d, ebp)
      let src1 = (s1, ebp)
      mov eax src2
      sub eax src1
      mov dst eax
    ge (SpillIReg d) (SpillIReg s1) (SpillIReg s2) = do
      let dst = (d, ebp)
      let src1 = (s1, ebp)
      let src2 = (s2, ebp)
      mov eax src2
      sub eax src1
      mov dst eax
    ge _ _ _ = error $ "sub: not impl.: " ++ show dst' ++ ", "
                     ++ show src1' ++ ", " ++ show src2'
girEmitOO (IROp Mul dst' src1' src2') = do
    -- edx is killed by `mul' instruction
    when isNotEdx $ push edx
    gm dst' src1' src2'
    when isNotEdx $ pop edx
  where
    isNotEdx = case dst' of
                HIReg dst -> dst /= edx
                _ -> True
    gm (HIReg dst) (HIReg src1) (HIReg src2) = do
      mov eax src1
      mul src2
      mov dst eax
    gm (HIReg dst) (SpillIReg sd1) (HIReg src2) = do
      mov eax src2
      mul (sd1, ebp)
      mov dst eax
    gm (HIReg dst) (HIReg src1) (HIConstant c2) = do
      mov eax (i32tow32 c2)
      mul src1
      mov dst eax
    gm (SpillIReg dst) (HIReg src1) (HIReg src2) = do
      mov eax src1
      mul src2
      mov (dst, ebp) eax
    gm (SpillIReg dst) (HIConstant c1) (HIReg src2) = do
      mov eax (i32tow32 c1)
      mul src2
      mov (dst, ebp) eax
    gm dst@(SpillIReg _) src1@(HIReg _) src2@(HIConstant _) = do
      gm dst src2 src1
    gm (SpillIReg dst) (HIConstant c1) (SpillIReg s2) = do
      let src2 = (s2, ebp)
      mov eax (i32tow32 c1)
      mul src2
      mov (dst, ebp) eax
    gm (SpillIReg dst) (SpillIReg s1) (SpillIReg s2) = do
      let src1 = (s1, ebp)
      let src2 = (s2, ebp)
      mov eax src1
      mul src2
      mov (dst, ebp) eax
    gm (SpillIReg dst) (SpillIReg s1) (HIConstant c2) = do
      let src1 = (s1, ebp)
      mov eax (i32tow32 c2)
      mul src1
      mov (dst, ebp) eax
    gm d s1 s2 = error $ printf "emit: impl. mul: %s = %s * %s\n" (show d) (show s1) (show s2)
girEmitOO (IRInvoke (RTPool cpidx) haveReturn ct) = do
  let static = girStatic cpidx haveReturn ct
  let virtual = girVirtual cpidx haveReturn ct
  case ct of
    CallStatic -> static
    CallSpecial -> static
    CallVirtual -> virtual
    CallInterface -> virtual
girEmitOO (IRLoad (RTPool x) (HIConstant 0) dst) = do
  cls <- classf <$> getState
  case constsPool cls M.! x of
    (CString s) -> do -- load str (ldc)
      sref <- liftIO $ getUniqueStringAddr s
      case dst of
        HIReg d -> mov d sref
        SpillIReg d -> mov (d, ebp) sref
        SpillRReg d -> mov (d, ebp) sref
        y -> error $ "irload: emit: cstring: " ++ show y
    (CInteger i) -> do -- load integer (ldc)
      case dst of
        HIReg d -> mov d i
        SpillIReg d -> mov (d, ebp) i
        y -> error $ "irload: emit: cinteger: " ++ show y
    (CField rc fnt) -> do -- getstatic
      let sfi = StaticField $ StaticFieldInfo rc (ntName fnt)
      trapaddr <- getCurrentOffset
      mov eax (Addr 0)
      case dst of
        HIReg d -> mov d eax
        SpillIReg d -> mov (d, ebp) eax
        SpillRReg d -> mov (d, ebp) eax
        y -> error $ "irload: emit: cfield: " ++ show y
      s <- getState
      setState (s { traps = M.insert trapaddr sfi (traps s) })
    (CClass objname) -> do -- `new' object
      saveRegs
      trapaddr <- emitSigIllTrap 5
      callMalloc
      restoreRegs
      -- 0x13371337 is just a placeholder; will be replaced with mtable ptr
      mov (Disp 0, eax) (0x13371337 :: Word32)
      mov (Disp 4, eax) (0 :: Word32)
      case dst of
        HIReg d -> mov d eax
        SpillIReg d -> mov (d, ebp) eax
        SpillRReg d -> mov (d, ebp) eax
        y -> error $ "irload: emit: cclass: " ++ show y
      let patcher wbr = do
            objsize <- liftIO $ getObjectSize objname
            push32 objsize
            callMalloc
            restoreRegs
            mtable <- liftIO $ getMethodTable objname
            mov (Disp 0, eax) mtable
            --mov (Disp 4, eax) (0x1337babe :: Word32)
            mov (Disp 4, eax) (0::Word32)
            case dst of
              HIReg d -> mov d eax
              SpillIReg d -> mov (d, ebp) eax
              SpillRReg d -> mov (d, ebp) eax
              y -> error $ "irload: emit: cclass2: " ++ show y
            return wbr
      s <- getState
      setState (s { traps = M.insert trapaddr (NewObject patcher) (traps s) })
    e -> error $ "emit: irload: missing impl.: " ++ show e
girEmitOO (IRLoad (RTPool x) src dst) = do
  cls <- classf <$> getState
  case constsPool cls M.! x of
    (CField rc fnt) -> do -- getfield
      push ebx
      case src of
        HIReg s -> mov eax s
        SpillIReg sd -> mov eax (sd, ebp)
        SpillRReg sd -> mov eax (sd, ebp)
        y -> error $ "irload: emit: cfield: src: " ++ show y
      trapaddr <- emitSigIllTrap 7
      let patcher wbr = do
            offset <- liftIO $ fromIntegral <$> getFieldOffset rc (ntName fnt)
            mov ebx (Disp offset, eax)
            return wbr
      case dst of
        HIReg d -> mov d ebx
        SpillIReg dd -> mov (dd, ebp) ebx
        SpillRReg dd -> mov (dd, ebp) ebx
        y -> error $ "irload: emit: cfield: dst: " ++ show y
      pop ebx
      let ofp = ObjectField patcher
      s <- getState
      setState (s { traps = M.insert trapaddr ofp (traps s) })
    y -> error $ "emit: irload: missing impl.: getfield or something: " ++ show y
girEmitOO (IRLoad (RTArray ta objType arrlen) (HIConstant 0) dst) = do
  let tsize = case decodeS (0 :: Integer) (B.pack [ta]) of
                T_INT -> 4
                T_CHAR -> 4
                _ -> error "newarray: type not implemented yet"
  let len = arrlen * tsize
  saveRegs
  push (len + (3 * ptrSize))
  callMalloc
  restoreRegs
  case objType of
    PrimitiveType -> mov (Disp 0, eax) (0x1228babe :: Word32)
    ReferenceType -> mov (Disp 0, eax) (0x1227babe :: Word32)
  mov (Disp 4, eax) (0x1337babe :: Word32) -- gcinfo
  mov (Disp 8, eax) arrlen -- store length at offset 0
  -- mov (Disp 12, eax) (0x1227bab1 :: Word32) -- TODO: delete me? (stackmaaaaaaaaaark)
  case dst of
    HIReg d -> mov d eax
    SpillIReg d -> mov (d, ebp) eax
    SpillRReg d -> mov (d, ebp) eax
    x -> error $ "irload: emit: newarray: " ++ show x
girEmitOO (IRLoad RTNone (HIReg src) (HIReg dst)) = do -- arraylength
  mov dst (Disp 8, src)
girEmitOO (IRLoad RTNone (SpillIReg d) (HIReg dst)) = do -- arraylength
  mov eax (d, ebp)
  mov dst (Disp 8, eax)
girEmitOO (IRLoad RTNone (HIReg src) (SpillIReg d)) = do -- arraylength
  let dst = (d, ebp)
  mov eax (Disp 8, src)
  mov dst eax
girEmitOO (IRLoad RTNone (SpillRReg sd) (SpillIReg dd)) = do -- arraylength
  let dst = (dd, ebp)
  let src = (sd, ebp)
  mov eax src
  mov eax (Disp 8, eax)
  mov dst eax
girEmitOO (IRLoad (RTIndex (HIConstant i) typ) (SpillIReg srcd) (SpillIReg dstd)) = do
  mov eax (srcd, ebp)
  -- TODO: ptrSize ...
  mov eax (Disp (fromIntegral . (+0xc) $ i * (typeSize typ)), eax)
  mov (dstd, ebp) eax
girEmitOO (IRLoad (RTIndex (HIConstant i) typ) (SpillIReg srcd) (SpillRReg dstd)) = do
  mov eax (srcd, ebp)
  -- TODO: ptrSize ...
  mov eax (Disp (fromIntegral . (+0xc) $ i * (typeSize typ)), eax)
  mov (dstd, ebp) eax
girEmitOO (IRLoad (RTIndex (HIConstant i) typ) (SpillIReg srcd) (HIReg dst)) = do
  mov eax (srcd, ebp)
  -- TODO: ptrSize ...
  mov eax (Disp (fromIntegral . (+0xc) $ i * (typeSize typ)), eax)
  mov dst eax
girEmitOO (IRLoad (RTIndex idx typ) src dst) = do
  let isNotEdx = case dst of
                  HIReg dst' -> dst' /= edx
                  _ -> True
      isNotEbx = case dst of
                  HIReg dst' -> dst' /= ebx
                  _ -> True
  when isNotEdx $ push edx
  when isNotEbx $ push ebx
  case idx of
    HIConstant i -> mov eax (((i32tow32 i) * (typeSize typ)) + 0xc)
    HIReg i -> do
      mov eax i
      mov ebx (typeSize typ :: Word32)
      mul ebx
      add eax (0xc :: Word32)
    SpillIReg d -> do
      mov eax (d, ebp)
      mov ebx (typeSize typ :: Word32)
      mul ebx
      add eax (0xc :: Word32)
    y -> error $ "girEmitOO: irload: rtindex: idx1: " ++ show y
  case src of
    HIReg s -> do add eax s
    SpillIReg d -> do add eax (d, ebp)
    SpillRReg d -> do add eax (d, ebp)
    y -> error $ "girEmitOO: irload: rtindex: src: " ++ show y
  case dst of
    HIReg d -> do mov d (Disp 0, eax)
    SpillIReg d -> do
      mov ebx (Disp 0, eax)
      mov (d, ebp) ebx
    SpillRReg d -> do
      mov ebx (Disp 0, eax)
      mov (d, ebp) ebx
    y -> error $ "girEmitOO: irload: rtindex: dst: " ++ show y
  when isNotEbx $ pop ebx
  when isNotEdx $ pop edx

girEmitOO (IRStore (RTPool x) obj src) = do
  cls <- classf <$> getState
  case constsPool cls M.! x of
    (CField rc fnt) -> do
      if obj == HIConstant 0
        then do -- putstatic
          let sfi = StaticField $ StaticFieldInfo rc (ntName fnt)
          case src of
            HIReg s1 -> mov eax s1
            SpillIReg d -> mov eax (d, ebp)
            HIConstant i -> mov eax (i32tow32 i)
            _ -> error "girEmitOO: IRStore: static field"
          trapaddr <- getCurrentOffset
          mov (Addr 0) eax
          s <- getState
          setState (s { traps = M.insert trapaddr sfi (traps s) })
        else do -- putfield
          push ebx
          case obj of
            HIReg dst -> mov eax dst
            SpillIReg d -> mov eax (d, ebp)
            SpillRReg d -> mov eax (d, ebp)
            x' -> error $ "girEmitOO: IRStore: putfield1: " ++ show x'
          case src of
            HIReg s1 -> mov ebx s1
            SpillIReg d -> mov ebx (d, ebp)
            SpillRReg d -> mov ebx (d, ebp)
            HIConstant c -> mov ebx (i32tow32 c)
            x' -> error $ "girEmitOO: IRStore: putfield2: " ++ show x'
          -- like: 4581fc6b  89 98 30 7b 00 00 movl   %ebx,31536(%eax)
          trapaddr <- emitSigIllTrap 6
          let patcher wbr = do
                let (cname, fname) = buildFieldOffset cls x
                offset <- liftIO $ fromIntegral <$> getFieldOffset cname fname
                -- mov32RelEbxEax (Disp offset) -- set field
                mov (Disp offset, eax) ebx
                return wbr
          pop ebx
          s <- getState
          setState (s { traps = M.insert trapaddr (ObjectField patcher) (traps s)})
    e -> error $ "emit: irstore: missing impl.: " ++ show e
girEmitOO (IRStore (RTIndex idx typ) dst src) = do
  let isNotEdx = case dst of
                  HIReg dst' -> dst' /= edx
                  _ -> True
      isNotEbx = case dst of
                  HIReg dst' -> dst' /= ebx
                  _ -> True
  when isNotEdx $ push edx
  when isNotEbx $ push ebx
  case idx of
    HIConstant _ -> mov eax (0 :: Word32)
    HIReg i -> do
      when (i == edx || i == ebx) $ error $ "irstore: rtindex: register not avail.1"
      mov eax i
      mov ebx (typeSize typ :: Word32)
      mul ebx
      add eax (0xc :: Word32)
    SpillIReg d -> do
      mov eax (d, ebp)
      mov ebx (typeSize typ :: Word32)
      mul ebx
      add eax (0xc :: Word32)
    y -> error $ "girEmitOO: irstore: rtindex: idx1: " ++ show y
  case dst of
    HIReg d -> add eax d
    SpillIReg d -> add eax (d, ebp)
    SpillRReg d -> add eax (d, ebp)
    y -> error $ "girEmitOO: irstore: rtindex: dst: " ++ show y
  -- store array elem
  case src of
    HIConstant i -> mov ebx (i32tow32 i)
    HIReg s -> do
      when (s == edx || s == ebx) $ error $ "irstore: rtindex: register not avail.2"
      mov ebx s
    SpillIReg sd -> mov ebx (sd, ebp)
    SpillRReg sd -> mov ebx (sd, ebp)
    y -> error $ "girEmitOO: irstore: rtindex: src: " ++ show y
  case idx of
    HIConstant i -> mov (Disp ((+0xc) . (*(typeSize typ)) $ i32tow32 i), eax) ebx
    HIReg _ -> mov (Disp 0, eax) ebx
    SpillIReg _ -> mov (Disp 0, eax) ebx
    y -> error $ "girEmitOO: irstore: rtindex: idx2: " ++ show y
  when isNotEbx $ pop ebx
  when isNotEdx $ pop edx
girEmitOO ins@(IRStore _ _ _) = do
  error $ "irstore: emit: " ++ show ins
girEmitOO (IRPush _ (HIReg x)) = push x
girEmitOO (IRPush _ (HIConstant x)) = push (i32tow32 x)
girEmitOO (IRPush _ (SpillIReg d)) = push (d, ebp)
girEmitOO (IRPush _ (SpillRReg d)) = push (d, ebp)
girEmitOO (IRPrep SaveRegs regs) = do
  forM_ (S.toList regs) $ \ x ->
    case x of
      HIReg r -> push r
      f -> error $ "emit: irprep: " ++ show f
girEmitOO (IRPrep RestoreRegs regs) = do
  forM_ (reverse (S.toList regs)) $ \(HIReg x) -> pop x
girEmitOO (IRMisc1 jins _) = do
  case jins of
    CHECKCAST _ -> do
      nop -- TODO ..
    x -> error $ "emit: misc1: " ++ show x
girEmitOO (IRMisc2 jins dst src) = do
  case jins of
    INSTANCEOF cpidx -> do
      cls <- classf <$> getState
      let movres :: Word32 -> CodeGen e s ()
          movres r = do
            case dst of
              HIReg i -> mov i r
              SpillIReg d -> mov (d, ebp) r
              y -> error $ "girEmitOO: misc2: instanceof: " ++ show y
      case src of
        HIReg s -> mov eax s
        SpillIReg d -> mov eax (d, ebp)
        SpillRReg d -> mov eax (d, ebp)
        HIConstant i -> mov eax (i32tow32 i)
        x -> error $ "emit: misc2: instanceof: src: " ++ show x
      -- place something like `mov edx $mtable_of_objref' instead
      trapaddr <- emitSigIllTrap 4
      movres 0
      let patcher wbr = do
            emitSigIllTrap 4
            let classname = buildClassID cls cpidx
            check <- liftIO $ isInstanceOf (fromIntegral $ wbEax wbr) classname
            if check
              then movres 1
              else movres 0
            return $ wbr {wbEip = wbEip wbr + 4}
      s <- getState
      setState (s { traps = M.insert trapaddr (InstanceOf patcher) (traps s) })
    x -> error $ "emit: misc2: " ++ show x
girEmitOO x = error $ "girEmitOO: insn not implemented: " ++ show x

girStatic :: Word16 -> Maybe HVar -> CallType -> CodeGen e CompileState ()
girStatic cpidx haveReturn ct = do
  cls <- classf <$> getState
  let hasThis = ct == CallSpecial
  let l = buildMethodID cls cpidx
  newNamedLabel (show l) >>= defineLabel
  -- like: call $0x01234567
  calladdr <- emitSigIllTrap 5
  let patcher wbr = do
        (entryAddr, _) <- liftIO $ getMethodEntry l
        call (fromIntegral (entryAddr - (wbEip wbr + 5)) :: NativeWord)
        return wbr
  -- discard arguments on stack
  let argcnt = ((if hasThis then 1 else 0)
               + methodGetArgsCount (methodNameTypeByIdx cls cpidx)
               ) * ptrSize
  when (argcnt > 0) (add esp argcnt)

  case haveReturn of
    Just (HIReg dst) -> mov dst eax
    Just y -> error $ "girStatic: haveReturn: " ++ show y
    Nothing -> return ()
  s <- getState
  setState (s { traps = M.insert calladdr (StaticMethod patcher) (traps s) })

girVirtual :: Word16 -> Maybe HVar -> CallType -> CodeGen e CompileState ()
girVirtual cpidx haveReturn ct = do
  let isInterface = ct == CallInterface
  cls <- classf <$> getState
  let mi@(MethodInfo methodname objname msig@(MethodSignature _ _)) =
          buildMethodID cls cpidx
  newNamedLabel (show mi) >>= defineLabel
  -- get method offset for call @ runtime
  let offset =
        if isInterface
          then getInterfaceMethodOffset objname methodname (encode msig)
          else getMethodOffset objname (methodname `B.append` encode msig)
  -- objref lives somewhere on the argument stack
  mov ebx (Disp 0, esp)
  when isInterface $
    mov ebx (Disp 0, ebx) -- get method-table-ptr, keep it in ebx
  -- get method-table-ptr (or interface-table-ptr)
  mov eax (Disp 0, ebx)
  -- make actual (indirect) call
  calladdr <- getCurrentOffset
  -- will be patched to this: call (Disp 0xXXXXXXXX, eax)
  emitSigIllTrap 6

  -- discard arguments on stack (`+1' for "this")
  let argcnt = ptrSize * (1 + methodGetArgsCount (methodNameTypeByIdx cls cpidx))
  when (argcnt > 0) (add esp argcnt)

  case haveReturn of
    Just (HIReg dst) -> mov dst eax
    Nothing -> return ()
    Just y -> error $ "girVirtual: haveReturn: " ++ show y
  -- note, that "mi" has the wrong class reference here.
  -- we figure that out at run-time, in the methodpool,
  -- depending on the method-table-ptr
  s <- getState
  setState (s { traps = M.insert calladdr
                        (VirtualCall isInterface mi offset)
                        (traps s) })

saveRegs :: CodeGen e s ()
saveRegs = do
  push ecx; push edx
  push ebx; push esi
  push edi

restoreRegs :: CodeGen e s ()
restoreRegs = do
  pop edi
  pop esi; pop ebx
  pop edx; pop ecx

-- helper
callMalloc :: CodeGen e s ()
callMalloc = do
  push ebp
  push esp
  call mallocObjectAddr
  add esp ((3 * ptrSize) :: Word32)


-- harpy tries to cut immediates (or displacements), if they fit in 8bit.
-- however, this is bad for patching so we want to put always 32bit.

-- push imm32
push32 :: Word32 -> CodeGen e s ()
push32 imm32 = emit8 0x68 >> emit32 imm32

-- call disp32(%eax)
call32Eax :: Disp -> CodeGen e s ()
call32Eax (Disp disp32) = emit8 0xff >> emit8 0x90 >> emit32 disp32

-- push disp32(%eax)
push32RelEax :: Disp -> CodeGen e s ()
push32RelEax (Disp disp32) = emit8 0xff >> emit8 0xb0 >> emit32 disp32

{-
-- mov disp32(%eax), %ebx
mov32EbxRelEax :: Disp -> CodeGen e s ()
mov32EbxRelEax (Disp d32) = emit8 0x67 >> emit8 0x8b >> emit8 0x98
                            >> emit32 d32
-}

-- mov %ebx, disp32(%eax)
mov32RelEbxEax :: Disp -> CodeGen e s ()
mov32RelEbxEax (Disp disp32) = emit8 0x89 >> emit8 0x98 >> emit32 disp32

emitSigIllTrap :: Int -> CodeGen e s NativeWord
emitSigIllTrap traplen = do
  when (traplen < 2) (error "emitSigIllTrap: trap len too short")
  trapaddr <- getCurrentOffset
  -- 0xffff causes SIGILL
  emit8 (0xff :: Word8); emit8 (0xff :: Word8)
  -- fill rest up with NOPs
  sequence_ [nop | _ <- [1 .. (traplen - 2)]]
  return trapaddr
-- /helper

getCurrentOffset :: CodeGen e s Word32
getCurrentOffset = do
  ep <- (fromIntegral . ptrToIntPtr) <$> getEntryPoint
  offset <- fromIntegral <$> getCodeOffset
  return $ ep + offset

typeSize :: Num a => VarType -> a
typeSize JChar = 4
typeSize JInt = 4
typeSize JRef = 4
typeSize x = error $ "typeSize: " ++ show x

handleExceptionPatcher :: ExceptionHandler
handleExceptionPatcher wbr = do
  let weip = fromIntegral $ wbEip wbr
  printfEx $ printf "eip of throw: 0x%08x %d\n" weip weip
  handleException weip (wbEbp wbr) (wbEsp wbr)
    where
      weax = fromIntegral (wbEax wbr) :: Word32
      unwindStack :: CPtrdiff -> IO WriteBackRegs
      unwindStack rebp = do
        let nesp = rebp + 8
        -- get ebp of caller
        nebp <- peek (intPtrToPtr . fromIntegral $ (nesp - 4))
        printfEx $ printf "nebp: 0x%08x\n" (fromIntegral nebp :: Word32)
        printfEx $ printf "nesp: 0x%08x\n" (fromIntegral nesp :: Word32)
        -- get return addr
        neip <- peek . intPtrToPtr . fromIntegral $ nesp
        printfEx $ printf "neip: 0x%08x\n" (neip :: Word32)
        handleException neip nebp nesp
      handleException :: Word32 -> CPtrdiff -> CPtrdiff -> IO WriteBackRegs
      handleException weip rebp resp = do
        -- get full exception map from stack
        stblptr <- peek (intPtrToPtr . fromIntegral $ rebp) :: IO Word32
        let sptr = castPtrToStablePtr $ intPtrToPtr $ fromIntegral stblptr
        stackinfo <- deRefStablePtr sptr :: IO RuntimeStackInfo
        let exmap = rsiExceptionMap stackinfo
        printfEx $ printf "methodname: %s\n" (toString $ rsiMethodname stackinfo)
        printfEx $ printf "size: %d\n" (M.size exmap)
        printfEx $ printf "exmap: %s\n" (show $ M.toList exmap)

        -- find the handler in a region. if there isn't a proper
        -- handler, go to the caller method (i.e. unwind the stack)
        let searchRegion :: [(Word32, Word32)] -> IO WriteBackRegs
            searchRegion [] = do
              printfEx "unwind stack now. good luck(x)\n\n"
              unwindStack rebp
            searchRegion (r:rs) = do
              -- let's see if there's a proper handler in this range
              res <- findHandler r exmap
              case res of
                Just x -> return x
                Nothing -> searchRegion rs
        -- is the EIP somewhere in the range?
        let matchingIPs = filter (\(x, y) -> weip >= x && weip <= y)
        -- if `fst' is EQ, sort via `snd', but reverse
        let ipSorter (x1, y1) (x2, y2) =
              case x1 `compare` x2 of
                EQ -> case y1 `compare` y2 of
                        LT -> GT; GT -> LT; EQ -> EQ
                x -> x
        -- due to reversing the list, we get the innermost range at
        -- nested try/catch statements
        searchRegion . reverse . sortBy ipSorter . matchingIPs . M.keys $ exmap
          where
            findHandler :: (Word32, Word32) -> ExceptionMap Word32 -> IO (Maybe WriteBackRegs)
            findHandler key exmap = do
              printfEx $ printf "key is: %s\n" (show key)
              let handlerObjs = exmap M.! key
              printfEx $ printf "handlerObjs: %s\n" (show handlerObjs)

              let myMapM :: (a -> IO (Maybe Word32)) -> [a] -> IO (Maybe WriteBackRegs)
                  myMapM _ [] = return Nothing
                  myMapM g (x:xs) = do
                    r <- g x
                    case r of
                      Just y -> return $ Just WriteBackRegs
                                  { wbEip = fromIntegral y
                                  , wbEbp = rebp
                                  , wbEsp = resp
                                  , wbEax = fromIntegral weax }
                      Nothing -> myMapM g xs
              let f :: (B.ByteString, Word32) -> IO (Maybe Word32)
                  f (x, y) = do
                        printfEx $ printf "looking at @ %s\n" (show x)
                        -- on B.empty, it's the "generic handler"
                        -- (e.g. finally)
                        x' <- if x == B.empty then return True else isInstanceOf weax x
                        return $ if x' then Just y else Nothing
              -- by using myMapM, we avoid to look at *every* handler,
              -- but abort on the first match (yes, it's rather
              -- ugly :/ better solutions are welcome)
              myMapM f handlerObjs
