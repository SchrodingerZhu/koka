-----------------------------------------------------------------------------
-- Copyright 2020 Microsoft Corporation, Daan Leijen, Ningning Xie
--
-- This is free software; you can redistribute it and/or modify it under the
-- terms of the Apache License, Version 2.0. A copy of the License can be
-- found in the file "license.txt" at the root of this distribution.
-----------------------------------------------------------------------------

-----------------------------------------------------------------------------
-- Lift all local and anonymous functions to top level. No more letrec :-)
-----------------------------------------------------------------------------

module Core.FunLift( liftFunctions
                   ) where


import qualified Lib.Trace
import Control.Monad
import Control.Applicative

import Lib.PPrint
import Common.Failure
import Common.Name
import Common.Range
import Common.Unique
import Common.Error
import Common.Syntax

import Kind.Kind
import Type.Type
import Type.Kind
import Type.TypeVar
import Type.Pretty hiding (Env)
import qualified Type.Pretty as Pretty
import Type.Assumption
import Core.Core
import qualified Core.Core as Core
import Core.Pretty
import Core.CoreVar

trace s x =
  Lib.Trace.trace s
    x

test = False


liftFunctions :: Pretty.Env -> Int -> DefGroups -> (DefGroups,Int)
liftFunctions penv u defs
  = if test then runLift penv u (liftDefGroups defs)
    else (defs, u)


{--------------------------------------------------------------------------
  transform definition groups
--------------------------------------------------------------------------}

-- TopLevel = True
liftDefGroups :: DefGroups -> Lift DefGroups
liftDefGroups defGroups
  = do traceDoc (\penv -> text "lifting")
       fmap concat $ mapM liftDefGroup defGroups

liftDefGroup :: DefGroup -> Lift DefGroups
liftDefGroup (DefNonRec def)
  = do (def', groups) <- liftDef def
       return $  groups ++ [DefNonRec def']

liftDefGroup (DefRec defs)
  = do (defs', groups) <- fmap unzip $ mapM liftDef defs
       let groups' = flattenAllDefGroups groups
       return [DefRec (defs' ++ groups')]

liftDef :: Def -> Lift (Def, DefGroups)
liftDef  def
  = withCurrentDef def $
    do (expr', defs) <- liftExpr True (defExpr def)
       return ( def{ defExpr = expr'}, defs)

-- TopLevel = False
liftDefGroupsX :: DefGroups -> Lift (DefGroups, DefGroups)
liftDefGroupsX defGroups
  = do (defs, groups) <- fmap unzip $ mapM liftDefGroupX defGroups
       return (defs, concat groups)

liftDefGroupX :: DefGroup -> Lift (DefGroup, DefGroups)
liftDefGroupX (DefNonRec def)
  = do (def', groups) <- liftDefX def
       return $  (DefNonRec def', groups)

liftDefGroupX (DefRec def)
  = return (DefRec def, []) -- TODO


liftDefX :: Def -> Lift (Def, DefGroups)
liftDefX def
  = withCurrentDef def $
    do (expr', defs) <- liftExpr False (defExpr def)
       return ( def{ defExpr = expr', defSort = DefVal}, defs) -- always value? what are DefVar?

liftExpr :: Bool    -- top-level functions are allowed
         -> Expr
         -> Lift (Expr, DefGroups)
liftExpr topLevel expr
  = case expr of
    App f args
      -> do (f', groups1) <- liftExpr False f
            (args', groups2) <- fmap unzip $ mapM (liftExpr False) args
            return (App f' args', groups1 ++ concat groups2)

    Lam args eff body
      -- top level functions are allowed
      | topLevel -> liftLambda
      -- lift local functions
      | otherwise ->
          do (expr1, groups) <- liftLambda
                 -- abstract over free variables
             let fvs = tnamesList $ freeLocals expr1
                 expr2 = addLambdasTName fvs eff expr1

                 -- abstract over type variables
                 tvs = tvsList (ftv expr2)
                 expr3 = addTypeLambdas tvs expr2

             name <- uniqueNameCurrentDef
             let ty = typeOf expr3
                 def = DefNonRec $ Def name ty expr3 Private DefFun rangeNull "// lifted"

             let liftExp1 = Var (TName name ty)
                                (InfoArity (length tvs) (length fvs + length args))
                 liftExp2 = addTypeApps tvs liftExp1
                 liftExp3 = addApps (map (\name -> Var name InfoNone) fvs) liftExp2

             return (liftExp3, groups ++ [def])
      where liftLambda
              = do (body', groups) <- liftExpr topLevel body
                   return (Lam args eff body', groups)
    Let defgs body
      -> do (defgs', groups1) <- liftDefGroupsX defgs
            (body', groups2) <- liftExpr False body
            return (Let defgs' body', groups1 ++ groups2)

    Case exprs bs
      -> do (exprs', groups1) <- fmap unzip $ mapM (liftExpr False) exprs
            (bs', groups2) <- fmap unzip $ mapM liftBranch bs
            return (Case exprs' bs', (concat groups1) ++ (concat groups2))

    TypeLam tvars body
      | not topLevel
      , Lam _ eff _ <- body
      -> do (expr1, groups) <- liftTypeLambda
            let fvs = tnamesList $ freeLocals expr1
                expr2 = addLambdasTName fvs eff expr1

                tvs = tvsList (ftv expr2)
                expr3 = addTypeLambdas tvs expr2
            name <- uniqueNameCurrentDef
            let ty = typeOf expr3
                def = DefNonRec $ Def name ty expr3 Private DefFun rangeNull ""

            let tvarLen = if null fvs then length tvars + length tvs else length tvs
                liftExp1 = Var (TName name ty)
                               (InfoArity tvarLen (length fvs))
                liftExp2 = addTypeApps tvs liftExp1
                liftExp3 = addApps (map (\name -> Var name InfoNone) fvs) liftExp2

            return (liftExp3, groups ++ [def])
      | otherwise -> liftTypeLambda
      where liftTypeLambda
              = do (body', groups) <- liftExpr topLevel body
                   return (TypeLam tvars body', groups)
    TypeApp body tps
      -> do (body', groups) <- liftExpr topLevel body
            return (TypeApp body' tps, groups)

    _ -> return (expr, [])

liftBranch :: Branch -> Lift (Branch, DefGroups)
liftBranch (Branch pat guards)
  = do (guards', groups) <- fmap unzip $ mapM liftGuard guards
       return $ (Branch pat guards', concat groups)

liftGuard :: Guard -> Lift (Guard, DefGroups)
liftGuard (Guard guard body)
  = do (guard', groups1) <- liftExpr False guard
       (body', groups2)  <- liftExpr False body
       return (Guard guard' body', groups1 ++ groups2 )

uniqueNameCurrentDef :: Lift Name
uniqueNameCurrentDef =
  do env <- getEnv
     let defNames = map defName (currentDef env)
     uniName <- uniqueName "lift"
     return $ foldr1 (\localName name -> postpend ("-" ++ show localName) name) (uniName:defNames)

{--------------------------------------------------------------------------
  Lift monad
--------------------------------------------------------------------------}
newtype Lift a = Lift (Env -> State -> Result a)

data Env = Env{ currentDef :: [Def],
                prettyEnv :: Pretty.Env }

data State = State{ uniq :: Int }

data Result a = Ok a State

runLift :: Pretty.Env -> Int -> Lift a -> (a,Int)
runLift penv u (Lift c)
  = case c (Env [] penv) (State u) of
      Ok x st -> (x,uniq st)

instance Functor Lift where
  fmap f (Lift c)  = Lift (\env st -> case c env st of
                                        Ok x st' -> Ok (f x) st')

instance Applicative Lift where
  pure  = return
  (<*>) = ap

instance Monad Lift where
  return x       = Lift (\env st -> Ok x st)
  (Lift c) >>= f = Lift (\env st -> case c env st of
                                      Ok x st' -> case f x of
                                                    Lift d -> d env st' )

instance HasUnique Lift where
  updateUnique f = Lift (\env st -> Ok (uniq st) st{ uniq = (f (uniq st)) })
  setUnique  i   = Lift (\env st -> Ok () st{ uniq = i} )

withEnv :: (Env -> Env) -> Lift a -> Lift a
withEnv f (Lift c)
  = Lift (\env st -> c (f env) st)

getEnv :: Lift Env
getEnv
  = Lift (\env st -> Ok env st)

updateSt :: (State -> State) -> Lift State
updateSt f
  = Lift (\env st -> Ok st (f st))

withCurrentDef :: Def -> Lift a -> Lift a
withCurrentDef def action
  = -- trace ("lifting: " ++ show (defName def)) $
    withEnv (\env -> env{currentDef = def:currentDef env}) $
    action

traceDoc :: (Pretty.Env -> Doc) -> Lift ()
traceDoc f
  = do env <- getEnv
       liftTrace (show (f (prettyEnv env)))

liftTrace :: String -> Lift ()
liftTrace msg
  = do env <- getEnv
       trace ("lift: " ++ show (map defName (currentDef env)) ++ ": " ++ msg) $ return ()