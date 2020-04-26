
open MyUtil
open Syntax


exception UnboundVariable of Range.t * string
exception ContradictionError of mono_type * mono_type
exception InclusionError of FreeID.t * mono_type * mono_type


type unification_result =
  | Consistent
  | Contradiction
  | Inclusion of FreeID.t


let (&&&) res1 res2 =
  match (res1, res2) with
  | (Consistent, _) -> res2
  | _               -> res1


let occurs fid ty =
  let lev = FreeID.get_level fid in
  let rec aux (_, tymain) =
    match tymain with
    | BaseType(_) ->
        false

    | FuncType(tydoms, tycod) ->
        let b1 = List.exists aux tydoms in
        let b2 = aux tycod in
        b1 || b2
          (* -- must not be short-circuit due to the level inference -- *)

    | EffType(eff, ty0) ->
        let beff = aux_effect eff in
        let b0 = aux ty0 in
        beff || b0
          (* -- must not be short-circuit due to the level inference -- *)

    | PidType(pidty) ->
        aux_pid_type pidty

    | TypeVar({contents = Link(ty)}) ->
        aux ty

    | TypeVar({contents = Free(fidx)}) ->
        if FreeID.equal fid fidx then true else
          begin
            FreeID.update_level fidx lev;
(*
            Format.printf "LEVEL %a L%d --> L%d\n" FreeID.pp fidx (FreeID.get_level fidx) lev;  (* for debug *)
*)
            false
          end

  and aux_effect (Effect(ty)) =
    aux ty

  and aux_pid_type (Pid(ty)) =
    aux ty
  in
  aux ty


let unify tyact tyexp =
(*
  Format.printf "UNIFY %a =?= %a\n" pp_mono_type tyact pp_mono_type tyexp; (* for debug *)
*)
  let rec aux ty1 ty2 =
    let (_, ty1main) = ty1 in
    let (_, ty2main) = ty2 in
    match (ty1main, ty2main) with
    | (TypeVar({contents = Link(ty1l)}), _) ->
        aux ty1l ty2

    | (_, TypeVar({contents = Link(ty2l)})) ->
        aux ty1 ty2l

    | (BaseType(bt1), BaseType(bt2)) ->
        if bt1 = bt2 then Consistent else Contradiction

    | (FuncType(ty1doms, ty1cod), FuncType(ty2doms, ty2cod)) ->
        let res1 =
          try
            List.fold_left2 (fun res ty1 ty2 ->
              match res with
              | Consistent -> aux ty1 ty2
              | _          -> res
            ) Consistent ty1doms ty2doms
          with
          | Invalid_argument(_) -> Contradiction
        in
        let res2 = aux ty1cod ty2cod in
        res1 &&& res2

    | (EffType(eff1, tysub1), EffType(eff2, tysub2)) ->
        let reseff = aux_effect eff1 eff2 in
        let ressub = aux tysub1 tysub2 in
        reseff &&& ressub

    | (PidType(pidty1), PidType(pidty2)) ->
        aux_pid_type pidty1 pidty2

    | (TypeVar({contents = Free(fid1)} as tvref1), TypeVar({contents = Free(fid2)})) ->
        let () =
          if FreeID.equal fid1 fid2 then () else
            begin
              tvref1 := Link(ty2);  (* -- not `Free(fid2)`! -- *)
            end
        in
        Consistent

    | (TypeVar({contents = Free(fid1)} as tvref1), _) ->
        let b = occurs fid1 ty2 in
        if b then
          Inclusion(fid1)
        else
          begin
            tvref1 := Link(ty2);
            Consistent
          end

    | (_, TypeVar({contents = Free(fid2)} as tvref2)) ->
        let b = occurs fid2 ty1 in
        if b then
          Inclusion(fid2)
        else
          begin
            tvref2 := Link(ty1);
            Consistent
          end

    | _ ->
        Contradiction

  and aux_effect (Effect(ty1)) (Effect(ty2)) =
    aux ty1 ty2

  and aux_pid_type (Pid(ty1)) (Pid(ty2)) =
    aux ty1 ty2
  in
  let res = aux tyact tyexp in
  match res with
  | Consistent     -> ()
  | Contradiction  -> raise (ContradictionError(tyact, tyexp))
  | Inclusion(fid) -> raise (InclusionError(fid, tyact, tyexp))


let fresh_type lev rng =
  let fid = FreeID.fresh lev in
  let tvref = ref (Free(fid)) in
  let ty = (rng, TypeVar(tvref)) in
(*
  Format.printf "GEN L%d %a\n" lev pp_mono_type ty;  (* for debug *)
*)
  ty


let rec aux lev tyenv (rng, utastmain) =
  match utastmain with
  | Unit -> (rng, BaseType(UnitType))
  | Int(_) -> (rng, BaseType(IntType))
  | Bool(_) -> (rng, BaseType(BoolType))

  | Var(x) ->
      begin
        match tyenv |> Typeenv.find_opt x with
        | None               -> raise (UnboundVariable(rng, x))
        | Some((_, ptymain)) -> instantiate lev (rng, ptymain)
      end

  | Lambda(binders, utast0) ->
      let (tyenv, tydomacc) =
        List.fold_left (fun (tyenv, tydomacc) (rngv, x) ->
          let tydom = fresh_type lev rngv in
          let ptydom = lift tydom in
          (tyenv |> Typeenv.add x ptydom, Alist.extend tydomacc tydom)
        ) (tyenv, Alist.empty) binders
      in
      let tycod = aux lev tyenv utast0 in
      (rng, FuncType(tydomacc |> Alist.to_list, tycod))

  | Apply(utastfun, utastargs) ->
      let tyfun = aux lev tyenv utastfun in
      let tyargs = List.map (aux lev tyenv) utastargs in
      let tyret = fresh_type lev rng in
      unify tyfun (Range.dummy "Apply", FuncType(tyargs, tyret));
      tyret

  | If(utast0, utast1, utast2) ->
      let ty0 = aux lev tyenv utast0 in
      unify ty0 (Range.dummy "If", BaseType(BoolType));
      let ty1 = aux lev tyenv utast1 in
      let ty2 = aux lev tyenv utast2 in
      unify ty1 ty2;
      ty1

  | LetIn(ident, utast1, utast2) ->
      let tyenv = typecheck_let lev tyenv ident utast1 in
      let ty2 = aux lev tyenv utast2 in
      ty2

  | LetRecIn(ident, utast1, utast2) ->
      let tyenv = typecheck_letrec lev tyenv ident utast1 in
      let ty2 = aux lev tyenv utast2 in
      ty2

  | Do(identopt, utast1, utast2) ->
      let ty1 = aux lev tyenv utast1 in
      let (tyx, tyenv) =
        match identopt with
        | None ->
            ((Range.dummy "do-unit", BaseType(UnitType)), tyenv)

        | Some(rng, x) ->
            let tyx = fresh_type lev rng in
            (tyx, tyenv |> Typeenv.add x (lift tyx))
      in
      let tyrecv = fresh_type lev (Range.dummy "do-recv") in
      unify ty1 (Range.dummy "do-eff2", EffType(Effect(tyrecv), tyx));
      let ty2 = aux lev tyenv utast2 in
      let tysome = fresh_type lev (Range.dummy "do-some") in
      unify ty2 (Range.dummy "do-eff2", EffType(Effect(tyrecv), tysome));
      ty2



and typecheck_let (lev : int) (tyenv : Typeenv.t) ((rngv, x) : Range.t * identifier) (utast1 : untyped_ast) : Typeenv.t =
  let ty1 = aux (lev + 1) tyenv utast1 in
  let pty1 = generalize lev ty1 in
  tyenv |> Typeenv.add x pty1


and typecheck_letrec (lev : int) (tyenv : Typeenv.t) ((rngv, x) : Range.t * identifier) (utast1 : untyped_ast) : Typeenv.t =
  let tyf = fresh_type (lev + 1) rngv in
  let tyenvsub = tyenv |> Typeenv.add x (lift tyf) in
  let ty1 = aux (lev + 1) tyenvsub utast1 in
  unify ty1 tyf;
  tyenv |> Typeenv.add x (generalize lev tyf)


let main (decls : declaration list) : Typeenv.t =
  let tyenv = Primitives.initial_type_environment in
  decls |> List.fold_left (fun tyenv decl ->
    match decl with
    | ValDecl(isrec, binder, utast) ->
        if isrec then
          typecheck_letrec 0 tyenv binder utast
        else
          typecheck_let 0 tyenv binder utast
  ) tyenv
