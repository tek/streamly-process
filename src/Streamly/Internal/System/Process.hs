-- |
-- Module      : Streamly.Internal.System.Process
-- Copyright   : (c) 2020 Composewell Technologies
-- License     : Apache-2.0
-- Maintainer  : streamly@composewell.com
-- Stability   : experimental
-- Portability : GHC
--

{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- TODO:
--
-- Remove dependency on the "process" package. We do not need a lot of it or
-- need to reimplement significantly.
--
-- Interactive processes:
--
-- To understand process groups and sessions, see the "General Terminal
-- Interface" section in the [POSIX
-- standard](https://pubs.opengroup.org/onlinepubs/9699919799/).
--
-- For running processes interactively we need to make a new process group for
-- the new process and make it the foreground process group. When the process
-- is done we can make the parent process group as the foreground process group
-- again. We need to ensure that this works properly under exceptions. We can
-- provide an "interact" function to do so.
--
-- - Need a way to specify additional parameters for process creation.
-- Possibly use something like @processBytesWith spec@ etc.
--
-- - Need a way to access the pid and manage the processes and process groups.
-- We can treat the processes in the same way as we treat threads. We can
-- compose processes in parallel, and cleanup can happen in the same way as
-- tids are cleaned up. But do we need this when we have threads anyway?
--
-- - Use unfolds for generation?
--
-- - Folds for composing process sinks? Input may be taken as input of the
-- fold and the output of the process can be consumed by another fold.
--
-- - Replace FilePath with a typed path.
--
{-# LANGUAGE FlexibleContexts #-}

module Streamly.Internal.System.Process
    (
    -- * Process Configuration
      Config

    -- * Exceptions
    , ProcessFailure (..)

    -- * Generation
    , toBytes
    , toBytes'
    , toChunks
    , toChunks'

    -- * Transformation
    , processBytes
    , processBytes'
    , processChunksWith
    , processChunks
    , processChunks'With
    , processChunks'
    )
where

-- #define USE_NATIVE

import Control.Monad.Catch (MonadCatch, throwM)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Word (Word8)
import Streamly.Data.Array.Foreign (Array)
import Streamly.Prelude (MonadAsync, parallel, IsStream, adapt)
import System.Exit (ExitCode(..))
import System.IO (hClose, Handle)

#ifdef USE_NATIVE
import Control.Exception (Exception(..), catch, throwIO, SomeException)
import System.Posix.Process (ProcessStatus(..))
import Streamly.Internal.System.Process.Posix
#else
import Control.Concurrent (forkIO)
import Control.Exception (Exception(..), catch, throwIO)
import Control.Monad (void, unless)
import Foreign.C.Error (Errno(..), ePIPE)
import GHC.IO.Exception (IOException(..), IOErrorType(..))
import System.Process
    ( ProcessHandle
    , CreateProcess(..)
    , StdStream (..)
    , createProcess
    , waitForProcess
    , CmdSpec(..)
    , terminateProcess
    )
#endif

import qualified Streamly.Data.Array.Foreign as Array
import qualified Streamly.Prelude as Stream

-- Internal imports
-- XXX chunked IO chunk size should be moved to Streamly.System.IO
import Streamly.Internal.System.IO (defaultChunkSize)
import Streamly.Internal.Data.Stream.StreamD.Step (Step (..))
import Streamly.Internal.Data.Stream.IsStream.Type (fromStreamD, toStreamD)
import Streamly.Internal.Data.Stream.StreamD.Type (Stream (..))
import Streamly.Internal.Data.SVar (adaptState)
import Streamly.Internal.Data.Unfold.Type (Unfold(..))

import qualified Streamly.Internal.Data.Array.Stream.Foreign
    as ArrayStream (arraysOf)
import qualified Streamly.Internal.FileSystem.Handle
    as Handle (toChunks, putChunks)
-- XXX To be exposed by streamly
-- import qualified Streamly.Internal.Data.Stream.IsStream as Stream (bracket')

-- $setup
-- >>> :set -XFlexibleContexts
-- >>> import Data.Char (toUpper)
-- >>> import Data.Function ((&))
-- >>> import qualified Streamly.Console.Stdio as Stdio
-- >>> import qualified Streamly.Data.Fold as Fold
-- >>> import qualified Streamly.Prelude as Stream
-- >>> import qualified Streamly.System.Process as Process
-- >>> import qualified Streamly.Unicode.Stream as Unicode
-- >>> import qualified Streamly.Internal.Data.Stream.IsStream as Stream

-- XXX To be imported from streamly in future releases.

data UnfoldManyEither o i f =
      UnfoldManyEitherOuter o
    | UnfoldManyEitherInner o i f

{-# INLINE [1] unfoldManyEitherD #-}
unfoldManyEitherD :: Monad m =>
    Unfold m a b -> Stream m (Either a a) -> Stream m (Either b b)
unfoldManyEitherD (Unfold istep inject) (Stream ostep ost) =
    Stream step (UnfoldManyEitherOuter ost)
  where
    {-# INLINE [0] step #-}
    step gst (UnfoldManyEitherOuter o) = do
        r <- ostep (adaptState gst) o
        case r of
            Yield (Left a) o' -> do
                i <- inject a
                i `seq` return (Skip (UnfoldManyEitherInner o' i Left))
            Yield (Right a) o' -> do
                i <- inject a
                i `seq` return (Skip (UnfoldManyEitherInner o' i Right))
            Skip o' -> return $ Skip (UnfoldManyEitherOuter o')
            Stop -> return Stop

    step _ (UnfoldManyEitherInner o i f) = do
        r <- istep i
        return $ case r of
            Yield x i' -> Yield (f x) (UnfoldManyEitherInner o i' f)
            Skip i'    -> Skip (UnfoldManyEitherInner o i' f)
            Stop       -> Skip (UnfoldManyEitherOuter o)

{-# INLINE unfoldManyEither #-}
unfoldManyEither ::(IsStream t, Monad m) =>
    Unfold m a b -> t m (Either a a) -> t m (Either b b)
unfoldManyEither u m = fromStreamD $ unfoldManyEitherD u (toStreamD m)

-------------------------------------------------------------------------------
-- Config
-------------------------------------------------------------------------------

-- | Process configuration used for creating a new process.
--
-- By default the process config is setup to inherit the following attributes
-- from the parent process:
--
-- * Current working directory
-- * Environment
-- * Open file descriptors
-- * Process group
-- * Process uid and gid
-- * Signal handlers
-- * Terminal (Session)
--
#ifdef USE_NATIVE

type ProcessHandle = Process

-- XXX After the fork specify what code to run in parent and in child before
-- exec. Also, use config to control whether to search the binary in the PATH
-- or not.
newtype Config = Config Bool

mkConfig :: FilePath -> [String] -> Config
mkConfig _ _ = Config False

pipeStdErr :: Config -> Config
pipeStdErr (Config _) = Config True
#else
newtype Config = Config CreateProcess

-- | Create a default process configuration from an executable file path and
-- an argument list.
--
mkConfig :: FilePath -> [String] -> Config
mkConfig path args = Config $ CreateProcess
    { cmdspec = RawCommand path args
    , cwd = Nothing -- inherit
    , env = Nothing -- inherit

    -- File descriptors
    , std_in = CreatePipe
    , std_out = CreatePipe
    , std_err = Inherit
    , close_fds = False

    -- Session/group/setuid/setgid
    , create_group = False
    , child_user = Nothing  -- Posix only
    , child_group = Nothing  -- Posix only

    -- Signals (Posix only) behavior
    -- Reset SIGINT (Ctrl-C) and SIGQUIT (Ctrl-\) to default handlers.
    , delegate_ctlc = False

    -- Terminal behavior
    , new_session = False  -- Posix only
    , detach_console = False -- Windows only
    , create_new_console = False -- Windows Only

    -- Added by commit 6b8ffe2ec3d115df9ccc047599545ca55c393005
    , use_process_jobs = True -- Windows only
    }

pipeStdErr :: Config -> Config
pipeStdErr (Config cfg) = Config $ cfg { std_err = CreatePipe }
#endif

-------------------------------------------------------------------------------
-- Exceptions
-------------------------------------------------------------------------------
--
-- TODO Add the path of the executable and the PID of the process to the
-- exception info to aid debugging.

-- | An exception that is raised when a process fails.
--
-- @since 0.1.0
newtype ProcessFailure = ProcessFailure Int -- ^ The exit code of the process.
    deriving Show

-- Exception instance of ProcessFailure
instance Exception ProcessFailure where

    displayException (ProcessFailure exitCode) =
        "Process failed with exit code: " ++ show exitCode

-------------------------------------------------------------------------------
-- Transformation
-------------------------------------------------------------------------------
--
-- | On normal cleanup we do not need to close the pipe handles as they are
-- already guaranteed to be closed (we can assert that) by the time we reach
-- here. We should not kill the process, rather wait for it to terminate
-- normally.
cleanupNormal :: MonadIO m =>
    (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) -> m ()
cleanupNormal (_, _, _, procHandle) = liftIO $ do
#ifdef USE_NATIVE
    -- liftIO $ putStrLn "cleanupNormal waiting"
    status <- wait procHandle
    -- liftIO $ putStrLn "cleanupNormal done"
    case status of
        Exited ExitSuccess -> return ()
        Exited (ExitFailure code) -> throwM $ ProcessFailure code
        Terminated signal _ ->
            throwM $ ProcessFailure (negate $ fromIntegral signal)
        Stopped signal ->
            throwM $ ProcessFailure (negate $ fromIntegral signal)
#else
    exitCode <- waitForProcess procHandle
    case exitCode of
        ExitSuccess -> return ()
        ExitFailure code -> throwM $ ProcessFailure code

-- | On an exception or if the process is getting garbage collected we need to
-- close the pipe handles, and send a SIGTERM to the process to clean it up.
-- Since we are using SIGTERM to kill the process, it may block forever. We can
-- possibly use a timer and send a SIGKILL after the timeout if the process is
-- still hanging around.
_cleanupException :: MonadIO m =>
    (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) -> m ()
_cleanupException (Just stdinH, Just stdoutH, stderrMaybe, ph) = liftIO $ do
    -- Send a SIGTERM to the process
    terminateProcess ph

    -- Ideally we should be closing the handle without flushing the buffers so
    -- that we cannot get a SIGPIPE. But there seems to be no way to do that as
    -- of now so we just ignore the SIGPIPE.
    hClose stdinH `catch` eatSIGPIPE
    hClose stdoutH
    whenJust hClose stderrMaybe

    -- Non-blocking wait for the process to go away
    void $ forkIO (void $ waitForProcess ph)

    where

    whenJust action mb = maybe (pure ()) action mb

    isSIGPIPE e =
        case e of
            IOError
                { ioe_type = ResourceVanished
                , ioe_errno = Just ioe
                } -> Errno ioe == ePIPE
            _ -> False

    eatSIGPIPE e = unless (isSIGPIPE e) $ throwIO e
_cleanupException _ = error "cleanupProcess: Not reachable"
#endif

-- | Creates a system process from an executable path and arguments. For the
-- default attributes used to create the process see 'mkConfig'.
--
createProc' ::
       (Config -> Config) -- ^ Process attribute modifier
    -> FilePath                         -- ^ Executable path
    -> [String]                         -- ^ Arguments
    -> IO (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle)
    -- ^ (Input Handle, Output Handle, Error Handle, Process Handle)
createProc' modCfg path args = do
#ifdef USE_NATIVE
    ((inp, out, err, _excParent, _excChild), parent, child, failure) <-
        mkStdioPipes cfg
    -- XXX Pass the exChild handle to the child process action
    proc <- newProcess child path args Nothing
              `catch` (\(e :: SomeException) -> failure >> throwIO e)
    -- XXX Read the exception channel and reap the process if it failed before
    -- exec.
    parent
    return (Just inp, Just out, err, proc)
#else
    createProcess cfg
#endif

    where

    Config cfg = modCfg $ mkConfig path args

{-# INLINE putChunksClose #-}
putChunksClose :: (MonadIO m, IsStream t) =>
    Handle -> t m (Array Word8) -> t m a
putChunksClose h input =
    Stream.before
        (Handle.putChunks h (adapt input) >> liftIO (hClose h))
        Stream.nil

{-# INLINE toChunksClose #-}
toChunksClose :: (IsStream t, MonadAsync m) => Handle -> t m (Array Word8)
toChunksClose h = Stream.after (liftIO $ hClose h) (Handle.toChunks h)

{-# INLINE processChunksWithAction #-}
processChunksWithAction ::
    (IsStream t, MonadCatch m, MonadAsync m)
    => ((Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) -> t m a)
    -> (Config -> Config)
    -> FilePath             -- ^ Path to Executable
    -> [String]             -- ^ Arguments
    -> t m a     -- ^ Output stream
processChunksWithAction run modCfg path args =
    -- Stream.bracket'
    --      alloc cleanupNormal _cleanupException _cleanupException run
    Stream.bracket alloc cleanupNormal run

    where

    alloc = liftIO $ createProc' modCfg path args

{-# INLINE processChunks'With #-}
processChunks'With ::
    (IsStream t, MonadCatch m, MonadAsync m)
    => (Config -> Config)   -- ^ Config modifier
    -> FilePath             -- ^ Executable name or path
    -> [String]             -- ^ Arguments
    -> t m (Array Word8)    -- ^ Input stream
    -> t m (Either (Array Word8) (Array Word8))     -- ^ Output stream
processChunks'With modifier path args input =
    processChunksWithAction run (modifier . pipeStdErr) path args

    where

    run (Just stdinH, Just stdoutH, Just stderrH, _) =
        putChunksClose stdinH input
            `parallel` Stream.map Left (toChunksClose stderrH)
            `parallel` Stream.map Right (toChunksClose stdoutH)
    run _ = error "processChunks': Not reachable"

{-# INLINE processChunks' #-}
processChunks' ::
    (IsStream t, MonadCatch m, MonadAsync m)
    => FilePath             -- ^ Executable name or path
    -> [String]             -- ^ Arguments
    -> t m (Array Word8)    -- ^ Input stream
    -> t m (Either (Array Word8) (Array Word8))     -- ^ Output stream
processChunks' = processChunks'With id

-- | @processBytes' path args input@ runs the executable at @path@ using @args@
-- as arguments and @input@ stream as its standard input.  The error stream of
-- the executable is presented as 'Left' values in the resulting stream and
-- output stream as 'Right' values.
--
-- Raises 'ProcessFailure' exception in case of failure.
--
-- For example, the following is equivalent to the shell command @echo "hello
-- world" | tr [:lower:] [:upper:]@:
--
-- >>> :{
--    processBytes' "echo" ["hello world"] Stream.nil
--  & Stream.rights
--  & processBytes' "tr" ["[:lower:]", "[:upper:]"]
--  & Stream.rights
--  & Stream.fold Stdio.write
--  :}
--HELLO WORLD
--
-- @since 0.1.0
{-# INLINE processBytes' #-}
processBytes' ::
    (IsStream t, MonadCatch m, MonadAsync m)
    => FilePath         -- ^ Executable name or path
    -> [String]         -- ^ Arguments
    -> t m Word8        -- ^ Input Stream
    -> t m (Either Word8 Word8) -- ^ Output Stream
processBytes' path args input =
    let input1 = ArrayStream.arraysOf defaultChunkSize input
        output = processChunks' path args input1
     in unfoldManyEither Array.read output

{-# INLINE processChunksWith #-}
processChunksWith ::
    (IsStream t, MonadCatch m, MonadAsync m)
    => (Config -> Config)   -- ^ Config modifier
    -> FilePath             -- ^ Executable name or path
    -> [String]             -- ^ Arguments
    -> t m (Array Word8)    -- ^ Input stream
    -> t m (Array Word8)    -- ^ Output stream
processChunksWith modifier path args input =
    processChunksWithAction run modifier path args

    where

    run (Just stdinH, Just stdoutH, _, _) =
        putChunksClose stdinH input `parallel` toChunksClose stdoutH
    run _ = error "processChunks: Not reachable"

-- | @processChunks file args input@ runs the executable @file@ specified by
-- its name or path using @args@ as arguments and @input@ stream as its
-- standard input.  Returns the standard output of the executable as a stream.
--
-- If only the name of an executable file is specified instead of its path then
-- the file name is searched in the directories specified by the PATH
-- environment variable.
--
-- If the input stream throws an exception or if the output stream is garbage
-- collected before it could finish then the process is sent a SIGTERM and we
-- wait for it to terminate gracefully.
--
-- If the process terminates with a non-zero exit code then a 'ProcessFailure'
-- exception is raised.
--
-- The following code is equivalent to the shell command @echo "hello world" |
-- tr [a-z] [A-Z]@:
--
-- >>> :{
--    Process.toChunks "echo" ["hello world"]
--  & Process.processChunks "tr" ["[a-z]", "[A-Z]"]
--  & Stream.fold Stdio.writeChunks
--  :}
--HELLO WORLD
--
-- @since 0.1.0
{-# INLINE processChunks #-}
processChunks ::
    (IsStream t, MonadCatch m, MonadAsync m)
    => FilePath             -- ^ Executable name or path
    -> [String]             -- ^ Arguments
    -> t m (Array Word8)    -- ^ Input stream
    -> t m (Array Word8)    -- ^ Output stream
processChunks = processChunksWith id

-- | Like 'processChunks' except that it works on a stream of bytes instead of
-- a stream of chunks.
--
-- We can write the example in 'processChunks' as follows. Notice how
-- seamlessly we can replace the @tr@ process with the Haskell @toUpper@
-- function:
--
-- >>> :{
--    Process.toBytes "echo" ["hello world"]
--  & Unicode.decodeLatin1 & Stream.map toUpper & Unicode.encodeLatin1
--  & Stream.fold Stdio.write
--  :}
--HELLO WORLD
--
-- @since 0.1.0
{-# INLINE processBytes #-}
processBytes ::
    (IsStream t, MonadCatch m, MonadAsync m)
    => FilePath     -- ^ Executable name or path
    -> [String]     -- ^ Arguments
    -> t m Word8    -- ^ Input Stream
    -> t m Word8    -- ^ Output Stream
processBytes path args input = -- rights . processBytes' path args
    let input1 = ArrayStream.arraysOf defaultChunkSize input
        output = processChunks path args input1
     in Stream.unfoldMany Array.read output

-------------------------------------------------------------------------------
-- Generation
-------------------------------------------------------------------------------
--
-- | @toBytes' path args@ runs the executable at @path@ using @args@ as
-- arguments and returns a stream of 'Either' bytes. The 'Left' values are from
-- @stderr@ and the 'Right' values are from @stdout@ of the executable.
--
-- Raises 'ProcessFailure' exception in case of failure.
--
-- The following example uses @echo@ to write @hello@ to @stdout@ and @world@
-- to @stderr@, then uses folds from "Streamly.Console.Stdio" to write them
-- back to @stdout@ and @stderr@ respectively:
--
--
-- >>> :{
--   Process.toBytes' "/bin/bash" ["-c", "echo 'hello'; echo 'world' 1>&2"]
-- & Stream.fold (Fold.partition Stdio.writeErr Stdio.write)
-- :}
-- world
-- hello
-- ((),())
--
-- >>> toBytes' path args = Process.processBytes' path args Stream.nil
--
-- @since 0.1.0
{-# INLINE toBytes' #-}
toBytes' ::
    (IsStream t, MonadAsync m, MonadCatch m)
    => FilePath     -- ^ Executable name or path
    -> [String]     -- ^ Arguments
    -> t m (Either Word8 Word8)    -- ^ Output Stream
toBytes' path args = processBytes' path args Stream.nil

-- | See 'processBytes'. 'toBytes' is defined as:
--
-- >>> toBytes path args = processBytes path args Stream.nil
--
-- The following code is equivalent to the shell command @echo "hello world"@:
--
-- >>> :{
--    Process.toBytes "echo" ["hello world"]
--  & Stream.fold Stdio.write
--  :}
--hello world
--
-- @since 0.1.0
{-# INLINE toBytes #-}
toBytes ::
    (IsStream t, MonadAsync m, MonadCatch m)
    => FilePath     -- ^ Executable name or path
    -> [String]     -- ^ Arguments
    -> t m Word8    -- ^ Output Stream
toBytes path args = processBytes path args Stream.nil

-- | Like 'toBytes' but generates a stream of @Array Word8@ instead of a stream
-- of @Word8@.
--
-- >>> :{
--   toChunks' "bash" ["-c", "echo 'hello'; echo 'world' 1>&2"]
-- & Stream.fold (Fold.partition Stdio.writeErrChunks Stdio.writeChunks)
-- :}
-- world
-- hello
-- ((),())
--
-- >>> toChunks' path args = processChunks' path args Stream.nil
--
-- Prefer 'toChunks' over 'toBytes' when performance matters.
--
-- @since 0.1.0
{-# INLINE toChunks' #-}
toChunks' ::
    (IsStream t, MonadAsync m, MonadCatch m)
    => FilePath             -- ^ Executable name or path
    -> [String]             -- ^ Arguments
    -> t m (Either (Array Word8) (Array Word8))    -- ^ Output Stream
toChunks' path args = processChunks' path args Stream.nil

-- | See 'processChunks'. 'toChunks' is defined as:
--
-- >>> toChunks path args = processChunks path args Stream.nil
--
-- The following code is equivalent to the shell command @echo "hello world"@:
--
-- >>> :{
--    Process.toChunks "echo" ["hello world"]
--  & Stream.fold Stdio.writeChunks
--  :}
--hello world
--
-- @since 0.1.0
{-# INLINE toChunks #-}
toChunks ::
    (IsStream t, MonadAsync m, MonadCatch m)
    => FilePath             -- ^ Executable name or path
    -> [String]             -- ^ Arguments
    -> t m (Array Word8)    -- ^ Output Stream
toChunks path args = processChunks path args Stream.nil
