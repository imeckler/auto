{-# LANGUAGE FlexibleContexts, LambdaCase, MultiParamTypeClasses,
             NamedFieldPuns, RecordWildCards, TupleSections, CPP #-}
module Mote.Refine where

import           Bag                 (bagToList)
import           Control.Monad.Error (throwError)
import qualified Data.Set            as S
import           HsExpr              (HsExpr (..), LHsExpr)
import           OccName             (mkVarOcc)
import           RdrName             (RdrName (Unqual))
import           SrcLoc              (noLoc, unLoc)
import           Type                (PredType, TyVar, mkForAllTys, mkPiTypes,
                                      splitForAllTys, splitFunTy_maybe)
import           TypeRep             (Type (..))

import           Mote.GhcUtil
import           Mote.Holes
import           Mote.Types
import           Mote.Util

-- Imports for doing subtype testing
import           PrelNames           (itName)
import           RnExpr              (rnLExpr)
import           SrcLoc              (getLoc)
import           TcEvidence          (EvBind (..), EvTerm (..), HsWrapper (..))
import           TcExpr              (tcInferRho)
import           TcMType             (zonkTcType)
import           TcRnMonad
import           TcSimplify          (simplifyInfer, simplifyInteractive)
import           TcType              (UserTypeCtxt (GhciCtxt))
import           TcUnify             (tcSubType)
#if __GLASGOW_HASKELL__ >= 710
import TcType (TcLevel(..))
#endif

-- tcRnExprTc :: LHsExpr RdrName -> TcRn Type
tcRnExprTc rdr_expr = do
  (rn_expr, _fvs) <- rnLExpr rdr_expr
  uniq <- newUnique
  let fresh_it = itName uniq (getLoc rdr_expr)
  -- I guess I could pick up some new holes here, but there's really no
  -- point since in general we might have to load after a refine.
  (((_tc_expr, res_ty), tc_level), lie) <- captureConstraints . captureTcLevel $ tcInferRho rn_expr -- TODO: I have no idea why I use tcInferRho rather than tcInfer
  ((qtvs, dicts, _, _), lie_top) <- captureConstraints $
    simplifyInfer tc_level False [(fresh_it, res_ty)] lie
  simplifyInteractive lie_top
  zonkTcType . mkForAllTys qtvs $ mkPiTypes dicts res_ty

data RefineMatch = RefineMatch
  { refineForAllVars :: [TyVar]
  , refinePredTys    :: [PredType]
  , refineArgTys     :: [Type]
  , refineTarget     :: Type
  , refineEvBinds    :: [EvBind]
  , refineWrapper    :: HsWrapper
  }

-- score :: RefineMatch -> Int
-- score (RefineMatch {..}) = 

refineMatch :: Type -> Type -> TcRn (Maybe RefineMatch)
refineMatch goalTy rty = go [] [] [] rty where
  go tyVars predTys argTys rty = do
    let (tyVars', rty')   = splitForAllTys rty
        (predTys', rty'') = splitPredTys rty'
        tyVars''          = tyVars ++ tyVars'
        predTys''         = predTys ++ predTys'

    (wrapper, b) <- subTypeEvTc (mkForAllTys tyVars'' $ withArgTys predTys'' rty) goalTy
    case allBag (\(EvBind _ t) -> case t of {EvDelayedError {} -> False; _ -> True}) b of
      True -> return . Just $
        RefineMatch
        { refineForAllVars = tyVars''
        , refinePredTys    = predTys''
        , refineTarget     = rty''
        , refineArgTys     = reverse argTys
        , refineEvBinds    = bagToList b
        , refineWrapper    = wrapper
        }

      False -> case splitFunTy_maybe rty'' of
        Nothing            -> return Nothing
        Just (arg, rty''') -> go tyVars'' predTys'' (arg : argTys) rty'''

  withArgTys ts t = foldr (\s r -> FunTy s r) t ts

refineNumArgs :: Type -> Type -> TcRn (Maybe Int)
refineNumArgs goalTy rty = fmap (length . refineArgTys) <$> refineMatch goalTy rty

-- TODO: If the return type doesn't match, assume it's in the
-- middle of a composition. Eg., if the user tries to refine with f
-- and the type of f doesn't match, insert 
-- _ $ f _ _ _ 
-- for the number of args f has
refine :: Ref MoteState -> String -> M (LHsExpr RdrName)
refine stRef eStr = do
  hi    <- holeInfo <$> getCurrentHoleErr stRef
  isArg <- S.member (holeSpan hi) . argHoles <$> gReadRef stRef
  let goalTy = holeType hi

  expr <- parseExpr eStr
  tcmod <- typecheckedModule <$> getFileDataErr stRef
  (nerr, _cons) <- inHoleEnv tcmod hi . captureConstraints $ do
    rty <- tcRnExprTc expr
    refineNumArgs goalTy rty

  case nerr of
    Just n  ->
      let expr' = withNHoles n expr
          atomic =
            case unLoc expr' of
              HsVar {}     -> True
              HsIPVar {}   -> True
              HsOverLit {} -> True
              HsLit {}     -> True
              HsPar {}     -> True
              EWildPat     -> True
              ArithSeq {}  -> True
              _            -> False
      in
      return $ if isArg && not atomic then noLoc (HsPar expr') else expr'

    Nothing -> throwError NoRefine


--    let (tyVars', rty') = splitForAllTys rty
--        tyVars''        = tyVars ++ tyVars'

  -- have to make sure that the hole-local type variables are in scope
  -- for "withBindings"
  {-
  ErrorT . withBindings holeEnv . runErrorT $ do
    expr' <- refineToExpr stRef goalTy =<< parseExpr eStr
-}

withNHoles :: Int -> LHsExpr RdrName -> LHsExpr RdrName
withNHoles n e = app e $ replicate n hole where
  app f args = foldl (\f' x -> noLoc $ HsApp f' x) f args
  hole       = noLoc $ HsVar (Unqual (mkVarOcc "_"))

-- TODO: There's a bug where goal type [a_a2qhr] doesn't accept refinement
-- type [HoleInfo]
-- TODO: Refinement for record constructors
subTypeEvTc t1 t2 = do
  { (wrapper, cons) <- captureConstraints (tcSubType' ctx t1 t2)
  ; (wrapper,) <$> simplifyInteractive cons }
  where
  tcSubType' =
#if __GLASGOW_HASKELL__ < 710
    tcSubType (AmbigOrigin GhciCtxt)
#else
    tcSubType
#endif
  ctx = GhciCtxt

