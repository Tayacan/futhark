{-# LANGUAGE FlexibleContexts #-}

-- | All (almost) compiler pipelines end with an 'Action', which does
-- something with the result of the pipeline.
module Futhark.Actions
  ( printAction,
    impCodeGenAction,
    kernelImpCodeGenAction,
    metricsAction,
    compileCAction,
    compileOpenCLAction,
    compileCUDAAction,
    sexpAction,
  )
where

import Control.Monad
import Control.Monad.IO.Class
import qualified Data.ByteString.Lazy.Char8 as ByteString
import Futhark.Analysis.Alias
import Futhark.Analysis.Metrics
import qualified Futhark.CodeGen.Backends.CCUDA as CCUDA
import qualified Futhark.CodeGen.Backends.COpenCL as COpenCL
import qualified Futhark.CodeGen.Backends.SequentialC as SequentialC
import qualified Futhark.CodeGen.ImpGen.Kernels as ImpGenKernels
import qualified Futhark.CodeGen.ImpGen.Sequential as ImpGenSequential
import Futhark.Compiler.CLI
import Futhark.IR
import Futhark.IR.KernelsMem (KernelsMem)
import Futhark.IR.Prop.Aliases
import Futhark.IR.SeqMem (SeqMem)
import Futhark.Util (runProgramWithExitCode)
import Language.SexpGrammar as Sexp
import System.Exit
import System.FilePath
import qualified System.Info

-- | Print the result to stdout, with alias annotations.
printAction :: (ASTLore lore, CanBeAliased (Op lore)) => Action lore
printAction =
  Action
    { actionName = "Prettyprint",
      actionDescription = "Prettyprint the resulting internal representation on standard output.",
      actionProcedure = const . liftIO . putStrLn . pretty . aliasAnalysis
    }

-- | Print metrics about AST node counts to stdout.
metricsAction :: OpMetrics (Op lore) => Action lore
metricsAction =
  Action
    { actionName = "Compute metrics",
      actionDescription = "Print metrics on the final AST.",
      actionProcedure = const . liftIO . putStr . show . progMetrics
    }

-- | Convert the program to sequential ImpCode and print it to stdout.
impCodeGenAction :: Action SeqMem
impCodeGenAction =
  Action
    { actionName = "Compile imperative",
      actionDescription = "Translate program into imperative IL and write it on standard output.",
      actionProcedure = const . (liftIO . putStrLn . pretty . snd <=< ImpGenSequential.compileProg)
    }

-- | Convert the program to GPU ImpCode and print it to stdout.
kernelImpCodeGenAction :: Action KernelsMem
kernelImpCodeGenAction =
  Action
    { actionName = "Compile imperative kernels",
      actionDescription = "Translate program into imperative IL with kernels and write it on standard output.",
      actionProcedure = const . (liftIO . putStrLn . pretty . snd <=< ImpGenKernels.compileProgOpenCL)
    }

-- | Print metrics about AST node counts to stdout.
sexpAction :: ASTLore lore => Action lore
sexpAction =
  Action
    { actionName = "Print sexps",
      actionDescription = "Print sexps on the final IR.",
      actionProcedure = const . liftIO . helper
    }
  where
    helper :: ASTLore lore => Prog lore -> IO ()
    helper prog =
      case encodePretty prog of
        Right prog' -> do
          ByteString.putStrLn prog'
          let prog'' = decode prog'
          unless (prog'' == Right prog) $
            error $
              "S-exp not isomorph!\n"
                ++ either show pretty prog''
        Left s ->
          error $ "Couldn't encode program: " ++ s

-- | The @futhark c@ action.
compileCAction :: FutharkConfig -> CompilerMode -> FilePath -> Action SeqMem
compileCAction fcfg mode outpath =
  Action
    { actionName = "Compile sequential C",
      actionDescription = "Compile sequential C",
      actionProcedure = helper
    }
  where
    helper prog foreignCode = do
      cprog <- handleWarnings fcfg $ SequentialC.compileProg prog
      let cpath = outpath `addExtension` "c"
          hpath = outpath `addExtension` "h"
      case mode of
        ToLibrary -> do
          let (header, impl) = SequentialC.asLibrary cprog
          liftIO $ writeFile hpath header
          liftIO $ writeFile cpath $ fullImpl impl foreignCode
        ToExecutable -> do
          let impl = SequentialC.asExecutable cprog
          liftIO $ writeFile cpath $ fullImpl impl foreignCode
          ret <-
            liftIO $
              runProgramWithExitCode
                "gcc"
                [cpath, "-O3", "-std=c99", "-lm", "-o", outpath]
                mempty
          case ret of
            Left err ->
              externalErrorS $ "Failed to run gcc: " ++ show err
            Right (ExitFailure code, _, gccerr) ->
              externalErrorS $
                "gcc failed with code "
                  ++ show code
                  ++ ":\n"
                  ++ gccerr
            Right (ExitSuccess, _, _) ->
              return ()

    fullImpl :: String -> String -> String
    fullImpl impl foreignCode =
      case futharkForeignInput fcfg of
        Just fp ->
          impl
          ++ "// Foreign code"
          ++ "\n"
          ++ "#line 0 "
          ++ "\""
          ++ (last $ splitPath fp)
          ++ "\""
          ++ "\n"
          ++ foreignCode
        Nothing -> impl

-- | The @futhark opencl@ action.
compileOpenCLAction :: FutharkConfig -> CompilerMode -> FilePath -> Action KernelsMem
compileOpenCLAction fcfg mode outpath =
  Action
    { actionName = "Compile to OpenCL",
      actionDescription = "Compile to OpenCL",
      actionProcedure = const . helper
    }
  where
    helper prog = do
      cprog <- handleWarnings fcfg $ COpenCL.compileProg prog
      let cpath = outpath `addExtension` "c"
          hpath = outpath `addExtension` "h"
          extra_options
            | System.Info.os == "darwin" =
              ["-framework", "OpenCL"]
            | System.Info.os == "mingw32" =
              ["-lOpenCL64"]
            | otherwise =
              ["-lOpenCL"]

      case mode of
        ToLibrary -> do
          let (header, impl) = COpenCL.asLibrary cprog
          liftIO $ writeFile hpath header
          liftIO $ writeFile cpath impl
        ToExecutable -> do
          liftIO $ writeFile cpath $ COpenCL.asExecutable cprog
          ret <-
            liftIO $
              runProgramWithExitCode
                "gcc"
                ([cpath, "-O", "-std=c99", "-lm", "-o", outpath] ++ extra_options)
                mempty
          case ret of
            Left err ->
              externalErrorS $ "Failed to run gcc: " ++ show err
            Right (ExitFailure code, _, gccerr) ->
              externalErrorS $
                "gcc failed with code "
                  ++ show code
                  ++ ":\n"
                  ++ gccerr
            Right (ExitSuccess, _, _) ->
              return ()

-- | The @futhark cuda@ action.
compileCUDAAction :: FutharkConfig -> CompilerMode -> FilePath -> Action KernelsMem
compileCUDAAction fcfg mode outpath =
  Action
    { actionName = "Compile to CUDA",
      actionDescription = "Compile to CUDA",
      actionProcedure = const . helper
    }
  where
    helper prog = do
      cprog <- handleWarnings fcfg $ CCUDA.compileProg prog
      let cpath = outpath `addExtension` "c"
          hpath = outpath `addExtension` "h"
          extra_options =
            [ "-lcuda",
              "-lcudart",
              "-lnvrtc"
            ]
      case mode of
        ToLibrary -> do
          let (header, impl) = CCUDA.asLibrary cprog
          liftIO $ writeFile hpath header
          liftIO $ writeFile cpath impl
        ToExecutable -> do
          liftIO $ writeFile cpath $ CCUDA.asExecutable cprog
          let args =
                [cpath, "-O", "-std=c99", "-lm", "-o", outpath]
                  ++ extra_options
          ret <- liftIO $ runProgramWithExitCode "gcc" args mempty
          case ret of
            Left err ->
              externalErrorS $ "Failed to run gcc: " ++ show err
            Right (ExitFailure code, _, gccerr) ->
              externalErrorS $
                "gcc failed with code "
                  ++ show code
                  ++ ":\n"
                  ++ gccerr
            Right (ExitSuccess, _, _) ->
              return ()
