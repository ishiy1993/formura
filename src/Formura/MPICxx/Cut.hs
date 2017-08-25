{-# LANGUAGE DeriveDataTypeable, FlexibleContexts, FlexibleInstances, GeneralizedNewtypeDeriving, ImplicitParams, LambdaCase, MultiParamTypeClasses, MultiWayIf, TemplateHaskell, TypeSynonymInstances #-}

{-

    ＿＿＿＿_＿＿＿＿
  ／＼／＼／ ＼／＼／＼
／＼／＼／＼ ／＼／＼／＼
＼  \   \   |   /   /  ／
  ＼ \  |\  |  /|  / ／
    ＼\ | \ | / | /／
      ＼|  \|/  |／
        ＼  |  ／
          ＼|／

-}

module Formura.MPICxx.Cut where

import           Algebra.Lattice.Levitated
import           Control.Lens
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.Bits(xor)
import           Data.List (sort, groupBy, sortBy)
import           Data.Data
import           Data.Foldable
import           Data.Function (on)
import qualified Data.Map as M
import qualified Data.Sequence as Q
import qualified Data.Set as S
import           Data.Maybe
import           Text.Trifecta (failed, raiseErr)

import qualified Formura.Annotation as A
import           Formura.Annotation.Boundary
import           Formura.CommandLineOption
import           Formura.Syntax(IdentName)
import           Formura.Vec
import           Formura.Geometry
import           Formura.GlobalEnvironment
import           Formura.OrthotopeMachine.Graph
import           Formura.NumericalConfig
import           Formura.Compiler
import qualified Formura.MPICxx.Language as C


newtype MPIRank = MPIRank (Vec Int) deriving (Eq, Ord, Show, Read, Num, Data)
data IRank = IRank IRankComparator (Vec Int) deriving (Eq, Show, Read, Data)
data IRankComparator = IRankCompareStraight | IRankCompareReverse deriving (Eq, Show, Read, Data)

instance Ord IRank where
  (IRank c (Vec xs)) `compare` (IRank _ (Vec ys)) =
    case c of IRankCompareStraight -> xs `compare` ys
              IRankCompareReverse -> reverse xs `compare` reverse ys
  compare _ _ = error "Comparison between IRank (PureVec _) is undefined"

data ResourceT a b = ResourceStatic IdentName a | ResourceOMNode OMNodeID b
                   deriving (Eq, Ord, Show, Read, Typeable, Data)
type Resource = ResourceT () ()
type ConcreteResource = ResourceT (MPIRank, Box) (MPIRank, IRank, Box)

data RidgeID = RidgeID { _ridgeDeltaMPI :: MPIRank, _ridgeDelta :: ResourceT () (IRank, IRank)}
                   deriving (Eq, Ord, Show, Read, Typeable, Data)
makeLenses ''RidgeID

doesRidgeNeedMPI :: RidgeID -> Bool
doesRidgeNeedMPI r = r ^.ridgeDeltaMPI /= MPIRank 0

type Ridge = (RidgeID, Box)

data FacetID = FacetID { _facetDeltaMPI :: MPIRank, _facetIRSrc :: IRank, _facetIRDest :: IRank}
                   deriving (Eq, Ord, Show, Read, Typeable, Data)
makeLenses ''FacetID

data DistributedInst
  = CommunicationWait FacetID                      -- receive a facet via MPI
  | Unstage RidgeID                                -- copy from ridge to slice
  | Computation (IRank, OMNodeID) ArrayResourceKey -- compute a region slice and store them into the resource
  | FreeResource ArrayResourceKey                  -- mark the end of use for given resource
  | Stage RidgeID                                  -- copy from slice to ridge
  | CommunicationSendRecv FacetID                  -- send a facet via MPI
                   deriving (Eq, Ord, Show, Read, Typeable, Data)

type ArrayResourceKey = ResourceT () IRank
newtype ResourceSharingID = ResourceSharingID {fromResourceSharingID :: Int}
                          deriving (Eq, Ord, Read, Data, Num, Enum)
instance Show ResourceSharingID where show = show . fromResourceSharingID

data SendOrRecv = Send | Recv | SendRecv
                deriving (Eq, Ord, Show, Read, Data, Enum)

data MPIPlan = MPIPlan
  { _planArrayAlloc :: M.Map ArrayResourceKey Box
  , _planRidgeAlloc :: M.Map RidgeID Box
  , _planFacetAssignment :: M.Map RidgeID FacetID
  , _planFacetAlloc :: M.Map FacetID [RidgeID]
  , _planRegionAlloc :: M.Map (IRank, OMNodeID) Box
  , _planDistributedProgram :: [DistributedInst]
  , _planSystemOffset :: Vec Int
  , _planResourceSharing :: M.Map ArrayResourceKey ResourceSharingID
  , _planSharedResourceExtent :: Box
  , _planResourceNames :: M.Map ArrayResourceKey C.Src
  , _planSharedResourceNames :: M.Map ResourceSharingID C.Src
  , _planRidgeNames :: M.Map (RidgeID, SendOrRecv) C.Src
  , _planFacetMPITag :: M.Map FacetID Int
  , _planMPIRequestNames :: M.Map FacetID C.Src
  }
makeClassy ''MPIPlan


data PlanRead = PlanRead
  { _prNumericalConfig :: NumericalConfig
  , _prMMProgram :: MMProgram
   }
makeClassy ''PlanRead

instance HasMachineProgram PlanRead MMInstruction OMNodeType where
  machineProgram = prMMProgram
instance HasGlobalEnvironment PlanRead where
  globalEnvironment = omGlobalEnvironment -- via HasMachineProgram
instance HasNumericalConfig PlanRead where
  numericalConfig = prNumericalConfig



data PlanState = PlanState
  { _psSyntacticState :: CompilerSyntacticState
  , _psDistributedProgramQ :: Q.Seq DistributedInst
  , _psAlreadyIssuedInst :: S.Set DistributedInst
  , _psResourceSharing :: M.Map ArrayResourceKey ResourceSharingID
  , _psFreeResourceSharingID :: [ResourceSharingID]
  }
makeClassy ''PlanState

instance HasCompilerSyntacticState PlanState where
  compilerSyntacticState = psSyntacticState

type PlanM = CompilerMonad PlanRead () PlanState

makePlan :: WithCommandLineOption => NumericalConfig -> MMProgram -> IO MPIPlan
makePlan nc prog0 = do
  let pr = PlanRead
           { _prNumericalConfig = nc
           , _prMMProgram = prunedProg
           }
      ps = PlanState
           { _psSyntacticState = defaultCompilerSyntacticState {_compilerStage = "MPI Planning"}
           , _psDistributedProgramQ = Q.empty
           , _psAlreadyIssuedInst = S.empty
           , _psResourceSharing = M.empty
           , _psFreeResourceSharingID = [0..]
           }

      prunedProg = prog0
           & omStepGraph %~ pruneMMGraph

  (ret, _, _) <- runCompilerRight cut pr ps
  return ret

pruneMMGraph :: MMGraph -> MMGraph
pruneMMGraph = M.map (nodeInst %~ pruneMMInst)

pruneMMInst :: MMInstruction -> MMInstruction
pruneMMInst = M.filter (\nd -> case A.viewMaybe nd of
                           Just (NBUSpine True) -> True
                           _ -> False)

getVecAccessor :: PlanM (Vec a -> IdentName -> a)
getVecAccessor = do
  Vec xs <- view axesNames
  let indmap = zip xs [0..]

      go (PureVec y) _ = y
      go (Vec ys) x' = let Just i = lookup x' indmap in ys!!i
  return go

type Walls = Vec [Partition]


initialWalls :: PlanM Walls
initialWalls = do
  axes <- view axesNames
  iwparam <- view ncInitialWalls
  intraShape <- view ncIntraNodeShape
  (!) <- getVecAccessor

  maybeInv <- view ncWallInverted
  let inverted0 = maybeInv == Just True :: Bool


  let boundOfAxis :: String -> Bool -> Int -> Vec (Levitated Int, Levitated Int)
      boundOfAxis x ascending n = flip fmap axes $ \y ->
        if | x == y && (ascending`xor`inverted0) -> (Levitate n, Bottom)
           | x == y                              -> (Top       , Levitate n)
           | otherwise                           -> (Top       , Bottom)
      mkWall :: String -> Bool -> Int -> Partition
      mkWall x a n = let ret = boundOfAxis x a n in Orthotope (fmap fst ret) (fmap snd ret)


  forM axes $ \ x ->
    case M.lookup x iwparam of
     Nothing -> raiseErr $ failed $ "cannot find initial_wall numerical configuration for axis: " ++ x
     Just [] -> raiseErr $ failed $ "at least 1 element is needed for initial_wall numerical configuration for axis: " ++ x
     Just ws -> do
       let ws2
             | inverted0 = reverse $ map (upperWall-) ws
             | otherwise = ws
           upperWall = intraShape ! x
       return $
         [mkWall x True 0] ++
         map (mkWall x False) ws2 ++
         [mkWall x True upperWall]

evalPartition :: Partition -> Int
evalPartition w = case foldMap (maybeToList . touchdown) w of
  [x] -> x
  _   -> error $ "malformed wall: " ++ show w






cut :: WithCommandLineOption => PlanM MPIPlan
cut = do
  dim <- view dimension
  let zeroVec = Vec $ replicate dim 0

  walls0 <- initialWalls
  -- liftIO $ print (walls0 :: Walls)
  -- let wvs = fmap (fmap evalPartition) walls0
  -- liftIO $ print (wvs :: Vec [Int])

  stepGraph <- view omStepGraph

  ncOpts <- view ncOptionStrings

  let wallMap :: M.Map OMNodeID Walls
      wallMap = M.mapWithKey go stepGraph

      go :: OMNodeID -> MMNode -> Walls
      go _ mmNode = let
          mmInst :: MMInstruction
          mmInst = mmNode ^. nodeInst
          --microInsts :: [MMInstF MMNodeID]
          --microInsts = map (^. nodeInst) $ M.elems mmInst
          in foldr1 (&&&) (map listBounds $ M.elems mmInst)

      infinityWall = fmap (fmap (const (mempty :: Partition))) walls0

      listBounds :: MicroNode -> Walls
      listBounds microNd =
        case microNd ^. nodeInst of
             LoadCursorStatic v _ -> move (negate v) walls0
             LoadCursor v nid -> let Just w_of_n = M.lookup nid wallMap
                                 in move (negate v) w_of_n
             _ -> infinityWall

  -- assign the same wall for all the Static nodes
  let wallMap2 = flip M.mapWithKey wallMap $ \nid0 wall0 ->
        case head $ mmInstTails $ (fromJust $ M.lookup nid0 stepGraph) ^. nodeInst of
          Store _ _ -> staticWallConsensus
          _ -> wall0

      staticWalls :: [Walls]
      staticWalls =
        [ fromJust $ M.lookup nid0 wallMap
        | (nid0, mmNode) <- M.toList stepGraph
        , Store _ _ <- mmInstTails $ mmNode ^. nodeInst
        ]

      staticWallConsensus :: Walls
      staticWallConsensus = minimum staticWalls

      systemOffset0 :: Vec Int
      systemOffset0 = fmap (head . fmap evalPartition) staticWallConsensus

  let wallEvolution :: M.Map OMNodeID (Vec [Int])
      wallEvolution = fmap (fmap (fmap evalPartition)) wallMap2

  -- liftIO $ print (wallEvolution :: M.Map OMNodeID (Vec [Int]))

  intraShape0 <- view ncIntraNodeShape

  maybeInv <- view ncWallInverted
  let inverted0 = maybeInv == Just True :: Bool


  let iRanks0 :: [IRank]
      iRanks0 =
        (if inverted0 then reverse else id) $
        sort $
        map (IRank iRankComparator) $
        sequence $
        fmap (\partitions0 -> [0..length partitions0-2]) walls0

      iRankComparator
        | "irank-order-f" `elem` ncOpts = IRankCompareStraight
        | otherwise                     = IRankCompareReverse

      boxAt :: IRank -> Vec [Int] -> Box
      boxAt (IRank _ vi) vw = Orthotope (liftVec2 (\i xs-> xs!!i) vi vw) (liftVec2 (\i xs-> xs!!(i+1)) vi vw)

      iRankMap :: M.Map OMNodeID (M.Map IRank Box)
      iRankMap = flip fmap wallEvolution $ \vi -> M.fromList
        [(ir, boxAt ir vi)| ir <- iRanks0]

      boxAssignment :: MPIRank -> IRank -> OMNodeID -> Box
      boxAssignment (MPIRank mpir) ir nid = fromJust $ do
        m <- M.lookup nid iRankMap
        ret <- M.lookup ir m
        return $ move (mpir*intraShape0) ret

      mpiRanks0 :: [MPIRank]
      mpiRanks0 =
        map MPIRank $
        (sequence :: Vec [Int] -> [Vec Int]) $
        Vec $
        replicate dim [-1,0,1]
      mpiRankOrigin :: MPIRank
      mpiRankOrigin = MPIRank zeroVec

      mpiBox0 :: Box
      mpiBox0 = Orthotope zeroVec intraShape0

{-
  liftIO $ forM_ (M.keys stepGraph) $ \nid -> do
    putStrLn $ "NODE: " ++ show nid
    forM_ iRanks0 $ \ir -> do
      putStrLn $ "  IR: " ++ show ir
      putStrLn $ "    " ++ show (boxAssignment mpiRankOrigin ir nid)
-}
  let supportMap :: M.Map (IRank, OMNodeID) (M.Map Resource Box)
      supportMap = M.fromList [((ir, nid), go ir nid (fromJust $ M.lookup nid stepGraph))
                              | ir <- iRanks0, nid <- M.keys stepGraph]

      go :: IRank -> OMNodeID -> MMNode -> M.Map Resource Box
      go ir nid mmNode = let
          mmInst :: MMInstruction
          mmInst = mmNode ^. nodeInst
          microInsts :: [MMInstF MMNodeID]
          microInsts = map (^. nodeInst) $ M.elems mmInst
          b0 = boxAssignment mpiRankOrigin ir nid
        in M.unionsWith (|||) (map (listSupport b0) microInsts)

      listSupport :: Box -> MMInstF MMNodeID -> M.Map Resource Box
      listSupport b0 (LoadCursorStatic v snName) = M.singleton (ResourceStatic snName ()) (move v b0)
      listSupport b0 (LoadCursor v nid) =
        M.singleton (ResourceOMNode nid ()) (move v b0)
      listSupport _ _ = M.empty

  {-
  liftIO $ forM_ iRanks0 $ \ir -> do
    putStrLn $ "IR: " ++ show ir
    forM_ (M.keys stepGraph) $ \nid -> do
      putStrLn $ "  NODE: " ++ show nid
      putStrLn $ "    " ++ show (M.lookup (ir,nid) supportMap)
-}

  let locateSources :: IRank -> (Resource, Box) -> [ConcreteResource]
      locateSources irDest (ResourceOMNode nid (),b0) =
        [ ResourceOMNode nid (mpir, ir, b01)
        | (mpir,ir,b1) <- fromJust $ M.lookup nid allPossibleSources
        , mpir /= mpiRankOrigin || ir /= irDest
        , let b01 = b0 &&& b1
        , volume b01 > 0]
      locateSources _ (ResourceStatic snName (),b0) =
        [ ResourceStatic snName (mpir, b01)
        | (mpir,b1) <- allPossibleSourcesStatic
        , mpir /= mpiRankOrigin
        , let b01 = b0 &&& b1
        , volume b01 > 0
        ]


      allPossibleSources :: M.Map OMNodeID [(MPIRank, IRank, Box)]
      allPossibleSources = M.fromList
                           [ (nid, [(mpir, ir, boxAssignment mpir ir nid)
                                   | mpir <- mpiRanks0
                                   , ir <- iRanks0])
                           | nid <- M.keys stepGraph
                           ]

      allPossibleSourcesStatic :: [(MPIRank, Box)]
      allPossibleSourcesStatic =
        [ (mpir,b)
        | mpir@(MPIRank mpiVec) <- mpiRanks0
        , let b = move (mpiVec*intraShape0) mpiBox0
        ]


  let ridgeAndBoxRequest :: M.Map (IRank, OMNodeID) [Ridge]
      ridgeAndBoxRequest = M.mapWithKey go supportMap

      ridgeRequest :: M.Map (IRank, OMNodeID) [RidgeID]
      ridgeRequest = M.map (map fst) ridgeAndBoxRequest

      ridgeFirstNeededAt :: M.Map RidgeID IRank
      ridgeFirstNeededAt = M.unionsWith (\a _ -> a)
        [ M.singleton rid ir
        | ir <- iRanks0
        , nid <- M.keys stepGraph
        , rid <- maybe [] id $ M.lookup (ir, nid) ridgeRequest
        ]


      go :: (IRank, OMNodeID) -> M.Map Resource Box -> [Ridge]
      go (ir, _) rbmap =
        [ mkRidge ir crsc
        | (rsc,b0) <- M.toList rbmap
        , crsc <- locateSources ir (rsc,b0)
        ]

      mkRidge :: IRank -> ConcreteResource -> Ridge
      mkRidge _      (ResourceStatic sn (mpir, b))         = (RidgeID mpir (ResourceStatic sn ())               ,b)
      mkRidge irDest (ResourceOMNode nid (mpir, irSrc, b)) = (RidgeID mpir (ResourceOMNode nid (irSrc, irDest)) ,b)

      allRidges :: M.Map RidgeID Box
      allRidges = M.unionsWith (|||) $ map (uncurry M.singleton) $ concat $  M.elems ridgeAndBoxRequest

  let ridgeProvide :: M.Map (ResourceT () IRank) [RidgeID]
      ridgeProvide = foldr (M.unionWith (++)) M.empty $ map mkProvide $ M.keys allRidges

      mkProvide :: RidgeID -> M.Map (ResourceT () IRank) [RidgeID]
      mkProvide ridge0@(RidgeID _ drsc) = case drsc of
        ResourceStatic sn () -> M.singleton (ResourceStatic sn ()) [ridge0]
        ResourceOMNode nid (iSrc,_) -> M.singleton (ResourceOMNode nid iSrc) [ridge0]

      facetAssignment :: M.Map RidgeID FacetID
      facetAssignment = M.fromList
        [ (r, FacetID (r ^. ridgeDeltaMPI) irSrc irDest)
        | r <- M.keys allRidges
        , doesRidgeNeedMPI r
        , let Just irDest = M.lookup r ridgeFirstNeededAt
        , let irSrc = case r ^. ridgeDelta of
                ResourceStatic _ _     -> head iRanks0
                ResourceOMNode _ (x,_) -> x]

      allFacets :: M.Map FacetID [RidgeID]
      allFacets = M.unionsWith (++) [M.singleton f [r] | (r,f) <- M.toList facetAssignment]


  let insert :: DistributedInst -> PlanM ()
      insert inst = do
        psAlreadyIssuedInst %= S.insert inst
        psDistributedProgramQ %= (Q.|> inst)

      insertOnce :: DistributedInst -> PlanM ()
      insertOnce inst = do
        aii <- use psAlreadyIssuedInst
        unless (S.member inst aii) $ insert inst

  stateSignature0 <- view omStateSignature


  forM_ (M.keys stateSignature0) $ \snName -> do
      let outRidges = fromMaybe [] $ M.lookup (ResourceStatic snName ()) ridgeProvide

      forM_ outRidges $ \rdg0 -> insertOnce $ Stage rdg0


  forM_ iRanks0 $ \ir -> do
    sequence [ insert $ CommunicationWait f
             | f <- M.keys allFacets
             , f ^. facetIRDest == ir]
    forM_ (M.keys stepGraph) $ \nid -> do
      let inRidges  = fromMaybe [] $ M.lookup (ir,nid) ridgeRequest
          outRidges = fromMaybe [] $ M.lookup (ResourceOMNode nid ir) ridgeProvide

      forM_ inRidges $ \rdg0 -> insertOnce $ Unstage rdg0

      let tailRsc :: ArrayResourceKey
          tailRsc = case head $ mmInstTails mmInst of
            Store snName _ -> ResourceStatic snName ()
            _              -> ResourceOMNode nid ir

          mmInst = fromJust (M.lookup nid stepGraph) ^. nodeInst

      insert $ Computation (ir, nid) tailRsc

      forM_ outRidges $ \rdg0 -> insertOnce $ Stage rdg0

    sequence [ insert $ CommunicationSendRecv f
             | f <- M.keys allFacets
             , f ^. facetIRSrc == ir]




  let allAllocs :: M.Map (ResourceT () IRank) Box
      allAllocs = M.unionsWith (|||) $ basicAllocStatic : basicAllocOMNode : ridgeMargins

      basicAllocStatic = M.fromList [(ResourceStatic sn (), mpiBox0) | sn <- M.keys stateSignature0]
      basicAllocOMNode = M.fromList [(ResourceOMNode nid ir, boxAssignment mpiRankOrigin ir nid)
                                    | ir <- iRanks0, nid <- M.keys stepGraph ]

      ridgeMargins = map mkRidgeMargin $ M.toList allRidges

      mkRidgeMargin :: Ridge -> M.Map (ResourceT () IRank) Box
      mkRidgeMargin (RidgeID _ drsc, box0) = case drsc of
        ResourceStatic sn () -> M.singleton (ResourceStatic sn ()) box0
        ResourceOMNode nid (_,iDest) -> M.singleton (ResourceOMNode nid iDest) box0


  dProg0 <- toList <$> use psDistributedProgramQ

  -- insert Free
  let numberedProg :: [(Double, DistributedInst)]
      numberedProg = zip [0..] dProg0

      lastUsed :: M.Map ArrayResourceKey Double
      lastUsed = M.unionsWith max
        [ M.singleton (ResourceOMNode nid2 ir) ln
        | (ln, Computation (ir,nid) _) <- numberedProg
        , Just rscmap <- [M.lookup (ir,nid) supportMap]
        , ResourceOMNode nid2 () <- M.keys rscmap
        ]

      numberedFrees = [ (ln+0.5, FreeResource ark)
                      | (ark, ln) <- M.toList lastUsed]
      dProg1 = map snd $ sort $ numberedProg ++ numberedFrees

  -- simulate resource alloc/free and assign ResourceSharingID
  forM_ dProg1 $ \case
    FreeResource rsc -> do
      rsmap <- use psResourceSharing
      case M.lookup rsc rsmap of
        Just id0 -> psFreeResourceSharingID %= (id0:)
        Nothing -> return ()
    Computation _ destRsc@(ResourceOMNode _ _) -> do
      rsmap <- use psResourceSharing
      case M.lookup destRsc rsmap of
        Just _ ->  return ()
        Nothing -> do
          (id0:ids) <- use psFreeResourceSharingID
          psResourceSharing %= M.insert destRsc id0
          psFreeResourceSharingID .= ids

    _ -> return ()

  resourceSharing0 <- use psResourceSharing

  let largestBox :: Box
      largestBox = maximum
        [ Orthotope 0 (u-l)
        | (ResourceOMNode _ _, Orthotope l u) <- M.toList allAllocs ]

  when (?commandLineOption ^. verbose) $ liftIO $ do
    putStrLn "#### Allocation List ####"
    forM_ (M.toList allAllocs) $ \(rsc, box0) -> do
      print rsc
      putStrLn $ "  " ++ show box0

    putStrLn "#### Resource Sharing ####"
    let s = M.unionsWith (++) [ M.singleton i [r] | (r,i) <- M.toList resourceSharing0]
    forM_ (M.toList s) $ \(i, rs) -> do
      print i
      forM_ rs $ \rsc -> putStrLn $ "  " ++ show rsc

    putStrLn "#### Ridge List ####"
    forM_ (M.toList allRidges) $ \(rid, box) -> do
      putStrLn $ show rid
      putStrLn $ "  " ++ show box

    putStrLn "#### Facet List ####"
    forM_ (M.toList allFacets) $ \(f,rs) -> do
      putStrLn $ show f
      putStrLn $ "  " ++ show rs

    putStrLn "#### Program ####"
    mapM_ print dProg1



  return MPIPlan
    { _planArrayAlloc = allAllocs
    , _planRidgeAlloc = allRidges
    , _planFacetAlloc = allFacets
    , _planFacetAssignment = facetAssignment
    , _planRegionAlloc = M.fromList
      [ ((ir,nid), boxAssignment mpiRankOrigin ir nid)
      | ir <- iRanks0
      , nid <- M.keys stepGraph
      ]
    , _planDistributedProgram = optimizeCommunicationsOrder dProg1
    , _planSystemOffset = systemOffset0
    , _planResourceSharing = resourceSharing0
    , _planSharedResourceExtent = largestBox
    , _planResourceNames = M.empty
    , _planSharedResourceNames = M.empty
    , _planRidgeNames = M.empty
    , _planFacetMPITag = M.fromList $ zip (M.keys allFacets) [0..]
    , _planMPIRequestNames = M.empty
    }


optimizeCommunicationsOrder :: [DistributedInst] ->  [DistributedInst]
optimizeCommunicationsOrder dprog = dprog1
  where
    waitOrder :: M.Map FacetID Int
    waitOrder = M.fromList [(fid, i)| (i, CommunicationWait fid) <- zip [0..] dprog ]

    groupedProg :: [[DistributedInst]]
    groupedProg = groupBy bothComm dprog

    dprog1 = concatMap (sortBy (compare `on` maybeWaitOrder)) groupedProg


    bothComm (CommunicationSendRecv _) (CommunicationSendRecv _) = True
    bothComm _ _ = False

    maybeWaitOrder :: DistributedInst -> Maybe Int
    maybeWaitOrder (CommunicationSendRecv fid) = M.lookup fid waitOrder
    maybeWaitOrder _ = Nothing
