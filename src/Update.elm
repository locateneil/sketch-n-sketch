module Update exposing  (..)

import Tuple exposing (first)
import Lang exposing (..)
import LangUnparser exposing (unparse)
import Eval exposing (doEval)
import Utils
import Syntax
import Results exposing (Results, ok1, oks, errs)

-- Make sure that Env |- Exp evaluates to oldVal
update : Env -> Exp -> Val -> Val -> Results String (Env, Exp)
update env e oldVal newVal =
  --let _ = Debug.log (String.concat [envToString env, unparse e] ++ " <-- " ++ (valToString newVal)) 1 in
  case e.val.e__ of
    EConst ws num loc widget -> ok1 <| (env, replaceE__ e <| EConst ws (getNum newVal) loc widget)
    EBase ws m -> ok1 <| (env, val_to_exp ws newVal)
    EVar ws is ->
      (case env of
        []            -> errs <| "No " ++ is ++ " found. \nVariables in scope: " ++ (String.join " " <| List.map Tuple.first env)
        (k0,v0) :: l_ -> if is == k0
                           then ok1 ((is, newVal) :: l_, e)
                           else
                             Results.map (Tuple.mapFirst (\newEnv -> (k0, v0) :: newEnv)) <| update l_ e oldVal newVal)
    EList ws elems ws2 Nothing ws3 ->
      case (oldVal.v_, newVal.v_) of
        (VList origVals, VList newOutVals) ->
          if List.length origVals == List.length newOutVals then
            updateList env elems origVals newOutVals
            |> Results.map (\(env, l) ->
              (env, replaceE__ e <| EList ws l ws2 Nothing ws3)
            )
          else errs <| "Cannot (yet) update a list " ++ unparse e ++ " with list of different length: " ++ valToString newVal
        _ -> errs <| "Cannot update a list " ++ unparse e ++ " with non-list " ++ valToString newVal

    --EList ws elems ws2 Nothing ws3 ->
    --  errs ""
    EFun ws0 ps e ws1 ->
      -- oldVal ==  VClosure Nothing p e env
      (case newVal.v_ of
        VClosure Nothing newPs newE newEnv -> ok1 (newEnv, replaceE__ e <| EFun ws0 newPs newE ws1)
        _ -> errs <| "Expected non-recursive closure, got " ++ toString newVal
      )

    EApp ws0 e1 e2s ws1 ->
      case doEval Syntax.Elm env e1 of
      Err s       -> errs s
      Ok ((v1, _),_) ->
        case List.map (doEval Syntax.Elm env) e2s |> Utils.projOk of
          Err s       -> errs s
          Ok v2ls ->
            let v2s = List.map (\((v2, _), _) -> v2) v2ls in
            case v1.v_ of
              VClosure Nothing ps eBody env_ as vClosure ->
                case conssWithInversion (ps, v2s) (Just (env_, \newEnv_ newPs newBody -> replaceV_ v1 <| VClosure Nothing newPs newBody newEnv_)) of
                  Just (env__, consBuilder) ->
                     -- consBuilder: Env -> ((Pat, Val), (newPat: Pat) -> (newBody: Exp) -> VClosure)
                      update env__ eBody oldVal newVal
                      |> Results.map (\(newEnv, newBody) ->
                           (consBuilder newEnv, newBody)
                         )
                      |> Results.map (\(((newPats, newArgs), patsBodyToClosure), newBody) ->
                        let newClosure = patsBodyToClosure newPats newBody in
                        let e1_updated = update env e1 v1 newClosure in
                        let e2s_updated = updateList env e2s v2s newArgs in
                        Results.map2 (\((envE1, newE1), (envE2, newE2s)) ->
                          (triCombine env envE1 envE2, replaceE__ e <| EApp ws0 newE1 newE2s ws1)
                        ) e1_updated e2s_updated
                      )
                      |> Results.flatten
                  _          -> errs <| strPos e1.start ++ "bad environment"
              VClosure (Just f) ps eBody env_ ->
                case consWithInversion (pVar f, v1) (conssWithInversion (ps, v2s) (Just (env_, \newEnv_ newPs newBody -> replaceV_ v1 <| VClosure (Just f) newPs newBody newEnv_))) of
                  Just (env__, consBuilder) ->
                     -- consBuilder: Env -> ((Pat, Val), ((Pat, Val), (newPat: Pat) -> (newBody: Exp) -> VClosure))
                      update env__ eBody oldVal newVal
                      |> Results.map (\(newEnv, newBody) ->
                           (consBuilder newEnv, newBody)
                         )
                      |> Results.map (\(((newPatFun, newArgFun), ((newPats, newArgs), patsBodyToClosure)), newBody) ->
                        let newClosure = if newArgFun /= v1 then -- Just propagate the change to the closure itself
                            newArgFun
                          else -- Regular replacement
                            patsBodyToClosure newPats newBody in

                        let e1_updated = update env e1 v1 newClosure in
                        let e2s_updated = updateList env e2s v2s newArgs in
                        Results.map2 (\((envE1, newE1), (envE2, newE2s)) ->
                          (triCombine env envE1 envE2, replaceE__ e <| EApp ws0 newE1 newE2s ws1)
                        ) e1_updated e2s_updated
                      )
                      |> Results.flatten
                  _          -> errs <| strPos e1.start ++ "bad environment"
              _ ->
                errs <| strPos e1.start ++ " not a function"

    EIf ws0 cond thn els ws1 ->
      case doEval Syntax.Elm env cond of
        Ok (({ v_ }, _), _) ->
          case v_ of
            VBase (VBool b) ->
              if b then
                update env thn oldVal newVal
                |> Results.map (\(env, newThn) ->
                  (env, replaceE__ e <| EIf ws0 cond newThn els ws1)
                )
              else
                update env els oldVal newVal
                |> Results.map (\(env, newEls) ->
                  (env, replaceE__ e <| EIf ws0 cond thn newEls ws1)
                )
            _ -> errs <| "Expected boolean condition, got " ++ toString v_
        Err s -> errs s
    EParens ws0 eInside ws1 ->
      update env eInside oldVal newVal
      |> Results.map (\(env, eReturn) -> (env, replaceE__ e <| EParens ws0 eReturn ws1))
    _ -> errs <| "Non-supported update " ++ envToString env ++ "|-" ++ unparse e ++ " <-- " ++ valToString newVal ++ " (was " ++ valToString oldVal ++ ")"

updateList: Env -> List Exp -> List Val -> List Val -> Results String (Env, List Exp)
updateList env elems origVals newOutVals =
  let results =
    List.map3 (\inputExpr oldOut newOut ->
              update env inputExpr oldOut newOut
              ) elems origVals newOutVals in
  List.foldl (\elem acc ->
    Results.map2withError (\(x, y) -> x ++ "\n" ++ y) (\((newEnvElem, newExpElem), (envAcc, lAcc)) ->
      (triCombine env envAcc newEnvElem, lAcc ++ [newExpElem])) elem acc
    ) (ok1 (env, [])) results

triCombine: Env -> Env -> Env -> Env
triCombine originalEnv newEnv1 newEnv2 =
  let aux acc originalEnv newEnv1 newEnv2 =
    case (originalEnv, newEnv1, newEnv2) of
      ([], [], []) -> acc
      ((x, v1)::oe, (y, v2)::ne1, (z, v3)::ne2) ->
        if x /= y || y /= z || x /= z then
          Debug.crash <| "Expected environments to have the same variables, got\n" ++
           toString x ++ " = " ++ toString v1 ++ "\n" ++
           toString y ++ " = " ++ toString v2 ++ "\n" ++
           toString z ++ " = " ++ toString v3
        else
          if v2 == v1 then aux (acc ++ [(x, v3)]) oe ne1 ne2
          else aux (acc ++ [(x, v2)]) oe ne1 ne2
      _ -> Debug.crash <| "Expected environments to have the same size, got\n" ++
           toString originalEnv ++ ", " ++ toString newEnv1 ++ ", " ++ toString newEnv2
    in
  aux [] originalEnv newEnv1 newEnv2

consWithInversion : (Pat, Val) -> Maybe (Env, Env -> a) -> Maybe (Env, Env -> ((Pat, Val), a))
consWithInversion pv menv =
  case (menv, matchWithInversion pv) of
    (Just (env, envToA), Just (env_, envToPatVal)) -> Just (env_ ++ env,
      \newEnv ->
        let (newEnv_, newEnvTail) = Utils.split (List.length env_) newEnv in
        (envToPatVal newEnv_, envToA newEnvTail)
      )
    _                     -> Nothing


conssWithInversion : (List Pat, List Val) -> Maybe (Env, Env -> a) -> Maybe (Env, Env -> ((List Pat, List Val), a))
conssWithInversion pvs menv =
  case (menv, matchListWithInversion pvs) of
    (Just (env, envToA), Just (env_, envToPatsVals)) -> Just (env_ ++ env,
      \newEnv ->
        let (newEnv_, newEnvTail) = Utils.split (List.length env_) newEnv in
        (envToPatsVals newEnv_, envToA newEnvTail)
      )
    _                     -> Nothing

matchWithInversion : (Pat, Val) -> Maybe (Env, Env -> (Pat, Val))
matchWithInversion (p,v) = case (p.val.p__, v.v_) of
  (PVar ws x wd, _) -> Just ([(x,v)], \newEnv ->
     case newEnv of
       [(x, newV)] -> (p, newV)
       _ -> Debug.crash <| "Not the same shape before/after pattern update: " ++ toString newEnv ++ " should have length 1"
     )
  (PAs ws0 x ws1 innerPat, _) ->
    matchWithInversion (innerPat, v) |> Maybe.map
      (\(env, envReverse) -> ((x,v)::env, \newEnv ->
        case newEnv of
          (_, newV)::newEnv2 ->
            if newV == v then
              case envReverse newEnv2 of
              (newInnerPat, newVal) -> (replaceP__ p <| PAs ws0 x ws1 newInnerPat, newVal)
            else
              case envReverse newEnv2 of
              (newInnerPat, _)      -> (replaceP__ p <| PAs ws0 x ws1 newInnerPat, newV)

          _ -> Debug.crash <| "Not the same shape before/after pattern update: " ++ toString newEnv ++ " should have length >= 1"
      ))

  (PList ws0 ps ws1 Nothing ws2, VList vs) ->
    (if List.length ps == List.length vs then Just (ps,vs) else Nothing)
    |> Maybe.andThen matchListWithInversion
    |> Maybe.map (\(env, envRenewer) ->
      (env, envRenewer >> \(newPats, newVals) ->
        (replaceP__ p <| PList ws0 newPats ws1 Nothing ws2, replaceV_ v <| VList newVals)
      )
    )
  (PList ws0 ps ws1 (Just rest) ws2, VList vs) ->
    let (n,m) = (List.length ps, List.length vs) in
    if n > m then Nothing
    else
      let (vs1,vs2) = Utils.split n vs in
      (ps, vs1)
      |> matchListWithInversion
      |> consWithInversion (rest, replaceV_ v <| VList vs2) -- Maybe (Env, Env -> ((Pat, Val), (List Pat, List Val)))
      |> Maybe.map (\(env, envRenewer) ->
        (env, envRenewer >> (\((newPat, newVal), (newPats, newVals)) ->
          case newVal.v_ of
            VList otherVals ->
              (replaceP__ p <| PList ws0 newPats ws1 (Just newPat) ws2, replaceV_ v <| (VList <| newVals ++ otherVals))
            _ -> Debug.crash <| "RHS of list pattern is not a list: " ++ toString newVal
        ))
      )
        -- dummy VTrace, since VList itself doesn't matter
  (PList _ _ _ _ _, _) -> Nothing
  (PConst _ n, VConst _ (n_,_)) -> if n == n_ then Just ([], \newEnv -> (p, v)) else Nothing
  (PBase _ bv, VBase bv_) -> if eBaseToVBase bv == bv_ then Just ([], \newEnv -> (p, v)) else Nothing
  _ -> Debug.crash <| "Little evaluator bug: Eval.match " ++ (toString p.val.p__) ++ " vs " ++ (toString v.v_)

matchListWithInversion : (List Pat, List Val) -> Maybe (Env, Env -> (List Pat, List Val))
matchListWithInversion (ps, vs) =
  List.foldl (\pv acc -> --: Maybe (Env, List (Env -> (Pat, Val, Env)))
    case (acc, matchWithInversion pv) of
      (Just (old, oldEnvBuilders), Just (new, newEnvBuilder)) -> Just (new ++ old,
           [\newEnv ->
            let (headNewEnv, tailNewEnv) = Utils.split (List.length new) newEnv in
            let (newPat, newVal) = newEnvBuilder headNewEnv in
            (newPat, newVal, tailNewEnv)
          ] ++ oldEnvBuilders
        )
      _                    -> Nothing
  ) (Just ([], [])) (Utils.zip ps vs)
  |> Maybe.map (\(finalEnv, envBuilders) -> -- envBuilders: List (Env -> (Pat, Val, Env)), but we want Env -> (Pat, Val), combining pattern/values into lists
    (finalEnv, \newEnv ->
      let (newPats, newVals, _) =
        List.foldl (\eToPVE (pats, vals, env)->
          let (p, v, e) = eToPVE env in
          ([p] ++ pats, [v] ++ vals, e)
          )  ([], [], newEnv) envBuilders in
      (newPats, newVals)
    ))
  {--|> (\x -> case x of
     Just (env, envBuilder) ->
       let _ = Debug.log ("matchListWithinversion" ++ toString pvs) (envBuilder env) in
       x
     Nothing -> Nothing
  )--}

val_to_exp: WS -> Val -> Exp
val_to_exp ws v =
  withDummyExpInfo <| case v.v_ of
    VConst mb num     -> EConst ws (first num) dummyLoc noWidgetDecl
    VBase (VBool b)   -> EBase  ws <| EBool b
    VBase (VString s) -> EBase  ws <| EString defaultQuoteChar s
    VBase (VNull)     -> EBase  ws <| ENull
    VList vals -> EList ws (List.map (val_to_exp ws) vals) ws Nothing <| ws
    VClosure Nothing patterns body env -> EFun ws patterns body ws -- Not sure about this one.
    _ -> Debug.crash <| "Trying to get an exp of the value " ++ toString v
    --VDict vs ->

getNum: Val -> Num
getNum v =
  case v.v_ of
    VConst _ (num, _) -> num
    _ -> Debug.crash <| "Espected VConst, got " ++ toString v


eBaseToVBase eBaseVal =
  case eBaseVal of
    EBool b     -> VBool b
    EString _ b -> VString b
    ENull       -> VNull

envToString: Env -> String
envToString env =
  case env of
    [] -> ""
    (v, value)::tail -> v ++ "->" ++ unparse (val_to_exp (ws "") value) ++ " " ++ (envToString tail)

valToString: Val -> String
valToString v = case v.v_ of
   VClosure Nothing patterns body env -> envToString env ++ "|-" ++ ((unparse << val_to_exp (ws " ")) v)
   _ -> (unparse << val_to_exp (ws " ")) v