module Main where

import qualified Streamly.Internal.Prelude as S
import qualified Streamly.System.Process as Proc
import qualified Streamly.Internal.FileSystem.Handle as FH
import qualified Streamly.Internal.Data.Fold as FL

import System.IO
    ( FilePath
    , Handle
    , IOMode(..)
    , openFile
    , hClose
    , stdout
    , writeFile
    )
import System.Process (proc, createProcess, waitForProcess, callCommand)
import System.Directory (removeFile, findExecutable)

import Control.Monad (replicateM_)
import Control.Monad.IO.Class (MonadIO, liftIO)

import Data.IORef (IORef (..), newIORef, readIORef, writeIORef)
import Data.Word (Word8)

import Gauge (Benchmarkable, defaultMain, bench, nfIO, perRunEnv, perRunEnvWithCleanup)

_a :: Word8
_a = 97

devRandom :: String
devRandom = "/dev/random"

devNull :: String
devNull = "/dev/null"

ioDdBinary :: IO FilePath
ioDdBinary = do
    maybeDdBinary <- findExecutable "dd"
    case maybeDdBinary of
        Just ddBinary -> return ddBinary
        _ -> error "dd Binary Not Found"

ddBlockSize :: Int
ddBlockSize = 1024

ddBlockCount :: Int
ddBlockCount = 100              -- ~100 KB

numCharInCharFile :: Int
numCharInCharFile = 100 * 1024  -- ~100 KB

ioCatBinary :: IO FilePath
ioCatBinary = do
    maybeDdBinary <- findExecutable "cat"
    case maybeDdBinary of
        Just ddBinary -> return ddBinary
        _ -> error "cat Binary Not Found"

ioTrBinary :: IO FilePath
ioTrBinary = do
    maybeDdBinary <- findExecutable "tr"
    case maybeDdBinary of
        Just ddBinary -> return ddBinary
        _ -> error "tr Binary Not Found"

largeByteFile :: String
largeByteFile = "./largeByteFile"

largeCharFile :: String
largeCharFile = "./largeCharFile"

executableFile :: String
executableFile = "./writeTrToError.sh"

executableFileContent :: String
executableFileContent = 
    "tr [a-z] [A-Z] <&0 >&2"

createExecutable :: IO ()
createExecutable = do
    writeFile executableFile executableFileContent
    callCommand ("chmod +x " ++ executableFile)

generateByteFile :: IO ()
generateByteFile = 
    do
        ddBinary <- ioDdBinary
        let procObj = proc ddBinary [
                    "if=" ++ devRandom,
                    "of=" ++ largeByteFile,
                    "count=" ++ show ddBlockCount,
                    "bs=" ++ show ddBlockSize
                ]

        (_, _, _, procHandle) <- createProcess procObj
        waitForProcess procHandle
        return ()

generateCharFile :: IO ()
generateCharFile = do
    handle <- openFile largeCharFile WriteMode
    FH.fromBytes handle (S.replicate numCharInCharFile _a)
    hClose handle

generateFiles :: IO ()
generateFiles = do
    createExecutable
    generateByteFile
    generateCharFile

deleteFiles :: IO ()
deleteFiles = do
    removeFile executableFile
    removeFile largeByteFile
    removeFile largeCharFile

toBytes :: Handle -> IO ()
toBytes hdl = do
    catBinary <- ioCatBinary
    FH.fromBytes hdl $ Proc.toBytes catBinary [largeByteFile]

toChunks :: Handle -> IO ()
toChunks hdl = do
    catBinary <- ioCatBinary
    FH.fromChunks hdl $ 
        Proc.toChunks catBinary [largeByteFile]

transformBytes_ :: (Handle, Handle) -> IO ()
transformBytes_ (inputHdl, outputHdl) = do
    trBinary <- ioTrBinary
    FH.fromBytes outputHdl $ 
        Proc.transformBytes_ trBinary ["[a-z]", "[A-Z]"] (FH.toBytes inputHdl)

transformChunks_ :: (Handle, Handle) -> IO ()
transformChunks_ (inputHdl, outputHdl) = do
    trBinary <- ioTrBinary
    FH.fromChunks outputHdl $ 
        Proc.transformChunks_ trBinary ["[a-z]", "[A-Z]"] (FH.toChunks inputHdl)

transformBytes1 :: (Handle, Handle) -> IO ()
transformBytes1 (inputHdl, outputHdl) = do
    trBinary <- ioTrBinary
    FH.fromBytes outputHdl $ 
        Proc.transformBytes trBinary ["[a-z]", "[A-Z]"] FL.drain (FH.toBytes inputHdl)

transformBytes2 :: (Handle, Handle) -> IO ()
transformBytes2 (inputHdl, outputHdl) =
    FH.fromBytes outputHdl $ 
        Proc.transformBytes executableFile ["[a-z]", "[A-Z]"] FL.drain (FH.toBytes inputHdl)

transformChunks1 :: (Handle, Handle) -> IO ()
transformChunks1 (inputHdl, outputHdl) = do
    trBinary <- ioTrBinary
    FH.fromChunks outputHdl $ 
        Proc.transformChunks trBinary ["[a-z]", "[A-Z]"] FL.drain (FH.toChunks inputHdl)

transformChunks2 :: (Handle, Handle) -> IO ()
transformChunks2 (inputHdl, outputHdl) = do
    trBinary <- ioTrBinary
    FH.fromChunks outputHdl $ 
        Proc.transformChunks executableFile ["[a-z]", "[A-Z]"] FL.drain (FH.toChunks inputHdl)

benchWithOut :: IORef Handle -> (Handle -> IO ()) -> Benchmarkable
benchWithOut nullFileIoRef func = perRunEnv openNewHandle benchCode

    where
    
    openNewHandle = do
        oldHandle <- readIORef nullFileIoRef
        hClose oldHandle
        newHandle <- openFile devNull WriteMode
        writeIORef nullFileIoRef newHandle

    benchCode _ = do
        handle <- readIORef nullFileIoRef
        func handle

benchWithInpOut :: IORef (Handle, Handle) -> ((Handle, Handle) -> IO ()) -> Benchmarkable
benchWithInpOut inpOutIoRef func = perRunEnv openNewHandles benchCode

    where
    
    openNewHandles = do
        (oldInputHdl, oldOutputHdl) <- readIORef inpOutIoRef
        hClose oldInputHdl
        hClose oldOutputHdl
        newInputHdl <- openFile largeCharFile ReadMode
        newOutputHdl <- openFile devNull WriteMode
        writeIORef inpOutIoRef (newInputHdl, newOutputHdl)

    benchCode _ = do
        inpOutHdls <- readIORef inpOutIoRef
        func inpOutHdls

main :: IO ()
main = do
    generateFiles
    tempHandleWrite <- openFile devNull WriteMode
    tempHandleRead <- openFile devNull ReadMode
    ioRefOut <- newIORef tempHandleWrite
    ioRefInpOut <- newIORef (tempHandleRead, tempHandleWrite)
    defaultMain [
            bench "exe - word8" $ 
                benchWithOut ioRefOut toBytes,
            bench "exe - array of word8" $
                benchWithOut ioRefOut toChunks,
            bench "exe - word8 to word8" $ 
                benchWithInpOut ioRefInpOut transformBytes_,
            bench "exe - array of word8 to array of word8" $
                benchWithInpOut ioRefInpOut transformChunks_,
            bench "exe - word8 to word8 - drain error" $ 
                benchWithInpOut ioRefInpOut transformBytes1,
            bench "exe - word8 to standard error - drain error" $ 
                benchWithInpOut ioRefInpOut transformBytes2,
            bench "exe - array of word8 to array of word8 - drain error" $
                benchWithInpOut ioRefInpOut transformChunks1,
            bench "exe - array of word8 to standard error - drain error" $ 
                benchWithInpOut ioRefInpOut transformChunks2
        ]
    handleOut1 <- readIORef ioRefOut
    hClose handleOut1
    (handleIn2, handleOut2) <- readIORef ioRefInpOut
    hClose handleIn2
    hClose handleOut2
    deleteFiles
