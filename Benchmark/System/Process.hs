{-# LANGUAGE  ScopedTypeVariables #-}

module Main (main) where

import Control.Exception (finally)
import Data.Either (isRight, fromRight, isLeft, fromLeft)
import Data.Word (Word8)
import Gauge (defaultMain, bench, nfIO)
import System.Directory (removeFile, findExecutable)
import System.IO
    ( Handle
    , IOMode(..)
    , openFile
    , hClose
    )
import System.Process (proc, createProcess, waitForProcess, callCommand)

import qualified Streamly.Data.Fold as FL
import qualified Streamly.FileSystem.Handle as FH
import qualified Streamly.Prelude as S
import qualified Streamly.System.Process as Proc

-- Internal imports
import qualified Streamly.Internal.FileSystem.Handle
    as FH (toBytes, toChunks, putBytes, putChunks)
import qualified Streamly.Internal.System.Process as Proc

-- XXX replace with streamly versions once they are fixed
{-# INLINE rights #-}
rights :: (S.IsStream t, Monad m, Functor (t m)) => t m (Either a b) -> t m b
rights = fmap (fromRight undefined) . S.filter isRight

{-# INLINE lefts #-}
lefts :: (S.IsStream t, Monad m, Functor (t m)) => t m (Either a b) -> t m a
lefts = fmap (fromLeft undefined) . S.filter isLeft

-------------------------------------------------------------------------------
-- Constants and utils
-------------------------------------------------------------------------------

_a :: Word8
_a = 97

-- XXX portability on macOS
devRandom :: String
devRandom = "/dev/urandom"

devNull :: String
devNull = "/dev/null"

which :: String -> IO FilePath
which cmd = do
    r <- findExecutable cmd
    case r of
        Just path -> return path
        _ -> error $ "Required command " ++ cmd ++ " not found"

-------------------------------------------------------------------------------
-- Create a data file filled with random data
-------------------------------------------------------------------------------

ddBlockSize :: Int
ddBlockSize = 1024 * 1024

ddBlockCount :: Int
ddBlockCount = 10

largeByteFile :: String
largeByteFile = "./largeByteFile"

generateByteFile :: IO ()
generateByteFile = do
    ddPath <- which "dd"
    let procObj = proc ddPath [
                "if=" ++ devRandom,
                "of=" ++ largeByteFile,
                "count=" ++ show ddBlockCount,
                "bs=" ++ show ddBlockSize
            ]

    (_, _, _, procHandle) <- createProcess procObj
    _ <- waitForProcess procHandle
    return ()

-------------------------------------------------------------------------------
-- Create a file filled with ascii chars
-------------------------------------------------------------------------------

largeCharFile :: String
largeCharFile = "./largeCharFile"

numCharInCharFile :: Int
numCharInCharFile = 10 * 1024 * 1024

generateCharFile :: IO ()
generateCharFile = do
    handle <- openFile largeCharFile WriteMode
    FH.putBytes handle (S.replicate numCharInCharFile _a)
    hClose handle

-------------------------------------------------------------------------------
-- Create a utility that writes to stderr
-------------------------------------------------------------------------------

trToStderr :: String
trToStderr = "./writeTrToError.sh"

trToStderrContent :: String
trToStderrContent =
    "tr [a-z] [A-Z] <&0 >&2"

createExecutable :: IO ()
createExecutable = do
    writeFile trToStderr trToStderrContent
    callCommand ("chmod +x " ++ trToStderr)

-------------------------------------------------------------------------------
-- Create and delete the temp data/exec files
-------------------------------------------------------------------------------

generateFiles :: IO ()
generateFiles = do
    createExecutable
    generateByteFile
    generateCharFile

deleteFiles :: IO ()
deleteFiles = do
    removeFile trToStderr
    removeFile largeByteFile
    removeFile largeCharFile

-------------------------------------------------------------------------------
-- Benchmark functions
-------------------------------------------------------------------------------

toBytes' :: String-> Handle -> IO ()
toBytes' catPath outH =
    FH.putBytes outH
        $ rights
        $ Proc.toBytes' catPath [largeByteFile]

toChunks' :: String -> Handle -> IO ()
toChunks' catPath hdl =
    FH.putChunks hdl
        $ rights
        $ Proc.toChunks' catPath [largeByteFile]

processBytes' :: String-> Handle -> IO ()
processBytes' trPath outputHdl = do
    inputHdl <- openFile largeCharFile ReadMode
    _ <- S.fold (FL.partition (FH.write outputHdl) (FH.write outputHdl))
        $ Proc.processBytes'
            trPath
            ["[a-z]", "[A-Z]"]
        $ FH.toBytes inputHdl
    hClose inputHdl

processBytes :: String-> Handle -> IO ()
processBytes trPath outputHdl = do
    inputHdl <- openFile largeCharFile ReadMode
    FH.putBytes outputHdl
        $ Proc.processBytes
            trPath
            ["[a-z]", "[A-Z]"]
        $ FH.toBytes inputHdl
    hClose inputHdl

processBytesToStderr :: Handle -> IO ()
processBytesToStderr outputHdl = do
    inputHdl <- openFile largeCharFile ReadMode
    FH.putBytes outputHdl
        $ lefts
        $ Proc.processBytes'
            trToStderr
            ["[a-z]", "[A-Z]"]
        $ FH.toBytes inputHdl
    hClose inputHdl

processChunks :: String -> Handle -> IO ()
processChunks trPath outputHdl = do
    inputHdl <- openFile largeCharFile ReadMode
    FH.putChunks outputHdl $
        Proc.processChunks
            trPath
            ["[a-z]", "[A-Z]"]
        $ FH.toChunks inputHdl
    hClose inputHdl

processChunks' :: String -> Handle -> IO ()
processChunks' trPath outputHdl = do
    inputHdl <- openFile largeCharFile ReadMode
    _ <- S.fold
            (FL.partition
                (FH.writeChunks outputHdl) (FH.writeChunks outputHdl)
            )
        $ Proc.processChunks'
            trPath
            ["[a-z]", "[A-Z]"]
            (FH.toChunks inputHdl)
    hClose inputHdl

processChunksToStderr :: Handle -> IO ()
processChunksToStderr outputHdl = do
    inputHdl <- openFile largeCharFile ReadMode
    FH.putChunks outputHdl
        $ lefts
        $ Proc.processChunks'
            trToStderr
            ["[a-z]", "[A-Z]"]
            (FH.toChunks inputHdl)
    hClose inputHdl

-------------------------------------------------------------------------------
-- Main
-------------------------------------------------------------------------------

main :: IO ()
main = do
    putStrLn "Generating files..."
    generateFiles
    trPath <- which "tr"
    catPath <- which "cat"
    nullH <- openFile devNull WriteMode
    putStrLn "Running benchmarks..."

    defaultMain
        [ bench "toBytes'" $ nfIO $ toBytes' catPath nullH
        , bench "toChunks'" $ nfIO $ toChunks' catPath nullH
        , bench "processBytes tr" $ nfIO $ processBytes trPath nullH
        , bench "processBytes' tr" $ nfIO $ processBytes' trPath nullH
        , bench "processBytesToStderr tr" $ nfIO $ processBytesToStderr nullH
        , bench "processChunks tr" $ nfIO (processChunks trPath nullH)
        , bench "processChunks' tr" $ nfIO (processChunks' trPath nullH)
        , bench "processChunksToStderr" $ nfIO $ processChunksToStderr nullH
        ] `finally` (do
            putStrLn "cleanup ..."
            hClose nullH
            deleteFiles
           )
