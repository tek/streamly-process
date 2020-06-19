{-# LANGUAGE FlexibleContexts #-}

module Streamly.System.Process
    ( fromExe
    , fromExeChunks
    , thruExe_
    , thruExeChunks_
    )
where

import qualified Streamly.Internal.Prelude as S
import qualified Streamly.Internal.FileSystem.Handle as FH
import qualified Streamly.Internal.Memory.ArrayStream as AS
import Streamly.Internal.Data.SVar (MonadAsync, fork)
import Streamly.Internal.Memory.Array.Types (Array)
import Streamly.Internal.Data.Stream.StreamK.Type (IsStream, adapt)

import System.Exit (ExitCode(..))
import System.IO (hClose, Handle)
import System.Process
    ( ProcessHandle
    , CreateProcess(..)
    , StdStream (..)
    , createProcess
    , createPipe
    , proc
    , waitForProcess
    )

import Data.Word (Word8)

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Catch (MonadCatch, throwM)
import Control.Exception (Exception, displayException)

-- | 
-- ProcessFailed exception which would be raised when process which
-- is made to run fails. The integer it contains is the exit code
-- of the failed process
--
-- @since 0.1.0.0
newtype ProcessFailed = ProcessFailed Int
    deriving Show

-- Exception instance of ProcessFailed
instance Exception ProcessFailed where

    displayException (ProcessFailed exitCodeInt) = 
        "Process Failed With Exit Code " ++ show exitCodeInt

-- |
-- Takes a process handle and waits for the process to exit, and then
-- raises 'ProcessFailed' exception if process failed with some 
-- exit code, else peforms no action
--
-- @since 0.1.0.0
exceptOnError :: (MonadIO m, MonadCatch m) => ProcessHandle -> m ()
exceptOnError procHandle = liftIO $ do
    exitCode <- waitForProcess procHandle
    case exitCode of
        ExitSuccess -> return ()
        ExitFailure exitCodeInt -> throwM $ ProcessFailed exitCodeInt

-- | 
-- Creates a process using the path to executable and arguments, then
-- connects a pipe's write end with output of the process, and 
-- returns the read end's handle and the process handle of the process
--
-- @since 0.1.0.0
{-# INLINE openProc #-}
openProc :: 
    FilePath                        -- ^ Path to Executable
    -> [String]                     -- ^ Arguments
    -> IO (Handle, ProcessHandle)   
    -- ^ Handle to read from output of process, process handle
openProc fpath args = do
    (readEnd, writeEnd) <- createPipe
    let procObj = (proc fpath args) {
            std_out = UseHandle writeEnd,
            close_fds = True
        }

    (_, _, _, procHandle) <- createProcess procObj
    return (readEnd, procHandle)

-- | 
-- Creates a process using the path to executable and arguments, then
-- connects a pipe's write end with output of the process and 
-- generates a stream based on a function which takes the read end of the
-- pipe and generates a stream
--
-- Raises an exception 'ProcessFailed' if process failed due to some
-- reason
--
-- @since 0.1.0.0
{-# INLINE withExe #-}
withExe :: 
        (IsStream t, MonadCatch m, MonadIO m)
        => FilePath          -- ^ Path to Executable
        -> [String]          -- ^ Arguments
        -> (Handle -> t m a) 
        -- ^ Given handle to read from output of 
        -- process generate stream output
        -> t m a             -- ^ Stream produced
withExe fpath args genStrm = S.bracket pre post body

    where

    pre = liftIO $ openProc fpath args

    post (readHdl, procHandle) = 
        liftIO $ hClose readHdl >> exceptOnError procHandle

    body (readHdl, _) = genStrm readHdl

-- | 
-- Creates a process using the path to executable and arguments, then
-- builds two pipes, one whose read end is made the process's standard
-- input, and another whose write end is made the process's standard
-- output. The function returns the handle to write end to the 
-- process's input, handle to read end to process's output and
-- process handle of the process
--
-- @since 0.1.0.0
{-# INLINE openProcInp #-}
openProcInp ::  
    FilePath                                -- ^ Path to Executable
    -> [String]                             -- ^ Arguments
    -> IO (Handle, Handle, ProcessHandle)   
    -- ^ (Input Handle, Output Handle, Process Handle)
openProcInp fpath args = do
    (readInpEnd, writeInpEnd) <- createPipe
    (readOutEnd, writeOutEnd) <- createPipe
    let procObj = (proc fpath args) {
            std_in = UseHandle readInpEnd, 
            std_out = UseHandle writeOutEnd,
            close_fds = True
        }

    (_, _, _, procHandle) <- createProcess procObj
    return (writeInpEnd, readOutEnd, procHandle)

-- | 
-- Creates a process using the path to executable, arguments and a stream
-- which would be used as input to the process (passed as standard input), 
-- then connects a pipe's write end with output of the process and generates 
-- a stream based on a function which takes the read end of the pipe and 
-- generates a stream.
--
-- Raises an exception 'ProcessFailed' if process failed due to some
-- reason
--
-- @since 0.1.0.0
{-# INLINE withInpExe #-}
withInpExe :: 
    (IsStream t, MonadCatch m, MonadIO m, MonadAsync m)
    => FilePath             -- ^ Path to Executable
    -> [String]             -- ^ Arguments
    -> t m Word8            -- ^ Input stream to the process
    -> (Handle -> t m a)    
    -- ^ Handle to read output of process and generate stream
    -> t m a                -- ^ Stream produced
withInpExe fpath args input genStrm = S.bracket pre post body

    where
        
    writeAction writeHdl = 
        FH.fromBytes writeHdl (adapt input) >> liftIO (hClose writeHdl)

    pre = liftIO $ openProcInp fpath args

    post (_, readHdl, procHandle) = 
        liftIO $ hClose readHdl >> exceptOnError procHandle
    
    body (writeHdl, readHdl, _) = 
        S.before (fork $ writeAction writeHdl) $ genStrm readHdl

-- |
-- Runs a process specified by the path to executable and arguments
-- that are to be passed and returns the output of the process
-- (standard output) in the form of a stream of Word8
--
-- Raises an exception 'ProcessFailed' if process failed due to some
-- reason
--
-- @since 0.1.0.0
{-# INLINE fromExe #-}
fromExe ::  
    (IsStream t, MonadIO m, MonadCatch m)
    => FilePath     -- ^ Path to executable
    -> [String]     -- ^ Arguments to pass to executable
    -> t m Word8    -- ^ Output Stream
fromExe fpath args = AS.concat $ withExe fpath args FH.toChunks

-- |
-- Runs a process specified by the path to executable and arguments
-- that are to be passed and returns the output of the process
-- (standard output) in the form of a stream of array of Word8
--
-- Raises an exception 'ProcessFailed' if process failed due to some
-- reason
--
-- @since 0.1.0.0
fromExeChunks ::    
    (IsStream t, MonadIO m, MonadCatch m)
    => FilePath             -- ^ Path to executable
    -> [String]             -- ^ Arguments to pass to executable
    -> t m (Array Word8)    -- ^ Output Stream
fromExeChunks fpath args = withExe fpath args FH.toChunks

-- |
-- Runs a process specified by the path to executable, arguments
-- that are to be passed and input to be provided to the process
-- (standard input) in the form of a stream of Word8 and returns 
-- the output of the process (standard output) in the form of a 
-- stream of Word8
--
-- Raises an exception 'ProcessFailed' if process failed due to some
-- reason
--
-- @since 0.1.0.0
{-# INLINE thruExe_ #-}
thruExe_ :: 
    (IsStream t, MonadIO m, MonadCatch m, MonadAsync m)
    => FilePath     -- ^ Path to executable
    -> [String]     -- ^ Arguments to pass to executable
    -> t m Word8    -- ^ Input Stream
    -> t m Word8    -- ^ Output Stream
thruExe_ fpath args inStream = 
    AS.concat $ withInpExe fpath args inStream FH.toChunks

-- |
-- Runs a process specified by the path to executable, arguments
-- that are to be passed and input to be provided to the process
-- (standard input) in the form of a stream of array of Word8 
-- and returns the output of the process (standard output) in 
-- the form of a stream of array of Word8
--
-- Raises an exception 'ProcessFailed' If process failed due to some
-- reason
--
-- @since 0.1.0.0
{-# INLINE thruExeChunks_ #-}
thruExeChunks_ :: 
    (IsStream t, MonadIO m, MonadCatch m, MonadAsync m)
    => FilePath             -- ^ Path to executable
    -> [String]             -- ^ Arguments to pass to executable
    -> t m (Array Word8)    -- ^ Input Stream
    -> t m (Array Word8)    -- ^ Output Stream
thruExeChunks_ fpath args inStream = 
    withInpExe fpath args (AS.concat inStream) FH.toChunks
