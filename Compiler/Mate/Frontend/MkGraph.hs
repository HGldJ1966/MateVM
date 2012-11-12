{- make Hoopl graph from J.Instruction.
   this includes:
     * type analysis of stack values
     * introducing (typed) virtual registers and constants
-}
module Compiler.Mate.Frontend.MkGraph
  ( SimStack(..)
  , LabelLookup(..)
  , addExceptionBlocks
  , resolveReferences
  , resetPC
  , mkBlocks
  , mkMethod
  ) where

import qualified Data.List as L
import qualified Data.Set as S
import qualified Data.Map as M
import qualified Data.IntervalMap as IM
import qualified Data.IntervalMap.Interval as IIM
import qualified Data.ByteString.Lazy as B
import Data.Int
import Data.Word

import Control.Applicative hiding ((<*>))
import Control.Monad
import Control.Monad.State

import qualified JVM.Assembler as J
import JVM.Assembler hiding (Instruction)
import JVM.ClassFile
import Compiler.Hoopl
import Harpy hiding (Label, fst)

import Compiler.Mate.Debug
import Compiler.Mate.Types
import Compiler.Mate.Frontend.IR
import Compiler.Mate.Frontend.StupidRegisterAllocation

-- import Debug.Trace

data SimStack = SimStack
  { stack :: [Var]
  , regcnt :: Integer
  , classf :: Class Direct
  , method :: Method Direct
  , preRegs :: [(Integer, (HVar, VarType))]
  }

data LabelLookup = LabelLookup
  { labels :: M.Map Int32 Label
  , nextTargets :: [Label]
  , blockEntries :: S.Set Int32
  , blockEnds :: M.Map Label [Var]
  , simStack :: SimStack
  , instructions :: [J.Instruction]
  , exceptionMap :: ExceptionMap Int32
  , handlerStarts :: S.Set Int32
  , pcOffset :: Int32 }

type LabelState a = StateT LabelLookup SimpleUniqueMonad a

-- mkFirst ::    GraphRep g              =>   n C O  -> g n C O
-- mkMiddle  :: (GraphRep g, NonLocal n) =>   n O O  -> g n O O
-- mkMiddles :: (GraphRep g, NonLocal n) =>  [n O O] -> g n O O
-- mkLast ::     GraphRep g =>                n O C  -> g n O C
-- (<*>) ::     (GraphRep g, NonLocal n) => g n e O  -> g n O x -> g n e x
-- (|*><*|) ::  (GraphRep g, NonLocal n) => g n e C  -> g n C x -> g n e x

w162i32 :: Word16 -> Int32
w162i32 w16 = fromIntegral i16
  where i16 = fromIntegral w16 :: Int16

w82i32 :: Word8 -> Int32
w82i32 w8 = fromIntegral i8
 where i8 = fromIntegral w8 :: Int8

addExceptionBlocks :: LabelState ()
addExceptionBlocks = do
  -- split on a new exception handler block
  hstarts <- S.toList <$> handlerStarts <$> get
  forM_ hstarts $ addPC . fromIntegral
  -- split on a try block
  tstarts <- map IIM.lowerBound <$> IM.keys <$> exceptionMap <$> get
  tends   <- map IIM.upperBound <$> IM.keys <$> exceptionMap <$> get
  forM_ tstarts $ addPC . fromIntegral
  forM_ tends   $ addPC . (+1) . fromIntegral

-- forward references wouldn't be a problem, but backwards are
resolveReferences :: LabelState ()
resolveReferences = do
    jvminsn <- instructions <$> get
    pc <- pcOffset <$> get
    if null jvminsn
      then do
        addPC 0 -- add entry instruction
        addPC pc -- mark return instruction
      else do
        when (null jvminsn) $ error "resolveReferences: something is really wrong here"
        let ins = head jvminsn
        addJumpTarget ins pc
        incrementPC ins
        popInstruction
        resolveReferences
  where
    addJumpTarget :: J.Instruction -> Int32 -> LabelState ()
    addJumpTarget ins pc = case ins of
        (IF _ rel) -> addPCs pc rel ins
        (IF_ICMP _ rel) -> addPCs pc rel ins
        (IF_ACMP _ rel) -> addPCs pc rel ins
        (IFNULL rel) -> addPCs pc rel ins
        (IFNONNULL rel) -> addPCs pc rel ins
        GOTO rel -> addPCs pc rel ins
        JSR _ -> error "addJumpTarget: JSR?!"
        GOTO_W _ -> error "addJumpTarget: GOTO_W?!"
        JSR_W _ -> error "addJumpTarget: JSR_W?!"
        TABLESWITCH _ _ _ _ _ -> error "addJumpTarget: tableswitch"
        LOOKUPSWITCH _ _ _ _ -> error "addJumpTarget: lookupswitch"
        _ -> return ()
    addPCs :: Int32 -> Word16 -> J.Instruction -> LabelState ()
    addPCs pc rel ins = do addPC (pc + insnLength ins); addPC (pc + (w162i32 rel))

addPC :: Int32 -> LabelState ()
addPC bcoff = do
  modify (\s -> s { blockEntries = S.insert bcoff (blockEntries s) })

mkMethod :: Graph (MateIR Var) C C -> LabelState (Graph (MateIR Var) O C)
mkMethod g = do
  hs <- handlerStarts <$> get
  entryseq <- mkLast <$> IRExHandler <$> mapM addLabel (S.toList hs ++ [0])
  return $ entryseq |*><*| g

mkBlocks :: LabelState [Graph (MateIR Var) C C]
mkBlocks = do
  pc <- pcOffset <$> get
  entries <- blockEntries <$> get
  jvminsn <- instructions <$> get
  if null jvminsn
    then return []
    else if S.member pc entries
      then do
        g <- mkBlock
        gs <- mkBlocks
        return $ g : gs
      else error $ "mkBlocks: something wrong here. pc: " ++ show pc ++
                   "\ninsn: " ++ show jvminsn

mkBlock :: LabelState (Graph (MateIR Var) C C)
mkBlock = do
  modify (\s -> s { nextTargets = [] })
  handlermap <- exceptionMap <$> get
  pc <- pcOffset <$> get
  l <- addLabel pc
  -- push JRef for Exceptionblock, which is passed via %eax
  isExceptionHandler <- S.member pc <$> handlerStarts <$> get
  handlerStart <- if isExceptionHandler
    then do
      apush2 (VReg JRef preeax)
      return $ Just $ fromIntegral pc
    else return Nothing
  let extable = map (\(x,y) -> (x, fromIntegral y))
                $ concatMap snd
                $ handlermap `IM.containing` pc
  let f' = IRLabel l extable handlerStart
  -- fixup block boundaries
  be <- -- trace (printf "pc: %d\nhstart: %s\nextable: %s\n" pc (show handlerStart) (show extable)) $
        (M.lookup l) <$> blockEnds <$> get
  fixup <- case be of
    Nothing -> return []
    Just ts -> forM ts $ \x -> do
                 st <- get
                 let (nv, state') = runState (newvar $ varType x) (simStack st)
                 put $ st { simStack = state'}
                 apush2 nv
                 return $ IROp Add nv x (nul (varType x))
  (ms', l') <- toMid
  return $ mkFirst f' <*> mkMiddles (fixup ++ ms') <*> mkLast l'

addLabel :: Int32 -> LabelState Label
addLabel boff = do
  lmap <- labels <$> get
  if M.member boff lmap
    then return $ lmap M.! boff
    else do
      label <- lift $ freshLabel
      modify (\s -> s {labels = M.insert boff label (labels s) })
      modify (\s -> s {nextTargets = label : (nextTargets s) })
      return label

popInstruction :: LabelState ()
popInstruction = do
  i <- instructions <$> get
  when (null i) $ error "popInstruction: something is really wrong here"
  modify (\s -> s { instructions = tail i })

toMid :: LabelState ([MateIR Var O O], MateIR Var O C)
toMid = do
    pc <- pcOffset <$> get
    insns <- instructions <$> get
    when (null insns) $ error "toMid: something is really wrong here :/"
    ins <- head <$> instructions <$> get
    entries <- blockEntries <$> get
    if S.member (pc + insnLength ins) entries
      then toLast ins
      else do
        insIR <- normalIns ins
        (insn, lastins) <- toMid
        return (insIR ++ insn, lastins)
  where
    normalIns ins = do
      -- st <- get
      st <- (tracePipe $ printf "tir': %s\n" (show ins)) get
      let (insIR, state') = runState (tir ins) (simStack st)
      put $ st { simStack = state'}
      incrementPC ins
      popInstruction
      return insIR

    toLast :: J.Instruction -> LabelState ([MateIR Var O O], MateIR Var O C)
    toLast ins = do
      pc <- pcOffset <$> get
      let ifstuff jcmp rel op1 op2 = do
            truejmp <- addLabel (pc + w162i32 rel)
            falsejmp <- addLabel (pc + insnLength ins)
            incrementPC ins
            popInstruction
            return $ ([], IRIfElse jcmp op1 op2 truejmp falsejmp)
      (ret1, ret2) <- case ins of
        RETURN -> do
          incrementPC ins
          popInstruction
          return $ ([], IRReturn Nothing)
        ARETURN -> returnSomething JRef
        IRETURN -> returnSomething JInt
        LRETURN -> error "toLast: LReturn"
        FRETURN -> returnSomething JFloat
        DRETURN -> error "toLast: DReturn"
        (IF jcmp rel) -> do
          let op1 = JIntValue 0
          op2 <- apop2
          unless (varType op2 == JInt) $ error "toLast IF: type mismatch"
          ifstuff jcmp rel op1 op2
        (IFNULL _) -> error "toLast: IFNULL"
        (IFNONNULL _) -> error "toLast: IFNONNULL"
        (IF_ICMP jcmp rel) -> do
          op1 <- apop2
          op2 <- apop2
          unless (varType op1 == varType op2) $ error "toLast IF_ICMP: type mismatch"
          ifstuff jcmp rel op1 op2
        (IF_ACMP jcmp rel) -> do
          op1 <- apop2
          op2 <- apop2
          unless (varType op1 == varType op2) $ error "toLast IF_ACMP: type mismatch"
          ifstuff jcmp rel op1 op2
        (GOTO rel) -> do
          jump <- addLabel (pc + w162i32 rel)
          incrementPC ins
          popInstruction
          return $ ([], IRJump jump)
        _ -> do -- fallthrough case
          next <- addLabel (pc + insnLength ins)
          insIR <- normalIns ins
          return $ (insIR, IRJump next)
      foo <- handleBlockEnd
      return (ret1 ++ foo, ret2)
      where
        returnSomething t = do
          incrementPC ins
          popInstruction
          r <- apop2
          unless (varType r == t) $ error "toLast return: type mismatch"
          return $ ([], IRReturn $ Just r)

handleBlockEnd :: LabelState [MateIR Var O O]
handleBlockEnd = do
  st <- simStack <$> get
  let len = L.genericLength $ stack $ st
  if len > 0
    then do
      forM [500000 .. (500000 + len - 1)] $ \r -> do
        x <- apop2
        let vreg = VReg (varType x) r
        targets <- nextTargets <$> get
        forM targets $ \t -> do
          be <- M.lookup t <$> blockEnds <$> get
          let be' = case be of
                      Just x' -> x'
                      Nothing -> []
          modify (\s -> s { blockEnds = M.insert t (vreg:be') (blockEnds s)})
        return (IROp Add vreg x (nul (varType x)))
    else return []

insnLength :: Integral a => J.Instruction -> a
insnLength x = case x of
  (TABLESWITCH padding _ _ _ xs) ->
    fromIntegral $ 1 {- opcode -}
                 + (fromIntegral padding)
                 + (3 * 4) {- def, low, high -}
                 + 4 * length xs {- entries -}
  (LOOKUPSWITCH padding _ _ xs) ->
    fromIntegral $ 1 {- opcode -}
                 + (fromIntegral padding)
                 + (2 * 4) {- def, n -}
                 + 8 * length xs {- pairs -}
  _ -> len
  where
    len = fromIntegral . B.length . encodeInstructions . (:[]) $ x

incrementPC :: J.Instruction -> LabelState ()
incrementPC ins = modify (\s -> s { pcOffset = pcOffset s + insnLength ins})

resetPC :: [J.Instruction] -> LabelState ()
resetPC jvmins = do
  modify (\s -> s { pcOffset = 0, instructions = jvmins })

-- helper
apush2 :: Var -> LabelState ()
apush2 x = do
  st <- simStack <$> get
  let st' = st { stack = x : (stack st) }
  modify (\s -> s { simStack = st'})

apop2 :: LabelState Var
apop2 = do
  st <- get
  let lol = simStack st
  when (null . stack $ lol) $ error "apop2: something is really wrong here"
  modify (\s -> s { simStack = lol { stack = tail (stack lol)} } )
  return . head . stack $ lol

imm2num :: Num a => IMM -> a
imm2num I0 = 0
imm2num I1 = 1
imm2num I2 = 2
imm2num I3 = 3

fieldType :: Class Direct -> Word16 -> VarType
fieldType cls off = fieldType2VarType $ ntSignature nt
  where nt = case constsPool cls M.! off of
                (CField _ nt') -> nt'
                _ -> error "fieldType: fail :("

methodType :: Bool -> Class Direct -> Word16 -> ([VarType], Maybe VarType)
methodType isVirtual cls off = (map fieldType2VarType argst', rett)
  where
    argst' = if isVirtual then (ObjectType "lol"):argst else argst
    (MethodSignature argst returnt) =
      case constsPool cls M.! off of
        (CMethod _ nt') -> ntSignature nt'
        (CIfaceMethod _ nt') -> ntSignature nt'
        _ -> error "methodType: fail :("
    rett = case returnt of
            Returns ft -> Just (fieldType2VarType ft)
            ReturnsVoid -> Nothing

methodIsStatic :: Method Direct -> Bool
methodIsStatic = S.member ACC_STATIC . methodAccessFlags

methodArgs :: Num a => Method Direct -> a
methodArgs meth = isStatic $ L.genericLength args
  where
    (MethodSignature args _) = methodSignature meth
    isStatic = if methodIsStatic meth then (+0) else (+1)

fieldType2VarType :: FieldType -> VarType
fieldType2VarType IntType = JInt
fieldType2VarType CharByte = JChar
fieldType2VarType BoolType = JInt -- TODO: is this okay?
fieldType2VarType FloatType = JFloat
fieldType2VarType (ObjectType _) = JRef
fieldType2VarType (Array _ _) = JRef -- fieldType2VarType ty -- TODO
fieldType2VarType x = error $ "fieldType2VarType: " ++ show x

tir :: J.Instruction -> State SimStack [MateIR Var O O]
tir ACONST_NULL = do apush $ JRefNull; return []
tir ICONST_M1 = tir (BIPUSH 0xff) -- (-1)
tir ICONST_0 = tir (BIPUSH 0)
tir ICONST_1 = tir (BIPUSH 1)
tir ICONST_2 = tir (BIPUSH 2)
tir ICONST_3 = tir (BIPUSH 3)
tir ICONST_4 = tir (BIPUSH 4)
tir ICONST_5 = tir (BIPUSH 5)
tir (BIPUSH x) = do apush $ JIntValue (w82i32 x); return []
tir (SIPUSH x) = do apush $ JIntValue (w162i32 x); return []
tir FCONST_0 =  do apush $ JFloatValue 0; return []
tir FCONST_1 =  do apush $ JFloatValue 1; return []
tir FCONST_2 =  do apush $ JFloatValue 3; return []
tir (ILOAD_ x) = tir (ILOAD (imm2num x))
tir (ILOAD x) = tirLoad x JInt
tir (IINC x con) = do
  tirLoad' x JInt
  y <- apop
  nv <- newvar JInt
  apush nv
  storeinsn <- tirStore x JInt
  return $ [IROp Add nv y (JIntValue (w82i32 con))] ++ storeinsn
tir (ALOAD_ x) = tir (ALOAD (imm2num x))
tir (ALOAD x) = tirLoad x JRef
tir (FLOAD_ x) = tir (FLOAD (imm2num x))
tir (FLOAD x) = tirLoad x JFloat
tir (ISTORE_ x) = tir (ISTORE (imm2num x))
tir (ISTORE y) = tirStore y JInt
tir (FSTORE_ y) = tir (FSTORE (imm2num y))
tir (FSTORE y) = tirStore y JFloat
tir (ASTORE_ x) = tir (ASTORE (imm2num x))
tir (ASTORE x) = tirStore x JRef
tir (PUTFIELD x) = do
  src <- apop
  obj <- apop
  unless (JRef == varType obj) $ error "putfield: type mismatch"
  -- TODO: char shit...
  -- cls <- classf <$> get
  -- unless (fieldType cls x == varType src) $ error "putfield: type mismatch2"
  return [IRStore (RTPool x) obj src]
tir (GETFIELD x) = do
  obj <- apop
  unless (JRef == varType obj) $ error "getfield: type mismatch"
  cls <- classf <$> get
  nv <- newvar (fieldType cls x)
  apush nv
  return [IRLoad (RTPool x) obj nv]
tir (GETSTATIC x) = do
  cls <- classf <$> get
  nv <- newvar (fieldType cls x)
  apush nv
  return [IRLoad (RTPool x) JRefNull nv]
tir (PUTSTATIC x) = do
  y <- apop
  return [IRStore (RTPool x) JRefNull y]
tir (LDC1 x) = tir (LDC2 (fromIntegral x))
tir (LDC2 x) = do
  cls <- classf <$> get
  let valuetype = case constsPool cls M.! x of
            (CString _) -> JRef
            (CInteger _) -> JInt
            e -> error $ "tir: LDCI... missing impl.: " ++ show e
  nv <- newvar valuetype
  apush nv
  return [IRLoad (RTPool x) JRefNull nv]
tir (NEW x) = do
  nv <- newvar JRef
  apush nv
  return [IRLoad (RTPoolCall x []) JRefNull nv]
tir (ANEWARRAY _) = tirArray ReferenceType 10 -- for int. TODO?
tir (NEWARRAY w8) = tirArray PrimitiveType w8
tir ARRAYLENGTH = do
  arr <- apop
  when (varType arr /= JRef) $ error "tir: arraylength: type mismatch"
  nv <- newvar JInt
  apush nv
  return [IRLoad RTNone arr nv]
tir AALOAD = tirArrayLoad JRef
tir IALOAD = tirArrayLoad JInt
tir CALOAD = tirArrayLoad JChar
tir AASTORE = tirArrayStore JRef
tir IASTORE = tirArrayStore JInt
tir CASTORE = tirArrayStore JChar
tir DUP = do
  x <- apop
  apush x
  nv <- newvar (varType x)
  apush nv
  return [IROp Add nv x (JIntValue 0)]
tir DUP_X2 = do
  -- WARNING: different behaviour for LONG & DOUBLE!!
  -- see, category 2 computational type (§2.11.1).
  v1 <- apop; v2 <- apop; v3 <- apop
  nv <- newvar (varType v1)
  apush nv
  apush v3; apush v2; apush v1
  return [IROp Add nv v1 (JIntValue 0)]
tir POP = do apop; return []
tir IADD = tirOpInt Add JInt
tir ISUB = tirOpInt Sub JInt
tir IMUL = tirOpInt Mul JInt
tir IDIV = tirOpInt Div JInt
tir IREM = tirOpInt Rem JInt
tir IAND = tirOpInt And JInt
tir IOR = tirOpInt Or JInt
tir IXOR = tirOpInt Xor JInt
tir IUSHR = tirOpInt ShiftRightLogical JInt
tir ISHR = tirOpInt ShiftRightArth JInt
tir ISHL = tirOpInt ShiftLeft JInt
tir FADD = tirOpInt Add JFloat
tir I2C = do
  x <- apop
  when (varType x /= JInt) $ error "tir: i2c: type mismatch"
  nv <- newvar JChar
  apush nv
  return [IROp Add nv x (JIntValue 0)]
tir (INVOKESTATIC ident) = tirInvoke CallStatic ident
tir (INVOKESPECIAL ident) = tirInvoke CallSpecial ident
tir (INVOKEVIRTUAL ident) = tirInvoke CallVirtual ident
tir (INVOKEINTERFACE ident _) = tirInvoke CallInterface ident
tir i@(CHECKCAST _) = do
  y <- apop
  apush y
  return [IRMisc1 i y]
tir i@(INSTANCEOF _) = do
  y <- apop
  nv <- newvar JInt
  apush nv
  return [IRMisc2 i nv y]
tir i@ATHROW = do
  y <- apop
  return [IRMisc1 i y]
tir x = error $ "tir: " ++ show x

tirArray :: MateObjType -> Word8 -> State SimStack [MateIR Var O O]
tirArray objtype w8 = do
  len <- apop
  let len' = case len of
              JIntValue x -> fromIntegral x
              x -> error $ "tir: anewarray: len is not constant: " ++ show x
  nv <- newvar JRef
  apush nv
  return [IRLoad (RTArray w8 objtype [] len') JRefNull nv]

tirArrayLoad :: VarType -> State SimStack [MateIR Var O O]
tirArrayLoad t = do
  idx <- apop
  arr <- apop
  when (varType arr /= JRef) $ error "tir: aaload: type mismatch1"
  when (varType idx /= JInt) $ error "tir: aaload: type mismatch2"
  nv <- newvar t
  apush nv
  case t of
    JChar -> do
      _ <- apop
      nv' <- newvar JChar
      apush nv'
      return [ IRLoad (RTIndex idx t) arr nv
             , IROp And nv' nv (JIntValue 0xff)]
    _ -> return [IRLoad (RTIndex idx t) arr nv]

tirArrayStore :: VarType -> State SimStack [MateIR Var O O]
tirArrayStore t = do
  value <- apop
  idx <- apop
  arr <- apop
  -- TODO: WTF?
  when (varType arr /= JRef) $ error $ "tir: tirArrayStore: type mismatch1: " ++ show (varType arr)
  when (varType idx /= JInt) $ error $ "tir: tirArrayStore: type mismatch2: " ++ show (varType idx)
  -- TODO: `char arr[] = new char[1]; arr[0] = 0x1337'
  --       is legal and withouth I2C.
  -- when (varType value /= t) $ error $ "tir: tirArrayStore: type mismatch3: " ++ show t
  case t of
    JChar -> do
      nv <- newvar JChar
      return [ IROp And nv value (JIntValue 0xff)
             , IRStore (RTIndex idx t) arr nv ]
    _ -> return [IRStore (RTIndex idx t) arr value]

tirInvoke :: CallType -> Word16 -> State SimStack [MateIR Var O O]
tirInvoke ct ident = do
  cls <- classf <$> get
  let (varts, mret) = methodType (ct /= CallStatic) cls ident
  pushes <- tracePipe (printf "tirInvoke: varts: %s returns %s\n" (show varts) (show mret)) $
            forM (reverse $ zip varts [0..]) $ \(x, nr) -> do
    y <- apop
    -- TODO: char shit...
    -- unless (x == varType y) $ error "invoke: type mismatch"
    case x of
      JChar -> return $ IRPush nr y
      JInt -> return $ IRPush nr y
      JRef -> return $ IRPush nr y
      JFloat -> do
        let nr8 = fromIntegral nr
        let nri = fromIntegral nr
        let assign = preFloats !! nri
        modify (\s -> s { preRegs = (assign, (HFReg $ XMMReg nr8, JFloat))
                                    : (preRegs s) })
        return $ IROp Add (VReg x assign) y (JFloatValue 0) -- mov
  (targetreg, maybemov) <- case mret of
    Just x -> do
      let prereg = case x of
                      JInt -> preeax
                      JFloat -> prexmm7
                      JRef -> preeax
                      y -> error $ "tirInvoke: prereg: " ++ show y
      let nv = VReg x prereg
      movtarget <- newvar x
      tracePipe(printf "return: %s@%s\n" (show prereg) (show x)) $apush movtarget
      let movretval = IROp Add movtarget nv (JIntValue 0)
      return (Just nv, Just movretval)
    Nothing -> return (Nothing, Nothing)
  let r = (IRPrep SaveRegs S.empty): pushes ++
          [IRInvoke (RTPoolCall ident []) targetreg ct, IRPrep RestoreRegs S.empty]
  case maybemov of
    Nothing -> return r
    Just m -> return $ r ++ [m]

tirLoad' :: Word8 -> VarType -> State SimStack ()
tirLoad' x t = do
  vreg <- maybeArgument x t
  apush vreg

nul :: VarType -> Var
nul t = case t of
  JInt -> JIntValue 0
  JFloat -> JFloatValue 0
  JRef -> JRefNull
  x -> error $ "tirLoad: nul: " ++ show x

tirLoad :: Word8 -> VarType -> State SimStack [MateIR Var O O]
tirLoad x t = do
  tirLoad' x t
  vreg <- apop
  nv <- newvar t
  apush nv
  return [IROp Add nv vreg (nul t)]

maybeArgument :: Word8 -> VarType -> State SimStack Var
maybeArgument x t = do
  meth <- method <$> get
  let genVReg :: (Disp -> HVar) -> Integer
              -> Word8 -> VarType
              -> (Integer, (HVar, VarType))
      genVReg constructor a w8 t' =
        (a,
           (constructor . Disp . (+0xc) . fromIntegral $ (ptrSize * w8)
           , t'))
  if x < methodArgs meth
    then do
      case t of
       JFloat -> do
         let assign = preFloats !! (fromIntegral x)
         let tup = (assign, (HFReg . XMMReg . fromIntegral $ x, JFloat))
         modify (\s -> s { preRegs = tup : (preRegs s) })
         return $ VReg t assign
       JRef -> do
         let assign = preArgs !! (fromIntegral x)
         let tup = genVReg SpillRReg assign x JInt
         modify (\s -> s { preRegs = tup : (preRegs s) })
         return $ VReg t assign
       JInt -> do
         let assign = preArgs !! (fromIntegral x)
         let tup = genVReg SpillIReg assign x JInt
         modify (\s -> s { preRegs = tup : (preRegs s) })
         return $ VReg t assign
       JChar -> do
         let assign = preArgs !! (fromIntegral x)
         let tup = genVReg SpillIReg assign x JInt
         modify (\s -> s { preRegs = tup : (preRegs s) })
         return $ VReg t assign
    else return $ VReg t (fromIntegral x)


tirStore :: Word8 -> VarType -> State SimStack [MateIR Var O O]
tirStore w8 t = do
  x <- apop
  unless (t == varType x) $ error "tirStore: type mismatch"
  vreg <- maybeArgument w8 t
  return [IROp Add vreg x (nul t)]

tirOpInt :: OpType -> VarType -> State SimStack [MateIR Var O O]
tirOpInt op t = do
  x <- apop; y <- apop
  nv <- newvar t; apush nv
  -- TODO: char ...
  -- unless (t == varType x && t == varType y) $ error "tirOpInt: type mismatch"
  return [IROp op nv x y]

newvar :: VarType -> State SimStack Var
newvar t = do
  sims <- get
  put $ sims { regcnt = regcnt sims + 1 }
  return $ VReg t $ regcnt sims

apush :: Var -> State SimStack ()
apush x = do
  s <- stack <$> get
  sims <- get
  put $ sims { stack = x : s }

apop :: State SimStack Var
apop = do
  simstack <- stack <$> get
  when (null simstack) $ error "apop: stack is empty"
  (s:ss) <- stack <$> get
  modify (\m -> m { stack = ss })
  return s
