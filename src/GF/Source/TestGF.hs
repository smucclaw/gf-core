-- automatically generated by BNF Converter
module TestGF where 

import LexGF
import ParGF
import SkelGF
import PrintGF
import AbsGF
import ErrM

type ParseFun a = [Token] -> Err a

runFile :: (Print a, Show a) => ParseFun a -> FilePath -> IO()
runFile p f = readFile f >>= run p

run :: (Print a, Show a) => ParseFun a -> String -> IO()
run p s = case (p (myLexer s)) of
           Bad s    -> do  putStrLn "\nParse Failed...\n"
                           putStrLn s
           Ok  tree -> do putStrLn "\nParse Successful!"
                          putStrLn $ "\n[Abstract Syntax]\n\n" ++ show tree
                          putStrLn $ "\n[Linearized tree]\n\n" ++ printTree tree
