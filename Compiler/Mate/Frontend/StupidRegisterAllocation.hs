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
emptyRegs = MappedRegs preAssignedRegs 0

allIntRegs, allFloatRegs :: [HVar]
-- register usage:
-- - eax as scratch/int return
-- - esp/ebp for stack (TODO: maybe we can elimate ebp usage?)
-- - xmm7 as scratch/float return
allIntRegs = map HIReg [ecx, edx, ebx, esi, edi] :: [HVar]
allFloatRegs = map HFReg [xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6] :: [HVar]

stupidRegAlloc :: [(Integer, HVar)] -> [LinearIns Var] -> [LinearIns HVar]
stupidRegAlloc preAssigned linsn = evalState regAlloc' startmapping
  where
    startmapping = emptyRegs { regMap = M.union (regMap emptyRegs) (M.fromList preAssigned) }
    regAlloc' = mapM assignReg linsn
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
          return $ Mid $ IRStore rt objnew srcnew
        IRLoad rt obj dst -> do
          objnew <- doAssign obj
          dstnew <- doAssign dst
          return $ Mid $ IRLoad rt objnew dstnew
        IRNop -> return $ Mid $ IRNop
        IRPrep typ [] -> do
          intuse <- regsInUse JInt -- TODO: float
          return $ Mid $ IRPrep typ (intuse `L.intersect` allIntRegs)
        IRPush nr src -> do
          srcnew <- doAssign src
          return $ Mid $ IRPush nr srcnew
        IRInvoke b (Just r) -> do
          rnew <- Just <$> doAssign r
          return $ Mid $ IRInvoke b rnew
        IRInvoke b Nothing -> return $ Mid $ IRInvoke b Nothing
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

    regsInUse :: VarType -> State MappedRegs [HVar]
    regsInUse t = do
      mr <- M.elems <$> regMap <$> get
      let unpackIntReg :: HVar -> Maybe HVar
          unpackIntReg x@(HIReg _) = Just x
          unpackIntReg _ = Nothing
      let unpackFloatReg :: HVar -> Maybe HVar
          unpackFloatReg x@(HFReg _) = Just x
          unpackFloatReg _ = Nothing
      let unpacker = case t of
                       JInt -> unpackIntReg
                       JRef -> unpackIntReg
                       JFloat -> unpackFloatReg
      return . mapMaybe unpacker $ mr

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
          case availregs of
            [] -> do
              let disp = stackCnt mr
              let spill = case t of
                            JInt -> SpillIReg (Disp disp)
                            JFloat -> SpillFReg (Disp disp)
                            JRef -> SpillRReg (Disp disp)
              let imap = M.insert vreg spill $ regMap mr
              put (mr { stackCnt = disp + 4, regMap = imap} )
              return spill
            (x:_) -> do
              let imap = M.insert vreg x $ regMap mr
              put (mr { regMap = imap })
              return x
        nextAvailReg _ = error "intNextReg: dafuq"

        availRegs :: VarType -> State MappedRegs [HVar]
        availRegs t = do
          inuse <- regsInUse t
          let allregs = case t of
                  JInt -> allIntRegs
                  JRef -> allIntRegs
                  JFloat -> allFloatRegs
          return (allregs L.\\ inuse)
{- /regalloc -}
