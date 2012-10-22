{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverlappingInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE RankNTypes #-}
module Main where

import qualified Data.List as L
import qualified Data.Map as M
import qualified Data.Set as S
import Data.Int
import Data.Word
import Data.Maybe
import Control.Applicative hiding ((<*>))
import Data.Monoid

import Harpy
import Harpy.X86Disassembler

import Compiler.Hoopl hiding (Label)
import qualified Compiler.Hoopl as H

import Control.Monad.State

import Debug.Trace
import Text.Printf

{- TODO
(.) extend `MateIR' with Open/Close for Hoopl
(.) replace BasicBlock stuff with Hoopl.Graph if possible (at least for codegen?)
(.) typeclass for codeemitting: http://pastebin.com/RZ9qR3k7 (depricated) || http://pastebin.com/BC3Jr5hG
(.) codegen: jmp/je bugfix plzkkthx -.-
(.) bbFold: Data.{Foldable,Traversable} and stuff

TODO for hoopl:
  - leave BasicBlock for JavaIR, and use Hoopl.Graph
  - we need a function with `BasicBlock JVMInstruction -> Graph (MateIR Var) C C'
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
  deriving Eq

deriving instance Eq Disp

data VarType = JInt | JFloat deriving (Show, Eq)

data Var
  = JIntValue Int32
  | JFloatValue Float
  | VReg VarType Integer

varType :: Var -> VarType
varType (JIntValue _) = JInt
varType (JFloatValue _) = JFloat
varType (VReg t _) = t


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
  show (JIntValue n) = printf "0x%08x" n
  show (JFloatValue n) = printf "%2.2ff" n
{- /show -}



{- traverse the basicblock datastructure -}
type Visited = [BlockID]
type FoldState m = State Visited m

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

data MateIR2 t e x where
  IR2Label :: H.Label -> MateIR2 t C O
  IR2Op :: (Show t) => OpType -> t -> t -> t -> MateIR2 t O O
  IR2Nop :: MateIR2 t O O
  IR2Invoke :: Word8 -> MateIR2 t O O

  IR2Jump :: H.Label -> MateIR2 t O C
  IR2IfElse :: (Show t) => t -> t -> H.Label -> H.Label -> MateIR2 t O C
  IR2Return :: Bool -> MateIR2 t O C

data LinearIns t
  = Fst (MateIR2 t C O)
  | Mid (MateIR2 t O O)
  | Lst (MateIR2 t O C)

instance Show (MateIR2 t e x) where
  show (IR2Label l) = printf "label: %s:\n" (show l)
  show (IR2Op op vr v1 v2) = printf "\t%s %s,  %s, %s" (show op) (show vr) (show v1) (show v2)
  show (IR2Invoke x) = printf "\tinvoke %s" (show x)
  show (IR2Jump l) = printf "\tjump %s" (show l)
  show (IR2IfElse v1 v2 l1 l2) = printf "\tif (%s == %s) then %s else %s" (show v1) (show v2) (show l1) (show l2)
  show (IR2Return b) = printf "\treturn (%s)" (show b)
  show IR2Nop = printf "\tnop"

instance Show (LinearIns t) where
  show (Fst n) = printf "%s\n" $ show n
  show (Mid n) = printf "%s\n" $ show n
  show (Lst n) = printf "%s\n" $ show n

instance NonLocal (MateIR2 Var) where
  entryLabel (IR2Label l) = l
  successors (IR2Jump l) = [l]
  successors (IR2IfElse _ _ l1 l2) = [l1, l2]
  successors (IR2Return _) = []

data LabelLookup = LabelLookup 
  { labels :: M.Map Int16 H.Label
  , simStack :: SimStack
  , pcOffset :: Int16 }

-- mkFirst ::    GraphRep g              =>   n C O  -> g n C O
-- mkMiddle  :: (GraphRep g, NonLocal n) =>   n O O  -> g n O O
-- mkMiddles :: (GraphRep g, NonLocal n) =>  [n O O] -> g n O O
-- mkLast ::     GraphRep g =>                n O C  -> g n O C
-- (<*>) ::     (GraphRep g, NonLocal n) => g n e O  -> g n O x -> g n e x
-- (|*><*|) ::  (GraphRep g, NonLocal n) => g n e C  -> g n C x -> g n e x

type LabelState a = StateT LabelLookup SimpleUniqueMonad a

mkMethod :: Graph (MateIR2 Var) C C -> LabelState (Graph (MateIR2 Var) O C)
mkMethod g = do
  entryseq <- mkLast <$> IR2Jump <$> addLabel 0
  return $ entryseq |*><*| g

mkBlock :: [JVMInstruction] -> LabelState (Graph (MateIR2 Var) C C)
mkBlock jvminsn = do
  pc <- pcOffset <$> get
  f' <- IR2Label <$> (addLabel pc)
  ms' <- toMid $ init jvminsn
  l' <- toLast (last jvminsn)
  return $ mkFirst f' <*> mkMiddles ms' <*> mkLast l'

addLabel :: Int16 -> LabelState H.Label
addLabel boff = do
  lmap <- labels <$> get
  if M.member boff lmap
    then return $ lmap M.! boff
    else do
      label <- lift $ freshLabel
      modify (\s -> s {labels = M.insert boff label (labels s) })
      return label

toMid :: [JVMInstruction] -> LabelState [MateIR2 Var O O]
toMid xs = do insn <- forM xs $ \x -> do
                -- st <- (trace $ printf "tir': %s\n" (show x)) get
                st <- get
                let (ins, state') = runState (tir2 x) (simStack st)
                put $ st { simStack = state'}
                incrementPC x
                return ins
              let noNop IR2Nop = False; noNop _ = True
              return $ filter noNop insn

incrementPC :: JVMInstruction -> LabelState ()
incrementPC ins = modify (\s -> s { pcOffset = pcOffset s + insnLength ins})

toLast :: JVMInstruction -> LabelState (MateIR2 Var O C)
toLast instruction = do
  res <- case instruction of
    RETURN -> return $ IR2Return True
    (IFEQ_ICMP rel) -> do
      x <- apop2
      y <- apop2
      unless (varType x == varType y) $ error "toLast IFEQ_ICMP: type mismatch"
      pc <- pcOffset <$> get
      truejmp <- addLabel (pc + rel)
      falsejmp <- addLabel (pc + insnLength instruction)
      return $ IR2IfElse x y truejmp falsejmp
    _ -> error $ "toLast: " ++ show instruction
  incrementPC instruction
  return res

apop2 :: LabelState Var
apop2 = do
  st <- get
  let lol = simStack st
  modify (\s -> s { simStack = lol { stack = tail (stack lol)} } )
  return . head . stack $ lol


mkLinear :: Graph (MateIR2 Var) O x -> [LinearIns Var] -- [Block (MateIR2 Var) C C]
mkLinear = concatMap lineariseBlock . postorder_dfs
  where
    -- see compiler/Lambdachine/Grin/RegAlloc.hs
    -- lineariseBlock :: Block (MateIR2 Var) C C -> [LinearIns Var]
    lineariseBlock block = entry_ins ++ map Mid middles ++ tail_ins
      where
        (entry, middles, tailb) = blockToNodeList block
        entry_ins :: [LinearIns Var]
        entry_ins = case entry of JustC n -> [Fst n]; NothingC -> []
        tail_ins :: [LinearIns Var]
        tail_ins = case tailb of JustC n -> [Lst n]; NothingC -> []

stupidRegAlloc2 :: [LinearIns Var] -> [LinearIns HVar]
stupidRegAlloc2 linsn = evalState regAlloc' emptyRegs
  where
    regAlloc' = mapM assignReg linsn
    assignReg :: LinearIns Var -> State MappedRegs (LinearIns HVar)
    assignReg lv = case lv of
      Fst x -> case x of
        IR2Label x' -> return $ Fst $ IR2Label x'
      Mid ins -> case ins of
        IR2Op op dst src1 src2 -> do
          dstnew <- doAssign dst
          src1new <- doAssign src1
          src2new <- doAssign src2
          return $ Mid $ IR2Op op dstnew src1new src2new
        IR2Nop -> return $ Mid $ IR2Nop
        IR2Invoke b -> return $ Mid $ IR2Invoke b
      Lst ins -> case ins of
        IR2Jump l -> return $ Lst $ IR2Jump l
        IR2IfElse cmp1 cmp2 l1 l2 -> do
          cmp1new <- doAssign cmp1
          cmp2new <- doAssign cmp2
          return $ Lst $ IR2IfElse cmp1new cmp2new l1 l2
        IR2Return b -> return $ Lst $ IR2Return b

    doAssign :: Var -> State MappedRegs HVar
    doAssign (JIntValue x) = return $ HIConstant x
    doAssign (JFloatValue x) = return $ HFConstant x
    doAssign vr = do
      isAssignVr <- hasAssign vr
      if isAssignVr
        then getAssign vr
        else nextAvailReg vr
      where
        hasAssign :: Var -> State MappedRegs Bool
        hasAssign (VReg _ vreg) = M.member vreg <$> regMap <$> get
        hasAssign x = error $ "hasAssign: " ++ show x

        getAssign :: Var -> State MappedRegs HVar
        getAssign (VReg _ vreg) = (M.! vreg) <$> regMap <$> get
        getAssign x = error $ "getAssign: " ++ show x

        nextAvailReg:: Var -> State MappedRegs HVar
        nextAvailReg (VReg t vreg) = do
          availregs <- availRegs t
          mr <- get
          case availregs of
            [] -> do
              let disp = stackCnt mr
              let spill = case t of
                            JInt -> SpillIReg (Disp disp)
                            JFloat -> SpillFReg (Disp disp)
              let imap = M.insert vreg spill $ regMap mr
              put (mr { stackCnt = disp + 4, regMap = imap} )
              return spill
            (x:_) -> do
              let imap = M.insert vreg x $ regMap mr
              put (mr { regMap = imap })
              return x
        nextAvailReg _ = error "intNextReg: dafuq"

        regsInUse :: VarType -> State MappedRegs [HVar]
        regsInUse t = do
          mr <- M.elems <$> regMap <$> get
          let unpackIntReg :: HVar -> Maybe HVar
              unpackIntReg x@(HIReg _) = Just x
              unpackIntReg _ = Nothing
          let unpackFloatReg :: HVar -> Maybe HVar
              unpackFloatReg x@(HFReg _) = Just x
              unpackFloatReg _ = Nothing
          let unpacker = case t of JInt -> unpackIntReg; JFloat -> unpackFloatReg
          return . mapMaybe unpacker $ mr

        availRegs :: VarType -> State MappedRegs [HVar]
        availRegs t = do
          inuse <- regsInUse t
          let allregs = case t of JInt -> allIntRegs; JFloat -> allFloatRegs
          return (allregs L.\\ inuse)

compileLinear :: M.Map Int16 H.Label -> [LinearIns HVar] -> CodeGen e s [Instruction]
compileLinear labels linsn = do
  bblabels <- forM (M.elems labels) $ \h -> do
                l <- newNamedLabel ("Label: " ++ show h)
                return (h, l)
  let lmap :: M.Map H.Label Label
      lmap = M.fromList bblabels
  let compileIns (Fst (IR2Label h)) = defineLabel $ lmap M.! h
      compileIns (Mid ins) = girEmitOO ins
      compileIns (Lst ins) = case ins of
        IR2IfElse src1 src2 h1 h2 -> do
          let l1 = lmap M.! h1
          let l2 = lmap M.! h2
          case (src1, src2) of
            (HIReg s1, HIReg s2) -> cmp s1 s2
            (HIConstant c, HIReg s1) -> cmp s1 (fromIntegral c :: Word32)
            (HIReg s1, HIConstant c) -> cmp s1 (fromIntegral c :: Word32)
            x -> error $ "ir2ifelse: not impl. yet" ++ show x
          je l1
          jmp l2
        IR2Return _ -> ret
        x -> error $ "lst: not impl. yet: " ++ show x
  mapM_ compileIns linsn
  disassemble




jvm0 = [ICONST_0, ICONST_1, IADD, RETURN]

jvm1 = [jvm1_1, jvm1_2]
jvm1_1 = [ICONST_0, ICONST_1, IADD, ICONST_1, IFEQ_ICMP (-9)]
jvm1_2 = [ICONST_1, RETURN]

jvm2 = [jvm2_1, jvm2_2, jvm2_3]
jvm2_1 = [ICONST_0, ISTORE 0
         , ILOAD 0, ICONST_1, IADD, ISTORE 0
         , IPUSH 10, ILOAD 0, IFEQ_ICMP (-14)]
jvm2_2 = [ILOAD 0, IPUSH 20, IFEQ_ICMP (-6)]
jvm2_3 = [FCONST_0, FCONST_1, FADD, FSTORE 1
         , IPUSH 20, IPUSH 1, IMUL, ISTORE 2
         , RETURN]

result :: IO ()
result = do
  let initstate = LabelLookup { labels = M.empty
                              , simStack = SimStack [] 50000
                              , pcOffset = 0 }
  let transform bs = do
        foldl (liftM2 (|*><*|)) (return emptyClosedGraph) (map mkBlock bs)
  let runStuff x = runSimpleUniqueMonad . runStateT x
  let res jvminsns = runStuff (transform jvminsns >>= \g -> mkMethod g) initstate

  let printjvmres :: [[JVMInstruction]] -> IO ()
      printjvmres insns = do
        let r = res insns
        let g = Prelude.fst r
        let lbls = labels . snd $ r
        let l = mkLinear g
        let ra = stupidRegAlloc2 l
        printf "GRAPH:\n%s\n" $ showGraph show g
        printf "MAP: %s\n" (show lbls)
        printf "LINEAR: %s\n" (show l)
        printf "REGALLOC: %s\n" (show ra)
        (_, Right dis) <- runCodeGen (compileLinear lbls ra) () ()
        mapM_ (printf "%s\n" . showIntel) dis
  printjvmres jvm1
  printjvmres jvm2

-- what is this
switchStateT :: Monad m => (s -> t) -> (t -> s) -> State t a -> StateT s m b -> StateT s m b
switchStateT project expand first second = do
  firstState <- get
  let (_, state') = runState first (project firstState)
  put $ expand state'
  second

-- dummy
insnLength :: JVMInstruction -> Int16
insnLength ICONST_0 = 2
insnLength ICONST_1 = 2
insnLength _ = 3

instance Functor SimpleUniqueMonad where
  fmap = liftM
  

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

-- hs did something evil here... (moved inner where clause to global. actually i think
-- it is not that evil)

tir2 :: JVMInstruction -> State SimStack (MateIR2 Var O O)
tir2 ICONST_0 = tir2 (IPUSH 0)
tir2 ICONST_1 = tir2 (IPUSH 1)
tir2 (IPUSH x) = do apush $ JIntValue x; return IR2Nop
tir2 FCONST_0 =  do apush $ JFloatValue 0; return IR2Nop
tir2 FCONST_1 =  do apush $ JFloatValue 1; return IR2Nop
tir2 (ILOAD x) = do apush $ VReg JInt (fromIntegral x); return IR2Nop
tir2 (ISTORE y) = tirStore2 y JInt
tir2 (FSTORE y) = tirStore2 y JFloat
tir2 IADD = tirOpInt2 Add JInt
tir2 ISUB = tirOpInt2 Sub JInt
tir2 IMUL = tirOpInt2 Mul JInt
tir2 FADD = tirOpInt2 Add JFloat
tir2 (IFEQ_ICMP _) = error "if in middle of block"
tir2 RETURN = error "return in middle of block" -- return $ IR2Return False
tir2 x = error $ "tir: " ++ show x

tirStore2 w8 t = do
  x <- apop
  let nul = case t of
              JInt -> JIntValue 0
              JFloat -> JFloatValue 0
  unless (t == varType x) $ error "tirStore: type mismatch"
  return $ IR2Op Add (VReg t $ fromIntegral w8) x nul
tirOpInt2 op t = do
  x <- apop; y <- apop
  nv <- newvar t; apush nv
  unless (t == varType x && t == varType y) $ error "tirOpInt: type mismatch"
  return $ IR2Op op nv x y

tir :: JVMInstruction -> State SimStack (MateIR Var)
tir ICONST_0 = tir (IPUSH 0)
tir ICONST_1 = tir (IPUSH 1)
tir (IPUSH x) = do apush $ JIntValue x; return IRNop
tir FCONST_0 =  do apush $ JFloatValue 0; return IRNop
tir FCONST_1 =  do apush $ JFloatValue 1; return IRNop
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
  unless (varType x == varType y) $ error "tir IFEQ_ICMP: type mismatch"
  return $ IRIfElse x y
tir RETURN = return $ IRReturn False
tir x = error $ "tir: " ++ show x

tirStore w8 t = do
  x <- apop
  let nul = case t of
              JInt -> JIntValue 0
              JFloat -> JFloatValue 0
  unless (t == varType x) $ error "tirStore: type mismatch"
  return $ IROp Add (VReg t $ fromIntegral w8) x nul
tirOpInt op t = do
  x <- apop; y <- apop
  nv <- newvar t; apush nv
  unless (t == varType x && t == varType y) $ error "tirOpInt: type mismatch"
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
  { regMap :: M.Map Integer HVar
  , stackCnt :: Word32 }

emptyRegs = MappedRegs M.empty 0

allIntRegs = map HIReg [eax, ecx, edx, ebx, esi, edi] :: [HVar]
allFloatRegs = map HFReg [xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7] :: [HVar]

stupidRegAlloc :: BasicBlock (MateIR Var)
            -> NextBlock (MateIR HVar)
            -> State MappedRegs (BasicBlock (MateIR HVar))
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

    doAssign :: Var -> State MappedRegs HVar
    doAssign (JIntValue x) = return $ HIConstant x
    doAssign (JFloatValue x) = return $ HFConstant x
    doAssign vr = do
      isAssignVr <- hasAssign vr
      if isAssignVr
        then getAssign vr
        else nextAvailReg vr
      where
        hasAssign :: Var -> State MappedRegs Bool
        hasAssign (VReg _ vreg) = M.member vreg <$> regMap <$> get
        hasAssign x = error $ "hasAssign: " ++ show x

        getAssign :: Var -> State MappedRegs HVar
        getAssign (VReg _ vreg) = (M.! vreg) <$> regMap <$> get
        getAssign x = error $ "getAssign: " ++ show x

        nextAvailReg:: Var -> State MappedRegs HVar
        nextAvailReg (VReg t vreg) = do
          availregs <- availRegs t
          mr <- get
          case availregs of
            [] -> do
              let disp = stackCnt mr
              let spill = case t of
                            JInt -> SpillIReg (Disp disp)
                            JFloat -> SpillFReg (Disp disp)
              let imap = M.insert vreg spill $ regMap mr
              put (mr { stackCnt = disp + 4, regMap = imap} )
              return spill
            (x:_) -> do
              let imap = M.insert vreg x $ regMap mr
              put (mr { regMap = imap })
              return x
        nextAvailReg _ = error "intNextReg: dafuq"

        regsInUse :: VarType -> State MappedRegs [HVar]
        regsInUse t = do
          mr <- M.elems <$> regMap <$> get
          let unpackIntReg :: HVar -> Maybe HVar
              unpackIntReg x@(HIReg _) = Just x
              unpackIntReg _ = Nothing
          let unpackFloatReg :: HVar -> Maybe HVar
              unpackFloatReg x@(HFReg _) = Just x
              unpackFloatReg _ = Nothing
          let unpacker = case t of JInt -> unpackIntReg; JFloat -> unpackFloatReg
          return . mapMaybe unpacker $ mr

        availRegs :: VarType -> State MappedRegs [HVar]
        availRegs t = do
          inuse <- regsInUse t
          let allregs = case t of JInt -> allIntRegs; JFloat -> allFloatRegs
          return (allregs L.\\ inuse)
{- /regalloc -}

{- codegen test -}
girEmitOO :: MateIR2 HVar O O -> CodeGen e s ()
girEmitOO (IR2Op Add dst' src1' src2') =
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
girEmitOO (IR2Op Mul _ _ _) = do
  newNamedLabel "TODO!" >>= defineLabel
  nop
girEmitOO x = error $ "girEmitOO: insn not implemented: " ++ show x
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
    -- mapM_ (\x -> printInsn x >> girEmit x) $ code bb
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
