{-# LANGUAGE LambdaCase, CPP #-}
module Mote.ReadType where

import           CoAxiom             (Role (Nominal))
import           Control.Monad.Error
import           DynFlags            (ExtensionFlag (Opt_PolyKinds))
import           FamInst             (tcGetFamInstEnvs)
import           FamInstEnv          (normaliseType)
import           GHC                 (Type, runTcInteractive)
import           GhcMonad            (getSession, getSessionDynFlags)
import           HsTypes             (mkImplicitHsForAllTy)
import           Name                (Name)
import           Parser              (parseType)
import           RnEnv               (HsDocContext (GHCiCtx))
import           RnTypes             (rnLHsType)
import           SrcLoc              (noLoc)
import           TcHsType            (tcHsSigType)
import           TcRnMonad           (setXOptM)
import           TcType              (UserTypeCtxt (GhciCtxt))
import Outputable (showSDoc, vcat)
import ErrUtils (pprErrMsgBag)

import           Mote.GhcUtil       (withTyVarsInScope)
import           Mote.Types
import           Mote.Util

-- useful things
-- RnTypes/rnHsTyKi
-- RnTypes/extractHsTysRdrTyVars
-- consider adding undbound type vars to environment

-- c/f TcRnDriver.hs/tcRnType. I just removed the failIfErrsM.
rdrTypeToTypeWithTyVarsInScope tvNames rdr_type = do
  hsc_env <- getSession
  liftIO
    . runTcInteractive hsc_env
    . setXOptM Opt_PolyKinds
    . withTyVarsInScope tvNames
    $ tcRdrTypeToType rdr_type

tcRdrTypeToType rdr_type = do
  (rn_type, _fvs) <- rnLHsType GHCiCtx rdr_type
  ty <- tcHsSigType GhciCtxt rn_type
  fam_envs <- tcGetFamInstEnvs
  let (_, ty') = normaliseType fam_envs Nominal ty
  return ty'

-- any kind quantifications should ideally be pushed in all the way.
-- for now I'm happy to replace

readTypeWithTyVarsInScope :: [Name] -> String -> M Type
readTypeWithTyVarsInScope tvNames str =
  lift (runParserM parseType str) >>= \case
    Left s  -> throwError $ ParseError s
    Right t -> do
      (_, mt) <- lift (rdrTypeToTypeWithTyVarsInScope tvNames t)
      maybe (throwError TypeNotInEnv) return mt


-- Bringing back the old readType for now as readTypeWithTyVarsInScope
-- doesn't work properly yet.
tcGetType rdr_type = do
  hsc_env <- getSession
  liftIO . runTcInteractive hsc_env . setXOptM Opt_PolyKinds $ do
    (rn_type, _fvs) <-
      rnLHsType GHCiCtx
#if MIN_VERSION_ghc(7, 10, 2)
        (noLoc $ mkImplicitHsForAllTy rdr_type)
#else
        (noLoc $ mkImplicitHsForAllTy (noLoc []) rdr_type)
#endif
    ty <- tcHsSigType GhciCtxt rn_type
    fam_envs <- tcGetFamInstEnvs
    let (_, ty') = normaliseType fam_envs Nominal ty
    return ty'

readType :: String -> M Type
readType str = do
  fs <- lift getSessionDynFlags
  lift (runParserM parseType str) >>= \case
    Left s  -> throwError $ ParseError s
    Right t -> do
      ((_warns, errs), mt) <- lift (tcGetType t)
      maybe (throwError (OtherError . showSDoc fs . vcat $ pprErrMsgBag errs)) return mt

