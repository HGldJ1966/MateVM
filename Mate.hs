{-# LANGUAGE OverloadedStrings #-}
module Main where

import System.Environment
import Data.Char
import Data.String.Utils
import Data.List
import qualified Data.ByteString.Lazy as B

import Text.Printf

import JVM.ClassFile
import JVM.Converter
import JVM.Dump

import Mate.BasicBlocks
import Mate.X86CodeGen
import Mate.MethodPool
import Mate.Types

main ::  IO ()
main = do
  args <- getArgs
  register_signal
  initMethodPool
  case args of
    [clspath] -> do
      cls <- parseClassFile clspath
      dumpClass cls
      hmap <- parseMethod cls "main"
      printMapBB hmap
      case hmap of
        Just hmap' -> do
          let methods = classMethods cls; methods :: [Method Resolved]
          let method = find (\x -> (methodName x) == "main") methods
          case method of
            Just m -> do
              let bclspath = B.pack $ map (fromIntegral . ord) (replace ".class" "" clspath)
              entry <- compileBB hmap' (MethodInfo "main" bclspath (methodSignature m))
              printf "executing `main' now:\n"
              executeFuncPtr entry
            Nothing -> error "main not found"
        Nothing -> error "main not found"
    _ -> error "Usage: mate <class-file>"
