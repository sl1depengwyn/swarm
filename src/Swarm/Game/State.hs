{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns #-}

-- |
-- Module      :  Swarm.Game.State
-- Copyright   :  Brent Yorgey
-- Maintainer  :  byorgey@gmail.com
--
-- SPDX-License-Identifier: BSD-3-Clause
--
-- Definition of the record holding all the game-related state, and various related
-- utility functions.
module Swarm.Game.State (
  -- * Game state record and related types
  ViewCenterRule (..),
  REPLStatus (..),
  WinCondition (..),
  _NoWinCondition,
  _WinCondition,
  _Won,
  RunStatus (..),
  Seed,
  GameState,

  -- ** GameState fields
  creativeMode,
  winCondition,
  winSolution,
  runStatus,
  paused,
  robotMap,
  robotsByLocation,
  activeRobots,
  waitingRobots,
  availableRecipes,
  availableCommands,
  allDiscoveredEntities,
  gensym,
  randGen,
  adjList,
  nameList,
  entityMap,
  recipesOut,
  recipesIn,
  scenarios,
  world,
  viewCenterRule,
  viewCenter,
  needsRedraw,
  replStatus,
  replWorking,
  messageQueue,
  focusedRobotID,
  ticks,

  -- ** Notifications
  Notifications (..),
  notificationsCount,
  notificationsContent,

  -- ** GameState initialization
  initGameState,
  scenarioToGameState,
  initGameStateForScenario,
  classicGame0,

  -- * Utilities
  applyViewCenterRule,
  recalcViewCenter,
  modifyViewCenter,
  viewingRegion,
  focusedRobot,
  clearFocusedRobotLogUpdated,
  addRobot,
  addURobot,
  emitMessage,
  sleepUntil,
  sleepForever,
  wakeUpRobotsDoneSleeping,
  deleteRobot,
  activateRobot,
) where

import Control.Applicative ((<|>))
import Control.Arrow (Arrow ((&&&)))
import Control.Lens hiding (Const, use, uses, view, (%=), (+=), (.=), (<+=), (<<.=))
import Control.Monad.Except
import Data.Array (Array, listArray)
import Data.Int (Int64)
import Data.IntMap (IntMap)
import Data.IntMap qualified as IM
import Data.IntSet (IntSet)
import Data.IntSet qualified as IS
import Data.IntSet.Lens (setOf)
import Data.List (partition)
import Data.Map (Map)
import Data.Map qualified as M
import Data.Maybe (fromMaybe)
import Data.Set qualified as S
import Data.Text (Text)
import Data.Text qualified as T (lines)
import Data.Text.IO qualified as T (readFile)
import Linear
import System.Clock qualified
import System.Random (StdGen, mkStdGen, randomRIO)
import Witch (into)

import Control.Algebra (Has)
import Control.Effect.Lens
import Control.Effect.State (State)

import Paths_swarm (getDataFileName)
import Swarm.Game.CESK (emptyStore, initMachine)
import Swarm.Game.Entity
import Swarm.Game.Recipe
import Swarm.Game.Robot
import Swarm.Game.Scenario
import Swarm.Game.Value
import Swarm.Game.World qualified as W
import Swarm.Game.WorldGen (Seed)
import Swarm.Language.Capability (constCaps)
import Swarm.Language.Context qualified as Ctx
import Swarm.Language.Pipeline (ProcessedTerm)
import Swarm.Language.Pipeline.QQ (tmQ)
import Swarm.Language.Syntax (Const, Term (TString), allConst)
import Swarm.Language.Types
import Swarm.Util

------------------------------------------------------------
-- Subsidiary data types
------------------------------------------------------------

-- | The 'ViewCenterRule' specifies how to determine the center of the
--   world viewport.
data ViewCenterRule
  = -- | The view should be centered on an absolute position.
    VCLocation (V2 Int64)
  | -- | The view should be centered on a certain robot.
    VCRobot RID
  deriving (Eq, Ord, Show)

makePrisms ''ViewCenterRule

-- | A data type to represent the current status of the REPL.
data REPLStatus
  = -- | The REPL is not doing anything actively at the moment.
    REPLDone
  | -- | A command entered at the REPL is currently being run.  The
    --   'Polytype' represents the type of the expression that was
    --   entered.  The @Maybe Value@ starts out as @Nothing@ and gets
    --   filled in with a result once the command completes.
    REPLWorking Polytype (Maybe Value)
  deriving (Eq, Show)

data WinCondition
  = -- | There is no winning condition.
    NoWinCondition
  | -- | The player has not won yet; this 'ProcessedTerm' of type @cmd
    --   bool@ is run every tick to determine whether they have won.
    WinCondition ProcessedTerm
  | -- | The player has won. The boolean indicates whether they have
    --   already been congratulated.
    Won Bool
  deriving (Show)

makePrisms ''WinCondition

-- | A data type to keep track of the pause mode.
data RunStatus
  = -- | The game is running.
    Running
  | -- | The user paused the game, and it should stay pause after visiting the help.
    ManualPause
  | -- | The game got paused while visiting the help,
    --   and it should unpause after returning back to the game.
    AutoPause
  deriving (Eq, Show)

-- | A data type to keep track of discovered recipes and commands
data Notifications a = Notifications
  { _notificationsCount :: Int
  , _notificationsContent :: [a]
  }
  deriving (Eq, Show)

instance Semigroup (Notifications a) where
  Notifications count1 xs1 <> Notifications count2 xs2 = Notifications (count1 + count2) (xs1 <> xs2)

instance Monoid (Notifications a) where
  mempty = Notifications 0 []

makeLenses ''Notifications

------------------------------------------------------------
-- The main GameState record type
------------------------------------------------------------

-- | The main record holding the state for the game itself (as
--   distinct from the UI).  See the lenses below for access to its
--   fields.
data GameState = GameState
  { _creativeMode :: Bool
  , _winCondition :: WinCondition
  , _winSolution :: Maybe ProcessedTerm
  , _runStatus :: RunStatus
  , _robotMap :: IntMap Robot
  , -- A set of robots to consider for the next game tick. It is guaranteed to
    -- be a subset of the keys of robotMap. It may contain waiting or idle
    -- robots. But robots that are present in robotMap and not in activeRobots
    -- are guaranteed to be either waiting or idle.
    _activeRobots :: IntSet
  , -- A set of probably waiting robots, indexed by probable wake-up time. It
    -- may contain robots that are in fact active or idle, as well as robots
    -- that do not exist anymore. Its only guarantee is that once a robot name
    -- with its wake up time is inserted in it, it will remain there until the
    -- wake-up time is reached, at which point it is removed via
    -- wakeUpRobotsDoneSleeping.
    -- Waiting robots for a given time are a list because it is cheaper to
    -- append to a list than to a Set.
    _waitingRobots :: Map Integer [RID]
  , _robotsByLocation :: Map (V2 Int64) IntSet
  , _allDiscoveredEntities :: Inventory
  , _availableRecipes :: Notifications (Recipe Entity)
  , _availableCommands :: Notifications Const
  , _gensym :: Int
  , _randGen :: StdGen
  , _adjList :: Array Int Text
  , _nameList :: Array Int Text
  , _entityMap :: EntityMap
  , _recipesOut :: IntMap [Recipe Entity]
  , _recipesIn :: IntMap [Recipe Entity]
  , _scenarios :: ScenarioCollection
  , _world :: W.World Int Entity
  , _viewCenterRule :: ViewCenterRule
  , _viewCenter :: V2 Int64
  , _needsRedraw :: Bool
  , _replStatus :: REPLStatus
  , _messageQueue :: [Text]
  , _focusedRobotID :: RID
  , _ticks :: Integer
  }

------------------------------------------------------------
-- Lenses
------------------------------------------------------------

-- We want to access active and waiting robots via lenses inside
-- this module but to expose it as a Getter to protect invariants.
makeLensesFor
  [ ("_activeRobots", "internalActiveRobots")
  , ("_waitingRobots", "internalWaitingRobots")
  ]
  ''GameState

let exclude = ['_viewCenter, '_focusedRobotID, '_viewCenterRule, '_activeRobots, '_waitingRobots, '_adjList, '_nameList]
 in makeLensesWith
      ( lensRules
          & generateSignatures .~ False
          & lensField . mapped . mapped %~ \fn n ->
            if n `elem` exclude then [] else fn n
      )
      ''GameState

-- | Is the user in creative mode (i.e. able to do anything without restriction)?
creativeMode :: Lens' GameState Bool

-- | How to determine whether the player has won.
winCondition :: Lens' GameState WinCondition

-- | How to win (if possible). This is useful for automated testing
--   and to show help to cheaters (or testers).
winSolution :: Lens' GameState (Maybe ProcessedTerm)

-- | The current 'RunStatus'.
runStatus :: Lens' GameState RunStatus

-- | Whether the game is currently paused.
paused :: Getter GameState Bool
paused = to (\s -> s ^. runStatus /= Running)

-- | All the robots that currently exist in the game, indexed by name.
robotMap :: Lens' GameState (IntMap Robot)

-- | The names of all robots that currently exist in the game, indexed by
--   location (which we need both for /e.g./ the 'Salvage' command as
--   well as for actually drawing the world).  Unfortunately there is
--   no good way to automatically keep this up to date, since we don't
--   just want to completely rebuild it every time the 'robotMap'
--   changes.  Instead, we just make sure to update it every time the
--   location of a robot changes, or a robot is created or destroyed.
--   Fortunately, there are relatively few ways for these things to
--   happen.
robotsByLocation :: Lens' GameState (Map (V2 Int64) IntSet)

-- | The list of entities that have been discovered.
allDiscoveredEntities :: Lens' GameState Inventory

-- | The list of available recipes.
availableRecipes :: Lens' GameState (Notifications (Recipe Entity))

-- | The list of available commands.
availableCommands :: Lens' GameState (Notifications Const)

-- | The names of the robots that are currently not sleeping.
activeRobots :: Getter GameState IntSet
activeRobots = internalActiveRobots

-- | The names of the robots that are currently sleeping, indexed by wake up
--   time. Note that this may not include all sleeping robots, particularly
--   those that are only taking a short nap (e.g. wait 1).
waitingRobots :: Getter GameState (Map Integer [RID])
waitingRobots = internalWaitingRobots

-- | A counter used to generate globally unique IDs.
gensym :: Lens' GameState Int

-- | Pseudorandom generator initialized at start.
randGen :: Lens' GameState StdGen

-- | Read-only list of words, for use in building random robot names.
adjList :: Getter GameState (Array Int Text)
adjList = to _adjList

-- | Read-only list of words, for use in building random robot names.
nameList :: Getter GameState (Array Int Text)
nameList = to _nameList

-- | The catalog of all entities that the game knows about.
entityMap :: Lens' GameState EntityMap

-- | All recipes the game knows about, indexed by outputs.
recipesOut :: Lens' GameState (IntMap [Recipe Entity])

-- | All recipes the game knows about, indexed by inputs.
recipesIn :: Lens' GameState (IntMap [Recipe Entity])

-- | The collection of scenarios that comes with the game.
scenarios :: Lens' GameState ScenarioCollection

-- | The current state of the world (terrain and entities only; robots
--   are stored in the 'robotMap').
world :: Lens' GameState (W.World Int Entity)

------------------------------------------------------------
-- Utilities
------------------------------------------------------------

-- | The current rule for determining the center of the world view.
--   It updates also, viewCenter and focusedRobotName to keep
--   everything synchronize.
viewCenterRule :: Lens' GameState ViewCenterRule
viewCenterRule = lens getter setter
 where
  getter :: GameState -> ViewCenterRule
  getter = _viewCenterRule

  -- The setter takes care of updating viewCenter and focusedRobotName
  -- So non of this fields get out of sync.
  setter :: GameState -> ViewCenterRule -> GameState
  setter g rule =
    case rule of
      VCLocation v2 -> g {_viewCenterRule = rule, _viewCenter = v2}
      VCRobot rid ->
        let robotcenter = g ^? robotMap . ix rid <&> view robotLocation
         in -- retrieve the loc of the robot if it exists, Nothing otherwise.
            -- sometimes, lenses are amazing...
            case robotcenter of
              Nothing -> g
              Just v2 -> g {_viewCenterRule = rule, _viewCenter = v2, _focusedRobotID = rid}

-- | The current center of the world view. Note that this cannot be
--   modified directly, since it is calculated automatically from the
--   'viewCenterRule'.  To modify the view center, either set the
--   'viewCenterRule', or use 'modifyViewCenter'.
viewCenter :: Getter GameState (V2 Int64)
viewCenter = to _viewCenter

-- | Whether the world view needs to be redrawn.
needsRedraw :: Lens' GameState Bool

-- | The current status of the REPL.
replStatus :: Lens' GameState REPLStatus

-- | Whether the repl is currently working.
replWorking :: Getter GameState Bool
replWorking = to (\s -> matchesWorking $ s ^. replStatus)
 where
  matchesWorking REPLDone = False
  matchesWorking (REPLWorking _ _) = True

-- | A queue of global messages.
messageQueue :: Lens' GameState [Text]

-- | The current robot in focus. It is only a Getter because
--   this value should be updated only when viewCenterRule is.
focusedRobotID :: Getter GameState RID
focusedRobotID = to _focusedRobotID

-- | Given a current mapping from robot names to robots, apply a
--   'ViewCenterRule' to derive the location it refers to.  The result
--   is @Maybe@ because the rule may refer to a robot which does not
--   exist.
applyViewCenterRule :: ViewCenterRule -> IntMap Robot -> Maybe (V2 Int64)
applyViewCenterRule (VCLocation l) _ = Just l
applyViewCenterRule (VCRobot name) m = m ^? at name . _Just . robotLocation

-- | Recalculate the veiw center (and cache the result in the
--   'viewCenter' field) based on the current 'viewCenterRule'.  If
--   the 'viewCenterRule' specifies a robot which does not exist,
--   simply leave the current 'viewCenter' as it is. Set 'needsRedraw'
--   if the view center changes.
recalcViewCenter :: GameState -> GameState
recalcViewCenter g =
  g
    { _viewCenter = newViewCenter
    }
    & (if newViewCenter /= oldViewCenter then needsRedraw .~ True else id)
 where
  oldViewCenter = g ^. viewCenter
  newViewCenter = fromMaybe oldViewCenter (applyViewCenterRule (g ^. viewCenterRule) (g ^. robotMap))

-- | Modify the 'viewCenter' by applying an arbitrary function to the
--   current value.  Note that this also modifies the 'viewCenterRule'
--   to match.  After calling this function the 'viewCenterRule' will
--   specify a particular location, not a robot.
modifyViewCenter :: (V2 Int64 -> V2 Int64) -> GameState -> GameState
modifyViewCenter update g =
  g
    & case g ^. viewCenterRule of
      VCLocation l -> viewCenterRule .~ VCLocation (update l)
      VCRobot _ -> viewCenterRule .~ VCLocation (update (g ^. viewCenter))

-- | Given a width and height, compute the region, centered on the
--   'viewCenter', that should currently be in view.
viewingRegion :: GameState -> (Int64, Int64) -> (W.Coords, W.Coords)
viewingRegion g (w, h) = (W.Coords (rmin, cmin), W.Coords (rmax, cmax))
 where
  V2 cx cy = g ^. viewCenter
  (rmin, rmax) = over both (+ (- cy - h `div` 2)) (0, h - 1)
  (cmin, cmax) = over both (+ (cx - w `div` 2)) (0, w - 1)

-- | Find out which robot is currently specified by the
--   'viewCenterRule', if any.
focusedRobot :: GameState -> Maybe Robot
focusedRobot g = g ^? robotMap . ix (g ^. focusedRobotID)

-- | Clear the 'robotLogUpdated' flag of the focused robot.
clearFocusedRobotLogUpdated :: Has (State GameState) sig m => m ()
clearFocusedRobotLogUpdated = do
  n <- use focusedRobotID
  robotMap . ix n . robotLogUpdated .= False

-- | Add an unidentified to the game state: first, generate a unique
--   ID number for it.  Then, add it to the main robot map, the active
--   robot set, and to to the index of robots by location. Return the
--   updated robot.
addURobot :: Has (State GameState) sig m => URobot -> m Robot
addURobot r = do
  rid <- gensym <+= 1
  let r' = setRobotID rid r
  addRobot r'
  return r'

-- | Add a robot to the game state, adding it to the main robot map,
--   the active robot set, and to to the index of robots by
--   location.
addRobot :: Has (State GameState) sig m => Robot -> m ()
addRobot r = do
  let rid = r ^. robotID

  robotMap %= IM.insert rid r
  robotsByLocation
    %= M.insertWith IS.union (r ^. robotLocation) (IS.singleton rid)
  internalActiveRobots %= IS.insert rid

maxMessageQueueSize :: Int
maxMessageQueueSize = 1000

-- | Add a message to the message queue.
emitMessage :: Has (State GameState) sig m => Text -> m ()
emitMessage msg = do
  q <- use messageQueue
  messageQueue %= (msg :) . (if length q >= maxMessageQueueSize then init else id)

-- | The number of ticks elapsed since the game started.
ticks :: Lens' GameState Integer

-- | Takes a robot out of the activeRobots set and puts it in the waitingRobots
--   queue.
sleepUntil :: Has (State GameState) sig m => RID -> Integer -> m ()
sleepUntil rid time = do
  internalActiveRobots %= IS.delete rid
  internalWaitingRobots . at time . non [] %= (rid :)

-- | Takes a robot out of the activeRobots set.
sleepForever :: Has (State GameState) sig m => RID -> m ()
sleepForever rid = internalActiveRobots %= IS.delete rid

-- | Adds a robot to the activeRobots set.
activateRobot :: Has (State GameState) sig m => RID -> m ()
activateRobot rid = internalActiveRobots %= IS.insert rid

-- | Removes robots whose wake up time matches the current game ticks count
--   from the waitingRobots queue and put them back in the activeRobots set
--   if they still exist in the keys of robotMap.
wakeUpRobotsDoneSleeping :: Has (State GameState) sig m => m ()
wakeUpRobotsDoneSleeping = do
  time <- use ticks
  mrids <- internalWaitingRobots . at time <<.= Nothing
  case mrids of
    Nothing -> return ()
    Just rids -> do
      robots <- use robotMap
      let aliveRids = filter (`IM.member` robots) rids
      internalActiveRobots %= IS.union (IS.fromList aliveRids)

deleteRobot :: Has (State GameState) sig m => RID -> m ()
deleteRobot rn = do
  internalActiveRobots %= IS.delete rn
  mrobot <- robotMap . at rn <<.= Nothing
  mrobot `forM_` \robot -> do
    -- Delete the robot from the index of robots by location.
    robotsByLocation . ix (robot ^. robotLocation) %= IS.delete rn

------------------------------------------------------------
-- Initialization
------------------------------------------------------------

-- | Create an initial game state record, first loading entities and
--   recipies from disk.
initGameState :: ExceptT Text IO GameState
initGameState = do
  let guardRight what i = i `isRightOr` (\e -> "Failed to " <> what <> ": " <> e)
  entities <- loadEntities >>= guardRight "load entities"
  recipes <- loadRecipes entities >>= guardRight "load recipes"
  loadedScenarios <- loadScenarios entities >>= guardRight "load scenarios"

  let markEx what a = catchError a (\e -> fail $ "Failed to " <> what <> ": " <> show e)

  (adjs, names) <- liftIO . markEx "load name generation data" $ do
    adjsFile <- getDataFileName "adjectives.txt"
    as <- tail . T.lines <$> T.readFile adjsFile
    namesFile <- getDataFileName "names.txt"
    ns <- tail . T.lines <$> T.readFile namesFile
    return (as, ns)

  return $
    GameState
      { _creativeMode = False
      , _winCondition = NoWinCondition
      , _winSolution = Nothing
      , _runStatus = Running
      , _robotMap = IM.empty
      , _robotsByLocation = M.empty
      , _availableRecipes = mempty
      , _availableCommands = mempty
      , _allDiscoveredEntities = empty
      , _activeRobots = IS.empty
      , _waitingRobots = M.empty
      , _gensym = 0
      , _randGen = mkStdGen 0
      , _adjList = listArray (0, length adjs - 1) adjs
      , _nameList = listArray (0, length names - 1) names
      , _entityMap = entities
      , _recipesOut = outRecipeMap recipes
      , _recipesIn = inRecipeMap recipes
      , _scenarios = loadedScenarios
      , _world = W.emptyWorld 0
      , _viewCenterRule = VCRobot 0
      , _viewCenter = V2 0 0
      , _needsRedraw = False
      , _replStatus = REPLDone
      , _messageQueue = []
      , _focusedRobotID = 0
      , _ticks = 0
      }

-- | Set a given scenario as the currently loaded scenario in the game state.
scenarioToGameState :: Scenario -> Maybe Seed -> Maybe String -> GameState -> IO GameState
scenarioToGameState scenario userSeed toRun g = do
  -- Decide on a seed.  In order of preference, we will use:
  --   1. seed value provided by the user
  --   2. seed value specified in the scenario description
  --   3. randomly chosen seed value
  seed <- case userSeed <|> scenario ^. scenarioSeed of
    Just s -> return s
    Nothing -> randomRIO (0, maxBound :: Int)

  now <- System.Clock.getTime System.Clock.Monotonic
  let robotList' = (robotCreatedAt .~ now) <$> robotList

  return $
    g
      { _creativeMode = scenario ^. scenarioCreative
      , _winCondition = theWinCondition
      , _winSolution = scenario ^. scenarioSolution
      , _runStatus = Running
      , _robotMap = IM.fromList $ map (view robotID &&& id) robotList'
      , _robotsByLocation =
          M.fromListWith IS.union $
            map (view robotLocation &&& (IS.singleton . view robotID)) robotList'
      , _activeRobots = setOf (traverse . robotID) robotList'
      , _availableCommands = Notifications 0 initialCommands
      , _waitingRobots = M.empty
      , _gensym = initGensym
      , _randGen = mkStdGen seed
      , _entityMap = g ^. entityMap <> scenario ^. scenarioEntities
      , _recipesOut = addRecipesWith outRecipeMap recipesOut
      , _recipesIn = addRecipesWith inRecipeMap recipesIn
      , _world = theWorld seed
      , _viewCenterRule = VCRobot baseID
      , _viewCenter = V2 0 0
      , _needsRedraw = False
      , _replStatus = REPLDone
      , _messageQueue = []
      , _focusedRobotID = baseID
      , _ticks = 0
      }
 where
  em = g ^. entityMap

  baseID = 0
  (things, devices) = partition (null . view entityCapabilities) (M.elems (entitiesByName em))
  robotList =
    zipWith setRobotID [0 ..] (scenario ^. scenarioRobots)
      -- If the  --run flag was used, use it to replace the CESK machine of the
      -- robot whose id is 0, i.e. the first robot listed in the scenario.
      & ix 0 . machine
        %~ case toRun of
          Nothing -> id
          Just (into @Text -> f) -> const (initMachine [tmQ| run($str:f) |] Ctx.empty emptyStore)
      -- If we are in creative mode, give robot 0 all the things
      & ix 0 . robotInventory
        %~ case scenario ^. scenarioCreative of
          False -> id
          True -> union (fromElems (map (0,) things))
      & ix 0 . installedDevices
        %~ case scenario ^. scenarioCreative of
          False -> id
          True -> const (fromList devices)

  initialCaps = mconcat $ map (^. robotCapabilities) robotList
  initialCommands =
    filter
      (maybe False (`S.member` initialCaps) . constCaps)
      allConst

  theWorld = W.newWorld . (scenario ^. scenarioWorld)
  theWinCondition = maybe NoWinCondition WinCondition (scenario ^. scenarioWin)
  initGensym = length robotList - 1
  addRecipesWith f gRs = IM.unionWith (<>) (f $ scenario ^. scenarioRecipes) (g ^. gRs)

-- | Create an initial game state for a specific scenario.
initGameStateForScenario :: String -> Maybe Seed -> Maybe String -> ExceptT Text IO GameState
initGameStateForScenario sceneName userSeed toRun = do
  g <- initGameState
  scene <- loadScenario sceneName (g ^. entityMap)
  liftIO $ scenarioToGameState scene userSeed toRun g

-- | For convenience, the 'GameState' corresponding to the classic
--   game with seed 0.
classicGame0 :: ExceptT Text IO GameState
classicGame0 = initGameStateForScenario "classic" (Just 0) Nothing
