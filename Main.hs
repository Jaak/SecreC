{-# LANGUAGE DeriveDataTypeable #-}
{-# OPTIONS_GHC -fno-cse #-}

module Main where

import qualified Data.List as List
import Data.List.Split

import Language.SecreC.Pretty
import Language.SecreC.Syntax
import Language.SecreC.Position
import Language.SecreC.Modules
import Language.SecreC.TypeChecker.Base
import Language.SecreC.TypeChecker
import Language.SecreC.Monad
import Language.SecreC.Utils

import System.Console.CmdArgs
import System.Environment

import Control.Monad
import Control.Monad.IO.Class

-- * main function

main :: IO ()
main = do
    opts <- getOpts
    case opts of
        Help     -> printHelp
        Opts  {} -> secrec opts

-- * front-end options

opts  :: Options
opts  = Opts { 
      inputs                = def &= args &= typ "FILE.sc"
    , outputs               = def &= typ "FILE1.sc:...:FILE2.sc" &= help "Output SecreC files"
    , paths                 = def &= typ "DIR1:...:DIRn" &= help "Import paths for input SecreC program"
    , parser                = Parsec &= typ "parsec OR derp" &= "backend Parser type"
    , knowledgeInference    = def &= name "ki" &= help "Infer private data from public data" &= groupname "Optimization"
    , typeCheck             = True &= name "tc" &= help "Typecheck the SecreC input" &= groupname "Verification"
    , debugLexer            = def &= name "debug-lexer" &= explicit &= help "Print lexer tokens to stderr" &= groupname "Debugging"
    , debugParser            = def &= name "debug-parser" &= explicit &= help "Print parser result to stderr" &= groupname "Debugging"
    }
    &= help "SecreC analyser"

chelp :: Options
chelp = Help
     &= help "Display help about SecreC modes"

mode  :: Mode (CmdArgs Options)
mode  = cmdArgsMode $
           modes [opts &= auto, chelp]
        &= help "SecreC analyser"
        &= summary "secrec v0.1 \n\
                   \(C) PRACTICE TEAM 2015 - DI/HasLab - Univ. Minho,\
                   \ Braga, Portugal"

printHelp :: IO ()
printHelp = withArgs ["--help"] $ cmdArgsRun mode >> return ()

getOpts :: IO Options
getOpts = getArgs >>= doGetOpts
    where 
    doGetOpts as
        | null as   = withArgs ["help"] $ cmdArgsRun mode
        | otherwise = liftM processOpts $ cmdArgsRun mode

processOpts :: Options -> Options
processOpts opts = Opts
    (inputs opts)
    (parsePaths $ outputs opts)
    (parsePaths $ paths opts)
    (knowledgeInference opts)
    (typeCheck opts || knowledgeInference opts)
    (debugLexer opts)
    (debugParser opts)

parsePaths :: [FilePath] -> [FilePath]
parsePaths = concatMap (splitOn ":")

-- back-end code

data OutputType = OutputFile FilePath | OutputStdout | NoOutput
  deriving (Show,Read,Data,Typeable)

defaultOutputType = NoOutput

-- | Set output mode for processed modules:
-- * inputs with explicit output files write to the file
-- * inputs without explicit output files write to stdout
-- * non-input modules do not output
resolveOutput :: [FilePath] -> [FilePath] -> [Module Position] -> [(Module Position,OutputType)]
resolveOutput inputs outputs modules = map res modules
    where
    db = zipLeft secrecFiles (outputs opts) 
    res m = case List.find (moduleFile m) db of
        Just (Just o) -> OutputFile o
        Just Nothing -> OutputStdout
        Nothing -> NoOutput

secrec :: Options -> IO ()
secrec opts = do
    let secrecFiles = inputs opts
    when (List.null secrecFiles) $ error "no SecreC input files"
    ioSecrecM opts $ do
        modules <- parseModuleFiles secrecFiles
        moduleso <- resolveOutput inputs outputs modules
        when (typeCheck opts) $ runTcM $ do
            typedModulesO <- mapFstM tcModule moduleso
            return ()

secreCOutput :: Options -> Module loc -> IO ()
secreCOutput opts ast = case output opts of
    Nothing -> putStrLn (ppr ast)
    Just output -> writeFile output (ppr ast)
    