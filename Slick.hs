{-# LANGUAGE LambdaCase, NamedFieldPuns, OverloadedStrings, RecordWildCards,
             ScopedTypeVariables, TupleSections #-}
module Main where

import           Control.Applicative        ((<$), (<$>))
import           Control.Monad.Error
import           Data.Aeson                 (decodeStrict, encode)
import qualified Data.ByteString            as B
import qualified Data.ByteString.Lazy.Char8 as LB8
import           Data.IORef
import qualified Data.List                  as List
import qualified Data.Map                   as M
import           Data.Maybe                 (isNothing)
import qualified Data.Set                   as S
import qualified DynFlags
import           ErrUtils                   (pprErrMsgBag)
import           Exception
import           FastString                 (fsLit)
import           GHC                        hiding (exprType)
import           GHC.Paths
import           HscTypes                   (srcErrorMessages)
import           Name
import           Outputable
import           System.Directory           (getHomeDirectory,
                                             getModificationTime)
import           System.FilePath
import           System.IO
import           UniqSupply                 (mkSplitUniqSupply)

import           Slick.Case
import           Slick.GhcUtil
import qualified Slick.Holes                as Holes
import           Slick.ParseHoleMessage     (parseHoleInfo)
import           Slick.Protocol
import           Slick.ReadType
import           Slick.Refine
import           Slick.Types
import           Slick.Util

-- Get module name from file text
parseModuleAt :: GhcMonad m => FilePath -> m ParsedModule
parseModuleAt p =
  GHC.parseModule =<< (getModSummary . mkModuleName $ takeBaseName p)

ghcInit :: GhcMonad m => IORef SlickState -> m ()
ghcInit stRef = do
  dfs <- getSessionDynFlags
  void . setSessionDynFlags . withFlags [DynFlags.Opt_DeferTypeErrors] $ dfs
    { hscTarget  = HscInterpreted
    , ghcLink    = LinkInMemory
    , ghcMode    = CompManager
    , log_action = \fs _sev span sty msg -> do
        -- Here be hacks
        let s = showSDoc fs (withPprStyle sty msg)
        logS stRef s
        case parseHoleInfo s of
          Nothing -> return ()
          Just info -> gModifyIORef stRef (\s ->
            s { holesInfo = M.insert span info (holesInfo s) })
    }
  where
  withFlags fs dynFs = foldl DynFlags.gopt_set dynFs fs

-- tcl_lie should contain the CHoleCan's

findEnclosingHole :: (Int, Int) -> [Hole] -> Maybe Hole
findEnclosingHole pos = List.find (`spans` pos)

-- TODO: access ghci cmomands from inside vim too. e.g., kind

-- TODO: Don't die on parse errors
loadModuleAt :: GhcMonad m => FilePath -> m (HsModule RdrName, TypecheckedModule)
loadModuleAt p = do
  -- TODO: Clear old names and stuff
  -- TODO: I think we can actually do all the parsing and stuff ourselves
  -- and then call GHC.loadMoudle to avoid duplicating work
  setTargets . (:[]) =<< guessTarget p Nothing
  load LoadAllTargets
  setContext [IIModule $ mkModuleName (takeBaseName p)] -- TODO: Shouldn't use basename
  parsedMod <- parseModuleAt p
  (unLoc $ parsedSource parsedMod,) <$> typecheckModule parsedMod
-- handleSourceError (return . Left) . fmap Right $ do

-- TODO: This is throwing and it's not clear how to catch
-- the error properly
loadFile :: IORef SlickState -> FilePath -> (M (HsModule RdrName, TypecheckedModule))
loadFile stRef p = eitherThrow =<< lift handled
  where
  getModules = do
    clearOldHoles
    _fs <- getSessionDynFlags
    mods <- loadModuleAt p
    mods <$ setStateForData stRef p mods

  handled = do
    fs <- getSessionDynFlags
    ghandle (\(e :: SomeException) -> Left (OtherError $ show e) <$ clearState stRef) $
      handleSourceError (\e ->
        (Left . GHCError . showErr fs $ srcErrorMessages e) <$ clearState stRef)
        (Right <$> getModules)

  clearOldHoles =
    liftIO $ readIORef stRef >>= \s -> case fileData s of
      Nothing                                         -> return ()
      Just (FileData {path, modifyTimeAtLastLoad}) -> do
        t <- getModificationTime path
        when (t /= modifyTimeAtLastLoad) (resetHolesInfo stRef)

  clearState stRef     = gModifyIORef stRef (\s -> s {fileData = Nothing, currentHole = Nothing})
  showErr fs           = showSDocForUser fs neverQualify . vcat . pprErrMsgBag
  resetHolesInfo stRef =
    gModifyIORef stRef (\s -> s { holesInfo = M.empty })

setStateForData :: GhcMonad m => IORef SlickState -> FilePath -> (HsModule RdrName, TypecheckedModule) -> m ()
setStateForData stRef path (hsModule, typecheckedModule) = do
  modifyTimeAtLastLoad <- liftIO $ getModificationTime path
  let argHoles = Holes.argHoles hsModule
  gModifyIORef stRef (\st -> st
    { fileData    = Just (FileData {path, hsModule, typecheckedModule, modifyTimeAtLastLoad})
    , currentHole = Nothing
    , argHoles
    })
  logS stRef $ show argHoles

srcLocPos :: SrcLoc -> (Int, Int)
srcLocPos (RealSrcLoc l)  = (srcLocLine l, srcLocCol l)
srcLocPos UnhelpfulLoc {} = error "srcLocPos: unhelpful loc"

respond :: IORef SlickState -> FromClient -> Ghc ToClient
respond stRef msg = either (Error . show) id <$> runErrorT (respond' stRef msg)

respond' :: IORef SlickState -> FromClient -> M ToClient
respond' stRef = \case
  Load p -> const Ok <$> loadFile stRef p

  NextHole (ClientState {path, cursorPos=(line,col)}) ->
    getHoles stRef >>| \holes ->
      let mh =
            case dropWhile ((currPosLoc >=) . srcSpanStart) holes of
              [] -> case holes of
                [] -> Nothing
                (h:_) -> Just h
              (h:_) -> Just h
      in
      maybe Ok (SetCursor . srcLocPos . srcSpanStart) mh
    where
    currPosLoc = mkSrcLoc (fsLit path) line col

  -- inefficient
  PrevHole (ClientState {path, cursorPos=(line, col)}) ->
    getHoles stRef >>| \holes ->
      let mxs = case takeWhile (< currPosSpan) holes of
                [] -> case holes of {[] -> Nothing; _ -> Just holes}
                xs -> Just xs
      in
      maybe Ok (SetCursor . srcLocPos . srcSpanStart . last) mxs
    where
    currPosSpan = srcLocSpan (mkSrcLoc (fsLit path) line col)

  EnterHole (ClientState {..}) -> do
    FileData {path=p} <- getFileDataErr stRef
    -- maybe shouldn't autoload
    when (p /= path) (void $ loadFile stRef path)

    mh <- findEnclosingHole cursorPos . M.keys . holesInfo <$> gReadIORef stRef
    gModifyIORef stRef (\st -> st { currentHole = mh })
    return $ case mh of
      Nothing -> SetInfoWindow "No Hole found"
      Just _  -> Ok

  GetEnv (ClientState {..}) -> do
    h               <- getCurrentHoleErr stRef
    _names          <- filter (isNothing . nameModule_maybe) <$> lift getNamesInScope
    (HoleInfo {..}) <- ((M.! h) . holesInfo) <$> gReadIORef stRef
    let goalStr = "Goal: " ++ holeName ++ " :: " ++ holeTypeStr ++ "\n" ++ replicate 40 '-'
        envVarTypes = map (\(x,t) -> x ++ " :: " ++ t) holeEnv

    return (SetInfoWindow $ unlines (goalStr : envVarTypes))

  -- TODO: Switch everything to use error monad
  Refine exprStr (ClientState {..}) -> do
    h     <- getCurrentHoleErr stRef
    expr' <- refine stRef exprStr
    fs    <- lift getSessionDynFlags
    return $
      Replace (toSpan h) path
        (showSDocForUser fs neverQualify (ppr expr'))


  SendStop -> return Stop

  -- Precondition here: Hole has already been entered
  CaseFurther var ClientState {} -> do
    SlickState {..} <- gReadIORef stRef
    FileData {path, hsModule} <- getFileDataErr stRef
    currHole           <- getCurrentHoleErr stRef
    HoleInfo {holeEnv} <- maybeThrow NoHoleInfo $ M.lookup currHole holesInfo
    (_, tyStr)         <- maybeThrow (NoVariable var) $
                            List.find ((== var) . fst) holeEnv

    ty <- readType tyStr
    expansions var ty currHole hsModule >>= \case
      Nothing                    -> return (Error "Variable not found")
      Just ((L sp _mg, mi), matches) -> do
        fs <- lift getSessionDynFlags
        let span              = toSpan sp
            indentLevel       = subtract 1 . snd . fst $ span
            indentTail []     = error "indentTail got []"
            indentTail (s:ss) = s : map (replicate indentLevel ' ' ++) ss

            showMatch :: HsMatchContext RdrName -> Match RdrName (LHsExpr RdrName) -> String
            showMatch ctx = showSDocForUser fs neverQualify . pprMatch ctx
        return $ case mi of
          Equation (L _l name) ->
            Replace (toSpan sp) path . unlines . indentTail $
              map (showMatch (FunRhs name False)) matches

          CaseBranch ->
            -- TODO shouldn't always unlines. sometimes should be ; and {}
            Replace (toSpan sp) path . unlines . indentTail $
              map (showMatch CaseAlt) matches

          SingleLambda _loc ->
            Error "TODO: SingleLambda"

  CaseOn _ -> return $ Error "CaseOn not implemented yet."

  -- every message should really send current file name (ClientState) and
  -- check if it matches the currently loaded file
  GetType e -> do
    fs <- lift getSessionDynFlags
    x  <- exprType e
    return . SetInfoWindow . showSDocForUser fs neverQualify $ ppr x

showM :: (GhcMonad m, Outputable a) => a -> m String
showM = showSDocM . ppr

main :: IO ()
main = do
  home <- getHomeDirectory
  withFile (home </> "slickserverlog") WriteMode $ \logFile -> do
    stRef <- newIORef =<< initialState logFile
    hSetBuffering logFile NoBuffering
    hSetBuffering stdout NoBuffering
    hPutStrLn logFile "Testing, testing"
    runGhc (Just libdir) $ do
      ghcInit stRef
      -- Init.init stRef
      logS stRef "init'd"
      forever $ do
        ln <- liftIO B.getLine
        case decodeStrict ln of
          Nothing  ->
            return ()
          Just msg -> do
            liftIO $ hPutStrLn logFile ("Got: " ++ show msg)
            resp <- respond stRef msg
            liftIO $ hPutStrLn logFile ("Giving: " ++ show resp)
            liftIO $ LB8.putStrLn (encode resp)

initialState :: Handle -> IO SlickState
initialState logFile = mkSplitUniqSupply 'x' >>| \uniq -> SlickState
  { fileData = Nothing
  , currentHole = Nothing
  , holesInfo = M.empty
  , argHoles = S.empty
  , logFile
  , uniq
  }

testStateRef :: IO (IORef SlickState)
testStateRef = do
  h <- openFile "testlog" WriteMode
  newIORef =<< initialState h

runWithTestRef :: (IORef SlickState -> Ghc b) -> IO b
runWithTestRef x = do
  home <- getHomeDirectory
  withFile (home </> "prog/slick/testlog") WriteMode $ \logFile -> do
    r <- newIORef =<< initialState logFile
    run $ do { ghcInit r; x r }


run :: Ghc a -> IO a
run = runGhc (Just libdir)

