{-# LANGUAGE LambdaCase, ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-incomplete-patterns #-}
module ReWire.FrontEnd.Desugar (desugar) where

import ReWire.FrontEnd.Error
import ReWire.FrontEnd.Annotate
import ReWire.SYB

import Control.Monad (liftM, replicateM, (>=>))
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.State (runStateT, StateT, get, modify)
import Data.Foldable (foldl', foldrM)
import Data.Functor ((<$>))
import Data.Functor.Identity (Identity(..))
import Data.Monoid ((<>))

import Language.Haskell.Exts.Annotated.Syntax

-- TODO(chathhorn): record syntax should be fairly easy to desugar.

-- | Desugar into lambdas then normalize the lambdas.
desugar :: Module Annote -> ParseError IO (Module Annote)
desugar = liftM fst . flip runStateT 0 .
      ( runT
            ( normIds
           <> deparenify
           <> desugarInfix
           <> wheresToLets
           <> addMainModuleHead
           <> normTyContext
           <> desugarTyFuns
            )
      >=> runT desugarFuns
      >=> runT
            ( desugarTuples
           <> desugarDos
            )
      >=> runT desugarLets
      >=> runT
            ( desugarIfs
           <> desugarNegs
           <> desugarWildCards
           <> desugarNegLitPats
            )
      -- *** Normalize lambdas:
      >=> runT flattenLambdas
      >=> runT depatLambdas
      >=> runT desugarAsPats
      >=> runT lambdasToCases
      )

type Fresh = StateT Int (ParseError IO)

fresh :: Annote -> Fresh (Name Annote)
fresh l = do
      x <- get
      modify $ const $ x + 1
      return $ Ident l $ "$" ++ show x

-- | Turns Symbols and Specials into normal identifiers and adds a prefix to
--   all names in the type namespace.
normIds :: Transform Fresh
normIds = (\ x -> case x :: Name Annote of
            Symbol l n                 -> return $ Ident l n)
      ||> (\ x -> case x :: QName Annote of
            Special l (UnitCon _)      -> return $ UnQual l $ Ident l "()"
            Special l (ListCon _)      -> return $ UnQual l $ Ident l "List"
            Special l (FunCon _)       -> return $ UnQual l $ Ident l "->"
            -- I think this is only for the prefix constructor.
            Special l (TupleCon _ _ i) -> return $ UnQual l $ mkTuple l i
            Special l (Cons _)         -> return $ UnQual l $ Ident l "Cons")
      ||> TId

mkTuple :: Annote -> Int -> Name Annote
mkTuple l n = Ident l $ "(" ++ replicate (n-1) ',' ++ ")"

-- | Removes parens in types, expressions, and patterns so they don't confuddle
--   everything.
deparenify :: Transform Fresh
deparenify = (\ (Paren   (_ :: Annote) n) -> return n)
      ||> (\ (PParen  (_ :: Annote) n) -> return n)
      ||> (\ (TyParen (_ :: Annote) n) -> return n)
      ||> (\ (DHParen (_ :: Annote) n) -> return n)
      ||> TId

-- | Turns sections and infix ops into regular applications and lambdas.
desugarInfix :: Transform Fresh
desugarInfix = (\ case
            LeftSection l e (QVarOp l' op)  -> return $ App l (Var l' op) e
            LeftSection l e (QConOp l' op)  -> return $ App l (Con l' op) e
            RightSection l (QVarOp l' op) e -> do
                  x <- fresh l
                  return $ Lambda l [PVar l x] $ App l (App l (Var l' op) $ Var l $ UnQual l x) e
            RightSection l (QConOp l' op) e -> do
                  x <- fresh l
                  return $ Lambda l [PVar l x] $ App l (App l (Con l' op) $ Var l $ UnQual l x) e
            InfixApp l e1 (QVarOp l' op) e2 -> return $ App l (App l (Var l' op) e1) e2
            InfixApp l e1 (QConOp l' op) e2 -> return $ App l (App l (Con l' op) e1) e2)
      ||> (\ (InfixConDecl (l :: Annote) a n b) -> return $ ConDecl l n [a, b])
      ||> (\ (InfixMatch (l :: Annote) p1 n p2 rhs bs) -> return $ Match l n (p1:p2) rhs bs)
      ||> (\ (DHInfix (l :: Annote) bind n) -> return $ DHApp l (DHead l n) bind)
      ||> TId

-- | Turns wildcard patterns into variable patterns.
desugarWildCards :: Transform Fresh
desugarWildCards = (||> TId) $
      \ (PWildCard (l :: Annote)) -> return $ PVar l $ Ident l "$_"

-- | TODO Apparently we'd actually need guards to properly support negated
-- literal patterns:
-- > f (-k) = v
-- is actually sugar for
-- > f z | z == negate (fromInteger k) = v
desugarNegLitPats :: Transform Fresh
desugarNegLitPats = (||> TId) $
      \ (PLit (l :: Annote) (Negative l') lit) -> return $ PLit l (Signless l') $ neg lit

neg :: Literal Annote -> Literal Annote
neg = \ case
      Int        l n s -> Int        l (-n) s
      Frac       l n s -> Frac       l (-n) s
      PrimInt    l n s -> PrimInt    l (-n) s
      PrimWord   l n s -> PrimWord   l (-n) s
      PrimFloat  l n s -> PrimFloat  l (-n) s
      PrimDouble l n s -> PrimDouble l (-n) s
      n                -> n

-- | Turns piece-wise function definitions into a single PatBind with a lambda
--   and case expression on the RHS. E.g.:
-- > f p1 p2 = rhs1
-- > f q1 q2 = rhs2
-- becomes
-- > f = \ $1 $2 -> case ($1, $2) of { (p1, p2) -> rhs1; (q1, q2) -> rhs2 }
desugarFuns :: Transform Fresh
desugarFuns = (||> TId) $ \ case
      FunBind l ms@(Match l' name pats _ Nothing:_) -> do
            e <- buildLambda l ms $ length pats
            return $ PatBind l (PVar l' name) (UnGuardedRhs l e) Nothing
      n@FunBind{}                                   -> lift $ pFailAt (ann n) "unsupported decl syntax"
      where buildLambda :: Annote -> [Match Annote] -> Int -> Fresh (Exp Annote)
            buildLambda l ms 1 = do
                  alts <- mapM toAlt ms
                  x <- fresh l
                  return $ Lambda l [PVar l x] $ Case l (Var l $ UnQual l x) alts
            buildLambda l ms arrity = do
                  alts <- mapM toAlt ms
                  xs <- replicateM arrity (fresh l)
                  return $ Lambda l (map (PVar l) xs) $ Case l (Tuple l Boxed (map (Var l . UnQual l) xs)) alts
            toAlt :: Match Annote -> Fresh (Alt Annote)
            toAlt (Match l' _ [p] rhs binds) = return $ Alt l' p rhs binds
            toAlt (Match l' _ ps  rhs binds) = return $ Alt l' (PTuple l' Boxed ps) rhs binds
            toAlt m                          = lift $ pFailAt (ann m) "unsupported decl syntax"

-- | Turns tuples into applications of a TupleN constructor (also in types and pats):
-- > (x, y, z)
-- becomes
-- > (Tuple3 x y z)
desugarTuples :: Transform Fresh
desugarTuples = (\ (Tuple l _ es)   -> return $ foldl' (App l) (Con l $ UnQual l $ mkTuple l $ length es) es)
            ||> (\ (TyTuple l _ ts) -> return $ foldl' (TyApp l) (TyCon l $ UnQual l $ mkTuple l $ length ts) ts)
            ||> (\ (PTuple l _ ps)  -> return $ PApp l (UnQual l $ mkTuple l $ length ps) ps)
            ||> TId

-- | Turns do-notation into a series of >>= \ x ->. Turns LetStmts into Lets.
--   Should run before Let and Lambda desugarage. E.g.:
-- > do p1 <- m
-- >    let p2 = e
-- >    return e
-- becomes
-- > m >>= (\ p1 -> (let p2 = e in return e))
desugarDos :: Transform Fresh
desugarDos = (||> TId) $ \ (Do l stmts) -> transDo l stmts
      where transDo :: Annote -> [Stmt Annote] -> Fresh (Exp Annote)
            transDo l = \ case
                  Generator l' p e : stmts -> App l' (App l' (Var l' $ UnQual l' $ Ident l' ">>=") e) . Lambda l' [p] <$> transDo l stmts
                  [Qualifier _ e]          -> return e
                  Qualifier l' e : stmts   -> App l' (App l' (Var l' $ UnQual l' $ Ident l' ">>=") e) . Lambda l' [PWildCard l'] <$> transDo l stmts
                  LetStmt l' binds : stmts -> Let l' binds <$> transDo l stmts
                  s : _                    -> lift $ pFailAt (ann s) "unsupported syntax in do-block"
                  []                       -> lift $ pFailAt l "ill-formed do-block"

-- | Turns where clauses into lets. Only valid because we're disallowing
--   guards, so this pass also raises an error if it encounters a guard.
wheresToLets :: Transform Fresh
wheresToLets = (\ case
            Match l name ps (UnGuardedRhs l' e) (Just binds) -> return $ Match l name ps (UnGuardedRhs l' $ Let l' binds e) Nothing
            Match l _ _ (GuardedRhss _ _) _                  -> lift $ pFailAt l "guards are not supported")
      ||> (\ case
            PatBind l p (UnGuardedRhs l' e) (Just binds) -> return $ PatBind l p (UnGuardedRhs l' $ Let l' binds e) Nothing
            PatBind l _ (GuardedRhss _ _) _              -> lift $ pFailAt l "guards are not supported")
      ||> (\ case
            Alt l p (UnGuardedRhs l' e) (Just binds) -> return $ Alt l p (UnGuardedRhs l' $ Let l' binds e) Nothing
            Alt l _ (GuardedRhss _ _) _              -> lift $ pFailAt l "guards are not supported")
      ||> TId

addMainModuleHead :: Transform Fresh
addMainModuleHead = (||> TId) $
      -- Just add the Main module, not the "main" export.
      \ (Module (l :: Annote) Nothing ps imps ds) -> return $ Module l (Just $ ModuleHead l (ModuleName l "Main") Nothing $ Just $ ExportSpecList l []) ps imps ds

normTyContext :: Transform Fresh
normTyContext = (||> TId) $ \ x -> case x :: Type Annote of
      TyForall (l :: Annote) tvs Nothing t   -> return $ TyForall l tvs (Just $ CxTuple l []) t
      TyForall l tvs (Just (CxEmpty _)) t    -> return $ TyForall l tvs (Just $ CxTuple l []) t
      TyForall l tvs (Just (CxSingle _ a)) t -> return $ TyForall l tvs (Just $ CxTuple l [a]) t

-- | Turns the type a -> b into (->) a b.
desugarTyFuns :: Transform Fresh
desugarTyFuns = (||> TId) $
      \ (TyFun (l :: Annote) a b) -> return $ TyApp l (TyApp l (TyCon l (UnQual l (Ident l "->"))) a) b

-- | Turns Lets into Cases. Assumes functions in Lets are already desugared.
--   E.g.:
-- > let p = e1
-- >     q = e2
-- > in e3
-- becomes
-- > case e1 of { p -> (case e2 of { q -> e3 } }
desugarLets :: Transform Fresh
desugarLets = (||> TId) $ \ case
      Let _ (BDecls _ ds) e -> foldrM transLet e ds
      n@Let{}               -> lift $ pFailAt (ann n) "unsupported let syntax"
      where transLet :: Decl Annote -> Exp Annote -> Fresh (Exp Annote)
            transLet (PatBind l p (UnGuardedRhs l' e1) Nothing) inner = return $ Case l e1 [Alt l p (UnGuardedRhs l' inner) Nothing]
            transLet n _                                              = lift $ pFailAt (ann n) "unsupported syntax in a let binding"

-- | Turns ifs into cases and unary minus.
-- > if e1 then e2 else e3
-- becomes
-- > case e1 of { True -> e2; False -> e3 }
desugarIfs :: Transform Fresh
desugarIfs = (||> TId) $
      \ (If (l :: Annote) e1 e2 e3) -> return $ Case l e1
            [ Alt l (PApp l (UnQual l $ Ident l "True")  []) (UnGuardedRhs l e2) Nothing
            , Alt l (PApp l (UnQual l $ Ident l "False") []) (UnGuardedRhs l e3) Nothing
            ]

desugarNegs :: Transform Fresh
desugarNegs = (||> TId) $
      \ (NegApp (l :: Annote) e) -> return $ App l (App l (Var l $ UnQual l $ Ident l "-") $ Lit l $ Int l 0 "0") e

-- | Turns Lambdas with several bindings into several lambdas with single
--   bindings. E.g.:
-- > \ p1 p2 -> e
-- becomes
-- > \ p1 -> \ p2 -> e
flattenLambdas :: Transform Fresh
flattenLambdas = (||> TId) $
      \ (Lambda (l :: Annote) ps e) -> return $ foldr (Lambda l . return) e ps

-- | Replaces non-var patterns in lambdas with a fresh var and a case. E.g.:
-- > \ (a,b) -> e
-- becomes
-- > \ $x -> case $x of { (a,b) -> e }
depatLambdas :: Transform Fresh
depatLambdas = (||> TId) $ \ case
      n@(Lambda _ [PVar _ _] _) -> return n
      Lambda l [p] e          -> do
            x <- fresh l
            return $ Lambda l [PVar l x] (Case l (Var l $ UnQual l x) [Alt l p (UnGuardedRhs l e) Nothing])

-- | Desugars as-patterns in (and only in) cases into more cases. Should run
--   after depatLambdas. E.g.:
-- > case e1 of
-- >   x@(C y@p) -> e2
-- becomes
-- > case e1 of { C p -> (\ x -> ((\ y -> e2) p)) (C p) }
desugarAsPats :: Transform Fresh
desugarAsPats = (||> TId) $
      \ (Alt l p (UnGuardedRhs l' e) Nothing) -> do
            app <- foldrM (mkApp l) e $ getAses p
            return $ Alt l (deAs p) (UnGuardedRhs l' app) Nothing
      where mkApp :: Annote -> (Pat Annote, Pat Annote) -> Exp Annote -> Fresh (Exp Annote)
            mkApp l (p, p') e = App l (Lambda l [p] e) <$> patToExp p'
            getAses :: Pat Annote -> [(Pat Annote, Pat Annote)]
            getAses = runPureQ $ (||? QEmpty) $ \ case
                  PAsPat (l :: Annote) n p -> [(PVar l n, p)]
                  _                        -> []
            deAs :: Pat Annote -> Pat Annote
            deAs = runIdentity . runPureT ((||> TId) $ \ case
                  PAsPat (_ :: Annote) _ p -> return p
                  n                        -> return n)
            patToExp :: Pat Annote -> Fresh (Exp Annote)
            patToExp = \ case
                  PVar l n                -> return $ Var l $ UnQual l n
                  PLit l (Signless _) n   -> return $ Lit l n
                  -- PNPlusK _name _int ->
                  PApp l n ps             -> foldl' (App l) (Con l n) <$> mapM patToExp ps
                  PList l ps              -> List l <$> mapM patToExp ps
                  -- PRec _qname _patfields ->
                  PAsPat _ _ p            -> patToExp p
                  PIrrPat _ p             -> patToExp p
                  PatTypeSig _ p _        -> patToExp p
                  -- PViewPat _exp _pat ->
                  PBangPat _ p            -> patToExp p
                  p                       -> lift $ pFailAt (ann p) "unsupported pattern"

-- | Turns beta-redexes into cases. E.g.:
-- > (\ x -> e2) e1
-- becomes
-- > case e1 of { x -> e2 }
lambdasToCases :: Transform Fresh
lambdasToCases = (||> TId) $
      \ (App (l :: Annote) (Lambda _ [p] e2) e1) -> return $ Case l e1 [Alt l p (UnGuardedRhs l e2) Nothing]

