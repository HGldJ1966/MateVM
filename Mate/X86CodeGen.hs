{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ForeignFunctionInterface #-}
module Mate.X86CodeGen where

import Data.Binary
import Data.BinaryState
import Data.Int
import Data.Maybe
import qualified Data.Map as M
import qualified Data.Set as S
import qualified Data.ByteString.Lazy as B
import Control.Monad

import Foreign hiding (xor)
import Foreign.C.Types

import Text.Printf

import qualified JVM.Assembler as J
import JVM.Assembler hiding (Instruction)
import JVM.ClassFile

import Harpy
import Harpy.X86Disassembler

import Mate.BasicBlocks
import Mate.Types
import Mate.Utilities
import Mate.ClassPool
import Mate.Strings


foreign import ccall "dynamic"
   code_int :: FunPtr (CInt -> CInt -> IO CInt) -> (CInt -> CInt -> IO CInt)

foreign import ccall "getaddr"
  getaddr :: CUInt

foreign import ccall "getMallocAddr"
  getMallocAddr :: CUInt

foreign import ccall "callertrap"
  callertrap :: IO ()

foreign import ccall "register_signal"
  register_signal :: IO ()

test_01, test_02, test_03 :: IO ()
test_01 = do
  register_signal
  (entry, end) <- testCase "./tests/Fib" "fib"
  let entryFuncPtr = ((castPtrToFunPtr entry) :: FunPtr (CInt -> CInt -> IO CInt))

  mapM_ (\x -> do
    result <- code_int entryFuncPtr x 0
    let iresult :: Int; iresult = fromIntegral result
    let kk :: String; kk = if iresult == (fib x) then "OK" else "FAIL (" ++ (show (fib x)) ++ ")"
    printf "result of fib(%2d): %3d\t\t%s\n" (fromIntegral x :: Int) iresult kk
    ) $ ([0..10] :: [CInt])
  printf "patched disasm:\n"
  Right newdisasm <- disassembleBlock entry end
  mapM_ (putStrLn . showAtt) newdisasm
  where
    fib :: CInt -> Int
    fib n
      | n <= 1 = 1
      | otherwise = (fib (n - 1)) + (fib (n - 2))


test_02 = do
  (entry,_) <- testCase "./tests/While" "f"
  let entryFuncPtr = ((castPtrToFunPtr entry) :: FunPtr (CInt -> CInt -> IO CInt))
  result <- code_int entryFuncPtr 5 4
  let iresult :: Int; iresult = fromIntegral result
  let kk :: String; kk = if iresult == 15 then "OK" else "FAIL"
  printf "result of f(5,4): %3d\t\t%s\n" iresult kk

  result2 <- code_int entryFuncPtr 4 3
  let iresult2 :: Int; iresult2 = fromIntegral result2
  let kk2 :: String; kk2 = if iresult2 == 10 then "OK" else "FAIL"
  printf "result of f(4,3): %3d\t\t%s\n" iresult2 kk2


test_03 = do
  (entry,_) <- testCase "./tests/While" "g"
  let entryFuncPtr = ((castPtrToFunPtr entry) :: FunPtr (CInt -> CInt -> IO CInt))
  result <- code_int entryFuncPtr 5 4
  let iresult :: Int; iresult = fromIntegral result
  let kk :: String; kk = if iresult == 15 then "OK" else "FAIL"
  printf "result of g(5,4): %3d\t\t%s\n" iresult kk

  result2 <- code_int entryFuncPtr 4 3
  let iresult2 :: Int; iresult2 = fromIntegral result2
  let kk2 :: String; kk2 = if iresult2 == 10 then "OK" else "FAIL"
  printf "result of g(4,3): %3d\t\t%s\n" iresult2 kk2


testCase :: B.ByteString -> B.ByteString -> IO (Ptr Word8, Int)
testCase cf method = do
      cls <- getClassFile cf
      hmap <- parseMethod cls method
      printMapBB hmap
      case hmap of
        Nothing -> error "sorry, no code generation"
        Just hmap' -> do
              let ebb = emitFromBB method cls hmap'
              (_, Right ((entry, bbstarts, end, _), disasm)) <- runCodeGen ebb () ()
              let int_entry = ((fromIntegral $ ptrToIntPtr entry) :: Int)
              printf "disasm:\n"
              mapM_ (putStrLn . showAtt) disasm
              printf "basicblocks addresses:\n"
              let b = map (\(x,y) -> (x,y + int_entry)) $ M.toList bbstarts
              mapM_ (\(x,y) -> printf "\tBasicBlock %2d starts at 0x%08x\n" x y) b
              return (entry, end)

type EntryPoint = Ptr Word8
type EntryPointOffset = Int
type PatchInfo = (BlockID, EntryPointOffset)

type BBStarts = M.Map BlockID Int

type CompileInfo = (EntryPoint, BBStarts, Int, TMap)


emitFromBB :: B.ByteString -> Class Resolved -> MapBB -> CodeGen e s (CompileInfo, [Instruction])
emitFromBB method cls hmap =  do
        llmap <- sequence [newNamedLabel ("bb_" ++ show x) | (x,_) <- M.toList hmap]
        let lmap = zip (Prelude.fst $ unzip $ M.toList hmap) llmap
        ep <- getEntryPoint
        push ebp
        mov ebp esp
        -- TODO(bernhard): determine a reasonable value.
        --                 e.g. (locals used) * 4
        sub esp (0x60 :: Word32)

        (calls, bbstarts) <- efBB (0,(hmap M.! 0)) M.empty M.empty lmap
        d <- disassemble
        end <- getCodeOffset
        return ((ep, bbstarts, end, calls), d)
  where
  getLabel :: BlockID -> [(BlockID, Label)] -> Label
  getLabel _ [] = error "label not found!"
  getLabel i ((x,l):xs) = if i==x then l else getLabel i xs

  efBB :: (BlockID, BasicBlock) -> TMap -> BBStarts -> [(BlockID, Label)] -> CodeGen e s (TMap, BBStarts)
  efBB (bid, bb) calls bbstarts lmap =
        if M.member bid bbstarts then
          return (calls, bbstarts)
        else do
          bb_offset <- getCodeOffset
          let bbstarts' = M.insert bid bb_offset bbstarts
          defineLabel $ getLabel bid lmap
          cs <- mapM emit' $ code bb
          let calls' = calls `M.union` (M.fromList $ catMaybes cs)
          case successor bb of
            Return -> return (calls', bbstarts')
            FallThrough t -> do
              efBB (t, hmap M.! t) calls' bbstarts' lmap
            OneTarget t -> do
              efBB (t, hmap M.! t) calls' bbstarts' lmap
            TwoTarget t1 t2 -> do
              (calls'', bbstarts'') <- efBB (t1, hmap M.! t1) calls' bbstarts' lmap
              efBB (t2, hmap M.! t2) calls'' bbstarts'' lmap
    -- TODO(bernhard): also use metainformation
    -- TODO(bernhard): implement `emit' as function which accepts a list of
    --                 instructions, so we can use patterns for optimizations
    where
    getCurrentOffset :: CodeGen e s (Word32)
    getCurrentOffset = do
      ep <- getEntryPoint
      let w32_ep = (fromIntegral $ ptrToIntPtr ep) :: Word32
      offset <- getCodeOffset
      return $ w32_ep + (fromIntegral offset)

    emitInvoke :: Word16 -> Bool -> CodeGen e s (Maybe (Word32, TrapInfo))
    emitInvoke cpidx hasThis = do
        let l = buildMethodID cls cpidx
        calladdr <- getCurrentOffset
        newNamedLabel (show l) >>= defineLabel
        -- causes SIGILL. in the signal handler we patch it to the acutal call.
        -- place a nop at the end, therefore the disasm doesn't screw up
        emit32 (0xffff9090 :: Word32) >> emit8 (0x90 :: Word8)
        -- discard arguments on stack
        let argcnt = ((if hasThis then 1 else 0) + (methodGetArgsCount cls cpidx)) * 4
        when (argcnt > 0) (add esp argcnt)
        -- push result on stack if method has a return value
        when (methodHaveReturnValue cls cpidx) (push eax)
        return $ Just $ (calladdr, MI l)

    emit' :: J.Instruction -> CodeGen e s (Maybe (Word32, TrapInfo))
    emit' (INVOKESPECIAL cpidx) = emitInvoke cpidx True
    emit' (INVOKESTATIC cpidx) = emitInvoke cpidx False
    emit' (INVOKEVIRTUAL cpidx) = do
        -- get methodInfo entry
        let mi@(MethodInfo methodname objname msig@(MethodSignature args _))  = buildMethodID cls cpidx
        newNamedLabel (show mi) >>= defineLabel
        -- objref lives somewhere on the argument stack
        mov eax (Disp ((*4) $ fromIntegral $ length args), esp)
        -- get method-table-ptr
        mov eax (Disp 0, eax)
        -- get method offset
        let nameAndSig = methodname `B.append` (encode msig)
        offset <- liftIO $ getMethodOffset objname nameAndSig
        -- make actual (indirect) call
        calladdr <- getCurrentOffset
        call (Disp offset, eax)
        -- discard arguments on stack (+4 for "this")
        let argcnt = 4 + ((methodGetArgsCount cls cpidx) * 4)
        when (argcnt > 0) (add esp argcnt)
        -- push result on stack if method has a return value
        when (methodHaveReturnValue cls cpidx) (push eax)
        -- note, the "mi" has the wrong class reference here.
        -- we figure that out at run-time, in the methodpool,
        -- depending on the method-table-ptr
        return $ Just $ (calladdr, VI mi)
    emit' (PUTSTATIC cpidx) = do
        pop eax
        trapaddr <- getCurrentOffset
        mov (Addr 0x00000000) eax -- it's a trap
        return $ Just $ (trapaddr, SFI $ buildStaticFieldID cls cpidx)
    emit' (GETSTATIC cpidx) = do
        trapaddr <- getCurrentOffset
        mov eax (Addr 0x00000000) -- it's a trap
        push eax
        return $ Just $ (trapaddr, SFI $ buildStaticFieldID cls cpidx)
    emit' insn = emit insn >> return Nothing

    emit :: J.Instruction -> CodeGen e s ()
    emit POP = do -- dropp value
        add esp (4 :: Word32)
    emit DUP = push (Disp 0, esp)
    emit AASTORE = emit IASTORE
    emit IASTORE = do
        pop eax -- value
        pop ebx -- offset
        add ebx (1 :: Word32)
        pop ecx -- aref
        mov (ecx, ebx, S4) eax
    emit AALOAD = emit IALOAD
    emit IALOAD = do
        pop ebx -- offset
        add ebx (1 :: Word32)
        pop ecx -- aref
        push (ecx, ebx, S4)
    emit ARRAYLENGTH = do
        pop eax
        push (Disp 0, eax)
    emit (ANEWARRAY _) = emit (NEWARRAY 10) -- 10 == T_INT
    emit (NEWARRAY typ) = do
        let tsize = case decodeS (0 :: Integer) (B.pack [typ]) of
                    T_INT -> 4
                    _ -> error $ "newarray: type not implemented yet"
        -- get length from stack, but leave it there
        mov eax (Disp 0, esp)
        mov ebx (tsize :: Word32)
        -- multiple amount with native size of one element
        mul ebx -- result is in eax
        add eax (4 :: Word32) -- for "length" entry
        -- push amount of bytes to allocate
        push eax
        callMalloc
        pop eax -- ref to arraymemory
        pop ebx -- length
        mov (Disp 0, eax) ebx -- store length at offset 0
        push eax -- push ref again
    emit (NEW objidx) = do
        let objname = buildClassID cls objidx
        amount <- liftIO $ getMethodSize objname
        push (amount :: Word32)
        callMalloc
        -- TODO(bernhard): save reference somewhere for GC
        -- set method table pointer
        mtable <- liftIO $ getMethodTable objname
        mov (Disp 0, eax) mtable
    emit (CHECKCAST _) = nop -- TODO(bernhard): ...
    emit (BIPUSH val) = push ((fromIntegral val) :: Word32)
    emit (SIPUSH val) = push ((fromIntegral $ ((fromIntegral val) :: Int16)) :: Word32)
    emit (ICONST_0) = push (0 :: Word32)
    emit (ICONST_1) = push (1 :: Word32)
    emit (ICONST_2) = push (2 :: Word32)
    emit (ICONST_3) = push (3 :: Word32)
    emit (ICONST_4) = push (4 :: Word32)
    emit (ICONST_5) = push (5 :: Word32)
    emit (ALOAD_ x) = emit (ILOAD_ x)
    emit (ILOAD_ x) = do
        push (Disp (cArgs_ x), ebp)
    emit (ALOAD x) = emit (ILOAD x)
    emit (ILOAD x) = do
        push (Disp (cArgs x), ebp)
    emit (ASTORE_ x) = emit (ISTORE_ x)
    emit (ISTORE_ x) = do
        pop eax
        mov (Disp (cArgs_ x), ebp) eax
    emit (ASTORE x) = emit (ISTORE x)
    emit (ISTORE x) = do
        pop eax
        mov (Disp (cArgs x), ebp) eax

    emit (LDC1 x) = emit (LDC2 $ fromIntegral x)
    emit (LDC2 x) = do
        value <- case (constsPool cls) M.! x of
                      (CString s) -> liftIO $ getUniqueStringAddr s
                      _ -> error $ "LDCI... missing impl."
        push value
    emit (GETFIELD x) = do
        pop eax -- this pointer
        let (cname, fname) = buildFieldOffset cls x
        offset <- liftIO $ getFieldOffset cname fname
        push (Disp (fromIntegral $ offset), eax) -- get field
    emit (PUTFIELD x) = do
        pop ebx -- value to write
        pop eax -- this pointer
        let (cname, fname) = buildFieldOffset cls x
        offset <- liftIO $ getFieldOffset cname fname
        mov (Disp (fromIntegral $ offset), eax) ebx -- set field

    emit IADD = do pop ebx; pop eax; add eax ebx; push eax
    emit ISUB = do pop ebx; pop eax; sub eax ebx; push eax
    emit IMUL = do pop ebx; pop eax; mul ebx; push eax
    emit IXOR = do pop ebx; pop eax; xor eax ebx; push eax
    emit (IINC x imm) = do
        add (Disp (cArgs x), ebp) (s8_w32 imm)

    emit (IF_ACMP cond x) = emit (IF_ICMP cond x)
    emit (IF_ICMP cond _) = do
        pop eax -- value2
        pop ebx -- value1
        cmp ebx eax -- intel syntax is swapped (TODO(bernhard): test that plz)
        let sid = case successor bb of TwoTarget _ t -> t; _ -> error "bad"
        let l = getLabel sid lmap
        case cond of
          C_EQ -> je  l; C_NE -> jne l
          C_LT -> jl  l; C_GT -> jg  l
          C_GE -> jge l; C_LE -> jle l

    emit (IF cond _) = do
        pop eax -- value1
        cmp eax (0 :: Word32) -- TODO(bernhard): test that plz
        let sid = case successor bb of TwoTarget _ t -> t; _ -> error "bad"
        let l = getLabel sid lmap
        case cond of
          C_EQ -> je  l; C_NE -> jne l
          C_LT -> jl  l; C_GT -> jg  l
          C_GE -> jge l; C_LE -> jle l

    emit (GOTO _ ) = do
        let sid = case successor bb of OneTarget t -> t; _ -> error "bad"
        jmp $ getLabel sid lmap

    emit RETURN = do mov esp ebp; pop ebp; ret
    emit ARETURN = emit IRETURN
    emit IRETURN = do
        pop eax
        mov esp ebp
        pop ebp
        ret
    emit invalid = error $ "insn not implemented yet: " ++ (show invalid)

    callMalloc :: CodeGen e s ()
    callMalloc = do
        calladdr <- getCurrentOffset
        let w32_calladdr = 5 + calladdr
        let malloaddr = (fromIntegral getMallocAddr :: Word32)
        call (malloaddr - w32_calladdr)
        add esp (4 :: Word32)
        push eax

  -- for locals we use a different storage
  cArgs :: Word8 -> Word32
  cArgs x = if (x' >= thisMethodArgCnt)
      -- TODO(bernhard): maybe s/(-4)/(-8)/
      then fromIntegral $ (-4) * (x' - thisMethodArgCnt + 1)
      else 4 + (thisMethodArgCnt * 4) - (4 * x')
    where x' = fromIntegral x

  cArgs_ :: IMM -> Word32
  cArgs_ x = cArgs $ case x of I0 -> 0; I1 -> 1; I2 -> 2; I3 -> 3

  thisMethodArgCnt :: Word32
  thisMethodArgCnt = isNonStatic + (fromIntegral $ length args)
    where
    (Just m) = lookupMethod method cls
    (MethodSignature args _) = methodSignature m
    isNonStatic = if S.member ACC_STATIC (methodAccessFlags m)
        then 0
        else 1 -- one argument for the this pointer


  -- sign extension from w8 to w32 (over s8)
  --   unfortunately, hs-java is using Word8 everywhere (while
  --   it should be Int8 actually)
  s8_w32 :: Word8 -> Word32
  s8_w32 w8 = fromIntegral s8
    where s8 = (fromIntegral w8) :: Int8
