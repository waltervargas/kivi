module GmCompiler where


import Common
import Parser
import Utils
import List
import Core
import Debug.Trace


type GmCompiledSc = (Name, Int, GmCode)
type GmCompiler = CoreExpr -> GmEnvironment -> GmCode
type GmEnvironment = Assoc Name Int


primitives :: [(Name, [Name], CoreExpr)]
primitives = [("+", ["x", "y"], EAp (EAp (EVar "+") (EVar "x")) (EVar "y")),
              ("-", ["x", "y"], EAp (EAp (EVar "-") (EVar "x")) (EVar "y")),
              ("*", ["x", "y"], EAp (EAp (EVar "*") (EVar "x")) (EVar "y")),
              ("/", ["x", "y"], EAp (EAp (EVar "/") (EVar "x")) (EVar "y")),
              ("negate", ["x"], EAp (EVar "negate") (EVar "x")),
              ("==", ["x", "y"], EAp (EAp (EVar "==") (EVar "x")) (EVar "y")),
              ("!=", ["x", "y"], EAp (EAp (EVar "!=") (EVar "x")) (EVar "y")),
              ("<", ["x", "y"], EAp (EAp (EVar "<") (EVar "x")) (EVar "y")),
              ("<=", ["x", "y"], EAp (EAp (EVar "<=") (EVar "x")) (EVar "y")),
              (">", ["x", "y"], EAp (EAp (EVar ">=") (EVar "x")) (EVar "y")),
              (">=", ["x", "y"], EAp (EAp (EVar ">=") (EVar "x")) (EVar "y")),
              ("if", ["c", "t", "f"], EAp (EAp (EAp (EVar "if") (EVar "c")) (EVar "t")) (EVar "y")),
              ("True", [], EConstr 2 0),
              ("False", [], EConstr 1 0)]


builtinDyadicBool :: Assoc Name Instruction
builtinDyadicBool = [("==", Eq),
                     ("!=", Ne),
                     ("<", Lt),
                     ("<=", Le),
                     (">", Gt),
                     (">=", Ge)]


builtinDyadicInt :: Assoc Name Instruction
builtinDyadicInt = [("+", Add),
                    ("-", Sub),
                    ("*", Mul),
                    ("/", Div)]


builtinDyadic :: Assoc Name Instruction
builtinDyadic = builtinDyadicBool ++ builtinDyadicInt


compile :: CoreProgram -> GmState
compile program = ([], initialCode, [], [], [], heap, globals, initialStats)
    where
        (heap, globals) = buildInitialHeap program


initialCode :: GmCode
initialCode = [Pushglobal "main", Eval, Print]


buildInitialHeap :: CoreProgram -> (GmHeap, GmGlobals)
buildInitialHeap program =
    mapAccumL allocateSc hInitial compiled
    where
        compiled = map compileSc $ preludeDefs ++ program ++ primitives


allocateSc :: GmHeap -> GmCompiledSc -> (GmHeap, (Name, Addr))
allocateSc heap (name, argc, code) = (heap', (name, addr))
    where
        (heap', addr) = hAlloc heap $ NGlobal argc code


compileSc :: (Name, [Name], CoreExpr) -> GmCompiledSc
compileSc (name, args, expr) =
    (name, n, compileR n expr $ zip args [0..])
    where
        n = length args


compileR :: Int -> GmCompiler
compileR d (ELet isRec defs body) env | isRec = compileLetrec [] (compileR $ d + n) defs body env
                                      | otherwise = compileLet [] (compileR $ d + n) defs body env
    where n = length defs
compileR d (EAp (EAp (EAp (EVar "if") cond) et) ef) env =
    compileB cond env ++ [Cond (compileR d et env) (compileR d ef env)]
compileR d (ECase expr alts) env =
    compileE expr env ++ [Casejump $ compileD (compileR $ d + n) alts env]
    where n = length alts
compileR d expr env = compileE expr env ++ [Update d, Pop d, Unwind]


compileB :: GmCompiler
compileB (ENum n) env = [Pushbasic n]
compileB (ELet isRec defs body) env | isRec = compileLetrec [Pop $ length defs] compileB defs body env
                                    | otherwise = compileLet [Pop $ length defs] compileB defs body env
compileB (EAp (EVar "negate") expr) env =
    compileB expr env ++ [Neg]
compileB (EAp (EAp (EAp (EVar "if") cond) et) ef) env =
    compileB cond env ++ [Cond (compileB et env) (compileB ef env)]
compileB expr@(EAp (EAp (EVar name) e1) e2) env =
    compileB e2 env ++
    compileB e1 (argOffset 1 env) ++ -- nie wiem czy tu ma byc argoffset
    case aHasKey builtinDyadic name of
        True -> [aLookup builtinDyadic name $ error "This is not possible"]
        False -> compileE expr env ++ [Get]
compileB expr env =
    compileE expr env ++ [Get]


compileE :: GmCompiler
compileE (ENum n) env = [Pushint n]
compileE (ELet isRec defs body) env | isRec = compileLetrec [Slide $ length defs] compileE defs body env
                                    | otherwise = compileLet [Slide $ length defs] compileE defs body env
compileE (ECase expr alts) env =
    compileE expr env ++ [Casejump $ compileD compileE alts env]
compileE (EConstr t n) env = [Pushglobal $ constrFunctionName t n]
compileE (EAp (EVar "negate") expr) env =
    compileB expr env ++ [MkInt]
compileE (EAp (EAp (EAp (EVar "if") cond) et) ef) env =
    compileB cond env ++ [Cond (compileE et env) (compileE ef env)]
compileE expr@(EAp (EAp (EVar name) e1) e2) env =
    compileB expr env ++
    case aHasKey builtinDyadic name of
        True -> [intOrBool name]
        False -> compileC expr env ++ [Eval]
compileE expr env =
    compileC expr env ++ [Eval]


intOrBool :: Name -> Instruction
intOrBool name =
    case aHasKey builtinDyadicInt name of
        True -> MkInt
        False ->
            case aHasKey builtinDyadicBool name of
                True -> MkBool
                False -> error $ "Name: " ++ name ++ " is not a built-in operator"


compileD :: GmCompiler -> [CoreAlt] -> Assoc Name Addr -> Assoc Int GmCode
compileD comp alts env = [compileA comp alt env | alt <- alts]


compileA :: GmCompiler -> CoreAlt -> Assoc Name Addr -> (Int, GmCode)
compileA comp (t, args, expr) env =
    (t, [Split n] ++ comp expr env' ++ [Slide n])
    where
        n = length args
        env' = zip args [0..] ++ argOffset n env


compileC :: GmCompiler
compileC (EVar v) env =
    case aHasKey env v of
        True -> [Push $ aLookup env v $ error "This is not possible"]
        False -> [Pushglobal v]
compileC (EConstr t n) env = [Pushglobal $ constrFunctionName t n]
compileC (ENum n) env = [Pushint n]
compileC (EAp e1 e2) env =
--fst $ compileAp (EAp e1 e2) env
    compileC e2 env ++
    compileC e1 (argOffset 1 env) ++
    [Mkap]
compileC (ELet isRec defs body) env | isRec = compileLetrec [Slide $ length defs] compileC defs body env
                                    | otherwise = compileLet [Slide $ length defs] compileC defs body env


constrFunctionName t n = "Pack{" ++ show t ++ "," ++ show n ++ "}"


--compileAp :: CoreExpr -> GmEnvironment -> (GmCode, Int)
--compileAp (EConstr t n) env = ([Pack t n], n)
--compileAp (EAp e1 e2) env =
--    case n > 0 of
--        True ->
--            (codeE2 ++ codeE1, n - 1)
--        False ->
--            (codeE2 ++ codeE1 ++ [Mkap], 0)
--    where
--        (codeE2, _) = compileAp e2 env
--        (codeE1, n) = compileAp e1 (argOffset 1 env)
--compileAp node env = (compileC node env, 0)


compileLet :: [Instruction] -> GmCompiler -> [(Name, CoreExpr)] -> GmCompiler
compileLet finalInstrs comp defs body env =
    compileDefs defs env ++ comp body env' ++ finalInstrs
    where
        env' = compileArgs defs env


compileDefs :: [(Name, CoreExpr)] -> GmEnvironment -> GmCode
compileDefs [] env = []
compileDefs ((name, expr) : defs) env =
    compileC expr env ++ (compileDefs defs $ argOffset 1 env)

compileArgs :: [(Name, CoreExpr)] -> GmEnvironment -> GmEnvironment
compileArgs defs env =
    zip (map fst defs) [n-1, n-2 .. 0] ++ argOffset n env
    where
        n = length defs


compileLetrec :: [Instruction] -> GmCompiler -> [(Name, CoreExpr)] -> GmCompiler
compileLetrec finalInstrs comp defs body env =
    [Alloc n] ++ compileRecDefs n defs env' ++ comp body env' ++ finalInstrs
    where
        n = length defs
        env' = compileArgs defs env


compileRecDefs :: Int -> [(Name, CoreExpr)] -> GmEnvironment -> GmCode
compileRecDefs 0 [] env = []
compileRecDefs n ((name, expr) : defs) env =
        compileC expr env ++ [Update $ n - 1] ++ compileRecDefs (n - 1) defs env


argOffset :: Int -> GmEnvironment -> GmEnvironment
argOffset n env = map (\(name, pos) -> (name, pos + n)) env

