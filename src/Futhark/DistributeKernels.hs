{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
-- | Distribute kernels.
-- In the following, I will use the term "width" to denote the amount
-- of immediate parallelism in a map - that is, the row size of the
-- array(s) being used as input.
--
-- = Basic Idea
--
-- If we have:
--
-- @
--   map
--     map(f)
--     bnds_a...
--     map(g)
-- @
--
-- Then we want to distribute to:
--
-- @
--   map
--     map(f)
--   map
--     bnds_a
--   map
--     map(g)
-- @
--
-- But for now only if
--
--  (0) it can be done without creating irregular arrays.
--      Specifically, the size of the arrays created by @map(f)@, by
--      @map(g)@ and whatever is created by @bnds_a@ that is also used
--      in @map(g)@, must be invariant to the outermost loop.
--
--  (1) the maps are _balanced_.  That is, the functions @f@ and @g@
--      must do the same amount of work for every iteration.
--
-- The advantage is that the map-nests containing @map(f)@ and
-- @map(g)@ can now be trivially flattened at no cost, thus exposing
-- more parallelism.  Note that the @bnds_a@ map constitutes array
-- expansion, which requires additional storage.
--
-- = Distributing Sequential Loops
--
-- As a starting point, sequential loops are treated like scalar
-- expressions.  That is, not distributed.  However, sometimes it can
-- be worthwhile to distribute if they contain a map:
--
-- @
--   map
--     loop
--       map
--     map
-- @
--
-- If we distribute the loop and interchange the outer map into the
-- loop, we get this:
--
-- @
--   loop
--     map
--       map
--   map
--     map
-- @
--
-- Now more parallelism may be available.
--
-- = Unbalanced Maps
--
-- Unbalanced maps will as a rule be sequentialised, but sometimes,
-- there is another way.  Assume we find this:
--
-- @
--   map
--     map(f)
--       map(g)
--     map
-- @
--
-- Presume that @map(f)@ is unbalanced.  By the simple rule above, we
-- would then fully sequentialise it, resulting in this:
--
-- @
--   map
--     loop
--   map
--     map
-- @
--
-- == Balancing by Loop Interchange
--
-- This is not ideal, as we cannot flatten the @map-loop@ nest, and we
-- are thus limited in the amount of parallelism available.
--
-- But assume now that the width of @map(g)@ is invariant to the outer
-- loop.  Then if possible, we can interchange @map(f)@ and @map(g)@,
-- sequentialise @map(f)@ and distribute:
--
-- @
--   loop(f)
--     map
--       map(g)
--   map
--     map
-- @
--
-- After flattening the two nests we can obtain more parallelism.
--
-- When distributing a map, we also need to distribute everything that
-- the map depends on - possibly as its own map.  When distributing a
-- set of scalar bindings, we will need to know which of the binding
-- results are used afterwards.  Hence, we will need to compute usage
-- information.
--
-- = Redomap
--
-- Redomap is handled much like map.  Distributed loops are
-- distributed as maps, with the parameters corresponding to the
-- neutral elements added to their bodies.  The remaining loop will
-- remain a redomap.  Example:
--
-- @
-- redomap(op,
--         fn (acc,v) =>
--           map(f)
--           map(g),
--         e,a)
-- @
--
-- distributes to
--
-- @
-- let b = map(fn v =>
--               let acc = e
--               map(f),
--               a)
-- redomap(op,
--         fn (acc,v,dist) =>
--           map(g),
--         e,a,b)
-- @
--
module Futhark.DistributeKernels
       (transformProg)
       where

import Control.Applicative
import Control.Monad.RWS.Strict
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Trans.Maybe
import qualified Data.HashMap.Lazy as HM
import qualified Data.HashSet as HS
import Data.Maybe
import Data.List
import Debug.Trace

import Futhark.Representation.Basic
import Futhark.MonadFreshNames
import Futhark.Tools
import qualified Futhark.FirstOrderTransform as FOT
import Futhark.Renamer
import Futhark.Util

import Prelude

transformProg :: Prog -> Prog
transformProg = intraproceduralTransformation transformFunDec

transformFunDec :: MonadFreshNames m => FunDec -> m FunDec
transformFunDec fundec = runDistribM $ do
  body' <- localTypeEnv (typeEnvFromParams $ funDecParams fundec) $
           transformBody $ funDecBody fundec
  return fundec { funDecBody = body' }

type DistribM = ReaderT TypeEnv (State VNameSource)

runDistribM :: MonadFreshNames m => DistribM a -> m a
runDistribM m = modifyNameSource $ runState (runReaderT m HM.empty)

transformBody :: Body -> DistribM Body
transformBody body = transformBindings (bodyBindings body) $
                     return $ resultBody $ bodyResult body

transformBindings :: [Binding] -> DistribM Body -> DistribM Body
transformBindings [] m =
  m
transformBindings (bnd:bnds) m = do
  bnd' <- transformBinding bnd
  localTypeEnv (typeEnvFromBindings bnd') $
    insertBindings bnd' <$> transformBindings bnds m

transformBinding :: Binding -> DistribM [Binding]
transformBinding (Let pat () (If c tb fb rt)) = do
  tb' <- transformBody tb
  fb' <- transformBody fb
  return [Let pat () $ If c tb' fb' rt]
transformBinding (Let pat () (LoopOp (DoLoop res mergepat form body))) =
  localTypeEnv (boundInForm form $ typeEnvFromParams mergeparams) $ do
    body' <- transformBody body
    return [Let pat () $ LoopOp $ DoLoop res mergepat form body']
  where boundInForm (ForLoop i _) = HM.insert i (Basic Int)
        boundInForm (WhileLoop _) = id
        mergeparams = map fst mergepat
transformBinding (Let pat () (LoopOp (Map cs lam arrs))) =
  distributeMap pat $ MapLoop cs lam arrs
transformBinding bnd = return [bnd]

data MapLoop = MapLoop Certificates Lambda [VName]

mapLoopExp :: MapLoop -> Exp
mapLoopExp (MapLoop cs lam arrs) = LoopOp $ Map cs lam arrs

type Target = (Pattern, Result)

-- ^ First pair element is the very innermost ("current") target.  In
-- the list, the outermost target comes first.
type Targets = (Target, [Target])

singleTarget :: Target -> Targets
singleTarget = (,[])

innerTarget :: Targets -> Target
innerTarget = fst

outerTarget :: Targets -> Target
outerTarget (inner_target, []) = inner_target
outerTarget (_, outer_target : _) = outer_target

pushOuterTarget :: Target -> Targets -> Targets
pushOuterTarget target (inner_target, targets) =
  (inner_target, target : targets)

pushInnerTarget :: Target -> Targets -> Targets
pushInnerTarget target (inner_target, targets) =
  (target, targets ++ [inner_target])

data Nesting = MapNesting Pattern Certificates [(LParam, VName)]
             deriving (Show)

-- ^ First pair element is the very innermost ("current") nest.  In
-- the list, the outermost nest comes first.
type Nestings = (Nesting, [Nesting])

singleNesting :: Nesting -> Nestings
singleNesting = (,[])

pushInnerNesting :: Nesting -> Nestings -> Nestings
pushInnerNesting nesting (inner_nesting, nestings) =
  (nesting, nestings ++ [inner_nesting])

nestingWidth :: Nesting -> SubExp
nestingWidth = arraysSize 0 . patternTypes . nestingPattern

nestingPattern :: Nesting -> Pattern
nestingPattern (MapNesting pat _ _) = pat

nestingParams :: Nesting -> [LParam]
nestingParams (MapNesting _ _ params_and_arrs) =
  map fst params_and_arrs

boundInNesting :: Nesting -> [VName]
boundInNesting = map paramName . nestingParams

data KernelEnv = KernelEnv { kernelLetBound :: Names
                           , kernelNest :: Nestings
                           , kernelTypeEnv :: TypeEnv
                           }

data KernelAcc = KernelAcc { kernelTargets :: Targets
                           , kernelBindings :: [Binding]
                           , kernelRequires :: Names
                           }

addBindingToKernel :: Binding -> KernelAcc -> KernelAcc
addBindingToKernel bnd acc =
  acc { kernelBindings = bnd : kernelBindings acc }

type PostKernels = [Binding]

newtype KernelM a = KernelM (RWS KernelEnv PostKernels VNameSource a)
  deriving (Functor, Applicative, Monad,
            MonadReader KernelEnv,
            MonadWriter PostKernels,
            MonadFreshNames)

instance HasTypeEnv KernelM where
  askTypeEnv = asks kernelTypeEnv

runKernelM :: (HasTypeEnv m, MonadFreshNames m) =>
              KernelEnv -> KernelM a -> m (a, [Binding])
runKernelM env (KernelM m) = modifyNameSource $ getKernels . runRWS m env
  where getKernels (x,s,a) = ((x, a), s)

distributeMap :: (HasTypeEnv m, MonadFreshNames m) =>
                 Pattern -> MapLoop -> m [Binding]
distributeMap pat (MapLoop cs lam arrs) = do
  types <- askTypeEnv
  let env = KernelEnv { kernelNest =
                        singleNesting (MapNesting pat cs $
                                       zip (lambdaParams lam) arrs)
                      , kernelLetBound = mempty
                      , kernelTypeEnv =
                        types <> typeEnvFromParams (lambdaParams lam)
                      }
  liftM (reverse . snd) $ runKernelM env $
    distribute =<< distributeMapBodyBindings acc (bodyBindings $ lambdaBody lam)
    where acc = KernelAcc { kernelTargets = singleTarget (pat, bodyResult $ lambdaBody lam)
                          , kernelRequires = mempty
                          , kernelBindings = mempty
                          }

withBinding :: Binding -> KernelM a -> KernelM a
withBinding bnd = local $ \env ->
  env { kernelTypeEnv =
          kernelTypeEnv env <> typeEnvFromBindings [bnd]
      , kernelLetBound =
          kernelLetBound env <>
          HS.fromList (patternNames (bindingPattern bnd))
      }

mapNesting :: Pattern -> Certificates -> Lambda -> [VName]
           -> KernelM a
           -> KernelM a
mapNesting pat cs lam arrs = local $ \env ->
  env { kernelNest = pushInnerNesting nest $ kernelNest env
      , kernelTypeEnv = kernelTypeEnv env <>
                        typeEnvFromParams (lambdaParams lam)
      }
  where nest = MapNesting pat cs (zip (lambdaParams lam) arrs)

newKernelNames :: Names -> Body -> Names
newKernelNames let_bound inner_body =
  freeInBody inner_body `HS.intersection` let_bound

ppTargets :: Targets -> String
ppTargets (target, targets) =
  unlines $ map ppTarget $ targets ++ [target]
  where ppTarget (pat, res) =
          pretty pat ++ " <- " ++ pretty res

ppNestings :: Nestings -> String
ppNestings (nesting, nestings) =
  unlines $ map ppNesting $ nestings ++ [nesting]
  where ppNesting (MapNesting _ _ params_and_arrs) =
          pretty (map fst params_and_arrs) ++
          " <- " ++
          pretty (map snd params_and_arrs)

distribute :: KernelAcc -> KernelM KernelAcc
distribute acc = do
  env <- ask
  let bnds = kernelBindings acc
      res = snd $ innerTarget $ kernelTargets acc
  if null bnds -- No point in distributing an empty kernel.
    then return acc
    else createKernelNest (kernelLetBound env) (kernelNest env)
         (kernelTargets acc) (mkBody bnds res) >>=
         \case
           Just (distributed, targets) -> do
             distributed' <- renameBinding distributed
             trace ("distributing\n" ++
                    pretty (mkBody bnds res) ++
                    "\nas\n" ++ pretty distributed ++
                    "\ndue to targets\n" ++ ppTargets (kernelTargets acc) ++
                    "\nand with new targets\n" ++ ppTargets targets) tell [distributed']
             return KernelAcc { kernelBindings = []
                              , kernelRequires = mempty
                              , kernelTargets = targets
                              }
           Nothing ->
             return acc

createKernelNest :: Names -> Nestings -> Targets
                 -> Body
                 -> KernelM (Maybe (Binding, Targets))
createKernelNest
  let_bound
  (inner_nest, nests)
  (inner_target@(inner_pat,_), targets)
  inner_body = do
    unless (length nests == length targets) $
      fail $ "Nests and targets do not match!\n" ++
      "nests: " ++ ppNestings (inner_nest, nests) ++
      "\ntargets:" ++ ppTargets (inner_target, targets)
    runMaybeT (recurse $ zip nests targets)

  where patternMapTypes =
          map rowType . patternTypes
        let_and_nestings_bound =
          let_bound <> HS.fromList (concatMap boundInNesting $ inner_nest : nests)
        liftedTypeOK =
          HS.null . HS.intersection let_and_nestings_bound . freeIn . arrayDims

        distributeAtNesting :: Nesting
                            -> Pattern
                            -> Body
                            -> [Ident]
                            -> (Target -> Targets)
                            -> MaybeT KernelM (Binding, Targets)
        distributeAtNesting
          (nest@(MapNesting _ cs params_and_arrs))
          pat
          body
          inner_returned_arrs
          addTarget = do
          let (params,arrs) = unzip params_and_arrs
              width = nestingWidth nest
              (pat', body', identity_map, expand_target) =
                removeIdentityMapping pat body
              required_res = newKernelNames let_bound body'
              (used_params, used_arrs) =
                unzip $
                filter ((`HS.member` freeInBody body') . paramName . fst) $
                zip params arrs

          required_res_idents <- forM (HS.toList required_res) $ \name -> do
            t <- lift $ lookupType name
            return $ Ident name t

          (free_params, free_arrs, bind_in_target) <-
            liftM unzip3 $
            forM (inner_returned_arrs++required_res_idents) $ \(Ident pname ptype) -> do
              unless (liftedTypeOK ptype) $
                fail "Would induce irregular array"
              case HM.lookup pname identity_map of
                Nothing -> do
                  arr <- newIdent (baseString pname ++ "_r") $
                         arrayOfRow ptype width
                  return (Param (Ident pname ptype) (),
                          arr,
                          True)
                Just arr ->
                  return (Param (Ident pname ptype) (),
                          arr,
                          False)

          let free_arrs_pat =
                basicPattern [] $ map ((,BindVar) . snd) $
                filter fst $ zip bind_in_target free_arrs
              free_params_pat =
                map snd $ filter fst $ zip bind_in_target free_params
              rettype = patternMapTypes pat'

              (actual_params, actual_arrs) =
                case (used_params++free_params,
                      used_arrs++map identName free_arrs) of
                 ([], []) -> (params,arrs) -- XXX - we want to avoid
                                           -- empty argument lists.
                 l        -> l

          return (Let pat' () $ LoopOp $
                  Map cs (Lambda actual_params body' rettype) actual_arrs,

                  addTarget $ expand_target
                  (free_arrs_pat, map (Var . paramName) free_params_pat))

        recurse :: [(Nesting,Target)]
                -> MaybeT KernelM (Binding, Targets)
        recurse [] =
          distributeAtNesting
            inner_nest
            inner_pat
            inner_body
            []
            singleTarget

        recurse ((nest, (pat,res)) : nests') = do
          (inner, inner_targets) <- recurse nests'
          distributeAtNesting
            nest
            pat
            (mkBody [inner] res)
            (patternIdents $ fst $ outerTarget inner_targets)
            (`pushOuterTarget` inner_targets)

removeIdentityMapping :: Pattern -> Body
                      -> (Pattern,
                          Body, HM.HashMap VName Ident,
                          Target -> Target)
removeIdentityMapping pat body =
  let (identities, not_identities) =
        mapEither isIdentity $ zip (patternElements pat) (bodyResult body)
      (not_identity_patElems, not_identity_res) = unzip not_identities
      (identity_patElems, identity_res) = unzip identities
      expandTarget (tpat, tres) =
        (Pattern [] $ patternElements tpat ++ identity_patElems,
         tres ++ map Var identity_res)
      inIdentityRes = HM.fromList $ zip identity_res $
                      map patElemIdent identity_patElems
  in (Pattern [] not_identity_patElems,
      body { bodyResult = not_identity_res },
      inIdentityRes,
      expandTarget)
  where bound_in_body = mconcat $
                        map (patternNames . bindingPattern) $
                        bodyBindings body

        isIdentity (patElem, Var v)
          | v `notElem` bound_in_body = Left (patElem, v)
        isIdentity x                  = Right x

unbalancedMap :: MapLoop -> KernelM Bool
unbalancedMap = const $ return False

distributeInnerMap :: Pattern -> MapLoop -> KernelAcc
                   -> KernelM KernelAcc
distributeInnerMap pat maploop@(MapLoop cs lam arrs) acc =
  unbalancedMap maploop >>= \case
    True ->
      foldl (flip addBindingToKernel) acc <$>
      liftM snd (runBinder $ FOT.transformBinding $
                 Let pat () $ mapLoopExp maploop)
    False ->
      liftM leavingNesting $
      mapNesting pat cs lam arrs $
      distribute =<<
      distributeMapBodyBindings acc' (bodyBindings $ lambdaBody lam)
      where acc' = KernelAcc { kernelTargets = pushInnerTarget
                                               (pat, bodyResult $ lambdaBody lam) $
                                               kernelTargets acc
                             , kernelRequires = mempty
                             , kernelBindings = mempty
                             }

leavingNesting :: KernelAcc -> KernelAcc
leavingNesting acc =
  acc { kernelTargets =
           case reverse $ snd $ kernelTargets acc of
             [] -> error "The kernel targets list is unexpectedly empty"
             x:xs -> (x, reverse xs)
      }

distributeMapBodyBindings :: KernelAcc -> [Binding] -> KernelM KernelAcc
distributeMapBodyBindings acc [] =
  return acc
distributeMapBodyBindings target (bnd:bnds) =
  withBinding bnd $
  maybeDistributeBinding bnd =<<
  distributeMapBodyBindings target bnds

maybeDistributeBinding :: Binding -> KernelAcc
                       -> KernelM KernelAcc
maybeDistributeBinding (Let pat _ (LoopOp (Map cs lam arrs))) acc = do
  acc' <- distribute acc
  distribute =<< distributeInnerMap pat (MapLoop cs lam arrs) acc'
maybeDistributeBinding bnd@(Let _ _ (LoopOp {})) acc =
  distribute $ addBindingToKernel bnd acc
maybeDistributeBinding bnd acc =
  return $ addBindingToKernel bnd acc
