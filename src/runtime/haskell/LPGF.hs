-- | Linearisation-only PGF format
-- Closely follows description in Section 2 of Angelov, Bringert, Ranta (2009)
-- "PGF: A Portable Run-Time Format for Type-Theoretical Grammars"
module LPGF where

import PGF (Language)
import PGF.CId
import PGF.Expr (Expr)
import PGF.Tree (Tree (..), expr2tree, prTree)

import Data.Binary (Binary, get, put, encodeFile, decodeFile)
import qualified Data.Map as Map
import Text.Printf (printf)

-- | Linearisation-only PGF
data LPGF = LPGF {
  absname   :: CId,
  abstract  :: Abstr,
  concretes :: Map.Map CId Concr
} deriving (Show)

-- | Abstract syntax
data Abstr = Abstr {
  -- cats :: Map.Map CId (),
  -- funs :: Map.Map CId Type
} deriving (Show)

-- | Concrete syntax
data Concr = Concr {
  -- lincats :: Map.Map CId LinType, -- ^ assigning a linearization type to each category
  lins    :: Map.Map CId LinFun  -- ^ assigning a linearization function to each function
} deriving (Show)

-- | Abstract function type
-- data Type = Type [CId] CId
--   deriving (Show)

-- | Linearisation type
data LinType =
    LTStr
  | LTInt Int
  | LTProduct [LinType]
  deriving (Show)

-- | Linearisation function
data LinFun =
    LFEmpty
  | LFToken String
  | LFConcat LinFun LinFun
  | LFInt Int
  | LFTuple [LinFun]
  | LFProjection LinFun LinFun -- ^ In order for the projection to be well-formed, t1 must be a tuple and t2 an integer within the bounds of the size of the tuple
  | LFArgument Int
  deriving (Show, Read)

instance Binary LPGF where
  put lpgf = do
    put (absname lpgf)
    put (abstract lpgf)
    put (concretes lpgf)
  get = do
    an <- get
    abs <- get
    concs <- get
    return $ LPGF {
      absname = an,
      abstract = abs,
      concretes = concs
    }

instance Binary Abstr where
  put abs = return ()
  get = return $ Abstr {}

instance Binary Concr where
  put concr = put (lins concr)
  get = do
    ls <- get
    return $ Concr {
      lins = ls
    }

instance Binary LinFun where
  put = put . show
  get = read <$> get

abstractName :: LPGF -> CId
abstractName = absname

encodeFile :: FilePath -> LPGF -> IO ()
encodeFile = Data.Binary.encodeFile

readLPGF :: FilePath -> IO LPGF
readLPGF = Data.Binary.decodeFile

-- | Helper for building concat trees
mkConcat :: [LinFun] -> LinFun
mkConcat [] = LFEmpty
mkConcat [x] = x
mkConcat xs = foldl1 LFConcat xs

-- | Main linearize function
linearize :: LPGF -> Language -> Expr -> String
linearize lpgf lang =
  case Map.lookup lang (concretes lpgf) of
    Just concr -> linearizeConcr concr
    Nothing -> error $ printf "Unknown language: %s" (showCId lang)

-- | Language-specific linearize function
-- Section 2.5
linearizeConcr :: Concr -> Expr -> String
linearizeConcr concr expr = lin2string $ lin (expr2tree expr)
  where
    lin :: Tree -> LinFun
    lin tree = case tree of
      Fun f as ->
        case Map.lookup f (lins concr) of
          Just t -> eval (map lin as) t
          _ -> error $ printf "Lookup failed for function: %s" (showCId f)
      x -> error $ printf "Cannot lin: %s" (prTree x)

-- | Evaluation context is a sequence of terms
type Context = [LinFun]

-- | Operational semantics, Table 2
eval :: Context -> LinFun -> LinFun
eval cxt t = case t of
  LFEmpty -> LFEmpty
  LFToken tok -> LFToken tok
  LFConcat s t -> LFConcat v w
    where
      v = eval cxt s
      w = eval cxt t
  LFInt i -> LFInt i
  LFTuple ts -> LFTuple vs
    where vs = map (eval cxt) ts
  LFProjection t u -> vs !! (i-1)
    where
      LFTuple vs = eval cxt t
      LFInt i = eval cxt u
  LFArgument i -> cxt !! (i-1)

-- | Turn concrete syntax terms into an actual string
lin2string :: LinFun -> String
lin2string l = case l of
  LFEmpty -> ""
  LFToken tok -> tok
  LFConcat l1 l2 -> unwords [lin2string l1, lin2string l2]
  x -> printf "[%s]" (show x)