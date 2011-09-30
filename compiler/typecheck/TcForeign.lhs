%
% (c) The University of Glasgow 2006
% (c) The AQUA Project, Glasgow University, 1998
%
\section[TcForeign]{Typechecking \tr{foreign} declarations}

A foreign declaration is used to either give an externally
implemented function a Haskell type (and calling interface) or
give a Haskell function an external calling interface. Either way,
the range of argument and result types these functions can accommodate
is restricted to what the outside world understands (read C), and this
module checks to see if a foreign declaration has got a legal type.

\begin{code}
module TcForeign
        (
          tcForeignImports
        , tcForeignExports
        ) where

#include "HsVersions.h"

import HsSyn

import TcRnMonad
import TcHsType
import TcExpr
import TcEnv

import FamInst
import FamInstEnv
import Type
import TypeRep
import ForeignCall
import ErrUtils
import Id
import Name
import RdrName
import DataCon
import TyCon
import TcType
import Coercion
import PrelNames
import DynFlags
import Outputable
import SrcLoc
import Bag
import FastString
import Util
\end{code}

\begin{code}
-- Defines a binding
isForeignImport :: LForeignDecl name -> Bool
isForeignImport (L _ (ForeignImport _ _ _ _)) = True
isForeignImport _                             = False

-- Exports a binding
isForeignExport :: LForeignDecl name -> Bool
isForeignExport (L _ (ForeignExport _ _ _ _)) = True
isForeignExport _                             = False
\end{code}

\begin{code}
-- normaliseFfiType takes the type from an FFI declaration, and
-- evaluates any type synonyms, type functions, and newtypes. However,
-- we are only allowed to look through newtypes if the constructor is
-- in scope.
normaliseFfiType :: Type -> TcM (Coercion, Type)
normaliseFfiType ty
    = do fam_envs <- tcGetFamInstEnvs
         normaliseFfiType' fam_envs ty

normaliseFfiType' :: FamInstEnvs -> Type -> TcM (Coercion, Type)
normaliseFfiType' env ty0 = go [] ty0
  where
    go :: [TyCon] -> Type -> TcM (Coercion, Type)
    go rec_nts ty | Just ty' <- coreView ty     -- Expand synonyms
        = go rec_nts ty'

    go rec_nts ty@(TyConApp tc tys)
        -- We don't want to look through the IO newtype, even if it is
        -- in scope, so we have a special case for it:
        | tc `hasKey` ioTyConKey
        = children_only
        | isNewTyCon tc         -- Expand newtypes
        -- We can't just use isRecursiveTyCon here, as we need to allow
        -- some recursive types as described below
        = if tc `elem` rec_nts  -- See Note [Expanding newtypes] in Type.lhs
          then -- If this is a recursive newtype then it will normally
               -- be rejected later as not being a valid FFI type.
               -- Sometimes recursion is OK though, e.g. with
               --     newtype T = T (Ptr T)
               -- we don't reject the type for being recursive.
               return (Refl ty, ty)
          else do newtypeOK <- do env <- getGblEnv
                                  case tyConSingleDataCon_maybe tc of
                                      Just dataCon ->
                                          return $ notNull $ lookupGRE_Name (tcg_rdr_env env) $ dataConName dataCon
                                      _ ->
                                          return False
                  let newtypeForeign = nameModule_maybe (tyConName tc) `elem`
                                       [Just (mkBaseModule (fsLit "Foreign.C.Types")),
                                        Just (mkBaseModule (fsLit "System.Posix.Types"))]
                  if newtypeOK || newtypeForeign
                      then do let nt_co = mkAxInstCo (newTyConCo tc) tys
                              add_co nt_co rec_nts' nt_rhs
                      else children_only
        | isFamilyTyCon tc              -- Expand open tycons
        , (co, ty) <- normaliseTcApp env tc tys
        , not (isReflCo co)
        = add_co co rec_nts ty
        | otherwise
        = children_only
        where
          children_only = do xs <- mapM (go rec_nts) tys
                             let (cos, tys') = unzip xs
                             return (mkTyConAppCo tc cos, mkTyConApp tc tys')
          nt_rhs = newTyConInstRhs tc tys
          rec_nts' | isRecursiveTyCon tc = tc:rec_nts
                   | otherwise           = rec_nts

    go rec_nts (AppTy ty1 ty2)
      = do (coi1, nty1) <- go rec_nts ty1
           (coi2, nty2) <- go rec_nts ty2
           return (mkAppCo coi1 coi2, mkAppTy nty1 nty2)

    go rec_nts (FunTy ty1 ty2)
      = do (coi1,nty1) <- go rec_nts ty1
           (coi2,nty2) <- go rec_nts ty2
           return (mkFunCo coi1 coi2, mkFunTy nty1 nty2)

    go rec_nts (ForAllTy tyvar ty1)
      = do (coi,nty1) <- go rec_nts ty1
           return (mkForAllCo tyvar coi, ForAllTy tyvar nty1)

    go _ ty@(TyVarTy _)
      = return (Refl ty, ty)

    add_co co rec_nts ty
        = do (co', ty') <- go rec_nts ty
             return (mkTransCo co co', ty')
\end{code}

%************************************************************************
%*                                                                      *
\subsection{Imports}
%*                                                                      *
%************************************************************************

\begin{code}
tcForeignImports :: [LForeignDecl Name] -> TcM ([Id], [LForeignDecl Id])
tcForeignImports decls
  = mapAndUnzipM (wrapLocSndM tcFImport) (filter isForeignImport decls)

tcFImport :: ForeignDecl Name -> TcM (Id, ForeignDecl Id)
tcFImport fo@(ForeignImport (L loc nm) hs_ty _ imp_decl)
  = addErrCtxt (foreignDeclCtxt fo)  $
    do { sig_ty <- tcHsSigType (ForSigCtxt nm) hs_ty
       ; (norm_co, norm_sig_ty) <- normaliseFfiType sig_ty
       ; let
           -- Drop the foralls before inspecting the
           -- structure of the foreign type.
             (_, t_ty)         = tcSplitForAllTys norm_sig_ty
             (arg_tys, res_ty) = tcSplitFunTys t_ty
             id                = mkLocalId nm sig_ty
                 -- Use a LocalId to obey the invariant that locally-defined
                 -- things are LocalIds.  However, it does not need zonking,
                 -- (so TcHsSyn.zonkForeignExports ignores it).

       ; imp_decl' <- tcCheckFIType sig_ty arg_tys res_ty imp_decl
          -- Can't use sig_ty here because sig_ty :: Type and
          -- we need HsType Id hence the undefined
       ; return (id, ForeignImport (L loc id) undefined (mkSymCo norm_co) imp_decl') }
tcFImport d = pprPanic "tcFImport" (ppr d)
\end{code}


------------ Checking types for foreign import ----------------------
\begin{code}
tcCheckFIType :: Type -> [Type] -> Type -> ForeignImport -> TcM ForeignImport

tcCheckFIType sig_ty arg_tys res_ty idecl@(CImport _ _ _ (CLabel _))
  = ASSERT( null arg_tys )
    do { checkCg checkCOrAsmOrLlvmOrInterp
       ; check (isFFILabelTy res_ty) (illegalForeignTyErr empty sig_ty)
       ; return idecl }      -- NB check res_ty not sig_ty!
                             --    In case sig_ty is (forall a. ForeignPtr a)

tcCheckFIType sig_ty arg_tys res_ty idecl@(CImport cconv _ _ CWrapper) = do
        -- Foreign wrapper (former f.e.d.)
        -- The type must be of the form ft -> IO (FunPtr ft), where ft is a
        -- valid foreign type.  For legacy reasons ft -> IO (Ptr ft) as well
        -- as ft -> IO Addr is accepted, too.  The use of the latter two forms
        -- is DEPRECATED, though.
    checkCg checkCOrAsmOrLlvmOrInterp
    checkCConv cconv
    case arg_tys of
        [arg1_ty] -> do checkForeignArgs isFFIExternalTy arg1_tys
                        checkForeignRes nonIOok  False isFFIExportResultTy res1_ty
                        checkForeignRes mustBeIO False isFFIDynResultTy    res_ty
                  where
                     (arg1_tys, res1_ty) = tcSplitFunTys arg1_ty
        _ -> addErrTc (illegalForeignTyErr empty sig_ty)
    return idecl

tcCheckFIType sig_ty arg_tys res_ty idecl@(CImport cconv safety _ (CFunction target))
  | isDynamicTarget target = do -- Foreign import dynamic
      checkCg checkCOrAsmOrLlvmOrInterp
      checkCConv cconv
      case arg_tys of           -- The first arg must be Ptr, FunPtr, or Addr
        []                -> do
          check False (illegalForeignTyErr empty sig_ty)
          return idecl
        (arg1_ty:arg_tys) -> do
          dflags <- getDOpts
          check (isFFIDynArgumentTy arg1_ty)
                (illegalForeignTyErr argument arg1_ty)
          checkForeignArgs (isFFIArgumentTy dflags safety) arg_tys
          let safe_on = safeLanguageOn dflags
              ioOK    = if safe_on then mustBeIO else nonIOok
          checkForeignRes ioOK safe_on (isFFIImportResultTy dflags) res_ty
          return idecl
  | cconv == PrimCallConv = do
      dflags <- getDOpts
      check (xopt Opt_GHCForeignImportPrim dflags)
            (text "Use -XGHCForeignImportPrim to allow `foreign import prim'.")
      checkCg (checkCOrAsmOrLlvmOrDotNetOrInterp)
      checkCTarget target
      check (playSafe safety)
            (text "The safe/unsafe annotation should not be used with `foreign import prim'.")
      checkForeignArgs (isFFIPrimArgumentTy dflags) arg_tys
      -- prim import result is more liberal, allows (#,,#)
      let safe_on = safeLanguageOn dflags
          ioOK    = if safe_on then mustBeIO else nonIOok
      checkForeignRes ioOK safe_on (isFFIPrimResultTy dflags) res_ty
      return idecl
  | otherwise = do              -- Normal foreign import
      checkCg (checkCOrAsmOrLlvmOrDotNetOrInterp)
      checkCConv cconv
      checkCTarget target
      dflags <- getDOpts
      checkForeignArgs (isFFIArgumentTy dflags safety) arg_tys
      let safe_on = safeLanguageOn dflags
          ioOK    = if safe_on then mustBeIO else nonIOok
      checkForeignRes ioOK safe_on (isFFIImportResultTy dflags) res_ty
      checkMissingAmpersand dflags arg_tys res_ty
      return idecl


-- This makes a convenient place to check
-- that the C identifier is valid for C
checkCTarget :: CCallTarget -> TcM ()
checkCTarget (StaticTarget str _) = do
    checkCg checkCOrAsmOrLlvmOrDotNetOrInterp
    check (isCLabelString str) (badCName str)

checkCTarget DynamicTarget = panic "checkCTarget DynamicTarget"


checkMissingAmpersand :: DynFlags -> [Type] -> Type -> TcM ()
checkMissingAmpersand dflags arg_tys res_ty
  | null arg_tys && isFunPtrTy res_ty &&
    wopt Opt_WarnDodgyForeignImports dflags
  = addWarn (ptext (sLit "possible missing & in foreign import of FunPtr"))
  | otherwise
  = return ()
\end{code}

%************************************************************************
%*                                                                      *
\subsection{Exports}
%*                                                                      *
%************************************************************************

\begin{code}
tcForeignExports :: [LForeignDecl Name]
                 -> TcM (LHsBinds TcId, [LForeignDecl TcId])
tcForeignExports decls
  = foldlM combine (emptyLHsBinds, []) (filter isForeignExport decls)
  where
   combine (binds, fs) fe = do
       (b, f) <- wrapLocSndM tcFExport fe
       return (b `consBag` binds, f:fs)

tcFExport :: ForeignDecl Name -> TcM (LHsBind Id, ForeignDecl Id)
tcFExport fo@(ForeignExport (L loc nm) hs_ty _ spec)
  = addErrCtxt (foreignDeclCtxt fo) $ do

    sig_ty <- tcHsSigType (ForSigCtxt nm) hs_ty
    rhs <- tcPolyExpr (nlHsVar nm) sig_ty

    (norm_co, norm_sig_ty) <- normaliseFfiType sig_ty

    tcCheckFEType norm_sig_ty spec

           -- we're exporting a function, but at a type possibly more
           -- constrained than its declared/inferred type. Hence the need
           -- to create a local binding which will call the exported function
           -- at a particular type (and, maybe, overloading).


    -- We need to give a name to the new top-level binding that
    -- is *stable* (i.e. the compiler won't change it later),
    -- because this name will be referred to by the C code stub.
    id  <- mkStableIdFromName nm sig_ty loc mkForeignExportOcc
    return (mkVarBind id rhs, ForeignExport (L loc id) undefined norm_co spec)
tcFExport d = pprPanic "tcFExport" (ppr d)
\end{code}

------------ Checking argument types for foreign export ----------------------

\begin{code}
tcCheckFEType :: Type -> ForeignExport -> TcM ()
tcCheckFEType sig_ty (CExport (CExportStatic str cconv)) = do
    checkCg checkCOrAsmOrLlvm
    check (isCLabelString str) (badCName str)
    checkCConv cconv
    checkForeignArgs isFFIExternalTy arg_tys
    checkForeignRes nonIOok False isFFIExportResultTy res_ty
  where
      -- Drop the foralls before inspecting n
      -- the structure of the foreign type.
    (_, t_ty) = tcSplitForAllTys sig_ty
    (arg_tys, res_ty) = tcSplitFunTys t_ty
\end{code}



%************************************************************************
%*                                                                      *
\subsection{Miscellaneous}
%*                                                                      *
%************************************************************************

\begin{code}
------------ Checking argument types for foreign import ----------------------
checkForeignArgs :: (Type -> Bool) -> [Type] -> TcM ()
checkForeignArgs pred tys
  = mapM_ go tys
  where
    go ty = check (pred ty) (illegalForeignTyErr argument ty)

------------ Checking result types for foreign calls ----------------------
-- Check that the type has the form
--    (IO t) or (t) , and that t satisfies the given predicate.
--
checkForeignRes :: Bool -> Bool -> (Type -> Bool) -> Type -> TcM ()

nonIOok, mustBeIO :: Bool
nonIOok  = True
mustBeIO = False

checkForeignRes non_io_result_ok safehs_check pred_res_ty ty
    -- We need an (IO t) result. Any newtype wrappers of type functions
    -- have already been dealt with by normaliseFfiType.
  = case tcSplitIOType_maybe ty of
    Just (_, res_ty)
     | pred_res_ty res_ty ->
        return ()
    _ ->
        check (non_io_result_ok && pred_res_ty ty)
              (illegalForeignTyErr result ty $+$ safeHsErr safehs_check)
\end{code}

\begin{code}
checkCOrAsmOrLlvm :: HscTarget -> Maybe SDoc
checkCOrAsmOrLlvm HscC    = Nothing
checkCOrAsmOrLlvm HscAsm  = Nothing
checkCOrAsmOrLlvm HscLlvm = Nothing
checkCOrAsmOrLlvm _
  = Just (text "requires via-C, llvm (-fllvm) or native code generation (-fvia-C)")

checkCOrAsmOrLlvmOrInterp :: HscTarget -> Maybe SDoc
checkCOrAsmOrLlvmOrInterp HscC           = Nothing
checkCOrAsmOrLlvmOrInterp HscAsm         = Nothing
checkCOrAsmOrLlvmOrInterp HscLlvm        = Nothing
checkCOrAsmOrLlvmOrInterp HscInterpreted = Nothing
checkCOrAsmOrLlvmOrInterp _
  = Just (text "requires interpreted, C, Llvm or native code generation")

checkCOrAsmOrLlvmOrDotNetOrInterp :: HscTarget -> Maybe SDoc
checkCOrAsmOrLlvmOrDotNetOrInterp HscC           = Nothing
checkCOrAsmOrLlvmOrDotNetOrInterp HscAsm         = Nothing
checkCOrAsmOrLlvmOrDotNetOrInterp HscLlvm        = Nothing
checkCOrAsmOrLlvmOrDotNetOrInterp HscInterpreted = Nothing
checkCOrAsmOrLlvmOrDotNetOrInterp _
  = Just (text "requires interpreted, C, Llvm or native code generation")

checkCg :: (HscTarget -> Maybe SDoc) -> TcM ()
checkCg check = do
    dflags <- getDOpts
    let target = hscTarget dflags
    case target of
      HscNothing -> return ()
      _ ->
        case check target of
          Nothing  -> return ()
          Just err -> addErrTc (text "Illegal foreign declaration:" <+> err)
\end{code}

Calling conventions

\begin{code}
checkCConv :: CCallConv -> TcM ()
checkCConv CCallConv    = return ()
#if i386_TARGET_ARCH
checkCConv StdCallConv  = return ()
#else
-- This is a warning, not an error. see #3336
checkCConv StdCallConv  = addWarnTc (text "the 'stdcall' calling convention is unsupported on this platform," $$ text "treating as ccall")
#endif
checkCConv PrimCallConv = addErrTc (text "The `prim' calling convention can only be used with `foreign import'")
checkCConv CmmCallConv  = panic "checkCConv CmmCallConv"
\end{code}

Warnings

\begin{code}
check :: Bool -> Message -> TcM ()
check True _       = return ()
check _    the_err = addErrTc the_err

illegalForeignTyErr :: SDoc -> Type -> SDoc
illegalForeignTyErr arg_or_res ty
  = hang (hsep [ptext (sLit "Unacceptable"), arg_or_res,
                ptext (sLit "type in foreign declaration:")])
       2 (hsep [ppr ty])

safeHsErr :: Bool -> SDoc
safeHsErr False = empty
safeHsErr True  = ptext $ sLit "Safe Haskell is on, all FFI imports must be in the IO monad"

-- Used for 'arg_or_res' argument to illegalForeignTyErr
argument, result :: SDoc
argument = text "argument"
result   = text "result"

badCName :: CLabelString -> Message
badCName target
  = sep [quotes (ppr target) <+> ptext (sLit "is not a valid C identifier")]

foreignDeclCtxt :: ForeignDecl Name -> SDoc
foreignDeclCtxt fo
  = hang (ptext (sLit "When checking declaration:"))
       2 (ppr fo)
\end{code}
