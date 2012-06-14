module Control.Distributed.Process.Internal.NodeController 
  ( runNodeController
  , NCMsg(..)
  ) where

import Data.Map (Map)
import qualified Data.Map as Map (empty, toList)
import Data.Set (Set)
import qualified Data.Set as Set (empty, insert)
import qualified Data.ByteString as BSS (ByteString)
import qualified Data.ByteString.Lazy as BSL (toChunks)
import Data.Binary (encode)
import Data.Foldable (forM_)
import Data.Maybe (isJust)
import Data.Accessor (Accessor, accessor, (^.), (^=), (^:))
import qualified Data.Accessor.Container as DAC (mapMaybe, mapDefault)
import Control.Category ((>>>))
import Control.Monad (when, unless, forever)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.State (MonadState, StateT, evalStateT, gets, modify)
import Control.Monad.Reader (MonadReader(..), ReaderT, runReaderT)
import Control.Concurrent.MVar (withMVar)
import Control.Concurrent.Chan (readChan, writeChan)
import Control.Exception (throwTo)
import qualified Network.Transport as NT ( EndPoint
                                         , Connection
                                         , Reliability(ReliableOrdered)
                                         , defaultConnectHints
                                         , send
                                         , connect
                                         )
import Control.Distributed.Process.Internal.CQueue (enqueue)
import Control.Distributed.Process.Internal ( NodeId(..)
                                            , LocalProcessId(..)
                                            , ProcessId(..)
                                            , LocalNode(..)
                                            , LocalProcess(..)
                                            , MonitorRef
                                            , MonitorNotification(..)
                                            , LinkException(..)
                                            , DiedReason(..)
                                            , Identifier
                                            , NCMsg(..)
                                            , ProcessSignal(..)
                                            , createMessage
                                            , idToPayload
                                            , localProcessWithId
                                            )

--------------------------------------------------------------------------------
-- Top-level access to the node controller                                    --
--------------------------------------------------------------------------------

runNodeController :: LocalNode -> IO ()
runNodeController node = 
  evalStateT (runReaderT (unNC nodeController) node) initNCState

--------------------------------------------------------------------------------
-- Internal data types                                                        --
--------------------------------------------------------------------------------

data NCState = NCState 
  {  -- Mapping from remote processes to linked local processes 
    _links :: Map NodeId (Map LocalProcessId (Set ProcessId))
     -- Mapping from remote processes to monitoring local processes
  , _monitors  :: Map NodeId (Map LocalProcessId (Map ProcessId (Set MonitorRef)))
     -- The node controller maintains its own set of connections
     -- TODO: still not convinced that this is correct
  , _connections :: Map Identifier NT.Connection 
  }

newtype NC a = NC { unNC :: ReaderT LocalNode (StateT NCState IO) a }
  deriving (Functor, Monad, MonadIO, MonadState NCState, MonadReader LocalNode)

--------------------------------------------------------------------------------
-- Core functionality                                                         --
--------------------------------------------------------------------------------

-- [Unified: Table 7]
nodeController :: NC ()
nodeController = do
  node <- ask
  forever $ do
    msg  <- liftIO $ readChan (localCtrlChan node)

    -- [Unified: Table 7, rule nc_forward] 
    case destNid (ctrlMsgSignal msg) of
      Just nid' | nid' /= localNodeId node -> sendCtrlMsg nid' msg
      _ -> return ()

    case msg of
      NCMsg (Left from) (Monitor them ref) ->
        ncEffectMonitor from them (Just ref)
      NCMsg (Right _) (Monitor _ _) ->
        error "Monitor message from a node?"
      NCMsg (Left from) (Link them) ->
        ncEffectMonitor from them Nothing
      NCMsg (Right _) (Link _) ->
        error "Link message from a node?"
      NCMsg _from (Died (Right nid) reason) ->
        ncEffectNodeDied nid reason
      NCMsg _from (Died (Left pid) reason) ->
        ncEffectProcessDied pid reason

-- [Unified: Table 10]
ncEffectMonitor :: ProcessId        -- ^ Who's watching? 
                -> ProcessId        -- ^ Who's being watched?
                -> Maybe MonitorRef -- ^ 'Nothing' to link
                -> NC ()
ncEffectMonitor from them mRef = do
  node <- ask 
  shouldLink <- 
    if processNodeId them /= localNodeId node 
      then return True
      else liftIO . withMVar (localState node) $ 
        return . isJust . (^. localProcessWithId (processLocalId them))
  let localFrom = processNodeId from == localNodeId node
  case (shouldLink, localFrom) of
    (True, _) ->  -- [Unified: first rule]
      case mRef of
        Just ref -> modify $ monitorsFor them from ^: Set.insert ref
        Nothing  -> modify $ linksForProcess them ^: Set.insert from 
    (False, True) -> -- [Unified: second rule]
      notifyDied from them DiedNoProc mRef 
    (False, False) -> -- [Unified: third rule]
      sendCtrlMsg (processNodeId from) NCMsg 
        { ctrlMsgSender = Right (localNodeId node)
        , ctrlMsgSignal = Died (Left them) DiedNoProc
        }

-- [Unified: Table 12, bottom rule]
ncEffectNodeDied :: NodeId -> DiedReason -> NC ()
ncEffectNodeDied nid reason = do
  node <- ask
  lnks <- gets (^. linksForNode nid)
  mons <- gets (^. monitorsForNode nid)

  -- We only need to notify local processes
  forM_ (Map.toList lnks) $ \(them, uss) -> do
    let pid = ProcessId nid them
    forM_ uss $ \us ->
      when (processNodeId us == localNodeId node) $
        notifyDied us pid reason Nothing

  forM_ (Map.toList mons) $ \(them, uss) -> do
    let pid = ProcessId nid them 
    forM_ (Map.toList uss) $ \(us, refs) -> 
      when (processNodeId us == localNodeId node) $
        forM_ refs $ notifyDied us pid reason . Just

  modify $ (linksForNode nid ^= Map.empty)
         . (monitorsForNode nid ^= Map.empty)

-- [Unified: Table 12, top rule]
ncEffectProcessDied :: ProcessId -> DiedReason -> NC ()
ncEffectProcessDied pid reason = do
  lnks <- gets (^. linksForProcess pid)
  mons <- gets (^. monitorsForProcess pid)

  forM_ lnks $ \us ->
    notifyDied us pid reason Nothing 

  forM_ (Map.toList mons) $ \(us, refs) ->
    forM_ refs $ 
      notifyDied us pid reason . Just

  modify $ (linksForProcess pid ^= Set.empty)
         . (monitorsForProcess pid ^= Map.empty)

--------------------------------------------------------------------------------
-- Connections                                                                --
--------------------------------------------------------------------------------

notifyDied :: ProcessId         -- ^ Who to notify?
           -> ProcessId         -- ^ Who died?
           -> DiedReason        -- ^ How did they die?
           -> Maybe MonitorRef  -- ^ 'Nothing' for linking
           -> NC ()
notifyDied dest src reason mRef = do
  node <- ask
  if processNodeId dest == localNodeId node 
    then liftIO $ do
      let lpid = processLocalId dest 
      mProc <- withMVar (localState node) $ return . (^. localProcessWithId lpid)
      -- By [Unified: table 6, rule missing_process] messages to dead processes
      -- can silently be dropped
      forM_ mProc $ \proc -> case mRef of
        Just ref -> do
          let msg = createMessage $ MonitorNotification ref src reason
          enqueue (processQueue proc) msg
        Nothing ->
          throwTo (processThread proc) $ LinkException src reason 
    else
      -- TODO: why the change in sender? How does that affect 'reconnect' semantics?
      -- (see [Unified: Table 10]
      sendCtrlMsg (processNodeId dest) NCMsg
        { ctrlMsgSender = Right (localNodeId node) 
        , ctrlMsgSignal = Died (Left src) reason
        }

sendTo :: Identifier -> [BSS.ByteString] -> NC () 
sendTo them payload = do
  mConn <- connTo them
  didSend <- case mConn of
    Just conn -> do
      didSend <- liftIO $ NT.send conn payload
      case didSend of
        Left _   -> return False
        Right () -> return True
    Nothing ->
      return False
  unless didSend $ do
    -- [Unified: Table 9, rule node_disconnect]
    node <- ask
    liftIO . writeChan (localCtrlChan node) $ NCMsg 
      { ctrlMsgSender = them 
      , ctrlMsgSignal = Died them DiedDisconnect
      }

sendCtrlMsg :: NodeId -> NCMsg -> NC ()
sendCtrlMsg dest = sendTo (Right dest) . BSL.toChunks . encode 

connTo :: Identifier -> NC (Maybe NT.Connection)
connTo them = do
  mConn <- gets (^. connectionTo them)
  case mConn of
    Just conn -> return (Just conn)
    Nothing   -> createConnTo them

createConnTo :: Identifier -> NC (Maybe NT.Connection)
createConnTo them = do
    node  <- ask
    mConn <- liftIO $ NT.connect (localEndPoint node) 
                                 addr 
                                 NT.ReliableOrdered 
                                 NT.defaultConnectHints 
    case mConn of
      Right conn -> do
        didSend <- liftIO $ NT.send conn firstMsg
        case didSend of
          Left _ -> 
            return Nothing 
          Right () -> do
            modify $ connectionTo them ^= Just conn
            return $ Just conn
      Left _ ->
        return Nothing
  where
    (addr, firstMsg) = case them of
       Left pid  -> ( nodeAddress (processNodeId pid)
                    , idToPayload (Just $ processLocalId pid)
                    )
       Right nid -> ( nodeAddress nid
                    , idToPayload Nothing 
                    )

--------------------------------------------------------------------------------
-- Auxiliary                                                                  --
--------------------------------------------------------------------------------

destNid :: ProcessSignal -> Maybe NodeId
destNid (Monitor pid _)      = Just $ processNodeId pid 
destNid (Link pid)           = Just $ processNodeId pid
destNid (Died (Right _) _)   = Nothing
destNid (Died (Left _pid) _) = fail "destNid: TODO"

initNCState :: NCState
initNCState = NCState
  { _links = Map.empty
  , _monitors  = Map.empty
  , _connections = Map.empty 
  }

--------------------------------------------------------------------------------
-- Accessors                                                                  --
--------------------------------------------------------------------------------

links :: Accessor NCState (Map NodeId (Map LocalProcessId (Set ProcessId)))
links = accessor _links (\lnks st -> st { _links = lnks })

monitors :: Accessor NCState (Map NodeId (Map LocalProcessId (Map ProcessId (Set MonitorRef))))
monitors = accessor _monitors (\mons st -> st { _monitors = mons })

connections :: Accessor NCState (Map Identifier NT.Connection)
connections = accessor _connections (\conns st -> st { _connections = conns })

connectionTo :: Identifier -> Accessor NCState (Maybe NT.Connection)
connectionTo them = connections >>> DAC.mapMaybe them 

linksForNode :: NodeId -> Accessor NCState (Map LocalProcessId (Set ProcessId))
linksForNode nid = links >>> DAC.mapDefault Map.empty nid 

monitorsForNode :: NodeId -> Accessor NCState (Map LocalProcessId (Map ProcessId (Set MonitorRef)))
monitorsForNode nid = monitors >>> DAC.mapDefault Map.empty nid 

linksForProcess :: ProcessId -> Accessor NCState (Set ProcessId)
linksForProcess pid = linksForNode (processNodeId pid) >>> DAC.mapDefault Set.empty (processLocalId pid)

monitorsForProcess :: ProcessId -> Accessor NCState (Map ProcessId (Set MonitorRef))
monitorsForProcess pid = monitorsForNode (processNodeId pid) >>> DAC.mapDefault Map.empty (processLocalId pid) 

monitorsFor :: ProcessId -> ProcessId -> Accessor NCState (Set MonitorRef)
monitorsFor them us = monitorsForProcess them >>> DAC.mapDefault Set.empty us 
