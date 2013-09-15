module Melvin.Damn (
  packetStream,
  responder
) where

import           Control.Applicative
import           Control.Arrow
import           Control.Concurrent hiding   (yield)
import           Control.Exception           (throwIO)
import           Control.Monad
import           Control.Monad.Fix
import qualified Data.Map as M
import           Data.Maybe
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.Read as T
import           Melvin.Chatrooms
import           Melvin.Client.Packet hiding (Packet(..), parse, render)
import qualified Melvin.Damn.Actions as Damn
import           Melvin.Damn.Tablumps
import           Melvin.Exception
import           Melvin.Logger
import           Melvin.Prelude
import           Melvin.Types
import           Pipes.Safe
import           System.IO hiding            (isEOF, print, putStrLn)
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

handler :: SomeException -> ClientT ()
handler ex | Just (ClientSocketErr e) <- fromException ex = do
    logWarning $ formatS "Server thread hit an exception, but client disconnected ({}), so nothing to do." [show e]
    throwM ex
handler ex = do
    uname <- lift $ use username
    writeClient $ rplNotify uname $ formatS "Error when communicating with dAmn: {}" [show ex]
    if isRetryable ex
        then writeClient $ rplNotify uname "Trying to reconnect..."
        else do
            writeClient $ rplNotify uname "Unrecoverable error. Disconnecting..."
            killClient
    throwM ex

packetStream :: MVar Handle -> Producer Packet ClientT ()
packetStream mv = bracket
    (do hndl <- liftIO $ readMVar mv
        liftIO $ auth hndl
        return hndl)
    (liftIO . hClose)
    (\h -> handle (lift . handler) $ fix $ \f -> do
        isEOF <- liftIO $ hIsEOF h
        isClosed <- liftIO $ hIsClosed h
        when (isEOF || isClosed) $ throwM (ServerDisconnect "socket closed")
        line <- liftIO $ hGetTillNull h
        lift . logWarning $ show $ cleanup line
        case parse $ cleanup line of
            Left err -> throwM $ ServerNoParse err line
            Right pk -> do
                yield pk
                f)
    where cleanup m = case T.stripSuffix "\n" m of
                         Nothing -> m
                         Just s -> cleanup s

responder :: Consumer Packet ClientT ()
responder = handle (lift . handler) $ fix $ \f -> do
    p <- await
    continue <- case M.lookup (pktCommand p) responses of
        Nothing -> do
            lift . logInfo $ formatS "Unhandled packet from damn: {}" [show p]
            return False
        Just callback -> do
            st <- lift $ lift get
            lift $ callback p st
    when continue f

auth :: Handle -> IO ()
auth h = hprint h "dAmnClient 0.3\nagent=melvin 0.1\n\0" ()


-- | Big ol' list of callbacks!
type Callback = Packet -> ClientSettings -> ClientT Bool

type RecvCallback = Packet -> Callback

responses :: M.Map Text Callback
responses = M.fromList [ ("dAmnServer", res_dAmnServer)
                       , ("ping", res_ping)
                       , ("login", res_login)
                       , ("join", res_join)
                       , ("part", res_part)
                       , ("property", res_property)
                       , ("recv", res_recv)
                       , ("kicked", res_kicked)
                       , ("send", res_send)
                       , ("disconnect", res_disconnect)
                       ]

recv_responses :: M.Map Text RecvCallback
recv_responses = M.fromList [ ("msg", res_recv_msg)
                            , ("action", res_recv_action)
                            , ("join", res_recv_join)
                            , ("part", res_recv_part)
                            , ("privchg", res_recv_privchg)
                            ]

res_dAmnServer :: Callback
res_dAmnServer _ st = do
    let (num, (user, tok)) = (clientNumber &&& view username &&& view token) st
    logInfo $ formatS "Client #{} handshook successfully." [num]
    writeServer $ Damn.login user tok
    return True

res_ping :: Callback
res_ping _ _ = writeServer Damn.pong >> return True

res_login :: Callback
res_login Packet { pktArgs = args } st = do
    let user = st ^. username
    case args ^. ix "e" of
        "ok" -> do
            modifyState (loggedIn .~ True)
            writeClient $ rplNotify user "Authenticated successfully."
            joinlist <- getsState (view joinList)
            forM_ (S.elems joinlist) $ writeServer <=< Damn.join
            return True
        x -> do
            writeClient $ rplNotify user "Authentication failed!"
            throwM $ AuthenticationFailed x

res_join :: Callback
res_join Packet { pktParameter = p
                , pktArgs = args } st = do
    let user = st ^. username
    channel <- toChannel $ fromJust p
    case args ^. ix "e" of
        "ok" -> do
            modifyState (joining %~ S.insert channel)
            writeClient $ cmdJoin user channel
        "not privileged" -> writeClient $ errBannedFromChan user channel
        _ -> return ()
    return True

res_part :: Callback
res_part Packet { pktParameter = p
                , pktArgs = args } st = do
    let user = st ^. username
    channel <- toChannel $ fromJust p
    case args ^. ix "e" of
        "ok" -> writeClient $ cmdPart user channel "leaving"
        _ -> return ()
    return True

res_property :: Callback
res_property Packet { pktParameter = p
                    , pktArgs = args
                    , pktBody = body } st = do
    let user = st ^. username
    channel <- toChannel $ fromJust p
    case args ^. ix "p" of
        "topic" -> case body of
            Nothing -> writeClient $ rplNoTopic user channel "No topic is set"
            Just b -> do
                writeClient $ rplTopic user channel (T.cons ':' . T.replace "\n" " | " . unRaw $ delump b)
                writeClient $ rplTopicWhoTime user channel (args ^. ix "by") (args ^. ix "ts")

        "title" -> logInfo $ formatS "Received title for {}: {}" [channel, body ^. _Just]

        "privclasses" -> do
            logInfo $ formatS "Received privclasses for {}" [channel]
            setPrivclasses channel $ body ^. _Just

        "members" -> do
            setMembers channel $ body ^. _Just
            joining' <- getsState (view joining)
            when (channel `S.member` joining') $ do
                let room = toChatroom channel ^?! _Just
                m <- getsState (\s -> s ^. users ^?! ix room)
                writeClient $ rplNameReply channel user (map renderUser $ M.elems m)
                mypc <- getsState (\s -> s ^?! users . ix room . ix (st ^. username) . userPrivclass)
                writeClient $ cmdModeUpdate channel user Nothing (mypc >>= asMode)
                modifyState (joining %~ S.delete channel)

        x -> logError $ formatS "unhandled property {}" [x]

    return True
    where
        setPrivclasses c b = do
            let pcs = toPrivclasses $
                  ((T.decimal *** T.tail) . T.breakOn ":") <$> T.splitOn "\n" b
                chat = toChatroom c ^?! _Just
            modifyState (privclasses . at chat ?~ pcs)

        -- decimal x returns a thing like Right (number, text)
        toPrivclasses ((Right (n,_),t):ns) = M.insert t (mkPrivclass n t) (toPrivclasses ns)
        toPrivclasses ((Left _,_):ns) = toPrivclasses ns
        toPrivclasses [] = M.empty

        setMembers c b = do
            let chat = toChatroom c ^?! _Just
            pcs <- if T.head c == '&'
                       then return mempty
                       else getsState (\s -> s ^. privclasses ^?! ix chat)
            let users_ = foldr (toUser pcs) M.empty $ T.splitOn "\n\n" b
            modifyState (users . at chat ?~ users_)

        toUser pcs text = M.insertWith (\b _ -> b & userJoinCount +~ 1) uname $
                mkUser pcs uname (g "pc")
                                 (read . T.unpack $ g "usericon")
                                 (T.head $ g "symbol")
                                 (g "realname")
                                 (g "gpc")
            where (header:as) = T.splitOn "\n" text
                  uname = last $ T.splitOn " " header
                  attrs = map (second T.tail . T.breakOn "=") as
                  g k = lookup k attrs ^. _Just

res_send :: Callback
res_send Packet { pktParameter = p
                , pktArgs = args
                } _ = do
    channel <- toChannel $ p ^. _Just
    writeClient $ cmdSendError channel (args ^. ix "e")
    return True

res_disconnect :: Callback
res_disconnect Packet { pktArgs = args } st = do
    let user = st ^. username
    case args ^. ix "e" of
        "ok" -> return False
        n -> do
            writeClient $ rplNotify user $ "Disconnected: " ++ n
            throwM $ ServerDisconnect n

res_recv :: Callback
res_recv pk st = case pk ^. pktSubpacketL of
    Nothing -> True <$ logError (formatS "Received an empty recv packet: {}" [show pk])
    Just spk -> case M.lookup (pktCommand spk) recv_responses of
                    Nothing -> True <$ logError (formatS "Unhandled recv packet: {}" [show spk])
                    Just c -> c pk spk st

res_recv_msg :: RecvCallback
res_recv_msg Packet { pktParameter = p }
             Packet { pktArgs = args
                    , pktBody = b
                    } st = do
    channel <- toChannel $ fromJust p
    unless (st ^. username == args ^. ix "from") $
        forM_ (lines . delump $ b ^. _Just) $ \line ->
            writeClient $ cmdPrivmsg (args ^. ix "from") channel line
    return True

res_recv_action :: RecvCallback
res_recv_action Packet { pktParameter = p }
                Packet { pktArgs = args
                       , pktBody = b
                       } st = do
    channel <- toChannel $ fromJust p
    unless (st ^. username == args ^. ix "from") $
        forM_ (lines . delump $ b ^. _Just) $ \line ->
            writeClient $ cmdPrivaction (args ^. ix "from") channel line
    return True

res_recv_join :: RecvCallback
res_recv_join Packet { pktParameter = p }
              Packet { pktParameter = u
                     , pktBody = b
                     } _st = do
    channel <- toChannel $ fromJust p
    let room = toChatroom channel ^?! _Just
    us <- getsState (\s -> s ^? users . ix room . ix (u ^. _Just))
    case us of
        Nothing -> do
            user <- buildUser (u ^. _Just) (b ^. _Just) room
            modifyState (users . ix room %~ M.insert (u ^. _Just) user)
            writeClient $ cmdJoin (u ^. _Just) channel
            case asMode =<< view userPrivclass user of
                Just m -> writeClient $ cmdModeChange channel (u ^. _Just) m
                Nothing -> return ()
        Just r -> do
            modifyState (users . ix room . ix (u ^. _Just) . userJoinCount +~ 1)
            writeClient $ cmdDupJoin (u ^. _Just) channel (r ^. userJoinCount + 1)
    return True
    where
        buildUser name as room = do
            pcs <- getsState (\s -> s ^. privclasses . ix room)
            return $ mkUser pcs name (g "pc")
                                     (read . T.unpack $ g "usericon")
                                     (T.head $ g "symbol")
                                     (g "realname")
                                     (g "gpc")
            where args' = map (second T.tail . T.breakOn "=") (T.splitOn "\n" as)
                  g k = lookup k args' ^. _Just

res_recv_part :: RecvCallback
res_recv_part Packet { pktParameter = p }
              Packet { pktParameter = u
                     , pktArgs = args
                     } _st = do
    channel <- toChannel $ p ^. _Just
    let room = toChatroom channel ^?! _Just
    us <- getsState (\s -> s ^?! users . ix room . ix (u ^. _Just))
    case us ^. userJoinCount of
        1 -> do
            modifyState (users . ix room %~ M.delete (u ^. _Just))
            writeClient $ cmdPart (u ^. _Just) channel (fromMaybe "no reason" $ args ^? ix "r")
        n -> do
            modifyState (users . ix room . ix (u ^. _Just) . userJoinCount -~ 1)
            writeClient $ cmdDupPart (u ^. _Just) channel (n - 1)
    return True

res_recv_privchg :: RecvCallback
res_recv_privchg Packet { pktParameter = p }
                 Packet { pktParameter = u
                        , pktArgs = args
                        } _st = do
    channel <- toChannel $ p ^. _Just
    let room = toChatroom channel ^?! _Just
    user <- getsState (\s -> s ^? users . ix room . ix (u ^. _Just))
    case user >>= fmap pcTitle . view userPrivclass of
        -- they're definitely here; possibly-empty Folds are ok
        Just pc' -> do
            pc <- getsState (\s -> s ^?! privclasses . ix room . ix pc')
            newpc <- getsState (\s -> s ^?! privclasses . ix room . ix (args ^. ix "pc"))
            writeClient $ cmdModeUpdate channel (u ^. _Just) (asMode pc) (asMode newpc)
            modifyState (users . ix room . ix (u ^. _Just) . userPrivclass ?~ newpc)

        -- either the user isn't here or they have no PC
        Nothing -> return ()
    writeClient $ cmdPcChange channel (u ^. _Just) (args ^. ix "pc") (args ^. ix "by")
    return True

res_kicked :: Callback
res_kicked Packet { pktParameter = p
                  , pktArgs = args
                  , pktBody = b
                  } st = do
    channel <- toChannel $ p ^. _Just
    writeClient $ cmdKick (args ^. ix "by") channel (st ^. username) b
    return True

{-# ANN module ("HLint: ignore Use camelCase" :: String) #-}
