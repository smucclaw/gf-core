module SourceToGrammar where

import qualified Grammar as G
import qualified PrGrammar as GP
import qualified Modules as GM
import qualified Macros as M
import qualified Update as U
import qualified Option as GO
import qualified ModDeps as GD
import Ident
import AbsGF
import PrintGF
import RemoveLiT --- for bw compat
import Operations

import Monad
import Char

-- based on the skeleton Haskell module generated by the BNF converter

type Result = Err String

failure :: Show a => a -> Err b
failure x = Bad $ "Undefined case: " ++ show x

transIdent :: Ident -> Err Ident
transIdent x = case x of
  x  -> return x

transGrammar :: Grammar -> Err G.SourceGrammar
transGrammar x = case x of
  Gr moddefs  -> do
    moddefs' <- mapM transModDef moddefs
    GD.mkSourceGrammar moddefs'

transModDef :: ModDef -> Err (Ident, G.SourceModInfo)
transModDef x = case x of
  MMain id0 id concspecs  -> do
    id0' <- transIdent id0
    id'  <- transIdent id
    concspecs' <- mapM transConcSpec concspecs
    return $ (id0', GM.ModMainGrammar (GM.MainGrammar id' concspecs'))
  MAbstract id extends opens defs  -> do
    id'      <- transIdent id
    extends' <- transExtend extends
    opens'   <- transOpens opens
    defs0    <- mapM transAbsDef $ getTopDefs defs
    defs'    <- U.buildAnyTree [d | Left  ds <- defs0, d <- ds]
    flags    <- return       [f | Right fs <- defs0, f <- fs]
    return $ (id', GM.ModMod (GM.Module GM.MTAbstract flags extends' opens' defs')) 
  MResource id extends opens defs  -> do
    id'      <- transIdent id
    extends' <- transExtend extends
    opens'   <- transOpens opens
    defs0    <- mapM transResDef $ getTopDefs defs
    defs'    <- U.buildAnyTree [d | Left  ds <- defs0, d <- ds]
    flags    <- return       [f | Right fs <- defs0, f <- fs]
    return $ (id', GM.ModMod (GM.Module GM.MTResource flags extends' opens' defs')) 
  MConcrete id open extends opens defs -> do
    id'      <- transIdent id
    open'    <- transIdent open
    extends' <- transExtend extends
    opens'   <- transOpens opens
    defs0    <- mapM transCncDef $ getTopDefs defs
    defs'    <- U.buildAnyTree [d | Left  ds <- defs0, d <- ds]
    flags    <- return       [f | Right fs <- defs0, f <- fs]
    return $ (id', 
      GM.ModMod (GM.Module (GM.MTConcrete open') flags extends' opens' defs'))
  MTransfer id open0 open extends opens defs -> do
    id'      <- transIdent id
    open0'   <- transOpen open0
    open'    <- transOpen open
    extends' <- transExtend extends
    opens'   <- transOpens opens
    defs0    <- mapM transAbsDef $ getTopDefs defs
    defs'    <- U.buildAnyTree [d | Left  ds <- defs0, d <- ds]
    flags    <- return       [f | Right fs <- defs0, f <- fs]
    return $ (id', 
     GM.ModMod (GM.Module (GM.MTTransfer open0' open') flags extends' opens' defs'))

  MReuseAbs id0 id  -> failure x
  MReuseCnc id0 id  -> failure x
  MReuseAll r e c  -> do
    r' <- transIdent r
    e' <- transExtend e
    c' <- transIdent c
    return $ (r', GM.ModMod (GM.Module (GM.MTReuse c') [] e' [] NT)) 

getTopDefs :: [TopDef] -> [TopDef]
getTopDefs x = x

transConcSpec :: ConcSpec -> Err (GM.MainConcreteSpec Ident)
transConcSpec x = case x of
  ConcSpec id concexp  -> do
    id' <- transIdent id
    (m,mi,mo) <- transConcExp concexp
    return $ GM.MainConcreteSpec id' m mi mo

transConcExp :: ConcExp -> 
       Err (Ident, Maybe (GM.OpenSpec Ident),Maybe (GM.OpenSpec Ident))
transConcExp x = case x of
  ConcExp id transfers  -> do
    id' <- transIdent id
    trs <- mapM transTransfer transfers
    tin <- case [o | Left o <- trs] of
      [o] -> return $ Just o
      []  -> return $ Nothing
      _   -> Bad "ambiguous transfer in"
    tout <- case [o | Right o <- trs] of
      [o] -> return $ Just o
      []  -> return $ Nothing
      _   -> Bad "ambiguous transfer out"
    return (id',tin,tout)

transTransfer :: Transfer -> 
                 Err (Either (GM.OpenSpec Ident)(GM.OpenSpec Ident))
transTransfer x = case x of
  TransferIn open  -> liftM Left  $ transOpen open
  TransferOut open -> liftM Right $ transOpen open

transExtend :: Extend -> Err (Maybe Ident)
transExtend x = case x of
  Ext id  -> transIdent id >>= return . Just
  NoExt -> return Nothing

transOpens :: Opens -> Err [GM.OpenSpec Ident]
transOpens x = case x of
  NoOpens  -> return []
  Opens opens  -> mapM transOpen opens

transOpen :: Open -> Err (GM.OpenSpec Ident)
transOpen x = case x of
  OName id   -> liftM  GM.OSimple $ transIdent id
  OQual id m -> liftM2 GM.OQualif (transIdent id) (transIdent m)

transAbsDef :: TopDef -> Err (Either [(Ident, G.Info)] [GO.Option])
transAbsDef x = case x of
  DefCat catdefs -> do
    catdefs' <- mapM transCatDef catdefs
    returnl [(cat, G.AbsCat (yes cont) nope) | (cat,cont) <- catdefs']
  DefFun fundefs -> do
    fundefs' <- mapM transFunDef fundefs
    returnl [(fun, G.AbsFun (yes typ) nope) | (funs,typ) <- fundefs', fun <- funs]
  DefDef defs  -> do
    defs' <- liftM concat $ mapM getDefsGen defs
    returnl [(c, G.AbsFun nope pe) | (c,(_,pe)) <- defs']
  DefData _ -> returnl [] ----
  DefTrans defs  -> do
    let (ids,vals) = unzip [(i,v) | FlagDef i v <- defs]
    defs' <- liftM2 zip (mapM transIdent ids) (mapM transIdent vals)
    returnl [(c, G.AbsTrans f) | (c,f) <- defs']
  DefFlag defs -> liftM Right $ mapM transFlagDef defs
  _ -> Bad $ "illegal definition in abstract module:" ++++ printTree x

returnl :: a -> Err (Either a b)
returnl = return . Left

transFlagDef :: FlagDef -> Err GO.Option
transFlagDef x = case x of
  FlagDef f x  -> return $ GO.Opt (prIdent f,[prIdent x])

transCatDef :: CatDef -> Err (Ident, G.Context)
transCatDef x = case x of
  CatDef id ddecls  -> liftM2 (,) (transIdent id) 
                                  (mapM transDDecl ddecls >>= return . concat)

transFunDef :: FunDef -> Err ([Ident], G.Type)
transFunDef x = case x of
  FunDef ids typ  -> liftM2 (,) (mapM transIdent ids) (transExp typ)

transResDef :: TopDef -> Err (Either [(Ident, G.Info)] [GO.Option])
transResDef x = case x of
  DefPar pardefs -> do
    pardefs' <- mapM transParDef pardefs
    returnl $ [(p, G.ResParam (if null pars 
                                  then nope -- abstract param type 
                                  else (yes pars))) | (p,pars) <- pardefs']
           ++ [(f, G.ResValue (yes (M.mkProdSimple co (G.Cn p)))) |
                     (p,pars) <- pardefs', (f,co) <- pars]
  DefOper defs -> do
    defs' <- liftM concat $ mapM getDefs defs
    returnl [(f, G.ResOper pt pe) | (f,(pt,pe)) <- defs']

  DefLintype defs -> do
    defs' <- liftM concat $ mapM getDefs defs
    returnl [(f, G.ResOper pt pe) | (f,(pt,pe)) <- defs']

  DefFlag defs -> liftM Right $ mapM transFlagDef defs
  _ -> Bad $ "illegal definition form in resource" +++ printTree x

transParDef :: ParDef -> Err (Ident, [G.Param])
transParDef x = case x of
  ParDef id params  -> liftM2 (,) (transIdent id) (mapM transParConstr params)
  ParDefAbs id -> liftM2 (,) (transIdent id) (return [])
  _ -> Bad $ "illegal definition in resource:" ++++ printTree x

transCncDef :: TopDef -> Err (Either [(Ident, G.Info)] [GO.Option])
transCncDef x = case x of
  DefLincat defs  -> do
    defs' <- liftM concat $ mapM transPrintDef defs
    returnl [(f, G.CncCat (yes t) nope nope) | (f,t) <- defs']
  DefLindef defs  -> do
    defs' <- liftM concat $ mapM getDefs defs
    returnl [(f, G.CncCat pt pe nope) | (f,(pt,pe)) <- defs']
  DefLin defs  -> do
    defs' <- liftM concat $ mapM getDefs defs
    returnl [(f, G.CncFun Nothing pe nope) | (f,(_,pe)) <- defs']
  DefPrintCat defs -> do
    defs' <- liftM concat $ mapM transPrintDef defs
    returnl [(f, G.CncCat nope nope (yes e)) | (f,e) <- defs']    
  DefPrintFun defs -> do
    defs' <- liftM concat $ mapM transPrintDef defs
    returnl [(f, G.CncFun Nothing nope (yes e)) | (f,e) <- defs']
  DefPrintOld defs -> do  -- a guess, for backward compatibility
    defs' <- liftM concat $ mapM transPrintDef defs
    returnl [(f, G.CncFun Nothing nope (yes e)) | (f,e) <- defs']    
  DefFlag defs -> liftM Right $ mapM transFlagDef defs
  DefPattern defs  -> do
    defs' <- liftM concat $ mapM getDefs defs
    let defs2 = [(f, termInPattern t) | (f,(_,Yes t)) <- defs']
    returnl [(f, G.CncFun Nothing (yes t) nope) | (f,t) <- defs2]

  _ -> Bad $ "illegal definition in concrete syntax:" ++++ printTree x

transPrintDef :: PrintDef -> Err [(Ident,G.Term)]
transPrintDef x = case x of
  PrintDef id exp  -> do
    (ids,e) <- liftM2 (,) (mapM transIdent id) (transExp exp)
    return $ [(i,e) | i <- ids]

getDefsGen :: Def -> Err [(Ident, (G.Perh G.Type, G.Perh G.Term))]
getDefsGen d = case d of
  DDecl ids t -> do
    ids' <- mapM transIdent ids
    t'   <- transExp t
    return [(i,(yes t', nope)) | i <- ids']
  DDef ids e -> do
    ids' <- mapM transIdent ids
    e'   <- transExp e
    return [(i,(nope, yes e')) | i <- ids']
  DFull ids t e -> do
    ids' <- mapM transIdent ids
    t'   <- transExp t
    e'   <- transExp e
    return [(i,(yes t', yes e')) | i <- ids']
  DPatt id patts e  -> do
    id' <- transIdent id
    ps' <- mapM transPatt patts
    e'  <- transExp e
    return [(id',(nope, yes (G.Eqs [(ps',e')])))]

-- sometimes you need this special case, e.g. in linearization rules
getDefs :: Def -> Err [(Ident, (G.Perh G.Type, G.Perh G.Term))]
getDefs d = case d of
  DPatt id patts e  -> do
    id' <- transIdent id
    xs  <- mapM tryMakeVar patts
    e'  <- transExp e
    return [(id',(nope, yes (M.mkAbs xs e')))]
  _ -> getDefsGen d

-- accepts a pattern that is either a variable or a wild card
tryMakeVar :: Patt -> Err Ident
tryMakeVar p = do
  p' <- transPatt p
  case p' of
    G.PV i -> return i
    G.PW   -> return identW
    _ -> Bad $ "not a legal pattern in lambda binding" +++ GP.prt p'

transExp :: Exp -> Err G.Term
transExp x = case x of
  EIdent id     -> liftM G.Vr $ transIdent id
  EConstr id    -> liftM G.Con $ transIdent id
  ECons id      -> liftM G.Cn $ transIdent id
  EQConstr m c  -> liftM2 G.QC (transIdent m) (transIdent c)
  EQCons m c    -> liftM2 G.Q  (transIdent m) (transIdent c)
  EString str   -> return $ G.K str 
  ESort sort    -> liftM G.Sort $ transSort sort
  EInt n        -> return $ G.EInt $ fromInteger n
  EMeta         -> return $ M.meta $ M.int2meta 0
  EEmpty        -> return G.Empty
  EStrings []   -> return G.Empty
  EStrings str  -> return $ foldr1 G.C $ map G.K $ words str
  ERecord defs  -> erecord2term defs
  ETupTyp _ _   -> do
    let tups t = case t of
          ETupTyp x y -> tups x ++ [y] -- right-associative parsing
          _ -> [t]
    es <- mapM transExp $ tups x
    return $ G.RecType $ M.tuple2recordType es
  ETuple tuplecomps  -> do
    es <- mapM transExp [e | TComp e <- tuplecomps]
    return $ G.R $ M.tuple2record es
  EProj exp id  -> liftM2 G.P (transExp exp) (trLabel id)
  EApp exp0 exp  -> liftM2 G.App (transExp exp0) (transExp exp)
  ETable cases  -> liftM (G.T G.TRaw) (transCases cases)
  ETTable exp cases -> 
    liftM2 (\t c -> G.T (G.TTyped t) c) (transExp exp) (transCases cases)
  ECase exp cases  -> do
    exp' <- transExp exp
    cases' <- transCases cases
    return $ G.S (G.T G.TRaw cases') exp'
  ECTable binds exp  -> liftM2 M.mkCTable (mapM transBind binds) (transExp exp)

  EVariants exps    -> liftM G.FV $ mapM transExp exps
  EPre exp alts     -> liftM2 (curry G.Alts) (transExp exp) (mapM transAltern alts)
  EStrs exps        -> liftM G.Strs $ mapM transExp exps
  ESelect exp0 exp  -> liftM2 G.S (transExp exp0) (transExp exp)
  EExtend exp0 exp  -> liftM2 G.ExtR (transExp exp0) (transExp exp)
  EAbstr binds exp  -> liftM2 M.mkAbs (mapM transBind binds) (transExp exp)
  ETyped exp0 exp   -> liftM2 G.Typed (transExp exp0) (transExp exp)

  EProd decl exp    -> liftM2 M.mkProdSimple (transDecl decl) (transExp exp)
  ETType exp0 exp   -> liftM2 G.Table (transExp exp0) (transExp exp)
  EConcat exp0 exp  -> liftM2 G.C (transExp exp0) (transExp exp)
  EGlue exp0 exp    -> liftM2 G.Glue (transExp exp0) (transExp exp)
  ELet defs exp  -> do
    exp'  <- transExp exp
    defs0 <- mapM locdef2fields defs
    defs' <- mapM tryLoc $ concat defs0
    return $ M.mkLet defs' exp'
   where
     tryLoc (c,(mty,Just e)) = return (c,(mty,e))
     tryLoc (c,_) = Bad $ "local definition of" +++ GP.prt c +++ "without value"

  ELString (LString str) -> return $ G.K str 
  ELin id -> liftM G.LiT $ transIdent id

  _ -> Bad $ "translation not yet defined for" +++ printTree x ----

--- this is complicated: should we change Exp or G.Term ?
 
erecord2term :: [LocDef] -> Err G.Term
erecord2term ds = do
  ds' <- mapM locdef2fields ds 
  mkR $ concat ds'
 where
  mkR fs = do 
    fs' <- transF fs
    return $ case fs' of
      Left ts  -> G.RecType ts
      Right ds -> G.R ds
  transF [] = return $ Left [] --- empty record always interpreted as record type
  transF fs@(f:_) = case f of
    (lab,(Just ty,Nothing)) -> mapM tryRT fs >>= return . Left
    _ -> mapM tryR fs >>= return . Right
  tryRT f = case f of
    (lab,(Just ty,Nothing)) -> return (M.ident2label lab,ty)
    _ -> Bad $ "illegal record type field" +++ GP.prt (fst f) --- manifest fields ?!
  tryR f = case f of
    (lab,(mty, Just t)) -> return (M.ident2label lab,(mty,t))
    _ -> Bad $ "illegal record field" +++ GP.prt (fst f)

  
locdef2fields d = case d of
    LDDecl ids t -> do
      labs <- mapM transIdent ids
      t'   <- transExp t
      return [(lab,(Just t',Nothing)) | lab <- labs]
    LDDef ids e -> do
      labs <- mapM transIdent ids
      e'   <- transExp e
      return [(lab,(Nothing, Just e')) | lab <- labs]
    LDFull ids t e -> do
      labs <- mapM transIdent ids
      t'   <- transExp t
      e'   <- transExp e
      return [(lab,(Just t', Just e')) | lab <- labs]

trLabel :: Label -> Err G.Label
trLabel x = case x of

  -- this case is for bward compatibiity and should be removed
  LIdent (IC ('v':ds)) | all isDigit ds -> return $ G.LVar $ readIntArg ds 
  
  LIdent (IC s) -> return $ G.LIdent s
  LVar x   -> return $ G.LVar $ fromInteger x

transSort :: Sort -> Err String
transSort x = case x of
  _ -> return $ printTree x

transPatt :: Patt -> Err G.Patt
transPatt x = case x of
  PW  -> return G.wildPatt
  PV id  -> liftM G.PV $ transIdent id
  PC id patts  -> liftM2 G.PC (transIdent id) (mapM transPatt patts)
  PCon id  -> liftM2 G.PC (transIdent id) (return [])
  PInt n  -> return $ G.PInt (fromInteger n)
  PStr str  -> return $ G.PString str
  PR pattasss -> do
    let (lss,ps) = unzip [(ls,p) | PA ls p <- pattasss]
        ls = map LIdent $ concat lss
    liftM G.PR $ liftM2 zip (mapM trLabel ls) (mapM transPatt ps)
  PTup pcs -> 
    liftM (G.PR . M.tuple2recordPatt) (mapM transPatt [e | PTComp e <- pcs])
  PQ id0 id  -> liftM3 G.PP (transIdent id0) (transIdent id) (return [])
  PQC id0 id patts  -> 
    liftM3 G.PP (transIdent id0) (transIdent id) (mapM transPatt patts)

transBind :: Bind -> Err Ident
transBind x = case x of
  BIdent id  -> transIdent id
  BWild  -> return identW

transDecl :: Decl -> Err [G.Decl]
transDecl x = case x of
  DDec binds exp  -> do
    xs   <- mapM transBind binds
    exp' <- transExp exp
    return [(x,exp') | x <- xs]
  DExp exp  -> liftM (return . M.mkDecl) $ transExp exp

transCases :: [Case] -> Err [G.Case]
transCases = liftM concat . mapM transCase

transCase :: Case -> Err [G.Case]
transCase (Case pattalts exp) = do
  patts <- mapM transPatt [p | AltP p <- pattalts]
  exp'  <- transExp exp  
  return [(p,exp') | p <- patts]

transAltern :: Altern -> Err (G.Term, G.Term)
transAltern x = case x of
  Alt exp0 exp  -> liftM2 (,) (transExp exp0) (transExp exp)

transParConstr :: ParConstr -> Err G.Param
transParConstr x = case x of
  ParConstr id ddecls  -> do
    id' <- transIdent id
    ddecls' <- mapM transDDecl ddecls
    return (id',concat ddecls')

transDDecl :: DDecl -> Err [G.Decl]
transDDecl x = case x of
  DDDec binds exp  -> transDecl $ DDec binds exp
  DDExp exp  ->  transDecl $ DExp exp

-- to deal with the old format, sort judgements in three modules, forming
-- their names from a given string, e.g. file name or overriding user-given string

transOldGrammar :: OldGrammar -> String -> Err G.SourceGrammar
transOldGrammar x name = case x of
  OldGr includes topdefs  -> do --- includes must be collected separately
    let moddefs = sortTopDefs topdefs
    g1 <- transGrammar $ Gr moddefs
    removeLiT g1 --- needed for bw compatibility with an obsolete feature
 where
   sortTopDefs ds = [mkAbs a,mkRes r,mkCnc c] 
     where (a,r,c) = foldr srt ([],[],[]) ds
   srt d (a,r,c) = case d of
     DefCat catdefs  -> (d:a,r,c)
     DefFun fundefs  -> (d:a,r,c)
     DefDef defs     -> (d:a,r,c)
     DefData pardefs -> (d:a,r,c)
     DefPar pardefs  -> (a,d:r,c)
     DefOper defs    -> (a,d:r,c)
     DefLintype defs -> (a,d:r,c)
     DefLincat defs  -> (a,r,d:c)
     DefLindef defs  -> (a,r,d:c)
     DefLin defs     -> (a,r,d:c)
     DefPattern defs -> (a,r,d:c)
     DefFlag defs    -> (a,r,d:c) --- a guess
     DefPrintCat printdefs  -> (a,r,d:c)
     DefPrintFun printdefs  -> (a,r,d:c)
     DefPrintOld printdefs  -> (a,r,d:c)
   mkAbs a = MAbstract absName NoExt (Opens []) $ topDefs a
   mkRes r = MResource resName NoExt (Opens []) $ topDefs r
   mkCnc r = MConcrete cncName absName NoExt (Opens [OName resName]) $ topDefs r
   topDefs t = t

   absName = identC topic
   resName = identC ("Res" ++ lang)
   cncName = identC lang

   (beg,rest) = span (/='.') name
   (topic,lang) = case rest of -- to avoid overwriting old files
     ".gf" -> ("Abs" ++ beg,"Cnc" ++ beg)
     []    -> ("Abs" ++ beg,"Cnc" ++ beg)
     _:s   -> (beg, takeWhile (/='.') s)

transInclude :: Include -> Err [FilePath]
transInclude x = case x of
  NoIncl -> return []
  Incl filenames  -> return $ map trans filenames
 where
   trans f = case f of
     FString s  -> s
     FIdent (IC s) -> s
     FSlash filename  -> '/' : trans filename
     FDot filename  -> '.' : trans filename
     FMinus filename  -> '-' : trans filename
     FAddId (IC s) filename  -> s ++ trans filename

termInPattern :: G.Term -> G.Term
termInPattern t = M.mkAbs xx $ G.R [(s, (Nothing, toP body))] where
  toP t = case t of
    G.Vr x -> G.P t s
    _ -> M.composSafeOp toP t
  s = G.LIdent "s"
  (xx,body) = abss [] t
  abss xs t = case t of
    G.Abs x b -> abss (x:xs) b
    _ -> (reverse xs,t)
