{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverlappingInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
module Main where

import qualified Data.List as L
import qualified Data.Map as M
import qualified Data.Set as S
import Data.Maybe
import Data.Int
import Data.Word
import Data.Typeable
import Control.Applicative
import Data.Monoid

import Harpy
import Harpy.X86Disassembler

import Compiler.Hoopl hiding (Label)

import Control.Monad.State

-- import Debug.Trace
import Text.Printf

{- TODO
(.) extend `MateIR' with Open/Close for Hoopl
(.) replace BasicBlock stuff with Hoopl.Graph if possible (at least for codegen?)
(.) typeclass for codeemitting: http://pastebin.com/RZ9qR3k7 (depricated) || http://pastebin.com/BC3Jr5hG
(.) data dep for Var: this `Var JInt a' should be `Var JInt Int32'. Or via constructors
(.) reg access typeclass for Var/HVar?
-}

-- source IR (jvm bytecode)
data JVMInstruction
  = ICONST_0 | ICONST_1
  | FCONST_0 | FCONST_1
  | IPUSH Int32
  | ILOAD Word8  -- storage offset
  | FLOAD Word8  -- storage offset
  | ISTORE Word8 -- storage offset
  | FSTORE Word8 -- storage offset
  | IADD | ISUB | IMUL | FADD
  | IFEQ_ICMP Int16 -- signed relative offset
  | GOTO Int16
  | DUP | SWAP
  | INVOKE Word8 -- amount of arguments
  | RETURN
  deriving Show

data MateIR t where
  IROp :: (Show t) => OpType -> t -> t -> t -> MateIR t
  IRJump :: MateIR t
  IRIfElse :: (Show t) => t -> t -> MateIR t
  IRReturn :: Bool -> MateIR t
  IRInvoke :: Word8 -> MateIR t
  IRNop :: MateIR t

data OpType
  = Add
  | Sub
  | Mul
  deriving Show

data HVar
  = HIReg Reg32
  | HIConstant Int32
  | SpillIReg Disp
  | HFReg XMMReg
  | HFConstant Float
  | SpillFReg Disp

data VarType = JInt | JFloat deriving Show

data Var
  = forall a . (Num a, Typeable a) => Value VarType a
  | VReg VarType Integer


{- generic basicblock datastructure -}
type BlockID = Int
data BasicBlock a = BasicBlock
  { bbID :: BlockID
  , code :: [a]
  , nextBlock :: NextBlock a }

data NextBlock a
  = Return
  | Jump (BlockRef a)
  | TwoJumps (BlockRef a) (BlockRef a)
  | Switch [BlockRef a]

data BlockRef a
  = Self
  | Ref (BasicBlock a)
{- /basicblock -}


{- pretty printing stuff. -}
instance Show a => Show (BasicBlock a) where
  show (BasicBlock bid insns end) = printf "BasicBlock%03d:\n" bid ++ scode ++ show end
    where scode = concatMap (printf "\t%s\n" . show) insns


instance Show (NextBlock a) where
  show x = case x of
    Return -> ""
    Jump br -> printf "jump: %s\n\n" (show br)
    TwoJumps br1 br2 -> printf "jump1: %s, jump2: %s\n\n" (show br1) (show br2)
    Switch _ -> error "showNextBlock: switch"

instance Show (BlockRef a) where
  show Self = "self"
  show (Ref bb) = printf "BasicBlock%03d" (bbID bb)

instance Show (MateIR t) where
  show (IROp op vr v1 v2) = printf "%s %s,  %s, %s" (show op) (show vr) (show v1) (show v2)
  show (IRInvoke x) = printf "invoke %s" (show x)
  show IRJump = printf "jump"
  show (IRIfElse v1 v2) = printf "if (%s == %s)" (show v1) (show v2)
  show (IRReturn b) = printf "return (%s)" (show b)
  show IRNop = printf "nop"

instance Show HVar where
  show (HIReg r32) = printf "%s" (show r32)
  show (HIConstant val) = printf "0x%08x" val
  show (SpillIReg (Disp d)) = printf "0x%02x(ebp[i])" d
  show (HFReg xmm) = printf "%s" (show xmm)
  show (HFConstant val) = printf "%2.2ff" val
  show (SpillFReg (Disp d)) = printf "0x%02x(ebp[f])" d

instance Show Var where
  show (VReg t n) = printf "%s(%02d)" (show t) n
  show (Value JInt n) = printf "0x%08x" ((fromJust . cast) n :: Int32)
  show (Value JFloat n) = printf "%2.2ff" ((fromJust . cast) n :: Float)
{- /show -}



{- traverse the basicblock datastructure -}
type Visited = [BlockID]
type FoldState m = Monoid m => State Visited m

-- TODO: this is a hack, is this defined somewhere?
instance Monoid (IO ()) where { mempty = return mempty; mappend = (>>) }
instance Monoid (CodeGen e s ()) where { mempty = return mempty; mappend = (>>) }

bbFold :: Monoid m => (BasicBlock a -> m) -> BasicBlock a -> m
bbFold f bb' = evalState (bbFoldState bb') []
  where
    -- TODO: type signature?!
    -- bbFoldState :: Monoid m => BasicBlock a -> FoldState m
    bbFoldState bb@(BasicBlock bid _ next) = do
      visited <- get
      if bid `L.elem` visited
        then return mempty
        else do
          modify (bid:)
          let b = f bb
          case next of
            Return -> return b
            Jump ref -> do
              r1 <- brVisit ref
              return $ b `mappend` r1
            TwoJumps ref1 ref2 -> do
              r1 <- brVisit ref1
              r2 <- brVisit ref2
              return $ b `mappend` r1 `mappend` r2
            Switch _ -> error "impl. switch stuff"
    -- brVisit :: BlockRef a -> FoldState m
    brVisit Self = return mempty
    brVisit (Ref bb) = bbFoldState bb
{- /traverse -}

{- rewrite basicblock: maintain structure, but transform instructions of
   basicblock -}
type BasicBlockMap a = M.Map BlockID (BasicBlock a)
type RewriteState a = State Visited (BasicBlockMap a)

bbRewrite :: (BasicBlock a -> BasicBlock b) -> BasicBlock a -> BasicBlock b
bbRewrite f = bbRewriteWith f' ()
  where f' x _ = return $ f x
{- /rewrite-}

{- rewrite with state -}
type Transformer a b s = (BasicBlock a -> NextBlock b -> State s (BasicBlock b))

-- TODO: refactor as state monad.  how?!
--      "tying the knot" not possible with state monad?
bbRewriteWith :: Transformer a b s -> s -> BasicBlock a -> BasicBlock b
bbRewriteWith f state' bb' = let (res, _, _) = bbRewrite' state' M.empty bb' in res
  where
    bbRewrite' st visitmap bb@(BasicBlock bid _ next)
      | bid `M.member` visitmap = (visitmap M.! bid, visitmap, st)
      | otherwise = (x, newvmap, allstate)
          where
            (x, newstate) = runState (f bb newnext) st
            visitmap' = M.insert bid x visitmap
            (newnext, newvmap, allstate) = case next of
              Return -> (Return, visitmap', newstate)
              Jump ref ->
                  let (r, m, s1) = brVisit newstate visitmap' ref
                  in (Jump r, m, s1)
              TwoJumps ref1 ref2 ->
                  let (r1, m1, s1) = brVisit newstate visitmap' ref1
                      (r2, m2, s2) = brVisit s1 m1 ref2
                  in (TwoJumps r1 r2, m2, s2)
              Switch _ -> error "impl. switch stuff (rewrite)"
    brVisit st vmap Self = (Self, vmap, st)
    brVisit st vmap (Ref bb) = (Ref r, m, newstate)
      where (r, m, newstate) = bbRewrite' st vmap bb
{- /rewrite with -}

{- JVMInstruction -> MateIR -}
data SimStack = SimStack
  { stack :: [Var]
  , regcnt :: Integer }

transformJ2IR :: BasicBlock JVMInstruction
                 -> NextBlock (MateIR Var)
                 -> State SimStack (BasicBlock (MateIR Var))
transformJ2IR jvmbb next = do
  res <- filter noNop <$> mapM tir (code jvmbb)
  return (BasicBlock (bbID jvmbb) res next)
  where
    noNop IRNop = False; noNop _ = True

    tir :: JVMInstruction -> State SimStack (MateIR Var)
    tir ICONST_0 = tir (IPUSH 0)
    tir ICONST_1 = tir (IPUSH 1)
    tir (IPUSH x) = do apush $ Value JInt x; return IRNop
    tir FCONST_0 =  do apush $ Value JFloat (0 :: Float); return IRNop
    tir FCONST_1 =  do apush $ Value JFloat (1 :: Float); return IRNop
    tir (ILOAD x) = do apush $ VReg JInt (fromIntegral x); return IRNop
    tir (ISTORE y) = tirStore y JInt
    tir (FSTORE y) = tirStore y JFloat
    tir IADD = tirOpInt Add JInt
    tir ISUB = tirOpInt Sub JInt
    tir IMUL = tirOpInt Mul JInt
    tir FADD = tirOpInt Add JFloat
    tir (IFEQ_ICMP _) = do
      x <- apop
      y <- apop
      return $ IRIfElse x y
    tir RETURN = return $ IRReturn False
    tir x = error $ "tir: " ++ show x

    tirStore w8 t = do
      x <- apop
      let nul = case t of JInt -> Value JInt (0 :: Int32); JFloat -> Value JFloat (0 :: Float)
      return $ IROp Add (VReg t $ fromIntegral w8) x nul
    tirOpInt op t = do
      x <- apop; y <- apop
      nv <- newvar t; apush nv
      return $ IROp op nv x y

    -- helper
    newvar t = do
      sims <- get
      put $ sims { regcnt = regcnt sims + 1 }
      return $ VReg t $ regcnt sims
    apush x = do
      sims <- get
      put $ sims { stack = x : stack sims }
    apop :: State SimStack Var
    apop = do
      sims <- get
      put $ sims { stack = tail $ stack sims }
      return . head . stack $ sims
{- /JVMInstruction -> MateIR -}

{- regalloc -}
data MappedRegs = MappedRegs
  { intMap :: M.Map Integer HVar
  , floatMap :: M.Map Integer HVar
  , stackCnt :: Word32 }

emptyRegs = MappedRegs M.empty M.empty 0

allIntRegs = [eax, ecx, edx, ebx, esi, edi] :: [Reg32]
allFloatRegs = [xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7] :: [XMMReg]

stupidRegAlloc :: BasicBlock (MateIR Var)
            -> NextBlock (MateIR HVar)
            -> State MappedRegs (BasicBlock (MateIR HVar))
{- post condition: basicblocks doesn't contain any IReg's or FReg's -}
stupidRegAlloc bb nb = do
  code' <- mapM assignRegs $ code bb
  return BasicBlock { bbID = bbID bb, code = code', nextBlock = nb }
  where
    assignRegs :: MateIR Var -> State MappedRegs (MateIR HVar)
    assignRegs (IROp op dst src1 src2) = do
      dstnew <- doAssign dst
      src1new <- doAssign src1
      src2new <- doAssign src2
      return $ IROp op dstnew src1new src2new
    assignRegs (IRIfElse cmp1 cmp2) = do
      cmp1new <- doAssign cmp1
      cmp2new <- doAssign cmp2
      return $ IRIfElse cmp1new cmp2new
    assignRegs (IRReturn x) = return $ IRReturn x -- TODO: what do?
    assignRegs x = error $ "assignRegs: " ++ show x

    hasAssign :: Var -> State MappedRegs Bool
    hasAssign (VReg JInt vreg) = M.member vreg <$> intMap <$> get
    hasAssign (VReg JFloat vreg) = M.member vreg <$> floatMap <$> get
    hasAssign x = error $ "hasAssign: " ++ show x

    getAssign :: Var -> State MappedRegs HVar
    getAssign (VReg JInt vreg) = (M.! vreg) <$> intMap <$> get
    getAssign (VReg JFloat vreg) = (M.! vreg) <$> floatMap <$> get
    getAssign x = error $ "getAssign: " ++ show x

    doAssign :: Var -> State MappedRegs HVar
    doAssign (Value JInt x) = return $ HIConstant (fromJust . cast $ x)
    doAssign (Value JFloat x) = return $ HFConstant (fromJust . cast $ x)
    doAssign vr = do
      isAssignVr <- hasAssign vr
      if isAssignVr
        then getAssign vr
        else nextAvailReg vr

    intRegsInUse :: State MappedRegs [Reg32]
    intRegsInUse = do
      mr <- M.elems <$> intMap <$> get
      let unpackReg :: HVar -> Reg32
          unpackReg (HIReg r) = r
          unpackReg _ = error "intRegsInUse: can't happen"
      let f (HIReg _) = True
          f _ = False
      return . map unpackReg . filter f $ mr

    floatRegsInUse :: State MappedRegs [XMMReg]
    floatRegsInUse = do
      mr <- M.elems <$> floatMap <$> get
      let unpackReg :: HVar -> XMMReg
          unpackReg (HFReg r) = r
          unpackReg _ = error "floatRegsInUse: can't happen"
      let f (HFReg _) = True
          f _ = False
      return . map unpackReg . filter f $ mr

    intAvailRegs :: State MappedRegs [Reg32]
    intAvailRegs = do
      inuse <- intRegsInUse
      return $ allIntRegs L.\\ inuse

    floatAvailRegs :: State MappedRegs [XMMReg]
    floatAvailRegs = do
      inuse <- floatRegsInUse
      return $ allFloatRegs L.\\ inuse

    nextAvailReg:: Var -> State MappedRegs HVar
    -- TODO: simplify
    nextAvailReg (VReg JInt vreg) = do
      availregs <- intAvailRegs
      mr <- get
      case availregs of
        [] -> do
          let disp = stackCnt mr
          let spill = SpillIReg (Disp disp)
          let imap = M.insert vreg spill $ intMap mr
          put (mr { stackCnt = disp + 4, intMap = imap} )
          return spill
        (x:_) -> do
          let regalloc = HIReg x
          let imap = M.insert vreg regalloc $ intMap mr
          put (mr { intMap = imap })
          return regalloc
    nextAvailReg (VReg JFloat vreg) = do
      availregs <- floatAvailRegs
      mr <- get
      case availregs of
        [] -> do
          let disp = stackCnt mr
          let spill = SpillFReg (Disp disp)
          let imap = M.insert vreg spill $ floatMap mr
          put (mr { stackCnt = disp + 4, floatMap = imap} )
          return spill
        (x:_) -> do
          let regalloc = HFReg x
          let imap = M.insert vreg regalloc $ floatMap mr
          put (mr { floatMap = imap })
          return regalloc
    nextAvailReg _ = error "intNextReg: dafuq"
{- /regalloc -}

{- codegen test -}
girEmit :: MateIR HVar -> CodeGen e s ()
girEmit (IROp Add dst' src1' src2') =
    ge dst' src1' src2'
  where
    ge :: HVar -> HVar -> HVar -> CodeGen e s ()
    ge (HIReg dst) (HIReg src1) (HIReg src2)
        | dst == src1 = add src1 src2
        | dst == src2 = add src2 src1
        | otherwise = do mov dst src1; add dst src2
    ge (HIReg dst) (HIConstant c1) (HIConstant c2) =
      mov dst (fromIntegral $ c1 + c2 :: Word32)

    ge (HIReg dst) (HIConstant c1) (HIReg src2) = do
      mov dst src2
      when (c1 /= 0) $ add dst (fromIntegral c1 :: Word32)
    ge (HIReg dst) (HIConstant c1) (SpillIReg disp) = do
      let src2 = (disp, ebp)
      mov dst src2
      when (c1 /= 0) $ add dst (fromIntegral c1 :: Word32)
    ge (HIReg dst) (SpillIReg disp) (HIReg src2) = do
      let src1 = (disp, ebp)
      mov dst src2
      add dst src1
    ge (HIReg dst) src1 c1@(HIConstant _) = ge (HIReg dst) c1 src1
    ge (HIReg dst) src1 spill@(SpillIReg _) = ge (HIReg dst) spill src1
    ge (HIReg dst) spill@(SpillIReg _) src2 = ge (HIReg dst) src2 spill
    ge (SpillIReg disp) (HIReg src1) (HIReg src2) = do
      let dst = (disp, ebp)
      mov dst src1
      add dst src2

    ge (HFReg dst) (HFReg src1) (HFReg src2) = do
      movss dst src2
      addss dst src1
    ge (HFReg dst) (HFConstant _) (HFConstant _) = do
      newNamedLabel "TODO!" >>= defineLabel
      movss dst dst
    ge (HFReg dst) (HFReg src) (HFConstant 0) =
      movss dst src
    ge p1 p2 p3 = error $ "girEmit (add): " ++ show p1 ++ ", " ++ show p2 ++ ", " ++ show p3
girEmit (IROp Mul _ _ _) = do
  newNamedLabel "TODO!" >>= defineLabel
  nop
girEmit (IRIfElse src1' src2') = ge src1' src2'
  where
    ge :: HVar -> HVar -> CodeGen e s ()
    ge (HIReg src1) (HIReg src2) = cmp src1 src2
    ge (HIReg src1) (HIConstant src2) =
      cmp src1 (fromIntegral src2 :: Word32)
    ge src1@(HIConstant _) src2 = ge src2 src1
    ge p1 p2 = error $ "girEmit (if): " ++ show p1 ++ ", " ++ show p2
girEmit (IRReturn _) = ret
girEmit x = error $ "girEmit: insn not implemented: " ++ show x
{- /codegen -}


{- application -}
dummy = 0x1337 -- jumpoffset will be eliminated after basicblock analysis

ex0 :: BasicBlock JVMInstruction
ex0 = BasicBlock 1 [ICONST_0, ISTORE 0] $ Jump (Ref bb2)
  where
    bb2 = BasicBlock 2 [ILOAD 0, ICONST_1, IADD, ISTORE 0
                       , ILOAD 0, IPUSH 10, IFEQ_ICMP dummy]
                       $ TwoJumps Self (Ref bb3)
    bb3 = BasicBlock 3 [ILOAD 0, IPUSH 20, IFEQ_ICMP dummy]
                       $ TwoJumps (Ref bb2) (Ref bb4)
    bb4 = BasicBlock 4 ([FCONST_0, FCONST_1, FADD, FSTORE 1, IPUSH 20
                       , IPUSH 1, IMUL, ISTORE 2]
                       ++ regpressure ++
                       [RETURN]) Return
    regpressure = concat $ replicate 5 [ILOAD 0, ILOAD 0, IADD, ISTORE 0]

ex1 :: BasicBlock JVMInstruction
ex1 = BasicBlock 1 [RETURN] Return

ex2 :: BasicBlock JVMInstruction
ex2 = BasicBlock 1 [IPUSH 0x20, IPUSH 0x30, IADD, RETURN] Return


prettyHeader :: String -> IO ()
prettyHeader str = do
  let len = length str + 6
  replicateM_ len (putChar '-'); putStrLn ""
  printf "-- %s --\n" str
  replicateM_ len (putChar '-'); putStrLn ""
  putStrLn "press any key to continue..." >> getChar
  return ()


main :: IO ()
main = do
  {-
  prettyHeader "PRINT ex2"
  bbFold print ex2
  prettyHeader "PRINT ex2 as MateIR"
  let bbgir2 = bbRewriteWith transformJ2IR (SimStack [] 4) ex2
  bbFold print bbgir2
  prettyHeader "PRINT ex2 as MateIR (reg alloc)"
  let bbgir2_regalloc = bbRewriteWith stupidRegAlloc emptyRegs bbgir2
  bbFold print bbgir2_regalloc
  prettyHeader "DISASM ex2"
  (_, Right d2) <- runCodeGen (compile bbgir2_regalloc) M.empty S.empty
  mapM_ (printf "%s\n" . showIntel) d2
  -}
  prettyHeader "PRINT ex0"
  bbFold print ex0
  prettyHeader "PRINT ex0 as MateIR"
  let bbgir0 = bbRewriteWith transformJ2IR (SimStack [] 50000) ex0
  bbFold print bbgir0
  prettyHeader "PRINT ex0 as MateIR (reg alloc)"
  let bbgir0_regalloc = bbRewriteWith stupidRegAlloc emptyRegs bbgir0
  bbFold print bbgir0_regalloc
  prettyHeader "DISASM ex0"
  (_, Right d0) <- runCodeGen (compile bbgir0_regalloc) M.empty S.empty
  mapM_ (printf "%s\n" . showIntel) d0


type BlockMap = M.Map BlockID Label
type BlockGenerated = S.Set BlockID

compile :: BasicBlock (MateIR HVar) -> CodeGen e BlockGenerated [Instruction]
compile bbgir = do
  bblabels <- mapM (\x -> do
                            l <- newNamedLabel ("BB: " ++ show x)
                            return (x, l)
                   ) $ basicBlockBids bbgir
  let lmap :: BlockMap
      lmap = M.fromList bblabels
  bbFold (\bb -> do
    defineLabel $ lmap M.! bbID bb
    mapM_ (\x -> printInsn x >> girEmit x) $ code bb
    bset <- getState
    let jmpblock :: BlockRef a -> CodeGen e s ()
        jmpblock Self = jmp $ lmap M.! bbID bb
        jmpblock (Ref bbnext) = jmp $ lmap M.! bbID bbnext

        jmpblock2 :: BlockRef a -> BlockRef a -> CodeGen e s ()
        jmpblock2 Self ref = do jmpblock Self; maybeJmpblock' ref
        jmpblock2 ref Self = do maybeJmpblock ref; jmpblock Self
        jmpblock2 ref1 ref2 = do
          skippedInsn <- maybeJmpblock ref1
          if skippedInsn
            then jmpblock ref2
            else maybeJmpblock' ref2

        maybeJmpblock' :: BlockRef a -> CodeGen e s ()
        maybeJmpblock' x = void (maybeJmpblock x)
        maybeJmpblock :: BlockRef a -> CodeGen e s Bool
        maybeJmpblock ref@(Ref bbnext) = do
          let bbid = bbID bbnext
          if S.member bbid bset
            then do jmpblock ref; return False
            else return True -- block will be generated next => jmp can be omitted
        maybeJmpblock x = do jmpblock x; return False
    case nextBlock bb of
      Return -> return ()
      Jump r -> maybeJmpblock' r
      TwoJumps r1 r2 -> jmpblock2 r1 r2
      Switch _ -> error "comiple: switch"
    setState (S.insert (bbID bb) bset)
   ) bbgir
  disassemble
    where
      printInsn insn = do
        l <- newNamedLabel ("//MateIR: " ++ show insn)
        defineLabel l

basicBlockBids :: BasicBlock a -> [BlockID]
basicBlockBids = bbFold ((:[]) . bbID)

oldmain :: IO ()
oldmain = do
  let extractbid (BasicBlock bid _ _) = [bid]
  putStrLn $ "woot: " ++ show (GOTO 12)
  putStrLn $ "getlabels: ex0: " ++ show (bbFold extractbid ex0)
  putStrLn $ "getlabels: ex1: " ++ show (bbFold extractbid ex1)
  putStrLn "\n\n-- REWRITING (id) --\n\n"
  bbFold print $ bbRewrite id ex0
  putStrLn "\n\n-- REWRITING (dup code segment [indeed, it's pointless]) --\n\n"
  bbFold print $ bbRewrite (\bb -> bb { code = code bb ++ code bb }) ex0
  putStrLn "\n\n-- REWRITING WITH STATE --\n\n"
  let rewrite1 bb _ = do
        modify (+1)
        factor <- get
        return $ bb { code = concat $ replicate factor (code bb) }
  bbFold print $ bbRewriteWith rewrite1 0 ex0
{- /application -}
