{-# LANGUAGE FlexibleContexts #-}

module Circuit.Builder where

import Circuit
import Util
import Rand

import Control.Monad.State
import Data.List.Split (chunksOf)
import Text.Printf
import qualified Data.Map as M
import qualified Data.Bimap as B
import qualified Data.Set as S
import qualified Data.Vector as V
import Debug.Trace

type Builder = State BuildSt

data BuildSt = BuildSt {
      bs_circ        :: Circuit
    , bs_next_ref    :: Ref
    , bs_next_inp    :: Id
    , bs_next_secret :: Id
    , bs_refmap      :: M.Map String Ref
    , bs_dedup       :: M.Map Op Ref
    }

emptyBuild :: BuildSt
emptyBuild = BuildSt emptyCirc 0 0 0 M.empty M.empty

getCirc :: Builder Circuit
getCirc = gets bs_circ

modifyCirc :: (Circuit -> Circuit) -> Builder ()
modifyCirc f = modify (\st -> st { bs_circ = f (bs_circ st) })

insertOp :: Ref -> Op -> Builder ()
insertOp ref op = do
    refs <- circ_refmap <$> getCirc
    when (M.member ref refs) $
        error ("redefinition of ref " ++ show ref)
    modifyCirc (\c -> c { circ_refmap = M.insert ref op refs })
    modify (\st -> st { bs_dedup = M.insert op ref (bs_dedup st)})

insertSecret :: Ref -> Id -> Builder ()
insertSecret ref id = do
    modifyCirc (\c -> c { circ_secret_refs = M.insert ref id (circ_secret_refs c) })
    insertOp ref (OpSecret id)

insertSecretVal :: Id -> Integer -> Builder ()
insertSecretVal id val = do
    ys <- circ_secrets <$> getCirc
    let ys' = safeInsert ("reassignment of y" ++ show id) id val ys
    modifyCirc (\c -> c { circ_secrets = ys' })

insertInput :: Ref -> Id -> Builder ()
insertInput ref id = do
    modifyCirc (\c -> c { circ_inputs = circ_inputs c ++ [ref] })
    insertOp ref (OpInput id)

newOp :: Op -> Builder Ref
newOp op = do
    dedup <- gets bs_dedup
    case M.lookup op dedup of
        Nothing -> do
            ref <- nextRef
            insertOp ref op
            return ref
        Just ref -> do
            return ref

nextRef :: Builder Ref
nextRef = do
    ref <- gets bs_next_ref
    modify (\st -> st { bs_next_ref = ref + 1 })
    return ref

nextInputId :: Builder Id
nextInputId = do
    id <- gets bs_next_inp
    modify (\st -> st { bs_next_inp = id + 1 })
    return id

nextSecretId :: Builder Id
nextSecretId = do
    id <- gets bs_next_secret
    modify (\st -> st { bs_next_secret = id + 1 })
    return id

markOutput :: Ref -> Builder ()
markOutput ref = modifyCirc (\c -> c { circ_outputs = circ_outputs c ++ [ref] })

markConst :: Ref -> Integer -> Builder ()
markConst ref val = modifyCirc (\c -> c { circ_consts = B.insert val ref (circ_consts c) })

foldTreeM :: Monad m => (a -> a -> m a) -> [a] -> m a
foldTreeM f [ ] = error "[foldTreeM] empty list"
foldTreeM f [x] = return x
foldTreeM f xs  = do
    let g ys = if length ys == 1
                  then return (head ys)
                  else f (ys!!0) (ys!!1)
    zs <- mapM g (chunksOf 2 xs)
    foldTreeM f zs

--------------------------------------------------------------------------------
-- smart constructors

buildCircuit :: Builder a -> Circuit
buildCircuit = bs_circ . flip execState emptyBuild

input :: Builder Ref
input = do
    id   <- nextInputId
    ref  <- nextRef
    insertInput ref id
    return ref

inputs :: Int -> Builder [Ref]
inputs n = replicateM n input

secret :: Integer -> Builder Ref
secret val = do
    id  <- nextSecretId
    ref <- nextRef
    insertSecret ref id
    insertSecretVal id val
    return ref

secrets :: [Integer] -> Builder [Ref]
secrets = mapM secret

constant :: Integer -> Builder Ref
constant val = do
    c <- getCirc
    if B.member val (circ_consts c) then do
        return (circ_consts c B.! val)
    else do
        ref <- secret val
        markConst ref val
        return ref

constants :: [Integer] -> Builder [Ref]
constants = mapM constant

circAdd :: Ref -> Ref -> Builder Ref
circAdd x y = newOp (OpAdd x y)

circSub :: Ref -> Ref -> Builder Ref
circSub x y = newOp (OpSub x y)

circMul :: Ref -> Ref -> Builder Ref
circMul x y = newOp (OpMul x y)

circProd :: [Ref] -> Builder Ref
circProd = foldTreeM circMul

-- This creates a balanced tree of binary additions
-- Do not change this API as users of this module for oblivious computation
-- require only binary operators
circSum :: [Ref] -> Builder Ref
circSum = foldTreeM circAdd

circSumN :: [Ref] -> Builder Ref
circSumN = newOp . OpNAdd

circXor :: Ref -> Ref -> Builder Ref
circXor x y = do
    z  <- circAdd x y
    c  <- circMul x y
    c' <- circAdd c c
    circSub z c'

circXors :: [Ref] -> Builder Ref
circXors = foldTreeM circXor

circOr :: Ref -> Ref -> Builder Ref
circOr x y = do
    z <- circAdd x y
    c <- circMul x y
    circSub z c

circOrs :: [Ref] -> Builder Ref
circOrs = foldTreeM circOr

circNot :: Ref -> Builder Ref
circNot x = do
    one <- constant 1
    circSub one x

outputs :: [Ref] -> Builder ()
outputs = mapM_ markOutput

output :: Ref -> Builder ()
output = markOutput

-- NOTE: unconnected secrets from the subcircuit will be secrets in the
-- resulting composite circuit.
subcircuit' :: Circuit -> [Ref] -> [Ref] -> Builder [Ref]
subcircuit' c xs ys
    | length xs /= ninputs c = error (printf "[subcircuit'] not enough inputs got %d, need %d"
                                            (length xs) (ninputs c))
    | length ys /= nconsts c = error (printf "[subcircuit'] not enough consts got %d, need %d"
                                            (length ys) (nconsts c))
    | otherwise = foldCircM translate c
  where
    translate (OpAdd _ _) _ [x,y] = circAdd x y
    translate (OpSub _ _) _ [x,y] = circSub x y
    translate (OpMul _ _) _ [x,y] = circMul x y
    translate (OpInput  id) _ _ = return (xs !! getId id)
    translate (OpSecret id) _ _ = return (ys !! getId id)
    translate op ref args =
        error ("[subcircuit'] weird input: " ++ show op ++ " " ++ show args)

-- lift the subcircuit's constants and secrets into the circuit above
subcircuit :: Circuit -> [Ref] -> Builder [Ref]
subcircuit c xs = do
    ys <- forM (M.toAscList (circ_secret_refs c)) $ \(sref, sid) -> do
        if B.memberR sref (circ_consts c) then do
            constant (circ_consts c B.!> sref)
        else do
            secret (circ_secrets c M.! sid)
    subcircuit' c xs ys

--------------------------------------------------------------------------------
-- extras!

selectPT :: [Ref] -> [Bool] -> Builder [Ref]
selectPT xs bs = do
    one <- constant 1
    when (length xs /= length bs) $ error "[select] unequal length inputs"
    let set one (x, True)  = return x
        set one (x, False) = circSub one x
    mapM (set one) (zip xs bs)

bitsSet :: [Ref] -> [Bool] -> Builder Ref
bitsSet xs bs = circProd =<< selectPT xs bs

-- transforms an input x into a vector [ 0 .. 1 .. 0 ] with a 1 in the xth place
selectionVector :: [Ref] -> Builder [Ref]
selectionVector xs = mapM (bitsSet xs) (permutations (length xs) [False, True])

lookupTable :: ([Bool] -> Bool) -> [Ref] -> Builder Ref
lookupTable f xs = do
    sel <- selectionVector xs
    let tt   = f <$> booleanPermutations (length xs)
        vars = snd <$> filter (\(i,_) -> tt !! i) (zip [0..] sel)
    circSum vars

lookupTableMultibit :: ([Bool] -> [Bool]) -> [Ref] -> Builder [Ref]
lookupTableMultibit f xs =
    mapM (flip lookupTable xs) [ (\x -> f x !! i) | i <- [0..noutputs - 1] ]
  where
    noutputs = length (f (replicate (length xs) False))

matrixTimesVect :: [[Ref]] -> [Ref] -> Builder [Ref]
matrixTimesVect rows vect
  | not $ all ((== length vect) . length) rows = error "[matrixTimesVect] bad dimensions"
  | otherwise = mapM (circXors <=< zipWithM circMul vect) rows

matrixTimesVectPT :: [[Bool]] -> [Ref] -> Builder [Ref]
matrixTimesVectPT rows vect
  | not $ all ((== length vect) . length) rows = error "[matrixTimesVectPT] bad dimensions"
  | otherwise = mapM (circXors <=< selectPT vect) rows

xor :: Bool -> Bool -> Bool
xor False False = False
xor False True  = True
xor True  False = True
xor True  True  = True
