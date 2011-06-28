module LetTransformer where


import ParserTypes
import Common
import List
import NameSupply


-- generic program traversal function
traverse :: (Expr Pattern -> Expr Pattern) -> PatTypeScPair -> PatTypeScPair
traverse transformFunction (adts, scs) = (adts, scs')
    where
        scs' = [(PatScDefn name $ traverseEqs transformFunction eqs) | (PatScDefn name eqs) <- scs]

traverseEqs :: (Expr Pattern -> Expr Pattern) -> [Equation] -> [Equation]
traverseEqs transformFunction eqs = [traverseEq transformFunction eq | eq <- eqs]


traverseEq :: (Expr Pattern -> Expr Pattern) -> Equation -> Equation
traverseEq transformFunction (patterns, expr) = (patterns, transformFunction expr)


transformLets :: PatTypeScPair -> PatTypeScPair
transformLets = traverse transformExpr


transformExpr :: Expr Pattern -> Expr Pattern
transformExpr (EAp e1 e2) = EAp (transformExpr e1) (transformExpr e2)
transformExpr (ELam args expr) = ELam args $ transformExpr expr
transformExpr (ECase expr alts) = ECase expr' alts'
    where
        expr' = transformExpr expr
        alts' = [(pattern, transformExpr expr) | (pattern, expr) <- alts]
transformExpr (ELet isRec defns expr) =
--    irrefutableToSimpleLet $ conformalityTransform letExpr
    irrefutableToSimple letExpr
    where
        letExpr = ELet isRec defns $ transformExpr expr
transformExpr expr = expr


--isRefutable :: Pattern -> Bool
--isRefutable (PVar v) = False
--isRefutable (PConstr tag arity args) =
--    foldl (||) False [isPatternRefutable arg | arg <- args]
--isRefutable other = True


createLet :: (Pattern, Expr Pattern) -> Expr Pattern -> Expr Pattern
createLet (pattern@(PVar v), rhs) expr = ELet False [(pattern, transformExpr rhs)] expr
createLet (pattern@(PConstr tag arity args), rhs) expr =
    ELet False [(PVar "v", rhs)] $ foldr mkLet expr $ [vars] ++ [[constr] | constr <- constrs]
    where
        mkLet patterns letExpr =
            case head patterns of
                (PVar v, pos) ->
                    ELet False [(PVar v, ESelect arity pos "v") | (PVar v, pos) <- patterns] letExpr
                (PConstr t a ps, pos) ->
                    ELet False [(PVar "w", ESelect arity pos "v")] $ foldr createLet letExpr [(pattern, ESelect a i "w") | (pattern, i) <- zip ps [0..]]

        (vars, constrs) = partition isVar $ zip args [0..]

        isVar ((PVar v), pos) = True
        isVar _               = False


createLetrec :: NameSupply -> [(Pattern, Expr Pattern)] -> (Pattern, Expr Pattern) -> [(Pattern, Expr Pattern)]
createLetrec ns defns (pattern@(PVar v), rhs) = (pattern, transformExpr rhs) : defns
createLetrec ns defns (pattern@(PConstr tag arity args), rhs) =
    defns ++ [(PVar varName, transformExpr rhs)] ++ (foldl (collectDefs ns' varName arity) [] $ zip args [0..])
    where
        (ns', varName) = getName ns "v"

collectDefs :: NameSupply -> Name -> Int -> [Defn Pattern] -> (Pattern, Int) -> [Defn Pattern]
collectDefs ns name arity acc ((PVar v), i) = acc ++ [(PVar v, ESelect arity i name)]
collectDefs ns name arity acc ((PConstr t a as), i) =
    foldl (collectDefs ns' name' a) (acc ++ [(PVar name', ESelect arity i name)]) (zip as [0..])
    where
        (ns', name') = getName ns "v"


irrefutableToSimple :: Expr Pattern -> Expr Pattern
irrefutableToSimple (ELet False defns expr) = foldr createLet expr defns
irrefutableToSimple (ELet True defns expr) = ELet True defns' expr
    where
        defns' = foldl (createLetrec initialNameSupply) [] defns
irrefutableToSimple expr =
    error $ "Trying to apply transformation for irrefutable let(rec)s into simple let(rec)s for: " ++ show expr
