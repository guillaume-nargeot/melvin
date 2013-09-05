module Melvin.Damn (
  packetStream,
  responder
) where

import           Control.Arrow
import           Control.Concurrent
import           Control.Exception           (fromException, throwIO)
import           Control.Monad
import           Control.Monad.Fix
import           Control.Proxy
import           Control.Proxy.Safe
import           Control.Proxy.Trans.State
import qualified Data.Map as M
import           Data.Maybe
import qualified Data.Set as S
import qualified Data.Text as T
import           Melvin.Chatrooms
import           Melvin.Client.Packet hiding (Packet(..), parse, render)
import qualified Melvin.Damn.Actions as Damn
import           Melvin.Exception
import           Melvin.Logger
import           Melvin.Prelude
import           Melvin.Types
import           System.IO hiding            (isEOF, putStrLn)
import           System.IO.Error
import           Text.Damn.Packet hiding     (render)

hGetTillNull :: Handle -> IO Text
hGetTillNull h = do
    ready <- hWaitForInput h 180000
    if ready
        then do
            ch <- hGetChar h
            if ch == '\0'
                then return mempty
                else fmap (T.cons ch) $ hGetTillNull h
        else throwIO $ mkIOError eofErrorType "read timeout" (Just h) Nothing

handler :: SomeException
        -> ClientP a' a b' b SafeIO ()
handler ex | Just (ClientSocketErr e) <- fromException ex = do
    logWarning $ formatS "Server thread hit an exception, but client disconnected ({}), so nothing to do." [show e]
    throw ex
handler ex = do
    uname <- liftP $ gets (view username)
    writeClient $ rplNotify uname $ formatS "Error when communicating with dAmn: {}" [show ex]
    if isRetryable ex
        then writeClient $ rplNotify uname "Trying to reconnect..."
        else do
            writeClient $ rplNotify uname "Unrecoverable error. Disconnecting..."
            killClient
    throw ex

packetStream :: MVar Handle -> () -> Producer ClientP Packet SafeIO ()
packetStream mv () = bracket id
    (do hndl <- readMVar mv
        auth hndl
        return hndl)
    hClose
    (\h -> handle handler $ fix $ \f -> do
        isEOF <- tryIO $ hIsEOF h
        isClosed <- tryIO $ hIsClosed h
        when (isEOF || isClosed) $ throw (ServerDisconnect "socket closed")
        line <- tryIO $ hGetTillNull h
        logWarning $ show line
        case parse $ cleanup line of
            Left err -> throw $ ServerNoParse err line
            Right pk -> do
                respond pk
                f)
    where cleanup m = fromMaybe m $ T.stripSuffix "\n" m

responder :: () -> Consumer ClientP Packet SafeIO ()
responder () = handle handler $ fix $ \f -> do
    p <- request ()
    continue <- case M.lookup (pktCommand p) responses of
        Nothing -> do
            logInfo $ formatS "Unhandled packet from damn: {}" [show p]
            return False
        Just callback -> do
            st <- liftP get
            callback p st
    when continue f

auth :: Handle -> IO ()
auth h = hprint h "dAmnClient 0.3\nagent=melvin 0.1\n\0" ()


-- | Big ol' list of callbacks!
type Callback = Packet -> ClientSettings -> Consumer ClientP Packet SafeIO Bool

responses :: M.Map Text Callback
responses = M.fromList [ ("dAmnServer", res_dAmnServer)
                       , ("login", res_login)
                       , ("join", res_join)
                       , ("disconnect", res_disconnect)
                       ]

res_dAmnServer :: Callback
res_dAmnServer _ st = do
    let (num, (user, tok)) = (clientNumber &&& view username &&& view token) st
    logInfo $ formatS "Client #{} handshook successfully." [num]
    writeServer $ Damn.login user tok
    return True

res_login :: Callback
res_login Packet { pktArgs = args } st = do
    let user = st ^. username
    case args ^. ix "e" of
        "ok" -> do
            modifyState (loggedIn .~ True)
            writeClient $ rplNotify user "Authenticated successfully."
            joinlist <- getsState (view joinList)
            forM_ (S.elems joinlist) Damn.join
            return True
        x -> do
            writeClient $ rplNotify user "Authentication failed!"
            throw $ AuthenticationFailed x

res_join :: Callback
res_join Packet { pktParameter = p
                , pktArgs = args } st = do
    let user = st ^. username
    channel <- toChannel $ fromJust p
    case args ^. ix "e" of
        "ok" -> writeClient $ cmdJoin user channel
        "not privileged" -> writeClient $ errBannedFromChan user channel
        _ -> return ()
    return True

res_disconnect :: Callback
res_disconnect Packet { pktArgs = args } st = do
    let user = st ^. username
    case args ^. ix "e" of
        "ok" -> return False
        n -> do
            writeClient $ rplNotify user $ "Disconnected: " ++ n
            throw $ ServerDisconnect n

{-# ANN module ("HLint: ignore Use camelCase" :: String) #-}
