{-# LANGUAGE GeneralizedNewtypeDeriving, UndecidableInstances, FlexibleInstances, FlexibleContexts, MultiParamTypeClasses, NamedFieldPuns, TupleSections #-}

{-
 Copyright (C) 2012 Jimmy Liang, Kacper Bak <http://gsd.uwaterloo.ca>

 Permission is hereby granted, free of charge, to any person obtaining a copy of
 this software and associated documentation files (the "Software"), to deal in
 the Software without restriction, including without limitation the rights to
 use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
 of the Software, and to permit persons to whom the Software is furnished to do
 so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE.
-}
module Language.Clafer.Intermediate.ScopeAnalyzer (scopeAnalysis) where

import Language.Clafer.Front.Absclafer hiding (Path)
import qualified Language.Clafer.Intermediate.Intclafer as I
import Language.Clafer.Intermediate.Analysis
import Language.Clafer.Common

import Control.Applicative (Applicative(..), (<$>))
import Control.Monad
import Control.Monad.List
import Control.Monad.LPMonad
import Control.Monad.Maybe
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Writer
import Data.Either
import Data.LinearProgram hiding (constraints)
import Data.List
import Data.Map ()
import qualified Data.Map as Map
import Data.Maybe
import System.IO.Unsafe
import Text.Parsec.Combinator
import Text.Parsec.Error
import Text.Parsec.Pos
import Text.Parsec.Prim
import Text.Parsec.String ()
import Language.Clafer.Intermediate.Test
import Debug.Trace


{------------------------------------------------------------
 ---------- Linear programming ------------------------------
 ------------------------------------------------------------}

scopeAnalysis :: I.IModule -> [(String, Integer)]
scopeAnalysis imodule =
  intScope ++ scopes
  where
  intScope = if bitwidth > 4 then return ("int", bitwidth) else fail "Bitwidth less than default."
  bitwidth = bitwidthAnalysis (constants ++ map snd scopes)
  
  scopes = 
    removeZeroes $ removeRoot $ removeAux $
      -- unsafePerformIO should be safe (?)
      -- We aren't modifying any global state.
      -- If we don't use unsafePerformIO, then we have to be inside the IO monad and
      -- makes things really ugly. Might as well contain the ugliness in here.
      case unsafePerformIO solution of
        (Success, Just (_, s)) -> Map.toList $ Map.map round s
        x -> [] -- No solution
  
  ((abstracts, constants), analysis) = runScopeAnalysis run $ gatherInfo imodule
  
  run =
    do
      setConstraints
      abstracts' <- clafers `suchThat` isAbstract
      constants' <- constantsAnalysis
      return (abstracts', constants')
  
  solution = {-trace (show $ unsafePerformIO $ writeLP "TESTTT" analysis) $-} glpSolveVars mipDefaults{msgLev = MsgOff} $ analysis
  -- Any scope that is 0 will take the global scope of 1 instead.
  removeZeroes = filter ((/= 0) . snd)
  -- The root is implied and not and not part of the actual solution.
  removeRoot = filter ((/= rootUid) . fst)
  -- Auxilary variables are only part of the computation, not the solution.
  removeAux = filter (not . (uniqNameSpace `isPrefixOf`) . fst)
  -- The scope for abstract clafers are removed. Alloy doesn't need it. Makes
  -- it easier use since user can increase the scope of subclafers without
  -- needing to increase the scope of the abstract Clafer.
  removeAbstracts = filter (not . (`elem` map uid abstracts) . fst)


bitwidthAnalysis :: [Integer] -> Integer
bitwidthAnalysis constants =
  toInteger $ 1 + fromJust (findIndex (\x -> all (`within` x) constants) bitRange)
  where
  within a (minB, maxB) = a >= minB && a <= maxB
  bitRange = [(-2^i, 2^i-1) | i <- [0..]]

  
constantsAnalysis :: ScopeAnalysis [Integer]
constantsAnalysis =
  do
    cons <- constraintsUnder anything `select` snd
    return $ mapMaybe integerConstant [I.exp sub | con <- cons, sub <- subexpressions con]
  where  
  integerConstant (I.IInt i) = Just i
  integerConstant _ = Nothing
    

setConstraints :: ScopeAnalysis ()
setConstraints =
  do
    reifyClafers <- constraintConstraints2
    withExtraClafers reifyClafers $ do
      optFormula
      colonConstraints
      refConstraints
      parentConstraints

    (var rootUid) `equalTo` 1


optFormula :: ScopeAnalysis ()
optFormula =
  do
    setDirection Min
    c <- clafers
    let concretes = [uid concrete | concrete <- c, isConcrete concrete, isDerived concrete]
    setObjective $ varSum concretes

parentConstraints :: ScopeAnalysis ()
parentConstraints =
  runListT_ $ do
    -- forall child under parent ...
    (child, parent) <- foreach $ anything |^ anything

    let uchild = uid child
    let uparent = uid parent
    
    -- ... scope_this <= scope_parent * low-card(this) ...
    var uchild `geq` (low child *^ var uparent)
    -- ... scope_this >= scope_parent * high-card(this) ...
    -- high == -1 implies high card is unbounded

    if high child /= -1
      then var uchild `leq` (high child *^ var uparent)
      else (smallM *^ var uchild) `leq`var uparent
    -- Use integer's not doubles
    setVarKind uchild IntVar
    setVarKind uparent IntVar


refConstraints :: ScopeAnalysis ()
refConstraints =
  runListT_ $ do
    -- for all uids of any clafer the refs another uid ...
    (sub, sup) <- foreach $ (anything |-> anything) `suchThat` (isDerived . superClafers)
    let usub = uid sub
    let usup = uid sup
    aux <- testPositive usub
    -- scope_sup >= low-card(sub)
    var usup `geq` ((max 1 $ low sub) *^ var aux)


colonConstraints :: ScopeAnalysis ()
colonConstraints =
  runListT_ $ do
    -- forall c in the set of clafers' uid ...
    c <- foreach $ clafers `suchThat` isDerived
    -- ... find all uids of any clafer that extends c (only colons) ...
    subs <- findAll $ (anything |: c) `select` (uid . subClafers)
    when (not $ null subs) $
      -- ... then set the constraint scope_C = sum scope_subs
      var (uid c) `equal` varSum subs


data Path =
  Path {parts::[Part]}
  deriving (Eq, Ord, Show)

data Part =
  Part {steps::[String]}
  deriving (Eq, Ord, Show)


-- Returns a list of reified clafers.
constraintConstraints :: ScopeAnalysis [SClafer]
constraintConstraints =
  do  
    pathList <- runListT $ do
      -- for all constraints ...
      (curThis, con) <- foreach $ constraintsUnder anything
      -- ... parse constraint expression ...
      (path, mult) <- foreach $ constraintConstraints' curThis (I.exp con)

      -- ... set the linear programming equations
      -- The first part is owned by curThis. The rest of the parts are after refs.
      let conc = head $ parts path
      let refs = tail $ parts path
      
      var (reifyVar conc) `geq` (mult *^ var (uid curThis))

      forM refs $
        \part -> var (reifyVar part) `geqTo` fromInteger (low curThis)
      
      return path
    
    rPartList <- forM [steps parts' | parts' <- pathList >>= parts] $
      \(conc : abst) -> do
        reifiedParts <- forM (tail $ inits abst) $
          \abst' -> reifyPart (Part $ conc : abst')
        return (conc, concat reifiedParts)
    
    -- Create reified clafers.
    runListT $ do
      (conc, parts) <- foreachM $ nub rPartList
      (parent, child) <- foreachM $ zip (Part [conc] : parts) parts
      baseClafer <- lift $ claferWithUid $ base child
      return $ SClafer (reifyVar child) False (low baseClafer) (high baseClafer) (Just $ reifyVar parent) (Just $ Colon $ uid baseClafer) []
  where 
  base (Part steps) = last steps

  reifyVar (Part [target]) = target
  reifyVar (Part target) = uniqNameSpace ++ "reify_" ++ intercalate "_" target
  
  reifyPart :: Part -> ScopeAnalysis [Part]
  reifyPart (Part steps) =
    do
      as <- claferWithUid (last steps) >>= nonTopAncestors
      forM as $
        \a -> return $ Part $ init steps ++ [uid a]
  
  nonTopAncestors :: SClafer -> ScopeAnalysis [SClafer]
  nonTopAncestors child =
    do
      parent <- parentOf child
      if uid parent == rootUid
        then return []
        else (++ [child]) `fmap` nonTopAncestors parent
  
  -- Does the work for one constraint.
  constraintConstraints' :: MonadScope m => SClafer -> I.IExp -> m [(Path, Double)]
  constraintConstraints' curThis iexp =
    runListT $ do
      (path, mult) <- pathAndMult iexp

      p <- Path <$> (map reify <$> parsePath curThis path)

      return (p, mult)

  -- [some my.path.expression]
  --   => #my.path.expression >= 1
  pathAndMult :: (MonadPlus m, MonadScope m) => I.IExp -> m (I.PExp, Double)
  pathAndMult I.IDeclPExp {I.quant = I.ISome, I.oDecls = [], I.bpexp} = return (bpexp, 1)
  -- [some disj a;b : my.path.expression | ...]
  --   => my.path.expression >= 2
  pathAndMult I.IDeclPExp {I.quant = I.ISome, I.oDecls} = msum $ map (return . pathAndMultDecl) oDecls
    where
    pathAndMultDecl :: I.IDecl -> (I.PExp, Double)
    pathAndMultDecl I.IDecl {I.isDisj = True, I.decls , I.body} = (body, fromIntegral $ length decls)
    pathAndMultDecl I.IDecl {I.isDisj = False, I.decls , I.body} = (body, 1)
    
  -- [one my.path.expression]
  --   => #my.path.expression >= 1
  pathAndMult I.IDeclPExp {I.quant = I.IOne, I.oDecls = [], I.bpexp} = return (bpexp, 1)
  pathAndMult I.IDeclPExp {I.quant = I.IOne, I.oDecls} = msum $ [return $ (I.body oDecl, 1) | oDecl <- oDecls]
  
  -- [#my.path.expression = const]
  --   => #my.path.expression >= const
  pathAndMult I.IFunExp {I.op = "=", I.exps = [I.PExp {I.exp = I.IFunExp {I.op = "#", I.exps = [path]}}, I.PExp {I.exp = I.IInt const}]} =
    return (path, fromInteger const)
  -- [const = #my.path.expression]
  --   => #my.path.expression >= const
  pathAndMult I.IFunExp {I.op = "=", I.exps = [I.PExp {I.exp = I.IInt const}, I.PExp {I.exp = I.IFunExp {I.op = "#", I.exps = [path]}}]} =
    return (path, fromInteger const)

  
  -- All quantifiers can be true even if scope is 0
  pathAndMult (I.IDeclPExp {I.quant = I.IAll}) = fail "No path."
  pathAndMult e = fail $ "TODO::" ++ show e

  reify :: [String] -> Part
  reify []  = error "Empty path." -- Bug, should never happen.
  reify xs  = Part xs
  
data Expr =
    This {path::Path} |
    Global {path::Path} |
    Const Integer |
    Union [Expr]
    deriving Show

isThis :: Expr -> Bool
isThis This{} = True
isThis _ = False
isGlobal :: Expr -> Bool
isGlobal Global{} = True
isGlobal _ = False
isConst :: Expr -> Bool
isConst Const{} = True
isConst _ = False
    

parsePath :: MonadScope m => SClafer -> I.PExp -> m [[String]]
parsePath start pexp =
  do
    root <- claferWithUid rootUid
    match <- patternMatch parsePath' (ParseState root []) (fromMaybe [] $ unfoldJoins pexp)
    case match of
      Left err -> error $ show err
      Right s -> return $ filter (not . null) s
  where
  parsePath' =
    do
      {-
       - We use the stack to push every abstraction we traverse through.
       - For example:
       - 
       -  abstract A
       -    B ?
       -      C : D ?
       -  abstract D
       -    E ?
       -  F : A
       -  G : A
       -  H : A
       -
       -  [some F.B.C.E]
       -  [some G.B.C.E]
       -
       - The first constraint's final stack will look like ["C" ,"F"]
       - Hence the linear programming equation will look like:
       -
       -  scope_F_C_E >= scope_root
       -
       - Adding the second constraint:
       -
       -  scope_G_C_E >= scope_root
       -  scope_E >= scope_F_C_E + scope_G_C_E (*)
       -
       - Solving the minimization should have scope_E = 2 in its solution.
       - The (*) equation is set in constraintConstraints
       -}
      paths <- many (step >>= follow)
      
      lifo <- popStack
      let end = if null paths then [] else [last paths]
      let result = reverse $ end ++ map uid lifo
      
      do
        _ref_ >>= follow
        -- recurse
        rec <- parsePath'
        return $ result : rec
        <|> return [result]
      
  -- Step handles non-this token.
  step :: MonadScope m => ParseT m String
  step = _this_ <|> _directChild_ <|> try (pushThis >> _indirectChild_)
  
  -- Update the state of where "this" is.
  -- Path is one step away from where "this" is.
  follow :: MonadScope m => String -> ParseT m String
  follow path =
    do
      curThis <- getThis
      case path of
        "this" -> putThis start
        "parent" -> lift (parentOf curThis) >>= putThis -- the parent is now "this"
        "ref" -> lift (refOf curThis) >>= putThis -- the ref'd Clafer is now "this"
        u -> lift (claferWithUid u) >>= putThis
      return path

constraintConstraints2 :: MonadScope m => m [SClafer]
constraintConstraints2 =
  do
    parts <- fmap (nub . concat) $ do
      runListT $ execWriterT $ do
        (curThis, con) <- lift $ foreach $ constraintsUnder anything
        
        t <- topNonRootAncestor curThis
        trace (show (uid t) ++ "::" ++ show (uid curThis)) $ return ()
        
        constraint <- lift $ foreach $ scopeConstraint curThis con
        oneConstraint curThis constraint

    rPartList <- forM (map steps parts) $
      \(conc : abst) -> do
        reifiedParts <- forM (tail $ inits abst) $
          \abst' -> reifyPart (Part $ conc : abst')
        return (conc, concat reifiedParts)
    
    -- Create reified clafers.
    runListT $ do
      (conc, parts) <- foreachM $ nub rPartList
      (parent, child) <- foreachM $ zip (Part [conc] : parts) parts
      baseClafer <- lift $ claferWithUid $ base child
      return $ SClafer (reifyVarName child) False (low baseClafer) (high baseClafer) (Just $ reifyVarName parent) (Just $ Colon $ uid baseClafer) []
  where
  base (Part steps) = last steps
  
  oneConstraint :: (MonadWriter [Part] m, MonadScope m) => SClafer -> (Expr, Con, Expr) -> m ()
  oneConstraint SClafer{uid} (e1, con, e2) =
    void $ runMaybeT $ oneConstraint' e1 e2 `mplus` oneConstraint' e2 e1
    where
    oneConstraint' (This (Path parts)) (Const constant) =
      -- TODO Not head
      reifyVar (head parts) `comp` (return $ constant *^ var uid)
    oneConstraint' (This (Path parts1)) (This (Path parts2)) =
      reifyVar (head parts1) `comp` reifyVar (head parts2)
    oneConstraint' (Global (Path parts)) (Const constant) =
      reifyVar (head parts) `compTo` (return $ fromInteger constant)
    oneConstraint' _ _ = mzero
    
    comp x y =
      do
        x' <- x
        y' <- y
        case con of
          LEQ -> x' `leq` y'
          EQU -> x' `equal` y'
          GEQ -> x' `geq` y'
    compTo x y =
      do
        x' <- x
        y' <- y
        case con of
          LEQ -> x' `leqTo` y'
          EQU -> x' `equalTo` y'
          GEQ -> x' `geqTo` y'
  
  reifyVar p = tell [p] >> return (var $ reifyVarName p)
  reifyVarName (Part [target]) = target
  reifyVarName (Part target)   = (uniqNameSpace ++ "reify_" ++ intercalate "_" target)
  
  reifyPart (Part steps) =
    do
      as <- claferWithUid (last steps) >>= nonTopAncestors
      forM as $
        \a -> return $ Part $ init steps ++ [uid a]
  
  nonTopAncestors child =
    do
      parent <- parentOf child
      if uid parent == rootUid
        then return []
        else (++ [child]) `fmap` nonTopAncestors parent
  

data Con = EQU | LEQ | GEQ deriving Show

scopeConstraint :: MonadScope m => SClafer -> I.PExp -> m [(Expr, Con, Expr)]
scopeConstraint curThis pexp =
  runListT $ scopeConstraint' $ I.exp pexp
  where
  scopeConstraint' I.IDeclPExp {I.quant = I.ISome, I.oDecls = [], I.bpexp} = parsePath2 curThis bpexp `greaterThan` constant 1
  scopeConstraint' I.IDeclPExp {I.quant = I.ISome, I.oDecls}               = msum $ map pathAndMultDecl oDecls
      where
      pathAndMultDecl I.IDecl {I.isDisj = True, I.decls, I.body}  = parsePath2 curThis body `greaterThan` constant (length decls)
      pathAndMultDecl I.IDecl {I.isDisj = False, I.decls, I.body} = parsePath2 curThis body `greaterThan` constant 1
  scopeConstraint' I.IDeclPExp {I.quant = I.IOne, I.oDecls = [], I.bpexp} = parsePath2 curThis bpexp `eqTo` constant 1
  scopeConstraint' I.IDeclPExp {I.quant = I.IOne, I.oDecls} =
    do
      oDecl <- foreachM oDecls
      parsePath2 curThis (I.body oDecl) `eqTo` constant 1
  scopeConstraint' I.IFunExp {I.op, I.exps = [exp1, exp2]}
    | op == "="  = scopeConstraintNum exp1 `eqTo` scopeConstraintNum exp2
    | op == "<=" = scopeConstraintNum exp1 `lessThan` scopeConstraintNum exp2
    | op == ">=" = scopeConstraintNum exp1 `greaterThan` scopeConstraintNum exp2
  
  scopeConstraintNum I.PExp {I.exp = I.IInt const} = constant const
  scopeConstraintNum I.PExp {I.exp = I.IFunExp {I.op = "#", I.exps = [path]}} = parsePath2 curThis path
  scopeConstraintNum _ = mzero

  constant :: (Monad m, Integral i) => i -> m Expr
  constant = return . Const . toInteger

  greaterThan = liftM2 (,GEQ,)
  lessThan = liftM2 (,LEQ,)
  eqTo = liftM2 (,EQU,)


{-
 - We use the stack to push every abstraction we traverse through.
 - For example:
 - 
 -  abstract A
 -    B ?
 -      C : D ?
 -  abstract D
 -    E ?
 -  F : A
 -  G : A
 -  H : A
 -
 -  [some F.B.C.E]
 -  [some G.B.C.E]
 -
 - The first constraint's final stack will look like ["C" ,"F"]
 - Hence the linear programming equation will look like:
 -
 -  scope_F_C_E >= scope_root
 -
 - Adding the second constraint:
 -
 -  scope_G_C_E >= scope_root
 -  scope_E >= scope_F_C_E + scope_G_C_E (*)
 -
 - Solving the minimization should have scope_E = 2 in its solution.
 - The (*) equation is set in constraintConstraints
 -}      
parsePath2 :: MonadScope m => SClafer -> I.PExp -> m Expr
parsePath2 start pexp =
  do
    root <- claferWithUid rootUid
    match <- patternMatch parsePath' (ParseState root []) (fromMaybe [] $ unfoldJoins pexp)
    either (error . show) return match
  where
  asPath :: [[String]] -> Path
  asPath parts = Path [Part part | part <- parts, not $ null part]
  
  parsePath' = (This . asPath <$> parseThisPath) <|> (Global . asPath <$> parseNonthisPath)
  
  parseThisPath = (_this_ >>= follow) >> parseNonthisPath
  parseNonthisPath =
    do
      paths <- many (step >>= follow)
      
      lifo <- popStack
      let end = if null paths then [] else [last paths]
      let result = reverse $ end ++ map uid lifo
      
      do
        _ref_ >>= follow
        -- recurse
        rec <- parseNonthisPath
        return $ result : rec
        <|> return [result]
      
  -- Step handles non-this token.
  step :: MonadScope m => ParseT m String
  step = _directChild_ <|> try (pushThis >> _indirectChild_)
  
  -- Update the state of where "this" is.
  -- Path is one step away from where "this" is.
  follow :: MonadScope m => String -> ParseT m String
  follow path =
    do
      curThis <- getThis
      case path of
        "this" -> putThis start
        "parent" -> lift (parentOf curThis) >>= putThis -- the parent is now "this"
        "ref" -> lift (refOf curThis) >>= putThis -- the ref'd Clafer is now "this"
        u -> lift (claferWithUid u) >>= putThis
      return path



      
      
{------------------------------------------------------------
 ---------- Internals ---------------------------------------
 ------------------------------------------------------------}

newtype ScopeAnalysis a = ScopeAnalysis (VSupplyT (AnalysisT (LPM String Double)) a)
  deriving (Monad, Functor, MonadState (LP String Double), MonadSupply Var, MonadReader Info, MonadAnalysis)

class (MonadAnalysis m, MonadState (LP String Double) m, MonadSupply Var m) => MonadScope m

instance (MonadAnalysis m, MonadState (LP String Double) m, MonadSupply Var m) => MonadScope m


runScopeAnalysis :: ScopeAnalysis a -> Info -> (a, LP String Double)
runScopeAnalysis (ScopeAnalysis s) info = runLPM $ runAnalysisT (runVSupplyT s) info

-- Unfold joins
-- If the expression is a tree of only joins, then this function will flatten
-- the joins into a list.
-- Otherwise, returns an empty list.
unfoldJoins :: Monad m => I.PExp -> m [Token]
unfoldJoins pexp =
    unfoldJoins' pexp
    where
    unfoldJoins' I.PExp{I.exp = (I.IFunExp "." args)} =
        return $ args >>= (fromMaybe [] . unfoldJoins)
    unfoldJoins' I.PExp{I.inPos, I.exp = I.IClaferId{I.sident}} =
        return $ [Token (spanToSourcePos inPos) sident]
    unfoldJoins' _ =
        fail "not a join"


-- Variables starting with "_aux_" are reserved for creating
-- new variables at runtime.
uniqNameSpace :: String
uniqNameSpace = "_aux_"

uniqVar :: MonadScope m => m String
uniqVar =
  do
    c <- supplyNew
    return $ uniqNameSpace ++ show (varId c)

{-
 - Create a new variable "aux". If
 -   v == 0 -> aux == 0
 -   v > 0  -> aux == 1
 -
 - pre: v >= 0
 -}
testPositive :: MonadScope m => String -> m String
testPositive v =
  do
    aux <- uniqVar
    var aux `leq` var v
    var aux `geq` (smallM *^ var v)
    var aux `leqTo` 1
    setVarKind aux IntVar
    return aux

{-
 - smallM cannot be too small. For example, with glpk
 -   0.000001 * 9 = 0
 -}
smallM :: Double
smallM = 0.00001





{-
 -
 - Parsing
 -
 -}
data Token = Token {tPos::SourcePos, tLexeme::String} deriving Show

data ParseState = ParseState
  {psThis::SClafer, -- "this"
   psStack::[SClafer] -- the list of all the abstract Clafers traversed
   }
   deriving Show
type ParseT = ParsecT [Token] ParseState


-- Where "this" refers to.
getThis :: MonadScope m => ParseT m SClafer
getThis =
  do
    s <- getState
    return (psThis s)

-- Update where "this" refers to.
putThis :: MonadScope m => SClafer -> ParseT m ()
putThis newThis = 
  do
    state' <- getState
    putState $ state'{psThis = newThis}

popStack :: MonadScope m => ParseT m [SClafer]
popStack =
  do
    state' <- getState
    let stack = psStack state'
    putState state'{psStack = []}
    return stack

pushThis :: MonadScope m => ParseT m ()
pushThis =
  do
    state' <- getState
    putState $ state'{psStack = psThis state' : psStack state'}


-- Parser combinator for "this"
_this_ :: MonadScope m => ParseT m String
_this_ = satisfy (== "this")

-- Parser combinator for "parent"
_parent_ :: MonadScope m => ParseT m String
_parent_ = satisfy (== "parent")

-- Parser combinator for "ref"
_ref_ :: MonadScope m => ParseT m String
_ref_ = satisfy (== "ref")

-- Parser combinator for a uid that is not "this", "parent", or "ref"
_child_ :: MonadScope m => ParseT m String
_child_ = satisfy (not . (`elem` ["this", "parent", "ref"]))

-- Parser combinator for a uid of direct child.
_directChild_ :: MonadScope m => ParseT m String
_directChild_ =
  try $ do
    curThis <- getThis
    clafer <- _child_ >>= lift . claferWithUid
    check <- lift $ isDirectChild clafer curThis
    when (not check) $ unexpected $ (uid clafer) ++ " is not a direct child of " ++ (uid curThis)
    return $ uid clafer

-- Parser combinator for a uid of indirect child.
_indirectChild_ :: MonadScope m => ParseT m String
_indirectChild_ =
  try $ do
    curThis <- getThis
    clafer <- _child_ >>= lift . claferWithUid
    check <- lift $ isIndirectChild clafer curThis
    when (not check) $ unexpected $ (uid clafer) ++ " is not an indirect child of " ++ (uid curThis)
    return $ uid clafer    
    

satisfy :: MonadScope m => (String -> Bool) -> ParseT m String
satisfy f = tLexeme <$> tokenPrim (tLexeme)
                                  (\_ c _ -> tPos c)
                                  (\c -> if f $ tLexeme c then Just c else Nothing)


spanToSourcePos :: Span -> SourcePos
spanToSourcePos (Span (Pos l c) _) = (newPos "" (fromInteger l) (fromInteger c))


patternMatch :: MonadScope m => ParseT m a -> ParseState -> [Token] -> m (Either ParseError a)
patternMatch parse' state' =
  runParserT (parse' <* eof) state' ""



{-
 -
 - Utility functions
 -
 -}
subexpressions :: I.PExp -> [I.PExp]
subexpressions p@I.PExp{I.exp} =
  p : subexpressions' exp
  where
  subexpressions' I.IDeclPExp{I.oDecls, I.bpexp} =
    concatMap (subexpressions . I.body) oDecls ++ subexpressions bpexp
  subexpressions' I.IFunExp{I.exps} = concatMap subexpressions exps
  subexpressions' _ = []

instance MonadSupply s m => MonadSupply s (ListT m) where
  supplyNew = lift supplyNew
  
instance MonadSupply s m => MonadSupply s (MaybeT m) where
  supplyNew = lift supplyNew

instance MonadSupply s m => MonadSupply s (ParsecT a b m) where
  supplyNew = lift supplyNew
