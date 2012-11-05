{-# LANGUAGE GADTs #-}
module Compiler.Mate.Frontend.StupidRegisterAllocation
  ( preeax
  , prexmm7
  , preFloats
  , preArgs
  , stupidRegAlloc
  , ptrSize -- TODO...
  ) where

import qualified Data.List as L
import qualified Data.Set as S
import qualified Data.Map as M
import Data.Maybe
import Data.Word

import Control.Applicative
import Control.Monad.State

import Harpy hiding (Label)

import Compiler.Mate.Frontend.IR
import Compiler.Mate.Frontend.Linear

{- regalloc PoC -}
data MappedRegs = MappedRegs
  { regMap :: M.Map Integer HVar
  , regsUsed :: S.Set HVar -- for fast access
  , stackCnt :: Word32 }

ptrSize :: Num a => a
ptrSize = 4

{- pre assign hardware registers -}
preeax, prexmm7, preArgsLength, preArgsStart :: Integer
preeax = 99999
prexmm7 = 100000
preArgsLength = 6
preArgsStart = 200000
preArgs :: [Integer]
preArgs = [preArgsStart .. (preArgsStart + preArgsLength - 1)]

preAssignedRegs :: M.Map Integer HVar
preAssignedRegs = M.fromList $
                  [ (preeax,  HIReg eax)
                  , (prexmm7, HFReg xmm7)
                  ]

-- calling convention for floats is different: arguments are passed via xmm
-- registers, while int arguements are passed via stack slots

preFloatStart :: Integer
preFloatStart = 300000
preFloats :: [Integer]
preFloats = [preFloatStart .. (preFloatStart + 5)]

emptyRegs :: MappedRegs
emptyRegs = MappedRegs preAssignedRegs S.empty (0xfffffffc) -- TODO: stack space...

allIntRegs, allFloatRegs :: S.Set HVar
-- register usage:
-- - eax as scratch/int return
-- - esp/ebp for stack (TODO: maybe we can elimate ebp usage?)
-- - xmm7 as scratch/float return
allIntRegs = S.fromList $ map HIReg [ecx, edx, ebx, esi, edi]
allFloatRegs = S.fromList $ map HFReg [xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6]

stupidRegAlloc :: [(Integer, HVar)] -> [LinearIns Var] -> [LinearIns HVar]
stupidRegAlloc preAssigned linsn = evalState regAlloc' startmapping
  where
    startassign = M.union (regMap emptyRegs) (M.fromList preAssigned)
    startmapping = emptyRegs { regMap = startassign
                             , regsUsed = S.filter regsonly
                                        $ S.fromList
                                        $ M.elems startassign }
    regAlloc' = mapM assignReg linsn

    rtRepack :: RTPool Var -> State MappedRegs (RTPool HVar)
    rtRepack (RTPool w16) = return $ RTPool w16
    rtRepack (RTArray w8 w32) = return $ RTArray w8 w32
    rtRepack (RTIndex vreg typ) = do
      newreg <- doAssign vreg
      return $ RTIndex newreg typ
    rtRepack RTNone = return RTNone

    assignReg :: LinearIns Var -> State MappedRegs (LinearIns HVar)
    assignReg lv = case lv of
      Fst x -> case x of
        IRLabel x' -> return $ Fst $ IRLabel x'
      Mid ins -> case ins of
        IROp op dst src1 src2 -> do
          dstnew <- doAssign dst
          src1new <- doAssign src1
          src2new <- doAssign src2
          return $ Mid $ IROp op dstnew src1new src2new
        IRStore rt obj src -> do
          objnew <- doAssign obj
          srcnew <- doAssign src
          nrt <- rtRepack rt
          return $ Mid $ IRStore nrt objnew srcnew
        IRLoad rt obj dst -> do
          objnew <- doAssign obj
          dstnew <- doAssign dst
          nrt <- rtRepack rt
          return $ Mid $ IRLoad nrt objnew dstnew
        IRMisc1 jins src -> do
          srcnew <- doAssign src
          return $ Mid $ IRMisc1 jins srcnew
        IRMisc2 jins dst src -> do
          dstnew <- doAssign dst
          srcnew <- doAssign src
          return $ Mid $ IRMisc2 jins dstnew srcnew
        IRPrep typ _ -> do
          ru <- regsInUse JInt -- TODO: float
          return $ Mid $ IRPrep typ ru
        IRPush nr src -> do
          srcnew <- doAssign src
          return $ Mid $ IRPush nr srcnew
        IRInvoke rt (Just r) ct -> do
          rnew <- Just <$> doAssign r
          nrt <- rtRepack rt
          return $ Mid $ IRInvoke nrt rnew ct
        IRInvoke rt Nothing ct -> do
          nrt <- rtRepack rt
          return $ Mid $ IRInvoke nrt Nothing ct
      Lst ins -> case ins of
        IRJump l -> return $ Lst $ IRJump l
        IRIfElse jcmp cmp1 cmp2 l1 l2 -> do
          cmp1new <- doAssign cmp1
          cmp2new <- doAssign cmp2
          return $ Lst $ IRIfElse jcmp cmp1new cmp2new l1 l2
        IRReturn (Just b) -> do
          bnew <- Just <$> doAssign b
          return $ Lst $ IRReturn bnew
        IRReturn Nothing -> return $ Lst $ IRReturn Nothing

    regsonly :: HVar -> Bool
    regsonly (HIReg _) = True
    regsonly (HFReg _) = True
    regsonly _ = False

    regsInUse :: VarType -> State MappedRegs (S.Set HVar)
    regsInUse t = do
      mr <- regsUsed <$> get
      let unpackIntReg :: HVar -> Bool
          unpackIntReg (HIReg _) = True
          unpackIntReg _ = False
      let unpackFloatReg :: HVar -> Bool
          unpackFloatReg (HFReg _) = True
          unpackFloatReg _ = False
      let unpacker = case t of
                       JChar -> unpackIntReg
                       JInt -> unpackIntReg
                       JRef -> unpackIntReg
                       JFloat -> unpackFloatReg
      return . S.filter unpacker $ mr

    doAssign :: Var -> State MappedRegs HVar
    doAssign (JIntValue x) = return $ HIConstant x
    doAssign JRefNull = return $ HIConstant 0
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
          if S.null availregs
            then do
              let disp = stackCnt mr
              let spill = case t of
                            JChar -> SpillIReg (Disp disp)
                            JInt -> SpillIReg (Disp disp)
                            JFloat -> SpillFReg (Disp disp)
                            JRef -> SpillRReg (Disp disp)
              let imap = M.insert vreg spill $ regMap mr
              put (mr { stackCnt = disp - 4
                      , regMap = imap} )
              return spill
            else do
              let x = S.findMin availregs
              let imap = M.insert vreg x $ regMap mr
              put (mr { regMap = imap
                      , regsUsed = S.insert x availregs })
              return x
        nextAvailReg _ = error "intNextReg: dafuq"

        availRegs :: VarType -> State MappedRegs (S.Set HVar)
        availRegs t = do
          inuse <- regsInUse t
          let allregs = case t of
                  JChar -> allIntRegs
                  JInt -> allIntRegs
                  JRef -> allIntRegs
                  JFloat -> allFloatRegs
          return (allregs S.\\ inuse)


{- /regalloc -}
