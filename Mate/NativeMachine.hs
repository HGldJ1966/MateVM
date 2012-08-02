{-# LANGUAGE CPP #-}
module Mate.NativeMachine(
  emitFromBB,
  mateHandler,
  register_signal,
  ptrSize, longSize
  )where

#ifdef i386_HOST_ARCH
import Mate.X86CodeGen
import Mate.X86TrapHandling
import Mate.NativeSizes

#else
#error "no other arch supported yet :/"
#endif
