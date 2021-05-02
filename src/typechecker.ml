
open MyUtil
open Syntax
open Env
open Errors


exception Error of type_error


let raise_error e =
  raise (Error(e))


module BindingMap = Map.Make(String)


type subtyping_error = unit


type binding_map = (mono_type * local_name * Range.t) BindingMap.t


let binding_map_union rng =
  BindingMap.union (fun x _ _ ->
    raise_error (BoundMoreThanOnceInPattern(rng, x))
  )


type unification_result =
  | Consistent
  | Contradiction
  | Inclusion     of FreeID.t
  | InclusionRow  of FreeRowID.t

type pre = {
  level : int;
  tyenv : Typeenv.t;
  local_type_parameters : local_type_parameter_map;
  local_row_parameters  : local_row_parameter_map;
}

type opaque_entry =
  | OpaqueToVariant of TypeID.Variant.t
  | OpaqueToOpaque  of TypeID.Opaque.t
  | OpaqueToSynonym of (BoundID.t list * poly_type) * type_name


module GlobalNameMap = Map.Make(OutputIdentifier.Global)


module WitnessMap : sig
  type t
  val empty : t
  val add_variant : TypeID.Variant.t -> TypeID.Variant.t -> t -> t
  val add_opaque : TypeID.Opaque.t -> TypeID.t -> t -> t
  val add_synonym : TypeID.Synonym.t -> TypeID.Synonym.t -> t -> t
  val find_synonym : TypeID.Synonym.t -> t -> TypeID.Synonym.t option
  val find_variant : TypeID.Variant.t -> t -> TypeID.Variant.t option
  val find_opaque : TypeID.Opaque.t -> t -> TypeID.t option
  val union : t -> t -> t
  val fold :
      variant:(TypeID.Variant.t -> TypeID.Variant.t -> 'a -> 'a) ->
      synonym:(TypeID.Synonym.t -> TypeID.Synonym.t -> 'a -> 'a) ->
      opaque:(TypeID.Opaque.t -> TypeID.t -> 'a -> 'a) ->
      'a -> t -> 'a
  (* for debug *)
  val print : t -> unit
end = struct

  type t = {
    variants : TypeID.Variant.t VariantIDMap.t;
    synonyms : TypeID.Synonym.t SynonymIDMap.t;
    opaques  : TypeID.t OpaqueIDMap.t;
  }


  let empty : t =
    {
      variants = VariantIDMap.empty;
      synonyms = SynonymIDMap.empty;
      opaques  = OpaqueIDMap.empty;
    }


  let union (wtmap1 : t) (wtmap2 : t) : t =
    let f _ x y = Some(y) in
    {
      variants = VariantIDMap.union  f wtmap1.variants wtmap2.variants;
      synonyms = SynonymIDMap.union  f wtmap1.synonyms wtmap2.synonyms;
      opaques  = OpaqueIDMap.union   f wtmap1.opaques  wtmap2.opaques;
    }


  let add_variant (vid2 : TypeID.Variant.t) (vid1 : TypeID.Variant.t) (wtmap : t) : t =
    { wtmap with variants = wtmap.variants |> VariantIDMap.add vid2 vid1 }


  let add_synonym (sid2 : TypeID.Synonym.t) (sid1 : TypeID.Synonym.t) (wtmap : t) : t =
    { wtmap with synonyms = wtmap.synonyms |> SynonymIDMap.add sid2 sid1 }


  let add_opaque (oid2 : TypeID.Opaque.t) (tyid1 : TypeID.t) (wtmap : t) : t =
    { wtmap with opaques = wtmap.opaques |> OpaqueIDMap.add oid2 tyid1 }


  let find_variant (vid2 : TypeID.Variant.t) (wtmap : t) : TypeID.Variant.t option =
    wtmap.variants |> VariantIDMap.find_opt vid2


  let find_synonym (sid2 : TypeID.Synonym.t) (wtmap : t) : TypeID.Synonym.t option =
    wtmap.synonyms |> SynonymIDMap.find_opt sid2


  let find_opaque (oid2 : TypeID.Opaque.t) (wtmap : t) : TypeID.t option =
    wtmap.opaques |> OpaqueIDMap.find_opt oid2


  let fold (type a)
      ~variant:(fv : TypeID.Variant.t -> TypeID.Variant.t -> a -> a)
      ~synonym:(fs : TypeID.Synonym.t -> TypeID.Synonym.t -> a -> a)
      ~opaque:(fo : TypeID.Opaque.t -> TypeID.t -> a -> a)
      (init : a)
      (wtmap : t)
      : a =
    init
      |> VariantIDMap.fold fv wtmap.variants
      |> SynonymIDMap.fold fs wtmap.synonyms
      |> OpaqueIDMap.fold fo wtmap.opaques


  (* for debug *)
  let print (wtmap : t) : unit =
    wtmap.variants |> VariantIDMap.iter (fun v2 v1 ->
      Format.printf "|V %a -> %a\n" TypeID.Variant.pp v2 TypeID.Variant.pp v1
    );
    wtmap.opaques |> OpaqueIDMap.iter (fun o2 t1 ->
      Format.printf "|O %a -> %a\n" TypeID.Opaque.pp o2 TypeID.pp t1
    );
    wtmap.synonyms |> SynonymIDMap.iter (fun s2 s1 ->
      Format.printf "|S %a -> %a\n" TypeID.Synonym.pp s2 TypeID.Synonym.pp s1
    );

end


let find_module (tyenv : Typeenv.t) ((rng, m) : module_name ranged) =
  match tyenv |> Typeenv.find_module m with
  | None    -> raise_error (UnboundModuleName(rng, m))
  | Some(v) -> v


let find_module_from_chain (tyenv : Typeenv.t) ((modident, projs) : module_name_chain) =
  let init = find_module tyenv modident in
  let (rng, _) = modident in
  let (ret, _) =
    projs |> List.fold_left (fun ((modsig, _), rng) proj ->
      match modsig with
      | ConcFunctor(_) ->
          raise_error (NotOfStructureType(rng, modsig))

      | ConcStructure(sigr) ->
          let (rngproj, modnm) = proj in
          begin
            match sigr |> SigRecord.find_module modnm with
            | None ->
                raise_error (UnboundModuleName(rngproj, modnm))

            | Some(modsig_and_sname) ->
                let (rng, _) = proj in
                (modsig_and_sname, rng)
          end
    ) (init, rng)
  in
  ret


let update_type_environment_by_signature_record (sigr : SigRecord.t) (tyenv : Typeenv.t) : Typeenv.t =
  sigr |> SigRecord.fold
    ~v:(fun x (pty, gname) ->
      Typeenv.add_val x pty (OutputIdentifier.Global(gname))
    )
    ~t:(fun tydefs tyenv ->
      tydefs |> List.fold_left (fun tyenv (tynm, tyopac) ->
        match tyopac with
        | (TypeID.Synonym(sid), arity) ->
            tyenv |> Typeenv.add_synonym_type tynm sid arity

        | (TypeID.Variant(vid), arity) ->
            let tyenv = tyenv |> Typeenv.add_variant_type tynm vid arity in
            let (bids, ctorbrs) = TypeDefinitionStore.find_variant_type vid in
            tyenv |> ConstructorMap.fold (fun ctornm (ctorid, ptyparams) tyenv ->
              let ctorentry =
                {
                  belongs         = vid;
                  constructor_id  = ctorid;
                  type_variables  = bids;
                  parameter_types = ptyparams;
                }
              in
              tyenv |> Typeenv.add_constructor ctornm ctorentry
            ) ctorbrs

        | (TypeID.Opaque(oid), arity) ->
            tyenv |> Typeenv.add_opaque_type tynm oid arity
      ) tyenv
    )
    ~m:(fun modnm (modsig, sname) tyenv ->
      let tyenv = tyenv |> Typeenv.add_module modnm modsig sname in
      tyenv
    )
    ~s:(fun signm absmodsig ->
      Typeenv.add_signature signm absmodsig
    )
    tyenv


module SynonymIDHashSet = Hashtbl.Make(TypeID.Synonym)


let (&&&) res1 res2 =
  match (res1, res2) with
  | (Consistent, _) -> res2
  | _               -> res1


let iapply (efun : ast) (mrow : mono_row) ((eargs, mndargmap, optargmap) : ast list * ast LabelAssoc.t * ast LabelAssoc.t) : ast =
  match efun with
  | IVar(name) ->
      IApply(name, mrow, eargs, mndargmap, optargmap)

  | _ ->
      let lname = OutputIdentifier.fresh () in
      ILetIn(lname, efun, IApply(OutputIdentifier.Local(lname), mrow, eargs, mndargmap, optargmap))


let ilambda ((ordnames, mndnamemap, optnamemap) : local_name list * local_name LabelAssoc.t * (local_name * ast option) LabelAssoc.t) (e0 : ast) : ast =
  ILambda(None, ordnames, mndnamemap, optnamemap, e0)


let iletpatin (ipat : pattern) (e1 : ast) (e2 : ast) : ast =
  ICase(e1, [ IBranch(ipat, e2) ])


let iletrecin_single (_, _, name_outer, name_inner, e1) (e2 : ast) : ast =
  match e1 with
  | ILambda(None, ordnames, mndnamemap, optnamemap, e0) ->
      ILetIn(name_outer, ILambda(Some(name_inner), ordnames, mndnamemap, optnamemap, e0), e2)

  | _ ->
      assert false


let iletrecin_multiple (binds : (identifier * poly_type * local_name * local_name * ast) List2.t) (e2 : ast) : ast =
  let (bind1, bind2, bindrest) = List2.decompose binds in
  let binds = TupleList.make bind1 (bind2 :: bindrest) in

  let ipat_inner_tuple =
    IPTuple(binds |> TupleList.map (fun (_, _, _, name_inner, _) -> IPVar(name_inner)))
  in
  let name_for_whole_rec = OutputIdentifier.fresh () in
  let tuple_entries =
    binds |> TupleList.map (fun (_, _, _name_outer, _name_inner, e1) ->
      match e1 with
      | ILambda(None, ordnames, mndnamemap, optnamemap, e0) ->
          ILambda(None, ordnames, mndnamemap, optnamemap,
            iletpatin ipat_inner_tuple
              (IApply(OutputIdentifier.Local(name_for_whole_rec),
                FixedRow(LabelAssoc.empty), [], LabelAssoc.empty, LabelAssoc.empty)) e0)

      | _ ->
          assert false
    )
  in
  let ipat_outer_tuple =
    IPTuple(binds |> TupleList.map (fun (_, _, name_outer, _, _) -> IPVar(name_outer)))
  in
  iletpatin ipat_outer_tuple
    (iapply
      (ILambda(Some(name_for_whole_rec), [], LabelAssoc.empty, LabelAssoc.empty, ITuple(tuple_entries)))
      (FixedRow(LabelAssoc.empty))
      ([], LabelAssoc.empty, LabelAssoc.empty))
    e2


let iletrecin (binds : (identifier * poly_type * local_name * local_name * ast) list) (e2 : ast) : ast =
  match binds with
  | []                     -> assert false
  | [bind]                 -> iletrecin_single bind e2
  | bind1 :: bind2 :: rest -> iletrecin_multiple (List2.make bind1 bind2 rest) e2


let occurs (fid : FreeID.t) (ty : mono_type) : bool =
  let lev = FreeID.get_level fid in
  let rec aux ((_, tymain) : mono_type) : bool =
    match tymain with
    | BaseType(_) ->
        false

    | FuncType(domain, tycod) ->
        let bdom = aux_domain domain in
        let bcod = aux tycod in
        bdom || bcod
          (* Must not be short-circuit due to the level inference. *)

    | ProductType(tys) ->
        tys |> TupleList.to_list |> aux_list

    | RecordType(labmap) ->
        aux_label_assoc labmap

    | DataType(_tyid, tyargs) ->
        aux_list tyargs

    | EffType(domain, eff, ty0) ->
        let bdom = aux_domain domain in
        let beff = aux_effect eff in
        let b0 = aux ty0 in
        bdom || beff || b0
          (* Must not be short-circuit due to the level inference. *)

    | PidType(pidty) ->
        aux_pid_type pidty

    | TypeVar(Updatable{contents = Link(ty)}) ->
        aux ty

    | TypeVar(Updatable{contents = Free(fidx)}) ->
        if FreeID.equal fid fidx then true else
          begin
            FreeID.update_level fidx lev;
(*
            Format.printf "LEVEL %a L%d --> L%d\n" FreeID.pp fidx (FreeID.get_level fidx) lev;  (* for debug *)
*)
            false
          end

    | TypeVar(MustBeBound(_)) ->
        false

  and aux_domain (domain : mono_domain_type) : bool =
    let {ordered = tydoms; mandatory = mndlabmap; optional = optrow} = domain in
    let b1 = aux_list tydoms in
    let bmnd = aux_label_assoc mndlabmap in
    let bopt = aux_option_row optrow in
    b1 || bmnd || bopt

  and aux_effect (Effect(ty)) =
    aux ty

  and aux_pid_type (Pid(ty)) =
    aux ty

  and aux_option_row = function
    | RowVar(UpdatableRow{contents = FreeRow(_)}) ->
        false
          (* DOUBTFUL: do we need to traverse the kind of the free row ID here? *)

    | RowVar(UpdatableRow{contents = LinkRow(labmap)}) ->
        aux_label_assoc labmap

    | RowVar(MustBeBoundRow(_)) ->
        false

    | FixedRow(labmap) ->
        aux_label_assoc labmap

  and aux_label_assoc labmap =
    LabelAssoc.fold (fun _ ty bacc ->
      let b = aux ty in
      b || bacc
    ) labmap false

  and aux_list (tys : mono_type list) : bool =
    tys |> List.map aux |> List.fold_left ( || ) false
      (* Must not be short-circuit due to the level inference *)
  in
  aux ty


let occurs_row (frid : FreeRowID.t) (labmap : mono_type LabelAssoc.t) =
  let rec aux (_, tymain) =
    match tymain with
    | BaseType(_) ->
        false

    | FuncType(domain, tycod) ->
        let bdom = aux_domain domain in
        let bcod = aux tycod in
        bdom || bcod
          (* Must not be short-circuit due to the level inference. *)

    | PidType(pidty) ->
        aux_pid pidty

    | EffType(domain, effty, ty0) ->
        let bdom = aux_domain domain in
        let beff = aux_effect effty in
        let b0 = aux ty0 in
        bdom || beff || b0
          (* Must not be short-circuit due to the level inference. *)

    | TypeVar(_) ->
        false

    | ProductType(tys) ->
        tys |> TupleList.to_list |> aux_list

    | RecordType(labmap) ->
        aux_label_assoc labmap

    | DataType(_tyid, tyargs) ->
        aux_list tyargs

  and aux_domain (domain : mono_domain_type) =
    let {ordered = tydoms; mandatory = mndlabmap; optional = optrow} = domain in
    let b1 = aux_list tydoms in
    let bmnd = aux_label_assoc mndlabmap in
    let bopt = aux_option_row optrow in
    b1 || bmnd || bopt

  and aux_pid (Pid(ty)) =
    aux ty

  and aux_effect (Effect(ty)) =
    aux ty

  and aux_option_row = function
    | FixedRow(labmap)                                 -> aux_label_assoc labmap
    | RowVar(UpdatableRow{contents = LinkRow(labmap)}) -> aux_label_assoc labmap
    | RowVar(UpdatableRow{contents = FreeRow(fridx)})  -> FreeRowID.equal fridx frid
    | RowVar(MustBeBoundRow(mbbrid))                   -> false

  and aux_label_assoc labmap =
    LabelAssoc.fold (fun _ ty bacc ->
      let b = aux ty in
      bacc || b
    ) labmap false

  and aux_list tys =
    tys |> List.map aux |> List.fold_left ( || ) false
      (* Must not be short-circuit due to the level inference. *)
  in
  LabelAssoc.fold (fun _ ty bacc ->
    let b = aux ty in
    bacc || b
  ) labmap false


let opaque_occurs_in_type_scheme : 'a 'b. (OpaqueIDSet.t -> TypeID.t -> bool) -> ('a -> bool) -> OpaqueIDSet.t -> ('a, 'b) typ -> bool =
fun tyidp tvp oidset ->
  let rec aux (_, ptymain) =
    match ptymain with
    | BaseType(_)             -> false
    | PidType(typid)          -> aux_pid typid
    | ProductType(tys)        -> tys |> TupleList.to_list |> List.exists aux

    | EffType(domain, tyeff, tysub) ->
        aux_domain domain || aux_effect tyeff || aux tysub

    | FuncType(domain, tycod) ->
        aux_domain domain || aux tycod

    | DataType(tyid, tyargs) ->
        tyidp oidset tyid || List.exists aux tyargs

    | RecordType(labmap) ->
        aux_label_assoc labmap

    | TypeVar(tv) ->
        tvp tv

  and aux_domain domain =
    let {ordered = tydoms; mandatory = mndlabmap; optional = optrow} = domain in
    List.exists aux tydoms || aux_label_assoc mndlabmap || aux_option_row optrow

  and aux_pid = function
    | Pid(ty) -> aux ty

  and aux_effect = function
    | Effect(ty) -> aux ty

  and aux_option_row = function
    | RowVar(_)        -> false
    | FixedRow(labmap) -> aux_label_assoc labmap

  and aux_label_assoc labmap =
    LabelAssoc.fold (fun _ ty bacc ->
      let b = aux ty in
      b || bacc
    ) labmap false
  in
  aux


let rec opaque_occurs_in_mono_type (oidset : OpaqueIDSet.t) : mono_type -> bool =
  let tvp : mono_type_var -> bool = function
    | Updatable({contents = Link(ty)}) -> opaque_occurs_in_mono_type oidset ty
    | _                                -> false
  in
  opaque_occurs_in_type_scheme opaque_occurs_in_type_id tvp oidset


and opaque_occurs_in_poly_type (oidset : OpaqueIDSet.t) : poly_type -> bool =
  let tvp : poly_type_var -> bool = function
    | Mono(Updatable({contents = Link(ty)})) -> opaque_occurs_in_mono_type oidset ty
    | _                                      -> false
  in
  opaque_occurs_in_type_scheme opaque_occurs_in_type_id tvp oidset


and opaque_occurs_in_type_id (oidset : OpaqueIDSet.t) (tyid : TypeID.t) : bool =
  match tyid with
  | TypeID.Opaque(oid) ->
      oidset |> OpaqueIDSet.mem oid

  | TypeID.Variant(vid) ->
      let (_bids, ctorbrs) = TypeDefinitionStore.find_variant_type vid in
      ConstructorMap.fold (fun _ctor (_ctorid, ptyparams) b ->
        b || ptyparams |> List.exists (opaque_occurs_in_poly_type oidset)
      ) ctorbrs false

  | TypeID.Synonym(sid) ->
      let (_, pty) = TypeDefinitionStore.find_synonym_type sid in
      opaque_occurs_in_poly_type oidset pty


let rec opaque_occurs (oidset : OpaqueIDSet.t) (modsig : module_signature) : bool =
  match modsig with
  | ConcStructure(sigr) ->
      opaque_occurs_in_structure oidset sigr

  | ConcFunctor(sigftor) ->
      let Domain(sigr) = sigftor.domain in
      let (_oidsetcod, modsigcod) = sigftor.codomain in
      opaque_occurs_in_structure oidset sigr || opaque_occurs oidset modsigcod


and opaque_occurs_in_structure (oidset : OpaqueIDSet.t) (sigr : SigRecord.t) : bool =
  sigr |> SigRecord.fold
      ~v:(fun _ (pty, _) b ->
        b || opaque_occurs_in_poly_type oidset pty
      )
      ~t:(fun tydefs b ->
        b || (tydefs |> List.exists (fun (_, (tyid, _arity)) ->
          opaque_occurs_in_type_id oidset tyid
        ))
      )
      ~m:(fun _ (modsig, _) b ->
        b || opaque_occurs oidset modsig
      )
      ~s:(fun _ (_oidset, modsig) b ->
        b || opaque_occurs oidset modsig
      )
      false


let label_assoc_union =
  LabelAssoc.union (fun _ _ ty2 -> Some(ty2))


module Unification = struct

  let rec aux (ty1 : mono_type) (ty2 : mono_type) : unification_result =
    let (_, ty1main) = ty1 in
    let (_, ty2main) = ty2 in
    match (ty1main, ty2main) with
    | (TypeVar(Updatable{contents = Link(ty1l)}), _) ->
        aux ty1l ty2

    | (_, TypeVar(Updatable{contents = Link(ty2l)})) ->
        aux ty1 ty2l

    | (TypeVar(MustBeBound(mbbid1)), TypeVar(MustBeBound(mbbid2))) ->
        if MustBeBoundID.equal mbbid1 mbbid2 then Consistent else Contradiction

    | (DataType(TypeID.Synonym(sid1), tyargs1), _) ->
        let ty1real = TypeConv.get_real_mono_type sid1 tyargs1 in
(*
        Format.printf "UNIFY-SYN %a => %a =?= %a\n" TypeID.Synonym.pp sid1 pp_mono_type ty1real pp_mono_type ty2;  (* for debug *)
*)
        aux ty1real ty2

    | (_, DataType(TypeID.Synonym(sid2), tyargs2)) ->
        let ty2real = TypeConv.get_real_mono_type sid2 tyargs2 in
(*
        Format.printf "UNIFY-SYN %a =?= %a <= %a\n" pp_mono_type ty1 pp_mono_type ty2real TypeID.Synonym.pp sid2;  (* for debug *)
*)
        aux ty1 ty2real

    | (DataType(TypeID.Opaque(oid1), tyargs1), DataType(TypeID.Opaque(oid2), tyargs2)) ->
        if TypeID.Opaque.equal oid1 oid2 then
          aux_list tyargs1 tyargs2
        else
          Contradiction

    | (BaseType(bt1), BaseType(bt2)) ->
        if bt1 = bt2 then Consistent else Contradiction

    | (FuncType(domain1, ty1cod), FuncType(domain2, ty2cod)) ->
        let resdom = aux_domain domain1 domain2 in
        let rescod = aux ty1cod ty2cod in
        resdom &&& rescod

    | (EffType(domain1, eff1, tysub1), EffType(domain2, eff2, tysub2)) ->
        let resdom = aux_domain domain1 domain2 in
        let reseff = aux_effect eff1 eff2 in
        let ressub = aux tysub1 tysub2 in
        resdom &&& reseff &&& ressub

    | (PidType(pidty1), PidType(pidty2)) ->
        aux_pid_type pidty1 pidty2

    | (ProductType(tys1), ProductType(tys2)) ->
        aux_list (tys1 |> TupleList.to_list) (tys2 |> TupleList.to_list)

    | (DataType(TypeID.Variant(vid1), tyargs1), DataType(TypeID.Variant(vid2), tyargs2)) ->
        if TypeID.Variant.equal vid1 vid2 then
          aux_list tyargs1 tyargs2
        else
          Contradiction

    | (RecordType(labmap1), RecordType(labmap2)) ->
        aux_label_assoc_exact labmap1 labmap2

    | (TypeVar(Updatable({contents = Free(fid1)} as mtvu1)), TypeVar(Updatable{contents = Free(fid2)})) ->
        if FreeID.equal fid1 fid2 then
          Consistent
        else begin
          let res =
            let bkd1 = KindStore.get_free_id fid1 in
            let bkd2 = KindStore.get_free_id fid2 in
            match (bkd1, bkd2) with
            | (UniversalKind, UniversalKind) ->
                Consistent

            | (UniversalKind, RecordKind(_)) ->
                KindStore.register_free_id fid1 bkd2;
                Consistent

            | (RecordKind(_), UniversalKind) ->
                KindStore.register_free_id fid2 bkd1;
                Consistent

            | (RecordKind(labmap1), RecordKind(labmap2)) ->
                let res = aux_label_assoc_intersection labmap1 labmap2 in
                let union = label_assoc_union labmap1 labmap2 in
                KindStore.register_free_id fid1 (RecordKind(union));
                KindStore.register_free_id fid2 (RecordKind(union));
                res
          in
          mtvu1 := Link(ty2);
            (* Not `mtvu1 := Free(fid2)`. But I don't really understand why... TODO: Understand this *)
          res
        end

    | (TypeVar(Updatable({contents = Free(fid1)} as mtvu1)), _) ->
        aux_free_id_and_record fid1 mtvu1 ty2

    | (_, TypeVar(Updatable({contents = Free(fid2)} as mtvu2))) ->
        aux_free_id_and_record fid2 mtvu2 ty1

    | _ ->
        Contradiction

  and aux_free_id_and_record (fid1 : FreeID.t) (mtvu1 : mono_type_var_updatable ref) (ty2 : mono_type) =
        let b = occurs fid1 ty2 in
        if b then
          Inclusion(fid1)
        else
          let res =
            match ty2 with
            | (_, RecordType(labmap2)) ->
                let bkd1 = KindStore.get_free_id fid1 in
                begin
                  match bkd1 with
                  | UniversalKind ->
                      Consistent

                  | RecordKind(labmap1) ->
                      aux_label_assoc_subtype ~specific:labmap2 ~general:labmap1
                end

            | _ ->
                Consistent
          in
          begin
            match res with
            | Consistent -> mtvu1 := Link(ty2); res
            | _          -> res
          end

  and aux_list tys1 tys2 =
    try
      List.fold_left2 (fun res ty1 ty2 ->
        match res with
        | Consistent -> aux ty1 ty2
        | _          -> res
      ) Consistent tys1 tys2
    with
    | Invalid_argument(_) -> Contradiction

  and aux_domain domain1 domain2 =
    let {ordered = ty1doms; mandatory = mndlabmap1; optional = optrow1} = domain1 in
    let {ordered = ty2doms; mandatory = mndlabmap2; optional = optrow2} = domain2 in
    let res1 = aux_list ty1doms ty2doms in
    let resmnd = aux_label_assoc_exact mndlabmap1 mndlabmap2 in
    let resopt = aux_option_row optrow1 optrow2 in
    res1 &&& resmnd &&& resopt

  and aux_effect (Effect(ty1)) (Effect(ty2)) =
    aux ty1 ty2

  and aux_pid_type (Pid(ty1)) (Pid(ty2)) =
    aux ty1 ty2

  and aux_option_row (optrow1 : mono_row) (optrow2 : mono_row) =
    match (optrow1, optrow2) with
    | (RowVar(UpdatableRow{contents = LinkRow(labmap1)}), _) ->
        aux_option_row (FixedRow(labmap1)) optrow2

    | (_, RowVar(UpdatableRow{contents = LinkRow(labmap2)})) ->
        aux_option_row optrow1 (FixedRow(labmap2))

    | (RowVar(MustBeBoundRow(mbbrid1)), RowVar(MustBeBoundRow(mbbrid2))) ->
        if MustBeBoundRowID.equal mbbrid1 mbbrid2 then
          Consistent
        else
          Contradiction

    | (RowVar(MustBeBoundRow(_)), _)
    | (_, RowVar(MustBeBoundRow(_))) ->
        Contradiction

    | (RowVar(UpdatableRow({contents = FreeRow(frid1)} as mrvu1)), FixedRow(labmap2)) ->
        if occurs_row frid1 labmap2 then
          InclusionRow(frid1)
        else
          let labmap1 = KindStore.get_free_row frid1 in
          begin
            match aux_label_assoc_subtype ~specific:labmap2 ~general:labmap1 with
            | Consistent -> mrvu1 := LinkRow(labmap2); Consistent
            | res        -> res
          end

    | (FixedRow(labmap1), RowVar(UpdatableRow({contents = FreeRow(frid2)} as mrvu2))) ->
        if occurs_row frid2 labmap1 then
          InclusionRow(frid2)
        else
          let labmap2 = KindStore.get_free_row frid2 in
          begin
            match aux_label_assoc_subtype ~specific:labmap1 ~general:labmap2 with
            | Consistent -> mrvu2 := LinkRow(labmap1); Consistent
            | res        -> res
          end

    | (RowVar(UpdatableRow({contents = FreeRow(frid1)} as mtvu1)), RowVar(UpdatableRow{contents = FreeRow(frid2)})) ->
        if FreeRowID.equal frid1 frid2 then
          Consistent
        else
          let labmap1 = KindStore.get_free_row frid1 in
          let labmap2 = KindStore.get_free_row frid2 in
          let res = aux_label_assoc_intersection labmap1 labmap2 in
          begin
            match res with
            | Consistent ->
                mtvu1 := FreeRow(frid2);
                  (* DOUBTFUL; maybe should be `LinkRow(FreeRow(frid2))`
                     with the definition of `LinkRow` changed. *)
                let union = label_assoc_union labmap1 labmap2 in
                KindStore.register_free_row frid2 union;
                Consistent

            | _ ->
                res
          end

    | (FixedRow(labmap1), FixedRow(labmap2)) ->
        let merged =
          LabelAssoc.merge (fun _ tyopt1 tyopt2 ->
            match (tyopt1, tyopt2) with
            | (None, None)           -> None
            | (None, Some(_))        -> Some(Contradiction)
            | (Some(_), None)        -> Some(Contradiction)
            | (Some(ty1), Some(ty2)) -> Some(aux ty1 ty2)
          ) labmap1 labmap2
        in
        LabelAssoc.fold (fun _ res resacc -> resacc &&& res) merged Consistent

  and aux_label_assoc_subtype ~specific:labmap2 ~general:labmap1 =
    (* Check that `labmap2` is more specific than or equal to `labmap1`,
       i.e., the domain of `labmap1` is contained in that of `labmap2`. *)
    LabelAssoc.fold (fun label ty1 res ->
      match res with
      | Consistent ->
          begin
            match labmap2 |> LabelAssoc.find_opt label with
            | None      -> Contradiction
            | Some(ty2) -> aux ty1 ty2
          end

      | _ ->
          res
    ) labmap1 Consistent

  and aux_label_assoc_exact labmap1 labmap2 =
    let merged =
      LabelAssoc.merge (fun _ tyopt1 tyopt2 ->
        match (tyopt1, tyopt2) with
        | (None, None)           -> None
        | (Some(ty1), Some(ty2)) -> Some(aux ty1 ty2)
        | _                      -> Some(Contradiction)
      ) labmap1 labmap2
    in
    LabelAssoc.fold (fun _ res resacc -> resacc &&& res) merged Consistent

  and aux_label_assoc_intersection labmap1 labmap2 =
    let intersection =
      LabelAssoc.merge (fun _ opt1 opt2 ->
        match (opt1, opt2) with
        | (Some(ty1), Some(ty2)) -> Some((ty1, ty2))
        | _                      -> None
      ) labmap1 labmap2
    in
    LabelAssoc.fold (fun label (ty1, ty2) res ->
      match res with
      | Consistent -> aux ty1 ty2
      | _          -> res
    ) intersection Consistent

end

let unify (tyact : mono_type) (tyexp : mono_type) : unit =
(*
  Format.printf "UNIFY %a =?= %a\n" pp_mono_type tyact pp_mono_type tyexp; (* for debug *)
*)
  let res = Unification.aux tyact tyexp in
  match res with
  | Consistent         -> ()
  | Contradiction      -> raise_error (ContradictionError(tyact, tyexp))
  | Inclusion(fid)     -> raise_error (InclusionError(fid, tyact, tyexp))
  | InclusionRow(frid) -> raise_error (InclusionRowError(frid, tyact, tyexp))


let unify_effect (Effect(tyact) : mono_effect) (Effect(tyexp) : mono_effect) : unit =
  let res = Unification.aux tyact tyexp in
  match res with
  | Consistent         -> ()
  | Contradiction      -> raise_error (ContradictionError(tyact, tyexp))
  | Inclusion(fid)     -> raise_error (InclusionError(fid, tyact, tyexp))
  | InclusionRow(frid) -> raise_error (InclusionRowError(frid, tyact, tyexp))


let fresh_type_variable ?name:nameopt (lev : int) (mbkd : mono_base_kind) (rng : Range.t) : mono_type =
  let fid = FreeID.fresh ~message:"fresh_type_variable" lev in
  KindStore.register_free_id fid mbkd;
  let mtvu = ref (Free(fid)) in
  let ty = (rng, TypeVar(Updatable(mtvu))) in
(*
  let name = nameopt |> Option.map (fun x -> x ^ " : ") |> Option.value ~default:"" in
  Format.printf "GEN %sL%d %a :: %a\n" name lev pp_mono_type ty pp_mono_base_kind mbkd;  (* for debug *)
*)
  ty


let check_properly_used (tyenv : Typeenv.t) ((rng, x) : identifier ranged) =
  match tyenv |> Typeenv.is_val_properly_used x with
  | None        -> assert false
  | Some(true)  -> ()
  | Some(false) -> Logging.warn_val_not_used rng x


let get_space_name (rng : Range.t) (m : module_name) : space_name =
  match OutputIdentifier.space_of_module_name m with
  | None        -> raise_error (InvalidIdentifier(rng, m))
  | Some(sname) -> sname


let generate_local_name (rng : Range.t) (x : identifier) : local_name =
  match OutputIdentifier.generate_local x with
  | None        -> raise_error (InvalidIdentifier(rng, x))
  | Some(lname) -> lname


let generate_global_name ~arity:(arity : int) ~has_option:(has_option : bool) (rng : Range.t) (x : identifier) : global_name =
  match OutputIdentifier.generate_global x ~arity:arity ~has_option:has_option with
  | None        -> raise_error (InvalidIdentifier(rng, x))
  | Some(gname) -> gname


let local_name_scheme letbind =
  let (rngv, x) = letbind.vb_identifier in
  let lname_inner = generate_local_name rngv x in
  let lname_outer = OutputIdentifier.fresh () in
  (lname_inner, lname_outer)


let global_name_scheme valbind =
  let arity = List.length valbind.vb_parameters + List.length valbind.vb_mandatories in
  let has_option = (List.length valbind.vb_optionals > 0) in
  let (rngv, x) = valbind.vb_identifier in
  let gname = generate_global_name ~arity:arity ~has_option:has_option rngv x in
  (gname, gname)


let types_of_format (lev : int) (fmtelems : format_element list) : mono_type list =
  fmtelems |> List.map (function
  | FormatHole(hole, _) ->
      let rng = Range.dummy "format" in
      let ty =
        match hole with
        | HoleC ->
            (rng, BaseType(CharType))

        | HoleF
        | HoleE
        | HoleG ->
            (rng, BaseType(FloatType))

        | HoleS ->
            Primitives.list_type rng (rng, BaseType(CharType))

        | HoleP
        | HoleW ->
            fresh_type_variable lev UniversalKind rng
      in
      [ ty ]

  | FormatConst(_)
  | FormatDQuote
  | FormatBreak
  | FormatTilde ->
      []

  ) |> List.concat


let type_of_base_constant (lev : int) (rng : Range.t) (bc : base_constant) =
  match bc with
  | Unit     -> (rng, BaseType(UnitType))
  | Bool(_)  -> (rng, BaseType(BoolType))
  | Int(_)   -> (rng, BaseType(IntType))
  | Float(_) -> (rng, BaseType(FloatType))
  | BinaryByString(_)
  | BinaryByInts(_)   -> (rng, BaseType(BinaryType))
  | String(_) -> Primitives.list_type rng (Range.dummy "string_literal", BaseType(CharType))
  | Char(_)   -> (rng, BaseType(CharType))

  | FormatString(fmtelems) ->
      let tyarg =
        match types_of_format lev fmtelems with
        | []         -> (Range.dummy "format", BaseType(UnitType))
        | ty1 :: tys -> (Range.dummy "format", ProductType(TupleList.make ty1 tys))
      in
      Primitives.format_type rng tyarg


let rec make_type_parameter_assoc (pre : pre) (tyvarnms : type_variable_binder list) : pre * type_parameter_assoc =
  tyvarnms |> List.fold_left (fun (pre, assoc) ((rng, tyvarnm), kdannot) ->
    let mbbid = MustBeBoundID.fresh (pre.level + 1) in
    let mbkd =
      match kdannot with
      | None        -> UniversalKind
      | Some(mnbkd) -> decode_manual_base_kind pre mnbkd
    in
    let pbkd =
      match TypeConv.generalize_base_kind pre.level mbkd with
      | Ok(pbkd) -> pbkd
      | Error(_) -> assert false
          (* Type parameters occurring in handwritten kinds cannot be cyclic. *)
    in
    KindStore.register_bound_id (MustBeBoundID.to_bound mbbid) pbkd;
(*
    Format.printf "MUST-BE-BOUND %s : L%d %a\n" tyvarnm lev MustBeBoundID.pp mbbid;  (* for debug *)
*)
    match assoc |> TypeParameterAssoc.add_last tyvarnm mbbid with
    | None ->
        raise_error (TypeParameterBoundMoreThanOnce(rng, tyvarnm))

    | Some(assoc) ->
        let localtyparams = pre.local_type_parameters |> TypeParameterMap.add tyvarnm mbbid in
        let pre = { pre with local_type_parameters = localtyparams } in
        (pre, assoc)
  ) (pre, TypeParameterAssoc.empty)


and decode_manual_base_kind (pre : pre) (mnbkd : manual_base_kind) : mono_base_kind =

  let aux_labeled_list =
    decode_manual_record_type_scheme (fun _ -> ()) pre
  in

  let rec aux (rng, mnbkdmain) =
    match mnbkdmain with
    | MKindName(kdnm) ->
        begin
          match kdnm with
          | "o" -> UniversalKind
          | _   -> raise_error (UndefinedKindName(rng, kdnm))
        end

    | MRecordKind(labmtys) ->
        let labmap = aux_labeled_list labmtys in
        RecordKind(labmap)
  in
  aux mnbkd


and decode_manual_kind (pre : pre) (mnkd : manual_kind) : mono_kind =
  match mnkd with
  | (_, MKind(mnbkddoms, mnbkdcod)) ->
      let bkddoms = mnbkddoms |> List.map (decode_manual_base_kind pre) in
      let bkdcod = decode_manual_base_kind pre mnbkdcod in
      Kind(bkddoms, bkdcod)


and decode_manual_type_scheme (k : TypeID.t -> unit) (pre : pre) (mty : manual_type) : mono_type =

  let tyenv = pre.tyenv in
  let typarams = pre.local_type_parameters in
  let rowparams = pre.local_row_parameters in

  let invalid rng tynm ~expect:len_expected ~actual:len_actual =
    raise_error (InvalidNumberOfTypeArguments(rng, tynm, len_expected, len_actual))
  in

  let aux_labeled_list =
    decode_manual_record_type_scheme k pre
  in

  let rec aux (rng, mtymain) =
    let tymain =
      match mtymain with
      | MTypeName(tynm, mtyargs) ->
          let ptyargs = mtyargs |> List.map aux in
          let len_actual = List.length ptyargs in
          begin
            match tyenv |> Typeenv.find_type tynm with
            | None ->
                begin
                  match (tynm, ptyargs) with
                  | ("unit", [])    -> BaseType(UnitType)
                  | ("unit", _)     -> invalid rng "unit" ~expect:0 ~actual:len_actual
                  | ("bool", [])    -> BaseType(BoolType)
                  | ("bool", _)     -> invalid rng "bool" ~expect:0 ~actual:len_actual
                  | ("int", [])     -> BaseType(IntType)
                  | ("int", _)      -> invalid rng "int" ~expect:0 ~actual:len_actual
                  | ("float", [])   -> BaseType(FloatType)
                  | ("float", _)    -> invalid rng "float" ~expect:0 ~actual:len_actual
                  | ("binary", [])  -> BaseType(BinaryType)
                  | ("binary", _)   -> invalid rng "binary" ~expect:0 ~actual:len_actual
                  | ("char", [])    -> BaseType(CharType)
                  | ("char", _)     -> invalid rng "char" ~expect:0 ~actual:len_actual
                  | ("pid", [ty])   -> PidType(Pid(ty))
                  | ("pid", _)      -> invalid rng "pid" ~expect:1 ~actual:len_actual
                  | _               -> raise_error (UndefinedTypeName(rng, tynm))
                end

            | Some(tyid, pkd) ->
                let len_expected = TypeConv.arity_of_kind pkd in
                if len_actual = len_expected then
                  begin
                    k tyid;
                    DataType(tyid, ptyargs)
                  end
                else
                  invalid rng tynm ~expect:len_expected ~actual:len_actual
          end

      | MFuncType((mtydoms, mndlabmtys, mrow), mtycod) ->
          let mndlabmap = aux_labeled_list mndlabmtys in
          let optrow = aux_row mrow in
          FuncType({ordered = List.map aux mtydoms; mandatory = mndlabmap; optional = optrow}, aux mtycod)

      | MProductType(mtys) ->
          ProductType(TupleList.map aux mtys)

      | MRecordType(labmtys) ->
          let labmap = aux_labeled_list labmtys in
          RecordType(labmap)

      | MEffType((mtydoms, mndlabmtys, mrow), mty1, mty2) ->
          let mndlabmap = aux_labeled_list mndlabmtys in
          let optrow = aux_row mrow in
          let domain = {ordered = List.map aux mtydoms; mandatory = mndlabmap; optional = optrow} in
          EffType(domain, Effect(aux mty1), aux mty2)

      | MTypeVar(typaram) ->
          begin
            match typarams |> TypeParameterMap.find_opt typaram with
            | None ->
                raise_error (UnboundTypeParameter(rng, typaram))

            | Some(mbbid) ->
                TypeVar(MustBeBound(mbbid))
          end

      | MModProjType(utmod1, tyident2, mtyargs) ->
          let (rng2, tynm2) = tyident2 in
          let (absmodsig1, _) = typecheck_module Alist.empty tyenv utmod1 in
          let (oidset1, modsig1) = absmodsig1 in
          begin
            match modsig1 with
            | ConcFunctor(_) ->
                let (rng1, _) = utmod1 in
                raise_error (NotOfStructureType(rng1, modsig1))

            | ConcStructure(sigr) ->
                begin
                  match sigr |> SigRecord.find_type tynm2 with
                  | None ->
                      raise_error (UndefinedTypeName(rng2, tynm2))

                  | Some(tyopac2) ->
                      let tyargs = mtyargs |> List.map aux in
                      let (tyid2, pkd2) = tyopac2 in
                      let arity_expected = TypeConv.arity_of_kind pkd2 in
                      let arity_actual = List.length tyargs in
                      if arity_actual = arity_expected then
                        if opaque_occurs_in_type_id oidset1 tyid2 then
                        (* Combining (T-Path) and the second premise “Γ ⊢ Σ : Ω” of (P-Mod)
                           in the original paper “F-ing modules” [Rossberg, Russo & Dreyer 2014],
                           we must assert that opaque type variables do not extrude their scope.
                        *)
                          raise_error (OpaqueIDExtrudesScopeViaType(rng, tyopac2))
                        else
                          DataType(tyid2, tyargs)
                      else
                        let (_, tynm2) = tyident2 in
                        raise_error (InvalidNumberOfTypeArguments(rng, tynm2, arity_expected, arity_actual))
                end
          end
    in
    (rng, tymain)

  and aux_row (mrow : manual_row) : mono_row =
    match mrow with
    | MFixedRow(optlabmtys) ->
        FixedRow(aux_labeled_list optlabmtys)

    | MRowVar(rng, rowparam) ->
        begin
          match rowparams |> RowParameterMap.find_opt rowparam with
          | None ->
              raise_error (UnboundRowParameter(rng, rowparam))

          | Some((mbbrid, _)) ->
              RowVar(MustBeBoundRow(mbbrid))
        end
  in
  aux mty


and decode_manual_record_type_scheme (k : TypeID.t -> unit) (pre : pre) (labmtys : labeled_manual_type list) : mono_type LabelAssoc.t =
  let aux = decode_manual_type_scheme k pre in
  labmtys |> List.fold_left (fun labmap (rlabel, mty) ->
    let (rnglabel, label) = rlabel in
    if labmap |> LabelAssoc.mem label then
      raise_error (DuplicatedLabel(rnglabel, label))
    else
      let ty = aux mty in
      labmap |> LabelAssoc.add label ty
  ) LabelAssoc.empty


and decode_manual_type (pre : pre) : manual_type -> mono_type =
  decode_manual_type_scheme (fun _ -> ()) pre


and decode_manual_type_and_get_dependency (vertices : SynonymIDSet.t) (pre : pre) (mty : manual_type) : mono_type * SynonymIDSet.t =
  let hashset = SynonymIDHashSet.create 32 in
    (* A hash set is created on every (non-partial) call. *)
  let k tyid =
    match tyid with
    | TypeID.Synonym(sid) ->
        if vertices |> SynonymIDSet.mem sid then
          SynonymIDHashSet.add hashset sid ()
        else
          ()

    | _ ->
        ()
  in
  let ty = decode_manual_type_scheme k pre mty in
  let dependencies =
    SynonymIDHashSet.fold (fun sid () set ->
      set |> SynonymIDSet.add sid
    ) hashset SynonymIDSet.empty
  in
  (ty, dependencies)


and add_local_row_parameter (rowvars : (row_variable_name ranged * (label ranged * manual_type) list) list) (pre : pre) : pre =
  rowvars |> List.fold_left (fun pre ((rng, rowvarnm), mkind) ->
    let rowparams = pre.local_row_parameters in
    if rowparams |> RowParameterMap.mem rowvarnm then
      raise_error (RowParameterBoundMoreThanOnce(rng, rowvarnm))
    else
      let mbbrid = MustBeBoundRowID.fresh pre.level in
      let plabmap =
        mkind |> List.fold_left (fun plabmap (rlabel, mty) ->
          let (rnglabel, label) = rlabel in
          if plabmap |> LabelAssoc.mem label then
            raise_error (DuplicatedLabel(rnglabel, label))
          else
            let ty = decode_manual_type pre mty in
            let pty = TypeConv.lift ty in
            plabmap |> LabelAssoc.add label pty
        ) LabelAssoc.empty
      in
      KindStore.register_bound_row (MustBeBoundRowID.to_bound mbbrid) plabmap;
      let rowparams = rowparams |> RowParameterMap.add rowvarnm (mbbrid, plabmap) in
      { pre with local_row_parameters = rowparams }
  ) pre


and decode_type_annotation_or_fresh (pre : pre) (((rng, x), tyannot) : binder) : mono_type =
  match tyannot with
  | None ->
      fresh_type_variable ~name:x pre.level UniversalKind rng

  | Some(mty) ->
      decode_manual_type pre mty


and decode_parameter (pre : pre) (binder : binder) =
  let ((rngv, x), _) = binder in
  let tydom = decode_type_annotation_or_fresh pre binder in
  let lname : local_name = generate_local_name rngv x in
  (x, tydom, lname)


and add_ordered_parameters_to_type_environment (pre : pre) (binders : binder list) : Typeenv.t * mono_type list * local_name list =
  let (tyenv, lnameacc, tydomacc) =
    List.fold_left (fun (tyenv, lnameacc, ptydomacc) binder ->
      let (x, tydom, lname) = decode_parameter pre binder in
      let ptydom = TypeConv.lift tydom in
      let tyenv = tyenv |> Typeenv.add_val x ptydom (OutputIdentifier.Local(lname)) in
      (tyenv, Alist.extend lnameacc lname, Alist.extend ptydomacc tydom)
    ) (pre.tyenv, Alist.empty, Alist.empty) binders
  in
  let lnames = lnameacc |> Alist.to_list in
  let tydoms = tydomacc |> Alist.to_list in
  (tyenv, tydoms, lnames)


and add_labeled_optional_parameters_to_type_environment (pre : pre) (optbinders : (labeled_binder * untyped_ast option) list) : Typeenv.t * mono_type LabelAssoc.t * (local_name * ast option) LabelAssoc.t =
  optbinders |> List.fold_left (fun (tyenv, labmap, optnamemap) ((rlabel, binder), utdefault) ->
    let (rnglabel, label) = rlabel in
    if labmap |> LabelAssoc.mem label then
      raise_error (DuplicatedLabel(rnglabel, label))
    else
      let (x, ty_inner, lname) = decode_parameter pre binder in
      let (ty_outer, default) =
        match utdefault with
        | None ->
            let ty_outer = fresh_type_variable pre.level UniversalKind (Range.dummy "optional") in
            unify ty_inner (Primitives.option_type (Range.dummy "option") ty_outer);
            (ty_outer, None)

        | Some(utast) ->
            let (ty, e) = typecheck pre utast in
            unify ty_inner ty;
            (ty_inner, Some(e))
      in
      let labmap = labmap |> LabelAssoc.add label ty_outer in
      let tyenv = tyenv |> Typeenv.add_val x (TypeConv.lift ty_inner) (OutputIdentifier.Local(lname)) in
      let optnamemap = optnamemap |> LabelAssoc.add label (lname, default) in
      (tyenv, labmap, optnamemap)
  ) (pre.tyenv, LabelAssoc.empty, LabelAssoc.empty)


and add_labeled_mandatory_parameters_to_type_environment (pre : pre) (mndbinders : labeled_binder list) : Typeenv.t * mono_type LabelAssoc.t * local_name LabelAssoc.t =
  mndbinders |> List.fold_left (fun (tyenv, labmap, optnamemap) (rlabel, binder) ->
    let (rnglabel, label) = rlabel in
    if labmap |> LabelAssoc.mem label then
      raise_error (DuplicatedLabel(rnglabel, label))
    else
      let (x, ty, lname) = decode_parameter pre binder in
      let labmap = labmap |> LabelAssoc.add label ty in
      let tyenv = tyenv |> Typeenv.add_val x (TypeConv.lift ty) (OutputIdentifier.Local(lname)) in
      let optnamemap = optnamemap |> LabelAssoc.add label lname in
      (tyenv, labmap, optnamemap)
  ) (pre.tyenv, LabelAssoc.empty, LabelAssoc.empty)


and add_parameters_to_type_environment (pre : pre) ((ordbinders, mndbinders, optbinders) : untyped_parameters) =
  let (tyenv, tydoms, ordnames) =
    add_ordered_parameters_to_type_environment pre ordbinders
  in
  let (tyenv, mndlabmap, mndnamemap) =
    add_labeled_mandatory_parameters_to_type_environment { pre with tyenv } mndbinders
  in
  let (tyenv, optlabmap, optnamemap) =
    add_labeled_optional_parameters_to_type_environment { pre with tyenv } optbinders
  in
  let pre = { pre with tyenv } in
  let domain = {ordered = tydoms; mandatory = mndlabmap; optional = FixedRow(optlabmap)} in
  let ibinders = (ordnames, mndnamemap, optnamemap) in
  (pre, domain, ibinders)


and typecheck (pre : pre) ((rng, utastmain) : untyped_ast) : mono_type * ast =
  match utastmain with
  | BaseConst(bc) ->
      let ty = type_of_base_constant pre.level rng bc in
      (ty, IBaseConst(bc))

  | Var(x) ->
      begin
        match pre.tyenv |> Typeenv.find_val x with
        | None ->
            raise_error (UnboundVariable(rng, x))

        | Some((_, ptymain), name) ->
            let ty = TypeConv.instantiate pre.level (rng, ptymain) in
(*
            Format.printf "INST %s : L%d %a\n" x pre.level pp_mono_type ty;  (* for debug *)
*)
            (ty, IVar(name))
      end

  | Lambda(binders, utast0) ->
      let (pre, domain, ibinders) = add_parameters_to_type_environment pre binders in
      let (tycod, e0) = typecheck pre utast0 in
      let ty = (rng, FuncType(domain, tycod)) in
      (ty, ilambda ibinders e0)

  | LambdaEff(binders, utcomp0) ->
      let (pre, domain, ibinders) = add_parameters_to_type_environment pre binders in
      let ((eff, ty0), e0) = typecheck_computation pre utcomp0 in
      let ty = (rng, EffType(domain, eff, ty0)) in
      (ty, ilambda ibinders e0)

  | Apply(utastfun, utargs) ->
      let (tyfun, efun) = typecheck pre utastfun in
      begin
        match TypeConv.canonicalize_root tyfun with
        | (_, FuncType(domain_expected, tyret)) ->
          (* A slight trick for making error messages easier to comprehend. *)
            let iargs = typecheck_arguments_against_domain pre rng utargs domain_expected in
            let tyret =
              let (_, tyretmain) = tyret in
              (rng, tyretmain)
            in
            (tyret, iapply efun domain_expected.optional iargs)

        | _ ->
            let (domain, optrow, iargs) = typecheck_arguments pre rng utargs in
            let tyret = fresh_type_variable ~name:"(Apply)" pre.level UniversalKind rng in
            unify tyfun (Range.dummy "Apply", FuncType(domain, tyret));
            (tyret, iapply efun optrow iargs)
      end

  | Freeze(rngapp, frozenfun, utastargs, restrngs) ->
      let (ptyfun, gname) =
        match frozenfun with
        | FrozenModFun(modidentchain1, ident2) ->
            let (modsig1, _) = find_module_from_chain pre.tyenv modidentchain1 in
            begin
              match modsig1 with
              | ConcFunctor(_) ->
                  let ((rng1, _), _) = modidentchain1 in
                  raise_error (NotOfStructureType(rng1, modsig1))

              | ConcStructure(sigr) ->
                  let (rng2, x) = ident2 in
                  begin
                    match sigr |> SigRecord.find_val x with
                    | None    -> raise_error (UnboundVariable(rng2, x))
                    | Some(v) -> v
                  end
            end

        | FrozenFun((rng0, x)) ->
            begin
              match pre.tyenv |> Typeenv.find_val x with
              | None ->
                  raise_error (UnboundVariable(rng0, x))

              | Some((_, ptymain), name) ->
                  begin
                    match name with
                    | OutputIdentifier.Global(gname) -> ((rng0, ptymain), gname)
                    | _                              -> raise_error (CannotFreezeNonGlobalName(rng0, x))
                  end
            end
      in
      let tyfun = TypeConv.instantiate pre.level ptyfun in
      let tyeargs = List.map (typecheck pre) utastargs in
      let tyargs = List.map fst tyeargs in
      let eargs = List.map snd tyeargs in
      let tyrests =
        restrngs |> List.map (fun restrng ->
          fresh_type_variable ~name:"Freeze, rest" pre.level UniversalKind restrng
        )
      in
      let tyargsall = List.append tyargs tyrests in

      let tyrecv = fresh_type_variable ~name:"Freeze, recv" pre.level UniversalKind rng in
      let eff = Effect(tyrecv) in
      let tyret = fresh_type_variable ~name:"Freeze, ret" pre.level UniversalKind rng in
      let domain = {ordered = tyargsall; mandatory = LabelAssoc.empty; optional = FixedRow(LabelAssoc.empty)} in
      unify tyfun (Range.dummy "Freeze1", EffType(domain, eff, tyret));
      let tyrest =
        let dr = Range.dummy "Freeze2" in
        match tyrests with
        | []        -> (dr, BaseType(UnitType))
        | ty :: tys -> (dr, ProductType(TupleList.make ty tys))
      in
      (Primitives.frozen_type rng ~rest:tyrest ~receive:tyrecv ~return:tyret, IFreeze(gname, eargs))

  | FreezeUpdate(utast0, utastargs, restrngs) ->
      let (ty0, e0) = typecheck pre utast0 in
      let tyeargs = List.map (typecheck pre) utastargs in
      let tyargs = List.map fst tyeargs in
      let eargs = List.map snd tyeargs in
      let tyholes =
        restrngs |> List.map (fun restrng ->
          fresh_type_variable ~name:"FreezeUpdate, rest1" pre.level UniversalKind restrng
        )
      in
      let tyrecv =
        fresh_type_variable ~name:"FreezeUpdate, recv" pre.level UniversalKind (Range.dummy "FreezeUpdate, recv")
      in
      let tyret =
        fresh_type_variable ~name:"FreezeUpdate, ret" pre.level UniversalKind (Range.dummy "FreezeUpdate, ret")
      in
      let ty_expected =
        let tyrest_expected =
          let dr = Range.dummy "FreezeUpdate, rest2" in
          match List.append tyargs tyholes with
          | []        -> (dr, BaseType(UnitType))
          | ty :: tys -> (dr, ProductType(TupleList.make ty tys))
        in
        Primitives.frozen_type (Range.dummy "FreezeUpdate") ~rest:tyrest_expected ~receive:tyrecv ~return:tyret
      in
      unify ty0 ty_expected;
      let tyrest =
        let dr = Range.dummy "FreezeUpdate, rest3" in
        match tyholes with
        | []        -> (dr, BaseType(UnitType))
        | ty :: tys -> (dr, ProductType(TupleList.make ty tys))
      in
      (Primitives.frozen_type rng ~rest:tyrest ~receive:tyrecv ~return:tyret, IFreezeUpdate(e0, eargs))


  | If(utast0, utast1, utast2) ->
      let (ty0, e0) = typecheck pre utast0 in
      unify ty0 (Range.dummy "If", BaseType(BoolType));
      let (ty1, e1) = typecheck pre utast1 in
      let (ty2, e2) = typecheck pre utast2 in
      unify ty1 ty2;
      let ibranches = [ IBranch(IPBool(true), e1); IBranch(IPBool(false), e2) ] in
      (ty1, ICase(e0, ibranches))

  | LetIn(NonRec(letbind), utast2) ->
      let (pty, lname, e1) = typecheck_let generate_local_name pre letbind in
      let tyenv =
        let (_, x) = letbind.vb_identifier in
        pre.tyenv |> Typeenv.add_val x pty (OutputIdentifier.Local(lname)) in
      let (ty2, e2) = typecheck { pre with tyenv } utast2 in
      check_properly_used tyenv letbind.vb_identifier;
      (ty2, ILetIn(lname, e1, e2))

  | LetIn(Rec(letbinds), utast2) ->
      let proj lname = OutputIdentifier.Local(lname) in
      let binds = typecheck_letrec_mutual local_name_scheme proj pre letbinds in
      let (ty2, e2) =
        let tyenv =
          binds |> List.fold_left (fun tyenv (x, pty, lname_outer, _, _) ->
            tyenv |> Typeenv.add_val x pty (OutputIdentifier.Local(lname_outer))
          ) pre.tyenv
        in
        typecheck { pre with tyenv } utast2
      in
      (ty2, iletrecin binds e2)

  | Tuple(utasts) ->
      let tyes = utasts |> TupleList.map (typecheck pre) in
      let tys = tyes |> TupleList.map fst in
      let es = tyes |> TupleList.map snd in
      let ty = (rng, ProductType(tys)) in
      (ty, ITuple(es))

  | ListNil ->
      let tysub = fresh_type_variable pre.level UniversalKind (Range.dummy "list-nil") in
      let ty = Primitives.list_type rng tysub in
      (ty, IListNil)

  | ListCons(utast1, utast2) ->
      let (ty1, e1) = typecheck pre utast1 in
      let (ty2, e2) = typecheck pre utast2 in
      unify ty2 (Primitives.list_type (Range.dummy "list-cons") ty1);
      (ty2, IListCons(e1, e2))

  | Case(utast0, branches) ->
      let (ty0, e0) = typecheck pre utast0 in
      let tyret = fresh_type_variable pre.level UniversalKind (Range.dummy "case-ret") in
      let ibrs = branches |> List.map (typecheck_pure_case_branch pre ~pattern:ty0 ~return:tyret) in
      (tyret, ICase(e0, ibrs))

  | LetPatIn(utpat, utast1, utast2) ->
      let (tyenv, ipat, bindmap, e1) = typecheck_let_pattern pre rng utpat utast1 in
      let (ty2, e2) = typecheck { pre with tyenv } utast2 in
      BindingMap.iter (fun x (_, _, rng) ->
        check_properly_used tyenv (rng, x)
      ) bindmap;
      (ty2, iletpatin ipat e1 e2)

  | Constructor(ctornm, utastargs) ->
      let (vid, ctorid, tyargs, tys_expected) = typecheck_constructor pre rng ctornm in
      begin
        try
          let es =
            List.fold_left2 (fun acc ty_expected utast ->
              let (ty, e) = typecheck pre utast in
              unify ty ty_expected;
              Alist.extend acc e
            ) Alist.empty tys_expected utastargs |> Alist.to_list
          in
          let ty = (rng, DataType(TypeID.Variant(vid), tyargs)) in
          let e = IConstructor(ctorid, es) in
          (ty, e)
        with
        | Invalid_argument(_) ->
            let len_expected = List.length tys_expected in
            let len_actual = List.length utastargs in
            raise_error (InvalidNumberOfConstructorArguments(rng, ctornm, len_expected, len_actual))
      end

  | BinaryByList(nrs) ->
      let ns =
        nrs |> List.map (fun (rngn, n) ->
          if 0 <= n && n <= 255 then n else
            raise_error (InvalidByte(rngn))
        )
      in
      ((rng, BaseType(BinaryType)), IBaseConst(BinaryByInts(ns)))

  | Record(labasts) ->
      let (emap, labmap) =
        labasts |> List.fold_left (fun (emap, labmap) (rlabel, utast) ->
          let (rnglabel, label) = rlabel in
          if labmap |> LabelAssoc.mem label then
            raise_error (DuplicatedLabel(rnglabel, label))
          else
            let (ty, e) = typecheck pre utast in
            let labmap = labmap |> LabelAssoc.add label ty in
            let emap = emap |> LabelAssoc.add label e in
            (emap, labmap)
        ) (LabelAssoc.empty, LabelAssoc.empty)
      in
      ((rng, RecordType(labmap)), IRecord(emap))

  | RecordAccess(utast1, (_, label)) ->
      let (ty1, e1) = typecheck pre utast1 in
      let tyret = fresh_type_variable pre.level UniversalKind rng in
      let tyF =
        let labmap = LabelAssoc.singleton label tyret in
        fresh_type_variable pre.level (RecordKind(labmap)) (Range.dummy "RecordAccess")
      in
      unify ty1 tyF;
      (tyret, IRecordAccess(e1, label))

  | RecordUpdate(utast1, (_, label), utast2) ->
      let (ty1, e1) = typecheck pre utast1 in
      let (ty2, e2) = typecheck pre utast2 in
      let tyF =
        let labmap = LabelAssoc.singleton label ty2 in
        fresh_type_variable pre.level (RecordKind(labmap)) (Range.dummy "RecordUpdate")
      in
      unify ty1 tyF;
      (ty1, IRecordUpdate(e1, label, e2))

  | ModProjVal(modidents1, (rng2, x2)) ->
      let sigr1 = get_structure_signature pre.tyenv modidents1 in
(*
      let (oidset1, modsig1) = absmodsig1 in
*)
      begin
        match sigr1 |> SigRecord.find_val x2 with
        | None ->
            raise_error (UnboundVariable(rng2, x2))

        | Some((_, ptymain2), gname2) ->
            let pty2 = (rng, ptymain2) in
(*
            if opaque_occurs_in_poly_type oidset1 pty2 then
            (* Combining (E-Path) and the second premise “Γ ⊢ Σ : Ω” of (P-Mod)
               in the original paper “F-ing modules” [Rossberg, Russo & Dreyer 2014],
               we must assert that opaque type variables do not extrude their scope.
            *)
              raise_error (OpaqueIDExtrudesScopeViaValue(rng, pty2))
            else
*)
              let ty = TypeConv.instantiate pre.level pty2 in
              (ty, IVar(OutputIdentifier.Global(gname2)))
      end

  | ModProjCtor(modidents1, (rng2, ctornm2), utasts) ->
      let sigr1 = get_structure_signature pre.tyenv modidents1 in
      begin
        match sigr1 |> SigRecord.find_constructor ctornm2 with
        | None ->
            raise_error (UndefinedConstructor(rng2, ctornm2))

        | Some(ctorentry) ->
            let vid = ctorentry.belongs in
            let ctorid = ctorentry.constructor_id in
            let bids = ctorentry.type_variables in
            let ptys = ctorentry.parameter_types in
            let (tyargs, tys_expected) = TypeConv.instantiate_type_arguments pre.level bids ptys in
            begin
              match List.combine utasts tys_expected with
              | exception Invalid_argument(_) ->
                  let len_expected = List.length tys_expected in
                  let len_actual = List.length utasts in
                  raise_error (InvalidNumberOfConstructorArguments(rng2, ctornm2, len_expected, len_actual))

              | zipped ->
                  let eacc =
                    zipped |> List.fold_left (fun eacc (utast, ty_expected) ->
                      let (ty, e) = typecheck pre utast in
                      unify ty ty_expected;
                      Alist.extend eacc e
                    ) Alist.empty
                  in
                  let ty = (rng, DataType(TypeID.Variant(vid), tyargs)) in
                  let e = IConstructor(ctorid, Alist.to_list eacc) in
                  (ty, e)
            end
      end

  | Pack(modidentchain) ->
      let (_modsig1, _sname1) = find_module_from_chain pre.tyenv modidentchain in
      failwith "TODO: Pack"


and typecheck_let_pattern (pre : pre) (rng : Range.t) (utpat : untyped_pattern) (utast1 : untyped_ast) =
  let (ty1, e1) = typecheck { pre with level = pre.level + 1 } utast1 in
  let (typat, ipat, bindmap) = typecheck_pattern pre utpat in
  unify ty1 typat;
  let tyenv =
    BindingMap.fold (fun x (ty, lname, _) tyenv ->
      let pty =
        match TypeConv.generalize pre.level ty with
        | Ok(pty)             -> pty
        | Error((cycle, pty)) -> raise_error (CyclicTypeParameter(rng, cycle, pty))
      in
      tyenv |> Typeenv.add_val x pty (OutputIdentifier.Local(lname))
    ) bindmap pre.tyenv
  in
  (tyenv, ipat, bindmap, e1)


and typecheck_computation (pre : pre) (utcomp : untyped_computation_ast) : (mono_effect * mono_type) * ast =
  let (rng, utcompmain) = utcomp in
  match utcompmain with
  | CompDo(identopt, utcomp1, utcomp2) ->
      let ((eff1, ty1), e1) = typecheck_computation pre utcomp1 in
      let (tyx, tyenv, lname) =
        match identopt with
        | None ->
            ((Range.dummy "do-unit", BaseType(UnitType)), pre.tyenv, OutputIdentifier.unused)

        | Some(((rngv, x), _) as binder) ->
            let tyx = decode_type_annotation_or_fresh pre binder in
            let lname = generate_local_name rngv x in
            (tyx, pre.tyenv |> Typeenv.add_val x (TypeConv.lift tyx) (OutputIdentifier.Local(lname)), lname)
      in
      unify ty1 tyx;
      let ((eff2, ty2), e2) = typecheck_computation { pre with tyenv } utcomp2 in
      unify_effect eff1 eff2;
      let e2 = ILetIn(lname, e1, e2) in
      ((eff2, ty2), e2)

  | CompReceive(branches) ->
      let lev = pre.level in
      let effexp =
        let ty = fresh_type_variable lev UniversalKind (Range.dummy "receive-recv") in
        Effect(ty)
      in
      let tyret = fresh_type_variable lev UniversalKind (Range.dummy "receive-ret") in
      let ibrs = branches |> List.map (typecheck_receive_branch pre effexp tyret) in
      ((effexp, tyret), IReceive(ibrs))

  | CompLetIn(NonRec(letbind), utcomp2) ->
      let (pty, lname, e1) = typecheck_let generate_local_name pre letbind in
      let tyenv =
        let (_, x) = letbind.vb_identifier in
        pre.tyenv |> Typeenv.add_val x pty (OutputIdentifier.Local(lname)) in
      let ((eff2, ty2), e2) = typecheck_computation { pre with tyenv } utcomp2 in
      check_properly_used tyenv letbind.vb_identifier;
      ((eff2, ty2), ILetIn(lname, e1, e2))

  | CompLetIn(Rec(letbinds), utcomp2) ->
      let proj lname = OutputIdentifier.Local(lname) in
      let binds = typecheck_letrec_mutual local_name_scheme proj pre letbinds in
      let ((eff2, ty2), e2) =
        let tyenv =
          binds |> List.fold_left (fun tyenv (x, pty, lname_outer, _, _) ->
            tyenv |> Typeenv.add_val x pty (OutputIdentifier.Local(lname_outer))
          ) pre.tyenv
        in
        typecheck_computation { pre with tyenv } utcomp2
      in
      ((eff2, ty2), iletrecin binds e2)

  | CompLetPatIn(utpat, utast1, utcomp2) ->
      let (tyenv, ipat, bindmap, e1) = typecheck_let_pattern pre rng utpat utast1 in
      let ((eff2, ty2), e2) = typecheck_computation { pre with tyenv } utcomp2 in
      ((eff2, ty2), iletpatin ipat e1 e2)

  | CompIf(utast0, utcomp1, utcomp2) ->
      let (ty0, e0) = typecheck pre utast0 in
      unify ty0 (Range.dummy "If", BaseType(BoolType));
      let ((eff1, ty1), e1) = typecheck_computation pre utcomp1 in
      let ((eff2, ty2), e2) = typecheck_computation pre utcomp2 in
      unify_effect eff1 eff2;
      unify ty1 ty2;
      let ibranches = [ IBranch(IPBool(true), e1); IBranch(IPBool(false), e2) ] in
      ((eff1, ty1), ICase(e0, ibranches))

  | CompCase(utast0, branches) ->
      let (ty0, e0) = typecheck pre utast0 in
      let eff =
        let tyrecv = fresh_type_variable pre.level UniversalKind (Range.dummy "CompCase1") in
        Effect(tyrecv)
      in
      let tyret = fresh_type_variable pre.level UniversalKind (Range.dummy "CompCase2") in
      let ibrs = branches |> List.map (typecheck_effectful_case_branch pre ~pattern:ty0 ~return:(eff, tyret)) in
      ((eff, tyret), ICase(e0, ibrs))

  | CompApply(utastfun, utargs) ->
      let (tyfun, efun) = typecheck pre utastfun in
      let (domain, optrow, iargs) = typecheck_arguments pre rng utargs in
      let eff =
        let tyrecv = fresh_type_variable ~name:"(CompApply2)" pre.level UniversalKind rng in
        Effect(tyrecv)
      in
      let tyret = fresh_type_variable ~name:"(CompApply1)" pre.level UniversalKind rng in
      unify tyfun (Range.dummy "CompApply", EffType(domain, eff, tyret));
      ((eff, tyret), iapply efun optrow iargs)


and get_structure_signature (tyenv : Typeenv.t) (modidents : (module_name ranged) list) : SigRecord.t =
  match modidents with
  | [] ->
      assert false

  | modident :: projs ->
      let (rnginit, _) = modident in
      let (modsig, _) = find_module tyenv modident in
      let (modsig, rnglast) =
        projs |> List.fold_left (fun (modsig, rnglast) proj ->
          match modsig with
          | ConcFunctor(_) ->
              raise_error (NotOfStructureType(rnglast, modsig))

          | ConcStructure(sigr) ->
              let (rng, modnm) = proj in
              begin
                match sigr |> SigRecord.find_module modnm with
                | None              -> raise_error (UnboundModuleName(rng, modnm))
                | Some((modsig, _)) -> (modsig, rng)
              end
        ) (modsig, rnginit)
      in
      begin
        match modsig with
        | ConcFunctor(_)      -> raise_error (NotOfStructureType(rnglast, modsig))
        | ConcStructure(sigr) -> sigr
      end


and typecheck_arguments (pre : pre) (rng : Range.t) ((utastargs, mndutastargs, optutastargs) : untyped_arguments) =
  let tyeargs = List.map (typecheck pre) utastargs in
  let tyargs = List.map fst tyeargs in
  let eargs = List.map snd tyeargs in
  let (mndlabmap, mndargmap) =
    mndutastargs |> List.fold_left (fun (mndlabmap, mndargmap) (rlabel, utast) ->
      let (rnglabel, label) = rlabel in
      if mndlabmap |> LabelAssoc.mem label then
        raise_error (DuplicatedLabel(rnglabel, label))
      else
        let (ty, e) = typecheck pre utast in
        let mndlabmap = mndlabmap |> LabelAssoc.add label ty in
        let mndargmap = mndargmap |> LabelAssoc.add label e in
        (mndlabmap, mndargmap)
    ) (LabelAssoc.empty, LabelAssoc.empty)
  in
  let (optlabmap, optargmap) =
    optutastargs |> List.fold_left (fun (optlabmap, optargmap) (rlabel, utast) ->
      let (rnglabel, label) = rlabel in
      if optlabmap |> LabelAssoc.mem label then
        raise_error (DuplicatedLabel(rnglabel, label))
      else
        let (ty, e) = typecheck pre utast in
        let optlabmap = optlabmap |> LabelAssoc.add label ty in
        let optargmap = optargmap |> LabelAssoc.add label e in
        (optlabmap, optargmap)
    ) (LabelAssoc.empty, LabelAssoc.empty)
  in
  let optrow =
    let frid = FreeRowID.fresh ~message:"Apply, row" pre.level in
    KindStore.register_free_row frid optlabmap;
    let mrvu = ref (FreeRow(frid)) in
    RowVar(UpdatableRow(mrvu))
  in
  let domain = {ordered = tyargs; mandatory = mndlabmap; optional = optrow} in
  (domain, optrow, (eargs, mndargmap, optargmap))


and typecheck_arguments_against_domain (pre : pre) (rng : Range.t) ((utastargs, mndutastargs, optutastargs) : untyped_arguments) (domain_expected : mono_domain_type) =
  let {ordered = tys_expected; mandatory = mndlabmap_expected; optional = optrow_expected} = domain_expected in
  let eargs =
    let numord_got = List.length utastargs in
    let numord_expected = List.length tys_expected in
    if numord_got = numord_expected then
      List.fold_left2 (fun eargacc utastarg ty_expected ->
        let (ty_got, e) = typecheck pre utastarg in
        unify ty_got ty_expected;
        Alist.extend eargacc e
      ) Alist.empty utastargs tys_expected |> Alist.to_list
    else
      raise_error @@ BadArityOfOrderedArguments{range = rng; got = numord_got; expected = numord_expected}
  in
  let mndargmap =
    let (mndlabmap_rest, mndargmap) =
      mndutastargs |> List.fold_left (fun (mndlabmap_rest, mndargmap) (rlabel, utast) ->
        let (rnglabel, label) = rlabel in
        if mndargmap |> LabelAssoc.mem label then
          raise_error @@ DuplicatedLabel(rnglabel, label)
        else
          match mndlabmap_rest |> LabelAssoc.find_opt label with
          | None ->
              raise_error @@ UnexpectedMandatoryLabel{range = rnglabel; label = label}

          | Some(ty_expected) ->
              let (ty_got, e) = typecheck pre utast in
              unify ty_got ty_expected;
              let mndlabmap_rest = mndlabmap_rest |> LabelAssoc.remove label in
              let mndargmap = mndargmap |> LabelAssoc.add label e in
              (mndlabmap_rest, mndargmap)

      ) (mndlabmap_expected, LabelAssoc.empty)
    in
    match mndlabmap_rest |> LabelAssoc.bindings with
    | []               -> mndargmap
    | (label, ty) :: _ -> raise_error @@ MissingMandatoryLabel{range = rng; label = label; typ = ty}
  in
  let optargmap =
    let labmap_known =
      match optrow_expected with
      | FixedRow(labmap) ->
          labmap

      | RowVar(UpdatableRow{contents = LinkRow(labmap)}) ->
          labmap

      | RowVar(MustBeBoundRow(mbbrid)) ->
          let plabmap = KindStore.get_bound_row (MustBeBoundRowID.to_bound mbbrid) in
          plabmap |> LabelAssoc.map (TypeConv.instantiate pre.level)

      | RowVar(UpdatableRow{contents = FreeRow(frid)}) ->
          KindStore.get_free_row frid
    in
    let (unknown_label, optlabmap, optargmap) =
      optutastargs |> List.fold_left (fun (unknown_label, optlabmap, optargmap) (rlabel, utast) ->
        let (rnglabel, label) = rlabel in
        if optargmap |> LabelAssoc.mem label then
          raise_error (DuplicatedLabel(rnglabel, label))
        else
          let (ty_got, e) = typecheck pre utast in
          let optargmap = optargmap |> LabelAssoc.add label e in
          match labmap_known |> LabelAssoc.find_opt label with
          | None ->
              let optlabmap = optlabmap |> LabelAssoc.add label ty_got in
              (Some(rlabel), optlabmap, optargmap)

          | Some(ty_expected) ->
              unify ty_got ty_expected;
              let optlabmap = optlabmap |> LabelAssoc.add label ty_expected in
              (unknown_label, optlabmap, optargmap)

      ) (None, LabelAssoc.empty, LabelAssoc.empty)
    in
    let () =
      match unknown_label with
      | Some(rnglabel, label) ->
          begin
            match optrow_expected with
            | RowVar(UpdatableRow{contents = FreeRow(frid)}) ->
                KindStore.register_free_row frid optlabmap

            | _ ->
                raise_error @@ UnexpectedOptionalLabel{range = rnglabel; label = label}
          end

      | None ->
          ()
    in
    optargmap
  in
  (eargs, mndargmap, optargmap)


and typecheck_constructor (pre : pre) (rng : Range.t) (ctornm : constructor_name) =
  match pre.tyenv |> Typeenv.find_constructor ctornm with
  | None ->
      raise_error (UndefinedConstructor(rng, ctornm))

  | Some(tyid, ctorid, bids, ptys) ->
      let (tyargs, tys_expected) = TypeConv.instantiate_type_arguments pre.level bids ptys in
      (tyid, ctorid, tyargs, tys_expected)


and typecheck_pure_case_branch (pre : pre) ~pattern:typatexp ~return:tyret (CaseBranch(pat, utast1)) =
  let (typat, ipat, bindmap) = typecheck_pattern pre pat in
  let tyenv =
    BindingMap.fold (fun x (ty, lname, _) tyenv ->
      tyenv |> Typeenv.add_val x (TypeConv.lift ty) (OutputIdentifier.Local(lname))
    ) bindmap pre.tyenv
  in
  let (ty1, e1) = typecheck { pre with tyenv } utast1 in
  BindingMap.iter (fun x (_, _, rng) ->
    check_properly_used tyenv (rng, x)
  ) bindmap;
  unify typat typatexp;
  unify ty1 tyret;
  IBranch(ipat, e1)


and typecheck_effectful_case_branch (pre : pre) ~pattern:typatexp ~return:(eff, tyret) (CompCaseBranch(pat, utcomp1)) =
  let (typat, ipat, bindmap) = typecheck_pattern pre pat in
  let tyenv =
    BindingMap.fold (fun x (ty, lname, _) tyenv ->
      tyenv |> Typeenv.add_val x (TypeConv.lift ty) (OutputIdentifier.Local(lname))
    ) bindmap pre.tyenv
  in
  let ((eff1, ty1), e1) = typecheck_computation { pre with tyenv } utcomp1 in
  BindingMap.iter (fun x (_, _, rng) ->
    check_properly_used tyenv (rng, x)
  ) bindmap;
  unify typat typatexp;
  unify_effect eff1 eff;
  unify ty1 tyret;
  IBranch(ipat, e1)


and typecheck_receive_branch (pre : pre) (effexp : mono_effect) (tyret : mono_type) (ReceiveBranch(pat, utcomp1)) =
  let (typat, ipat, bindmap) = typecheck_pattern pre pat in
  let tyenv =
    BindingMap.fold (fun x (ty, lname, _) tyenv ->
      tyenv |> Typeenv.add_val x (TypeConv.lift ty) (OutputIdentifier.Local(lname))
    ) bindmap pre.tyenv
  in
  let ((eff1, ty1), e1) = typecheck_computation { pre with tyenv } utcomp1 in
  BindingMap.iter (fun x (_, _, rng) ->
    check_properly_used tyenv (rng, x)
  ) bindmap;
  unify_effect (Effect(typat)) effexp;
  unify_effect eff1 effexp;
  unify ty1 tyret;
  IBranch(ipat, e1)


and typecheck_pattern (pre : pre) ((rng, patmain) : untyped_pattern) : mono_type * pattern * binding_map =
  let immediate tymain ipat = ((rng, tymain), ipat, BindingMap.empty) in
  match patmain with
  | PUnit    -> immediate (BaseType(UnitType)) IPUnit
  | PBool(b) -> immediate (BaseType(BoolType)) (IPBool(b))
  | PInt(n)  -> immediate (BaseType(IntType)) (IPInt(n))

  | PChar(uchar) ->
      immediate (BaseType(CharType)) (IPChar(uchar))

  | PVar(x) ->
      let ty = fresh_type_variable ~name:x pre.level UniversalKind rng in
      let lname = generate_local_name rng x in
      (ty, IPVar(lname), BindingMap.singleton x (ty, lname, rng))

  | PWildCard ->
      let ty = fresh_type_variable ~name:"_" pre.level UniversalKind rng in
      (ty, IPWildCard, BindingMap.empty)

  | PListNil ->
      let ty =
        let tysub = fresh_type_variable pre.level UniversalKind rng in
        Primitives.list_type rng tysub
      in
      (ty, IPListNil, BindingMap.empty)

  | PListCons(pat1, pat2) ->
      let (ty1, ipat1, bindmap1) = typecheck_pattern pre pat1 in
      let (ty2, ipat2, bindmap2) = typecheck_pattern pre pat2 in
      let bindmap = binding_map_union rng bindmap1 bindmap2 in
      unify ty2 (Primitives.list_type (Range.dummy "pattern-cons") ty1);
      (ty2, IPListCons(ipat1, ipat2), bindmap)

  | PTuple(pats) ->
      let triples = pats |> TupleList.map (typecheck_pattern pre) in
      let tys = triples |> TupleList.map (fun (ty, _, _) -> ty) in
      let ipats = triples |> TupleList.map (fun (_, ipat, _) -> ipat) in
      let bindmaps = triples |> TupleList.map (fun (_, _, bindmap) -> bindmap) in
      let bindmap =
        bindmaps |> TupleList.to_list
          |> List.fold_left (binding_map_union rng) BindingMap.empty
      in
      let ty = (rng, ProductType(tys)) in
      (ty, IPTuple(ipats), bindmap)

  | PConstructor(ctornm, pats) ->
      let (vid, ctorid, tyargs, tys_expected) = typecheck_constructor pre rng ctornm in
      begin
        try
          let (ipatacc, bindmap) =
            List.fold_left2 (fun (ipatacc, bindmapacc) ty_expected pat ->
              let (ty, ipat, bindmap) = typecheck_pattern pre pat in
              unify ty ty_expected;
              (Alist.extend ipatacc ipat, binding_map_union rng bindmapacc bindmap)
            ) (Alist.empty, BindingMap.empty) tys_expected pats
          in
          let ty = (rng, DataType(TypeID.Variant(vid), tyargs)) in
          (ty, IPConstructor(ctorid, Alist.to_list ipatacc), bindmap)
        with
        | Invalid_argument(_) ->
            let len_expected = List.length tys_expected in
            let len_actual = List.length pats in
            raise_error (InvalidNumberOfConstructorArguments(rng, ctornm, len_expected, len_actual))
      end


and typecheck_let : 'n. (Range.t -> identifier -> 'n) -> pre -> untyped_let_binding -> poly_type * 'n * ast =
fun namef pre letbind ->
  let (rngv, x) = letbind.vb_identifier in
  let ordparams = letbind.vb_parameters in
  let mndparams = letbind.vb_mandatories in
  let optparams = letbind.vb_optionals in

  let (ty1, e0, ibinders) =

   (* First, add local type/row parameters at level `levS`. *)
    let pre =
      let (pre, assoc) = make_type_parameter_assoc pre letbind.vb_forall in
      let levS = pre.level + 1 in
      let pre = { pre with level = levS } in
      pre |> add_local_row_parameter letbind.vb_forall_row
    in

   (* Second, add local value parameters at level `levS`. *)
    let (pre, domain, ibinders) = add_parameters_to_type_environment pre (ordparams, mndparams, optparams) in

    (* Finally, typecheck the body expression. *)
    match letbind.vb_return with
    | Pure((tyretopt, utast0)) ->
        let (ty0, e0) = typecheck pre utast0 in
        tyretopt |> Option.map (fun mty0 ->
          let ty0_expected = decode_manual_type pre mty0 in
          unify ty0 ty0_expected
        ) |> Option.value ~default:();
        let ty1 = (rngv, FuncType(domain, ty0)) in
        (ty1, e0, ibinders)

    | Effectful((tyretopt, utcomp0)) ->
        let ((eff0, ty0), e0) = typecheck_computation pre utcomp0 in
        tyretopt |> Option.map (fun (mty1, mty2) ->
          let ty1_expected = decode_manual_type pre mty1 in
          let ty2_expected = decode_manual_type pre mty2 in
          unify_effect eff0 (Effect(ty1_expected));
          unify ty0 ty2_expected
        ) |> Option.value ~default:();
        let ty1 = (rngv, EffType(domain, eff0, ty0)) in
        (ty1, e0, ibinders)
  in
  let e1 = ilambda ibinders e0 in
  let pty1 =
    match TypeConv.generalize pre.level ty1 with
    | Ok(pty1)             -> pty1
    | Error((cycle, pty1)) -> raise_error (CyclicTypeParameter(rngv, cycle, pty1))
  in
  let name = namef rngv x in
  (pty1, name, e1)


and typecheck_letrec_mutual : 'n. (untyped_let_binding -> 'n * 'n) -> ('n -> name) -> pre -> untyped_let_binding list -> (identifier * poly_type * 'n * 'n * ast) list =
fun namesf proj pre letbinds ->

  (* Register type variables and names for output corresponding to bound names
     before traversing definitions *)
  let (tupleacc, tyenv) =
    letbinds |> List.fold_left (fun (tupleacc, tyenv) letbind ->
      let (rngv, x) = letbind.vb_identifier in
      let (name_inner, name_outer) = namesf letbind in
      let levS = pre.level + 1 in
      let tyf = fresh_type_variable ~name:x levS UniversalKind rngv in
      let tyenv = tyenv |> Typeenv.add_val x (TypeConv.lift tyf) (proj name_inner) in
      (Alist.extend tupleacc (letbind, name_inner, name_outer, tyf), tyenv)
    ) (Alist.empty, pre.tyenv)
  in

  let pre = { pre with tyenv } in
  let bindacc =
    tupleacc |> Alist.to_list |> List.fold_left (fun bindacc (letbind, name_inner, name_outer, tyf) ->
      let (pty, e1) = typecheck_letrec_single pre letbind tyf in
      let (_, x) = letbind.vb_identifier in
      Alist.extend bindacc (x, pty, name_outer, name_inner, e1)
    ) Alist.empty
  in
  bindacc |> Alist.to_list


and typecheck_letrec_single (pre : pre) (letbind : untyped_let_binding) (tyf : mono_type) : poly_type * ast =
  let (rngv, _) = letbind.vb_identifier in
  let ordparams = letbind.vb_parameters in
  let mndparams = letbind.vb_mandatories in
  let optparams = letbind.vb_optionals in

  let (ty1, e0, ibinders) =
    (* First, add local type/row parameters at level `levS`. *)
    let pre =
      let (pre, assoc) = make_type_parameter_assoc pre letbind.vb_forall in
      let levS = pre.level + 1 in
      let pre = { pre with level = levS } in
      pre |> add_local_row_parameter letbind.vb_forall_row
    in

    (* Second, add local value parameters at level `levS`. *)
    let (pre, domain, ibinders) = add_parameters_to_type_environment pre (ordparams, mndparams, optparams) in

    (* Finally, typecheck the body expression. *)
    match letbind.vb_return with
    | Pure((tyretopt, utast0)) ->
        let (ty0, e0) = typecheck pre utast0 in
        tyretopt |> Option.map (fun mty0 ->
          let ty0_expected = decode_manual_type pre mty0 in
          unify ty0 ty0_expected
        ) |> Option.value ~default:();
        let ty1 = (rngv, FuncType(domain, ty0)) in
        (ty1, e0, ibinders)

    | Effectful((tyretopt, utcomp0)) ->
        let ((eff0, ty0), e0) = typecheck_computation pre utcomp0 in
        tyretopt |> Option.map (fun (mty1, mty2) ->
          let ty1_expected = decode_manual_type pre mty1 in
          let ty2_expected = decode_manual_type pre mty2 in
          unify_effect eff0 (Effect(ty1_expected));
          unify ty0 ty2_expected
        ) |> Option.value ~default:();
        let ty1 = (rngv, EffType(domain, eff0, ty0)) in
        (ty1, e0, ibinders)
  in
  let e1 = ilambda ibinders e0 in
  unify ty1 tyf;
  let ptyf =
    match TypeConv.generalize pre.level ty1 with
    | Ok(ptyf)             -> ptyf
    | Error((cycle, ptyf)) -> raise_error (CyclicTypeParameter(rngv, cycle, ptyf))
  in
  (ptyf, e1)


and make_constructor_branch_map (pre : pre) (ctorbrs : constructor_branch list) : constructor_branch_map =
  ctorbrs |> List.fold_left (fun ctormap ctorbr ->
    match ctorbr with
    | ConstructorBranch((rng, ctornm), mtyargs) ->
        let tyargs = mtyargs |> List.map (decode_manual_type pre) in
        let ptyargs =
          tyargs |> List.map (fun ty ->
            match TypeConv.generalize pre.level ty with
            | Ok(pty)  -> pty
            | Error(_) -> assert false
                (* Type parameters occurring in handwritten types cannot be cyclic. *)
          )
        in
        let ctorid =
          match ConstructorID.make ctornm with
          | Some(ctorid) -> ctorid
          | None         -> raise_error (InvalidIdentifier(rng, ctornm))
        in
        ctormap |> ConstructorMap.add ctornm (ctorid, ptyargs)
  ) ConstructorMap.empty


(* `subtype_poly_type_scheme wtmap internbid pty1 pty2` checks that
   whether `pty1` is more general than (or equal to) `[wtmap]pty2`
   where `wtmap` is a substitution for type definitions in `pty2`.
   Note that being more general means being smaller as polymorphic types;
   we have `pty1 <= pty2` in that if `x : pty1` holds and `pty1` is more general than `pty2`, then `x : pty2`.
   The parameter `internbid` is used for `internbid bid pty`, which returns
   whether the bound ID `bid` occurring in `pty1` is mapped to a type equivalent to `pty`.
*)
and subtype_poly_type_scheme (wtmap : WitnessMap.t) (internbid : BoundID.t -> poly_type -> bool) (internbrid : BoundRowID.t -> poly_row -> bool) (pty1 : poly_type) (pty2 : poly_type) : bool =
  let rec aux pty1 pty2 =
(*
  let (sbt1, sbr1, sty1) = TypeConv.show_poly_type pty1 in
  let (sbt2, sbr2, sty2) = TypeConv.show_poly_type pty2 in
  Format.printf "subtype_poly_type_scheme> aux: %s <?= %s\n" sty1 sty2;  (* for debug *)
  Format.printf "%a\n" (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.fprintf ppf ",@ ") Format.pp_print_string) (List.concat [sbt1; sbr1; sbt2; sbr2]);
*)

    let (_, ptymain1) = pty1 in
    let (_, ptymain2) = pty2 in
    match (ptymain1, ptymain2) with
    | (TypeVar(Mono(_)), _)
    | (_, TypeVar(Mono(_))) ->
        assert false
          (* Monomorphic type variables cannot occur at level 0, according to type generalization. *)

    | (DataType(TypeID.Synonym(sid1), ptyargs1), _) ->
        let pty1real = TypeConv.get_real_poly_type sid1 ptyargs1 in
        aux pty1real pty2

    | (_, DataType(TypeID.Synonym(sid2), ptyargs2)) ->
        let pty2real = TypeConv.get_real_poly_type sid2 ptyargs2 in
        aux pty1 pty2real

    | (BaseType(bt1), BaseType(bt2)) ->
        bt1 = bt2

    | (FuncType(pdomain1, ptycod1), FuncType(pdomain2, ptycod2)) ->
        let bdom = aux_domain pdomain1 pdomain2 in
        let bcod = aux ptycod1 ptycod2 in
        bdom && bcod

    | (PidType(pidty1), PidType(pidty2)) ->
        aux_pid pidty1 pidty2

    | (EffType(domain1, effty1, pty1), EffType(domain2, effty2, pty2)) ->
        let b0 = aux_domain domain1 domain2 in
        let b1 = aux_effect effty1 effty2 in
        let b2 = aux pty1 pty2 in
        b0 && b1 && b2

    | (ProductType(ptys1), ProductType(ptys2)) ->
        aux_list (TupleList.to_list ptys1) (TupleList.to_list ptys2)

    | (RecordType(plabmap1), RecordType(plabmap2)) ->
        aux_label_assoc plabmap1 plabmap2

    | (TypeVar(Bound(bid1)), _) ->
        let b =
          match ptymain2 with
          | TypeVar(Bound(bid2)) ->
              let pbkd1 = KindStore.get_bound_id bid1 in
              let pbkd2 = KindStore.get_bound_id bid2 in
              aux_base_kind pbkd1 pbkd2

          | RecordType(plabmap2) ->
              let pbkd1 = KindStore.get_bound_id bid1 in
              aux_base_kind pbkd1 (RecordKind(plabmap2))

          | _ ->
              true

        in
        if b then internbid bid1 pty2 else false

    | (DataType(TypeID.Variant(vid1), ptyargs1), DataType(TypeID.Variant(vid2), ptyargs2)) ->
        begin
          match wtmap |> WitnessMap.find_variant vid2 with
          | None ->
              if TypeID.Variant.equal vid1 vid2 then
                aux_list ptyargs1 ptyargs2
              else
                false

          | Some(vid) ->
              if TypeID.Variant.equal vid vid1 then
                aux_list ptyargs1 ptyargs2
              else
                false
        end

    | (_, DataType(TypeID.Opaque(oid2), ptyargs2)) ->
        begin
          match wtmap |> WitnessMap.find_opaque oid2 with
          | None ->
            (* Existentially quantified type IDs will be not found in `wtmap`. *)
              begin
                match ptymain1 with
                | DataType(TypeID.Opaque(oid1), ptyargs1) ->
                    if TypeID.Opaque.equal oid1 oid2 then
                      aux_list ptyargs1 ptyargs2
                    else
                      false

                | _ ->
                    false
              end

          | Some(TypeID.Synonym(sid)) ->
              let pty2real = TypeConv.get_real_poly_type sid ptyargs2 in
              aux pty1 pty2real

          | Some(TypeID.Variant(vid)) ->
              begin
                match ptymain1 with
                | DataType(TypeID.Variant(vid1), ptyargs1) ->
                    if TypeID.Variant.equal vid vid1 then
                      aux_list ptyargs1 ptyargs2
                    else
                      false

                | _ ->
                    false
              end

          | Some(TypeID.Opaque(oid)) ->
              begin
                match ptymain1 with
                | DataType(TypeID.Opaque(oid1), ptyargs1) ->
                    if  TypeID.Opaque.equal oid oid1 then
                      aux_list ptyargs1 ptyargs2
                    else
                      false

                | _ ->
                    false
              end
        end

    | _ ->
        false

  and aux_list ptys1 ptys2 =
    match List.combine ptys1 ptys2 with
    | exception Invalid_argument(_) ->
        false

    | ptypairs ->
        ptypairs |> List.fold_left (fun bacc (pty1, pty2) ->
          let b = aux pty1 pty2 in
          bacc && b
        ) true

  and aux_base_kind pbkd1 pbkd2 =
    match (pbkd1, pbkd2) with
    | (UniversalKind, _) ->
        true

    | (RecordKind(_), UniversalKind) ->
        false

    | (RecordKind(plabmap1), RecordKind(plabmap2)) ->
        subtype_label_assoc wtmap internbid internbrid plabmap1 plabmap2

  and aux_label_assoc plabmap1 plabmap2 =
    LabelAssoc.merge (fun _ ptyopt1 ptyopt2 ->
      match (ptyopt1, ptyopt2) with
      | (None, None)             -> None
      | (Some(pty1), Some(pty2)) -> Some(aux pty1 pty2)
      | _                        -> Some(false)
    ) plabmap1 plabmap2 |> LabelAssoc.for_all (fun _ b -> b)

  and aux_domain domain1 domain2 =
    let {ordered = ptydoms1; mandatory = mndlabmap1; optional = poptrow1} = domain1 in
    let {ordered = ptydoms2; mandatory = mndlabmap2; optional = poptrow2} = domain2 in
    let b1 = aux_list ptydoms1 ptydoms2 in
    let bmnd = aux_label_assoc mndlabmap1 mndlabmap2 in
    let bopt = subtype_option_row wtmap internbid internbrid poptrow1 poptrow2 in
    b1 && bmnd && bopt

  and aux_pid (Pid(pty1)) (Pid(pty2)) =
    aux pty1 pty2

  and aux_effect (Effect(pty1)) (Effect(pty2)) =
    aux pty1 pty2
  in
  aux pty1 pty2


and subtype_label_assoc (wtmap : WitnessMap.t) (internbid : BoundID.t -> poly_type -> bool) (internbrid : BoundRowID.t -> poly_row -> bool) (plabmap1 : poly_type LabelAssoc.t) (plabmap2 : poly_type LabelAssoc.t) =
  LabelAssoc.fold (fun label pty1 b ->
    if not b then
      false
    else
      match plabmap2 |> LabelAssoc.find_opt label with
      | None       -> false
      | Some(pty2) -> subtype_poly_type_scheme wtmap internbid internbrid pty1 pty2
  ) plabmap1 true


and subtype_option_row (wtmap : WitnessMap.t) (internbid : BoundID.t -> poly_type -> bool) (internbrid : BoundRowID.t -> poly_row -> bool) (poptrow1 : poly_row) (poptrow2 : poly_row) : bool =
(*
  Format.printf "subtype_option_row: %a <?= %a\n" pp_poly_row poptrow1 pp_poly_row poptrow2;  (* for debug *)
*)

  let aux_label_assoc =
    subtype_label_assoc wtmap internbid internbrid
  in

  let aux poptrow1 poptrow2 =
    match (poptrow1, poptrow2) with
    | (RowVar(MonoRow(_)), _)
    | (_, RowVar(MonoRow(_))) ->
        assert false

    | (FixedRow(plabmap1), FixedRow(plabmap2)) ->
        aux_label_assoc plabmap1 plabmap2

    | (FixedRow(_), RowVar(_)) ->
        false

    | (RowVar(BoundRow(brid1)), FixedRow(plabmap2)) ->
        (* First check that the kind of `brid1` is more general than (or equal to) `prow2`. *)
        let plabmap1 = KindStore.get_bound_row brid1 in
        if aux_label_assoc plabmap1 plabmap2 then
          internbrid brid1 poptrow2
        else
          false

    | (RowVar(BoundRow(brid1)), RowVar(BoundRow(brid2))) ->
        (* First check that the kind of `brid1` is more general than (or equal to) that of `brid2`. *)
        let plabmap1 = KindStore.get_bound_row brid1 in
        let plabmap2 = KindStore.get_bound_row brid2 in
        if aux_label_assoc plabmap1 plabmap2 then
          internbrid brid1 poptrow2
        else
          false
  in
  aux poptrow1 poptrow2


and subtype_poly_type (wtmap : WitnessMap.t) (pty1 : poly_type) (pty2 : poly_type) : bool =
(*
  Format.printf "subtype_poly_type: %a <?= %a\n" TypeConv.pp_poly_type pty1 TypeConv.pp_poly_type pty2;  (* for debug *)
*)
  let bidht = BoundIDHashTable.create 32 in
  let bridht = BoundRowIDHashTable.create 32 in
  let internbid (bid1 : BoundID.t) (pty2 : poly_type) : bool =
    match BoundIDHashTable.find_opt bidht bid1 with
    | None ->
        BoundIDHashTable.add bidht bid1 pty2;
        true

    | Some(pty) ->
        poly_type_equal pty pty2
  in
  let internbrid (brid1 : BoundRowID.t) (prow2 : poly_row) : bool =
(*
    Format.printf "internbrid: %a --> %a\n" BoundRowID.pp brid1 pp_poly_row prow2;  (* for debug *)
*)
    match BoundRowIDHashTable.find_opt bridht brid1 with
    | None ->
        BoundRowIDHashTable.add bridht brid1 prow2;
        true

    | Some(prow) ->
        poly_row_equal prow prow2
  in
  subtype_poly_type_scheme wtmap internbid internbrid pty1 pty2


and poly_row_equal (prow1 : poly_row) (prow2 : poly_row) : bool =
  match (prow1, prow2) with
  | (RowVar(MonoRow(_)), _)
  | (_, RowVar(MonoRow(_))) ->
      assert false

  | (RowVar(BoundRow(brid1)), RowVar(BoundRow(brid2))) ->
      BoundRowID.equal brid1 brid2

  | (FixedRow(plabmap1), FixedRow(plabmap2)) ->
      LabelAssoc.merge (fun _ ptyopt1 ptyopt2 ->
        match (ptyopt1, ptyopt2) with
        | (None, None)             -> None
        | (Some(pty1), Some(pty2)) -> Some(poly_type_equal pty1 pty2)
        | _                        -> Some(false)
      ) plabmap1 plabmap2 |> LabelAssoc.for_all (fun _ b -> b)

  | _ ->
      false


and poly_type_equal (pty1 : poly_type) (pty2 : poly_type) : bool =

  let aux_label_assoc = poly_label_assoc_equal in

  let rec aux (pty1 : poly_type) (pty2 : poly_type) : bool =
    let (_, ptymain1) = pty1 in
    let (_, ptymain2) = pty2 in
    match (ptymain1, ptymain2) with
    | (DataType(TypeID.Synonym(sid1), ptyargs1), _) ->
        let pty1real = TypeConv.get_real_poly_type sid1 ptyargs1 in
        aux pty1real pty2

    | (_, DataType(TypeID.Synonym(sid2), ptyargs2)) ->
        let pty2real = TypeConv.get_real_poly_type sid2 ptyargs2 in
        aux pty1 pty2real

    | (DataType(TypeID.Opaque(oid1), ptyargs1), DataType(TypeID.Opaque(oid2), ptyargs2)) ->
        TypeID.Opaque.equal oid1 oid2 && aux_list ptyargs1 ptyargs2

    | (BaseType(bty1), BaseType(bty2)) ->
        bty1 = bty2

    | (FuncType(pdomain1, pty1cod), FuncType(pdomain2, pty2cod)) ->
        let bdom = aux_domain pdomain1 pdomain2 in
        bdom && aux pty1cod pty2cod

    | (EffType(pdomain1, peff1, ptysub1), EffType(pdomain2, peff2, ptysub2)) ->
        let bdom = aux_domain pdomain1 pdomain2 in
        bdom && aux_effect peff1 peff2 && aux ptysub1 ptysub2

    | (PidType(ppidty1), PidType(ppidty2)) ->
        aux_pid_type ppidty1 ppidty2

    | (ProductType(ptys1), ProductType(ptys2)) ->
        aux_list (ptys1 |> TupleList.to_list) (ptys2 |> TupleList.to_list)

    | (RecordType(plabmap1), RecordType(plabmap2)) ->
        aux_label_assoc plabmap1 plabmap2

    | (DataType(TypeID.Variant(vid1), ptyargs1), DataType(TypeID.Variant(vid2), ptyargs2)) ->
        TypeID.Variant.equal vid1 vid2 && aux_list ptyargs1 ptyargs2

    | (TypeVar(Bound(bid1)), TypeVar(Bound(bid2))) ->
        BoundID.equal bid1 bid2

    | (TypeVar(Mono(_)), _)
    | (_, TypeVar(Mono(_))) ->
        assert false

    | _ ->
        false

  and aux_list tys1 tys2 =
    try
      List.fold_left2 (fun b ty1 ty2 -> b && aux ty1 ty2) true tys1 tys2
    with
    | Invalid_argument(_) -> false

  and aux_domain pdomain1 pdomain2 =
    let {ordered = pty1doms; mandatory = pmndlabmap1; optional = poptrow1} = pdomain1 in
    let {ordered = pty2doms; mandatory = pmndlabmap2; optional = poptrow2} = pdomain2 in
    aux_list pty1doms pty2doms && aux_label_assoc pmndlabmap1 pmndlabmap2 && aux_option_row poptrow1 poptrow2

  and aux_effect (Effect(pty1)) (Effect(pty2)) =
    aux pty1 pty2

  and aux_pid_type (Pid(pty1)) (Pid(pty2)) =
    aux pty1 pty2

  and aux_option_row poptrow1 poptrow2 =
    match (poptrow1, poptrow2) with
    | (RowVar(MonoRow(_)), _)
    | (_, RowVar(MonoRow(_))) ->
        assert false

    | (RowVar(BoundRow(brid1)), RowVar(BoundRow(brid2))) ->
        BoundRowID.equal brid1 brid2

    | (FixedRow(plabmap1), FixedRow(plabmap2)) ->
        aux_label_assoc plabmap1 plabmap2

    | _ ->
        false

  in
  aux pty1 pty2


and poly_label_assoc_equal plabmap1 plabmap2 =
  let merged =
    LabelAssoc.merge (fun _ ptyopt1 ptyopt2 ->
      match (ptyopt1, ptyopt2) with
      | (None, None)             -> None
      | (None, Some(_))          -> Some(false)
      | (Some(_), None)          -> Some(false)
      | (Some(pty1), Some(pty2)) -> Some(poly_type_equal pty1 pty2)
    ) plabmap1 plabmap2
  in
  merged |> LabelAssoc.for_all (fun _ b -> b)


and subtype_type_abstraction (wtmap : WitnessMap.t) (ptyfun1 : BoundID.t list * poly_type) (ptyfun2 : BoundID.t list * poly_type) : bool =
  let (typarams1, pty1) = ptyfun1 in
  let (typarams2, pty2) = ptyfun2 in
(*
  Format.printf "subtype_type_abstraction: %a <?= %a\n" pp_poly_type pty1 pp_poly_type pty2;  (* for debug *)
*)
  match List.combine typarams1 typarams2 with
  | exception Invalid_argument(_) ->
      false

  | typarampairs ->
      let map =
        typarampairs |> List.fold_left (fun map (bid1, bid2) ->
          map |> BoundIDMap.add bid2 bid1
        ) BoundIDMap.empty
      in
      let internbid (bid1 : BoundID.t) (pty2 : poly_type) : bool =
        match pty2 with
        | (_, TypeVar(Bound(bid2))) ->
            begin
              match map |> BoundIDMap.find_opt bid1 with
              | None      -> false
              | Some(bid) -> BoundID.equal bid bid2
            end

        | _ ->
            false
      in
      let internbrid (brid1 : BoundRowID.t) (prow2 : poly_row) : bool =
        (* TODO: implement this when type definitions become able to take row parameters *)
        false
      in
      subtype_poly_type_scheme wtmap internbid internbrid pty1 pty2


and lookup_type_opacity (tynm : type_name) (tyopac1 : type_opacity) (tyopac2 : type_opacity) : WitnessMap.t option =
  let (tyid1, arity1) = tyopac1 in
  let (tyid2, arity2) = tyopac2 in
  if arity1 <> arity2 then
    None
  else
    match (tyid1, tyid2) with
    | (_, TypeID.Opaque(oid2)) ->
(*
        Format.printf "lookup_type_opacity> %a <= %a\n" TypeID.pp tyid1 TypeID.pp tyid2;  (* for debug *)
*)
        Some(WitnessMap.empty |> WitnessMap.add_opaque oid2 tyid1)

    | (TypeID.Variant(vid1), TypeID.Variant(vid2)) ->
(*
        Format.printf "lookup_type_opacity> %a --> %a\n"
          TypeID.Variant.pp vid1
          TypeID.Variant.pp vid2;  (* for debug *)
*)
        Some(WitnessMap.empty |> WitnessMap.add_variant vid2 vid1)

    | (TypeID.Synonym(sid1), TypeID.Synonym(sid2)) ->
(*
        Format.printf "lookup_type_opacity> %a --> %a\n"
          TypeID.Synonym.pp sid1
          TypeID.Synonym.pp sid2;  (* for debug *)
*)
        Some(WitnessMap.empty |> WitnessMap.add_synonym sid2 sid1)

    | _ ->
        None


and lookup_record (rng : Range.t) (modsig1 : module_signature) (modsig2 : module_signature) : WitnessMap.t =
    match (modsig1, modsig2) with
    | (ConcStructure(sigr1), ConcStructure(sigr2)) ->
        (* Performs signature matching by looking up signatures `sigr1` and `sigr2`,
           and associate type IDs in them
           so that we can check whether subtyping relation `sigr1 <= sigr2` holds.
           Here we do not check each type IDs indeed form a subtyping relation;
           it will be done by `check_well_formedness_of_witness_map` afterwards.
        *)
        sigr2 |> SigRecord.fold
            ~v:(fun x2 (pty2, gname2) wtmapacc ->
              match sigr1 |> SigRecord.find_val x2 with
              | None    -> raise_error (MissingRequiredValName(rng, x2, pty2))
              | Some(_) -> wtmapacc
            )
            ~t:(fun tydefs2 wtmapacc ->
              tydefs2 |> List.fold_left (fun wtmapacc (tynm2, tyopac2) ->
                match sigr1 |> SigRecord.find_type tynm2 with
                | None ->
                    raise_error (MissingRequiredTypeName(rng, tynm2, tyopac2))

                | Some(tyopac1) ->
                    begin
                      match lookup_type_opacity tynm2 tyopac1 tyopac2 with
                      | None        -> raise_error (NotASubtypeTypeOpacity(rng, tynm2, tyopac1, tyopac2))
                      | Some(wtmap) -> WitnessMap.union wtmapacc wtmap
                    end
              ) wtmapacc
            )
            ~m:(fun modnm2 (modsig2, _) wtmapacc ->
              match sigr1 |> SigRecord.find_module modnm2 with
              | None ->
                  raise_error (MissingRequiredModuleName(rng, modnm2, modsig2))

              | Some(modsig1, _) ->
                  let wtmap = lookup_record rng modsig1 modsig2 in
                  WitnessMap.union wtmapacc wtmap
            )
            ~s:(fun _ _ wtmapacc ->
              wtmapacc
            )
            WitnessMap.empty

    | _ ->
        WitnessMap.empty


(* Given `wtmap`, which was produced by `lookup_record`, this function checks whether

   - for each mapping (`vid1` ↦ `vid2`) of variant IDs in `wtmap`,
     the definition of `vid1` is indeed more specific than that of `vid2`, and

   - for each mapping (`sid1` ↦ `sid2`) of synonym IDs in `wtmap`,
     the definition of `sid1` is indeed more specific than that of `sid2`.
*)
and check_well_formedness_of_witness_map (rng : Range.t) (wtmap : WitnessMap.t) : unit =
  let mergef vid1 vid2
      (ctor : constructor_name)
      (opt1 : (ConstructorID.t * poly_type list) option)
      (opt2 : (ConstructorID.t * poly_type list) option) =
    match (opt1, opt2) with
    | (None, _)                -> raise_error (NotASubtypeVariant(rng, vid1, vid2, ctor))
    | (_, None)                -> raise_error (NotASubtypeVariant(rng, vid1, vid2, ctor))
    | (Some(def1), Some(def2)) -> Some(def1, def2)
  in
  wtmap |> WitnessMap.fold
      ~variant:(fun vid2 vid1 () ->
        let (typarams1, ctorbrs1) = TypeDefinitionStore.find_variant_type vid1 in
        let (typarams2, ctorbrs2) = TypeDefinitionStore.find_variant_type vid2 in
        let brpairs = ConstructorMap.merge (mergef vid1 vid2) ctorbrs1 ctorbrs2 in
        brpairs |> ConstructorMap.iter (fun ctor (def1, def2) ->
          let (_, ptyargs1) = def1 in
          let (_, ptyargs2) = def2 in
          match List.combine ptyargs1 ptyargs2 with
          | exception Invalid_argument(_) ->
              raise_error (NotASubtypeVariant(rng, vid1, vid2, ctor))

          | ptyargpairs ->
              ptyargpairs |> List.iter (fun (ptyarg1, ptyarg2) ->
                let ptyfun1 = (typarams1, ptyarg1) in
                let ptyfun2 = (typarams2, ptyarg2) in
                if subtype_type_abstraction wtmap ptyfun1 ptyfun2 then
                  ()
                else
                  raise_error (NotASubtypeVariant(rng, vid1, vid2, ctor))
              )
        )
      )
      ~synonym:(fun sid2 sid1 () ->
        let ptyfun1 = TypeDefinitionStore.find_synonym_type sid1 in
        let ptyfun2 = TypeDefinitionStore.find_synonym_type sid2 in
        if subtype_type_abstraction wtmap ptyfun1 ptyfun2 then
          ()
        else
          raise_error (NotASubtypeSynonym(rng, sid1, sid2))
      )
      ~opaque:(fun oid2 tyid1 () ->
        ()
          (* The consistency of arity has already been checked by `lookup_record`. *)
      )
      ()


and subtype_abstract_with_abstract (address : address) (rng : Range.t) (absmodsig1 : module_signature abstracted) (absmodsig2 : module_signature abstracted) : unit =
  let (_, modsig1) = absmodsig1 in
  let _ = subtype_concrete_with_abstract address rng modsig1 absmodsig2 in
  ()


(* `subtype_concrete_with_concrete rng wtmap modsig1 modsig2` asserts that
   `modsig1 <= [wtmap]modsig2` holds (where `[-]-` is the application of a substitution). *)
and subtype_concrete_with_concrete (address : address) (rng : Range.t) (wtmap : WitnessMap.t) (modsig1 : module_signature) (modsig2 : module_signature) : unit =
  match (modsig1, modsig2) with
  | (ConcFunctor(sigftor1), ConcFunctor(sigftor2)) ->
      let (oidset1, Domain(sigr1), absmodsigcod1) = (sigftor1.opaques, sigftor1.domain, sigftor1.codomain) in
      let (oidset2, Domain(sigr2), absmodsigcod2) = (sigftor2.opaques, sigftor2.domain, sigftor2.codomain) in
      let wtmap =
        let modsigdom1 = ConcStructure(sigr1) in
        let modsigdom2 = ConcStructure(sigr2) in
        subtype_concrete_with_abstract address rng modsigdom2 (oidset1, modsigdom1)
      in
      let (absmodsigcod1, _) = absmodsigcod1 |> substitute_abstract address wtmap in
      subtype_abstract_with_abstract address rng absmodsigcod1 absmodsigcod2

  | (ConcStructure(sigr1), ConcStructure(sigr2)) ->
      sigr2 |> SigRecord.fold
          ~v:(fun x2 (pty2, _) () ->
            match sigr1 |> SigRecord.find_val x2 with
            | None ->
                raise_error (MissingRequiredValName(rng, x2, pty2))

            | Some(pty1, _) ->
               if subtype_poly_type wtmap pty1 pty2 then
                 ()
               else
                 raise_error (PolymorphicContradiction(rng, x2, pty1, pty2))
          )
          ~t:(fun _ () ->
            ()
          )
          ~m:(fun modnm2 (modsig2, _) () ->
            match sigr1 |> SigRecord.find_module modnm2 with
            | None ->
                raise_error (MissingRequiredModuleName(rng, modnm2, modsig2))

            | Some(modsig1, _) ->
                subtype_concrete_with_concrete address rng wtmap modsig1 modsig2
          )
          ~s:(fun signm2 absmodsig2 () ->
            match sigr1 |> SigRecord.find_signature signm2 with
            | None ->
                raise_error (MissingRequiredSignatureName(rng, signm2, absmodsig2))

            | Some(absmodsig1) ->
                subtype_abstract_with_abstract address rng absmodsig1 absmodsig2;
                subtype_abstract_with_abstract address rng absmodsig2 absmodsig1;
                ()
          )
          ()

  | _ ->
      raise_error (NotASubtype(rng, modsig1, modsig2))


and subtype_concrete_with_abstract (address : address) (rng : Range.t) (modsig1 : module_signature) (absmodsig2 : module_signature abstracted) : WitnessMap.t =
  let (oidset2, modsig2) = absmodsig2 in
  let wtmap = lookup_record rng modsig1 modsig2 in
  check_well_formedness_of_witness_map rng wtmap;
  let (modsig2, wtmap) = modsig2 |> substitute_concrete address wtmap in
  subtype_concrete_with_concrete address rng wtmap modsig1 modsig2;
  wtmap


and subtype_signature (address : address) (rng : Range.t) (modsig1 : module_signature) (absmodsig2 : module_signature abstracted) : WitnessMap.t =
  subtype_concrete_with_abstract address rng modsig1 absmodsig2


and substitute_concrete (address : address) (wtmap : WitnessMap.t) (modsig : module_signature) : module_signature * WitnessMap.t =
  match modsig with
  | ConcFunctor(sigftor) ->
      let (oidset, Domain(sigr), absmodsigcod) = (sigftor.opaques, sigftor.domain, sigftor.codomain) in
      let (sigr, wtmap) = sigr |> substitute_structure address wtmap in
      let (absmodsigcod, wtmap) = absmodsigcod |> substitute_abstract address wtmap in
      let sigftor =
        { sigftor with
          opaques  = oidset;
          domain   = Domain(sigr);
          codomain = absmodsigcod;
        }
      in
      (ConcFunctor(sigftor), wtmap)
        (* Strictly speaking, we should assert that `oidset` and the domain of `wtmap` be disjoint. *)

  | ConcStructure(sigr) ->
      let (sigr, wtmap) = sigr |> substitute_structure address wtmap in
      (ConcStructure(sigr), wtmap)


(* Given `modsig1` and `modsig2` which are already known to satisfy `modsig1 <= modsig2`,
   `copy_closure` copies every closure and every global name occurred in `modsig1`
   into the corresponding occurrence in `modsig2`. *)
and copy_closure (modsig1 : module_signature) (modsig2 : module_signature) : module_signature =
  match (modsig1, modsig2) with
  | (ConcStructure(sigr1), ConcStructure(sigr2)) ->
      let sigr2new = copy_closure_in_structure sigr1 sigr2 in
      ConcStructure(sigr2new)

  | (ConcFunctor(sigftor1), ConcFunctor(sigftor2)) ->
      let Domain(sigrdom1) = sigftor1.domain in
      let Domain(sigrdom2) = sigftor2.domain in
      let sigrdom2new = copy_closure_in_structure sigrdom1 sigrdom2 in
      let (_, modsig1) = sigftor1.codomain in
      let (oidset2, modsig2) = sigftor2.codomain in
      let modsig2new = copy_closure modsig1 modsig2 in
      ConcFunctor({ sigftor2 with
        domain   = Domain(sigrdom2new);
        codomain = (oidset2, modsig2new);
        closure  = sigftor1.closure;
      })

  | _ ->
      assert false


and copy_closure_in_structure (sigr1 : SigRecord.t) (sigr2 : SigRecord.t) : SigRecord.t =
  sigr2 |> SigRecord.map
    ~v:(fun x (pty2, gname2) ->
      match sigr1 |> SigRecord.find_val x with
      | None              -> assert false
      | Some((_, gname1)) -> (pty2, gname1)
    )
    ~t:(fun tydefs -> tydefs |> List.map (fun (_, tyopac) -> tyopac))
    ~s:(fun _ sentry -> sentry)
    ~m:(fun modnm (modsig2, _) ->
      match sigr1 |> SigRecord.find_module modnm with
      | None ->
          assert false

      | Some((modsig1, sname1)) ->
          let modsig2new = copy_closure modsig1 modsig2 in
          (modsig2new, sname1)
    )


and substitute_structure (address : address) (wtmap : WitnessMap.t) (sigr : SigRecord.t) : SigRecord.t * WitnessMap.t =
    sigr |> SigRecord.map_and_fold
        ~v:(fun _ (pty, gname) wtmap ->
          let ventry = (substitute_poly_type wtmap pty, gname) in
          (ventry, wtmap)
        )
        ~t:(fun tydefs_from wtmap ->

          (* Apply the substitution `wtmap` or else
             generate new type IDs that will be used after substitution. *)
          let wtmap =
            tydefs_from |> List.fold_left (fun wtmap (_, (tyid_from, arity)) ->
              match tyid_from with
              | TypeID.Synonym(sid_from) ->
                  let sid_to =
                    match wtmap |> WitnessMap.find_synonym sid_from with
                    | Some(sid_to) ->
                        sid_to

                    | None ->
                        let s = TypeID.Synonym.name sid_from in
                        TypeID.Synonym.fresh (Alist.to_list address) s
                  in
(*
                  Format.printf "substitute_structure> %a --> %a\n"
                    TypeID.Synonym.pp sid_from
                    TypeID.Synonym.pp sid_to;  (* for debug *)
*)
                  wtmap |> WitnessMap.add_synonym sid_from sid_to

              | TypeID.Variant(vid_from) ->
                  let vid_to =
                    match wtmap |> WitnessMap.find_variant vid_from with
                    | Some(vid_from) ->
                        vid_from

                    | None ->
                        let s = TypeID.Variant.name vid_from in
                        TypeID.Variant.fresh (Alist.to_list address) s
                  in
(*
                  Format.printf "substitute_structure> %a --> %a\n"
                    TypeID.Variant.pp vid_from
                    TypeID.Variant.pp vid_to;  (* for debug *)
*)
                  wtmap |> WitnessMap.add_variant vid_from vid_to

              | TypeID.Opaque(_) ->
                  wtmap
            ) wtmap
          in

          (* Replace all occurrences of the old type IDs *)
          let tyopacs_to =
            tydefs_from |> List.map (fun (_, (tyid_from, arity)) ->
              match tyid_from with
              | TypeID.Synonym(sid_from) ->
                  let (typarams, ptyreal_from) = TypeDefinitionStore.find_synonym_type sid_from in
                  let ptyreal_to = ptyreal_from |> substitute_poly_type wtmap in
                  begin
                    match wtmap |> WitnessMap.find_synonym sid_from with
                    | None ->
                        assert false

                    | Some(sid_to) ->
                        TypeDefinitionStore.add_synonym_type sid_to typarams ptyreal_to;
                        (TypeID.Synonym(sid_to), arity)
                  end

              | TypeID.Variant(vid_from) ->
                  begin
                    match wtmap |> WitnessMap.find_variant vid_from with
                    | None ->
                        assert false

                    | Some(vid_to) ->
                        let (typarams, ctorbrs_from) = TypeDefinitionStore.find_variant_type vid_from in
                        let ctorbrs_to =
                          ConstructorMap.fold (fun ctornm (ctorid_from, ptyargs_from) ctorbrs_to ->
                            let ptyargs_to = ptyargs_from |> List.map (substitute_poly_type wtmap) in
                            let ctorid_to = ctorid_from in
                            ctorbrs_to |> ConstructorMap.add ctornm (ctorid_to, ptyargs_to)
                          ) ctorbrs_from ConstructorMap.empty
                        in
                        TypeDefinitionStore.add_variant_type vid_to typarams ctorbrs_to;
                        (TypeID.Variant(vid_to), arity)
                  end

              | TypeID.Opaque(oid) ->
                  begin
                    match wtmap |> WitnessMap.find_opaque oid with
                    | None          -> (tyid_from, arity)
                    | Some(tyid_to) -> (tyid_to, arity)
                  end
            )
          in
          (tyopacs_to, wtmap)
        )
        ~m:(fun _ (modsig, name) wtmap ->
          let (modsig, wtmap) = substitute_concrete address wtmap modsig in
          let mentry = (modsig, name) in
          (mentry, wtmap)
        )
        ~s:(fun _ absmodsig wtmap ->
          let (absmodsig, wtmap) = substitute_abstract address wtmap absmodsig in
          (absmodsig, wtmap)
        )
        wtmap


and substitute_abstract (address : address) (wtmap : WitnessMap.t) (absmodsig : module_signature abstracted) : module_signature abstracted * WitnessMap.t =
  let (oidset, modsig) = absmodsig in
  let (modsig, wtmap) = substitute_concrete address wtmap modsig in
  ((oidset, modsig), wtmap)
    (* Strictly speaking, we should assert that `oidset` and the domain of `wtmap` be disjoint. *)


and substitute_poly_type (wtmap : WitnessMap.t) (pty : poly_type) : poly_type =
  let rec aux (rng, ptymain) =
    let ptymain =
      match ptymain with
      | BaseType(_)               -> ptymain
      | PidType(ppid)             -> PidType(aux_pid ppid)
      | TypeVar(_)                -> ptymain
      | ProductType(ptys)         -> ProductType(ptys |> TupleList.map aux)

      | EffType(pdomain, peff, ptysub) ->
          EffType(aux_domain pdomain, aux_effect peff, aux ptysub)

      | FuncType(pdomain, ptycod) ->
          FuncType(aux_domain pdomain, aux ptycod)

      | RecordType(labmap) ->
          RecordType(labmap |> LabelAssoc.map aux)

      | DataType(TypeID.Opaque(oid_from), ptyargs) ->
          begin
            match wtmap |> WitnessMap.find_opaque oid_from with
            | None          -> DataType(TypeID.Opaque(oid_from), ptyargs |> List.map aux)
            | Some(tyid_to) -> DataType(tyid_to, ptyargs |> List.map aux)
          end

      | DataType(TypeID.Synonym(sid_from), ptyargs) ->
          begin
            match wtmap |> WitnessMap.find_synonym sid_from with
            | None         -> DataType(TypeID.Synonym(sid_from), ptyargs |> List.map aux)
                (* TODO: DOUBTFUL; maybe we must traverse the definition of type synonyms beforehand.
                   → The replacement probably has been properly done by `substitute_structure`. *)
            | Some(sid_to) -> DataType(TypeID.Synonym(sid_to), ptyargs |> List.map aux)
          end

      | DataType(TypeID.Variant(vid_from), ptyargs) ->
          begin
            match wtmap |> WitnessMap.find_variant vid_from with
            | None         -> DataType(TypeID.Variant(vid_from), ptyargs |> List.map aux)
                (* TODO: DOUBTFUL; maybe we must traverse the definition of variant types beforehand.
                   → The replacement probably has been properly done by `substitute_structure`. *)
            | Some(vid_to) -> DataType(TypeID.Variant(vid_to), ptyargs |> List.map aux)
          end
    in
    (rng, ptymain)

  and aux_domain pdomain =
    let {ordered = ptydoms; mandatory = pmndlabmap; optional = poptrow} = pdomain in
    {
      ordered   = ptydoms |> List.map aux;
      mandatory = pmndlabmap |> LabelAssoc.map aux;
      optional  = aux_option_row poptrow;
    }

  and aux_pid = function
    | Pid(pty) -> Pid(aux pty)

  and aux_effect = function
    | Effect(pty) -> Effect(aux pty)

  and aux_option_row (poptrow : poly_row) =
    match poptrow with
    | RowVar(_)         -> poptrow
    | FixedRow(plabmap) -> FixedRow(plabmap |> LabelAssoc.map aux)
  in
  aux pty


and typecheck_declaration (address : address) (tyenv : Typeenv.t) (utdecl : untyped_declaration) : SigRecord.t abstracted =
  let (_, utdeclmain) = utdecl in
  match utdeclmain with
  | DeclVal((_, x), typarams, rowparams, mty) ->
      let pre =
        let pre_init =
          {
            level                 = 0;
            tyenv                 = tyenv;
            local_type_parameters = TypeParameterMap.empty;
            local_row_parameters  = RowParameterMap.empty;
          }
        in
        let (pre, _) = make_type_parameter_assoc pre_init typarams in
        { pre with level = 1 } |> add_local_row_parameter rowparams
      in
      let ty = decode_manual_type pre mty in
      let pty =
        match TypeConv.generalize 0 ty with
        | Ok(pty)  -> pty
        | Error(_) -> assert false
            (* Type parameters occurring in handwritten types cannot be cyclic. *)
      in
      let gname = OutputIdentifier.fresh_global_dummy () in
      let sigr = SigRecord.empty |> SigRecord.add_val x pty gname in
      (OpaqueIDSet.empty, sigr)

  | DeclTypeOpaque(tyident, kdannot) ->
      let (_, tynm) = tyident in
      let pre_init =
        {
          level                 = 0;
          tyenv                 = tyenv;
          local_type_parameters = TypeParameterMap.empty;
          local_row_parameters  = RowParameterMap.empty;
        }
      in
      let mkd =
        match kdannot with
        | None       -> Kind([], UniversalKind)
        | Some(mnkd) -> decode_manual_kind pre_init mnkd
      in
      let oid = TypeID.Opaque.fresh (Alist.to_list address) tynm in
      let sigr = SigRecord.empty |> SigRecord.add_opaque_type tynm oid (TypeConv.lift_kind mkd) in
      (OpaqueIDSet.singleton oid, sigr)

  | DeclModule(modident, utsig) ->
      let (rngm, m) = modident in
      let absmodsig = typecheck_signature address tyenv utsig in
      let (oidset, modsig) = absmodsig in
      let sname = get_space_name rngm m in
      let sigr = SigRecord.empty |> SigRecord.add_module m modsig sname in
      (oidset, sigr)

  | DeclSig(sigident, utsig) ->
      let (_, signm) = sigident in
      let absmodsig = typecheck_signature address tyenv utsig in
      let sigr = SigRecord.empty |> SigRecord.add_signature signm absmodsig in
      (OpaqueIDSet.empty, sigr)

  | DeclInclude(utsig) ->
      let absmodsig = typecheck_signature address tyenv utsig in
      let (oidset, modsig) = absmodsig in
      begin
        match modsig with
        | ConcFunctor(_) ->
            let (rng, _) = utsig in
            raise_error (NotAStructureSignature(rng, modsig))

        | ConcStructure(sigr) ->
            (oidset, sigr)
      end


and typecheck_declaration_list (address : address) (tyenv : Typeenv.t) (utdecls : untyped_declaration list) : SigRecord.t abstracted =
  let (oidsetacc, sigracc, _) =
    utdecls |> List.fold_left (fun (oidsetacc, sigracc, tyenv) ((rng, _) as utdecl) ->
      let (oidset, sigr) = typecheck_declaration address tyenv utdecl in
      let oidsetacc = OpaqueIDSet.union oidsetacc oidset in
      let sigracc =
        match SigRecord.disjoint_union sigracc sigr with
        | Ok(sigr) -> sigr
        | Error(s) -> raise_error (ConflictInSignature(rng, s))
      in
      let tyenv = tyenv |> update_type_environment_by_signature_record sigr in
      (oidsetacc, sigracc, tyenv)
    ) (OpaqueIDSet.empty, SigRecord.empty, tyenv)
  in
  (oidsetacc, sigracc)


and copy_abstract_signature (address : address) (absmodsig_from : module_signature abstracted) : module_signature abstracted * WitnessMap.t =
  let (oidset_from, modsig_from) = absmodsig_from in
  let (oidset_to, wtmap) =
    OpaqueIDSet.fold (fun oid_from (oidset_to, wtmap) ->
      let oid_to =
        let s = TypeID.Opaque.name oid_from in
        TypeID.Opaque.fresh (Alist.to_list address) s
      in
      let oidset_to = oidset_to |> OpaqueIDSet.add oid_to in
      let wtmap = wtmap |> WitnessMap.add_opaque oid_from (TypeID.Opaque(oid_to)) in
      (oidset_to, wtmap)
    ) oidset_from (OpaqueIDSet.empty, WitnessMap.empty)
  in
  let (modsig_to, wtmap) = substitute_concrete address wtmap modsig_from in
  ((oidset_to, modsig_to), wtmap)


and typecheck_signature (address : address) (tyenv : Typeenv.t) (utsig : untyped_signature) : module_signature abstracted =
  let (rng, utsigmain) = utsig in
  match utsigmain with
  | SigVar(signm) ->
      begin
        match tyenv |> Typeenv.find_signature signm with
        | None ->
            raise_error (UnboundSignatureName(rng, signm))

        | Some(absmodsig_from) ->
            let (absmodsig_to, _) = copy_abstract_signature address absmodsig_from in
            absmodsig_to
              (* We need to rename opaque IDs here, since otherwise
                 we would mistakenly make the following program pass:

                 ```
                 signature S = sig
                   type t:: 0
                 end

                 module F = fun(X: S) -> fun(Y: S) -> struct
                   type f(x: X.t): Y.t = x
                 end
                 ```

                 This issue was reported by `@elpinal`:
                 https://twitter.com/elpin1al/status/1269198048967589889?s=20
              *)
      end

  | SigPath(utmod1, sigident2) ->
      let (absmodsig1, _e) = typecheck_module Alist.empty tyenv utmod1 in
      let (oidset1, modsig1) = absmodsig1 in
      begin
        match modsig1 with
        | ConcFunctor(_) ->
            let (rng1, _) = utmod1 in
            raise_error (NotOfStructureType(rng1, modsig1))

        | ConcStructure(sigr1) ->
            let (rng2, signm2) = sigident2 in
            begin
              match sigr1 |> SigRecord.find_signature signm2 with
              | None ->
                  raise_error (UnboundSignatureName(rng2, signm2))

              | Some((_, modsig2) as absmodsig2) ->
                  if opaque_occurs oidset1 modsig2 then
                    raise_error (OpaqueIDExtrudesScopeViaSignature(rng, absmodsig2))
                  else
                    absmodsig2
                    (* Combining typing rules (P-Mod) and (S-Path)
                       in the original paper "F-ing modules" [Rossberg, Russo & Dreyer 2014],
                       we can ignore `oidset1` here.
                       However, we CANNOT SIMPLY ignore `oidset1`;
                       according to the second premise “Γ ⊢ Σ : Ω” of (P-Mod),
                       we must assert `absmodsig2` do not contain every type variable in `oidset1`.
                       (we have again realized this thanks to `@elpinal`.)
                       https://twitter.com/elpin1al/status/1272110415435010048?s=20
                     *)
            end
      end

  | SigDecls(utdecls) ->
      let (oidset, sigr) = typecheck_declaration_list address tyenv utdecls in
      (oidset, ConcStructure(sigr))

  | SigFunctor(modident, utsigdom, utsigcod) ->
      let (oidset, sigdom) = typecheck_signature Alist.empty tyenv utsigdom in
      let abssigcod =
        let (rngm, m) = modident in
        let sname = get_space_name rngm m in
        let tyenv = tyenv |> Typeenv.add_module m sigdom sname in
        typecheck_signature Alist.empty tyenv utsigcod
      in
      begin
        match sigdom with
        | ConcStructure(sigr) ->
            let sigftor =
              {
                opaques  = oidset;
                domain   = Domain(sigr);
                codomain = abssigcod;
                closure  = None;
              }
            in
            (OpaqueIDSet.empty, ConcFunctor(sigftor))

        | _ ->
            raise_error (SupportOnlyFirstOrderFunctor(rng))
      end

  | SigWith(utsig0, modidents, tybinds) ->
      let (rng0, _) = utsig0 in
      let absmodsig0 = typecheck_signature address tyenv utsig0 in
      let (oidset0, modsig0) = absmodsig0 in
      let sigrlast =
        let (rnglast, modsiglast) =
          modidents |> List.fold_left (fun (rngpre, modsig) (rng, modnm) ->
            match modsig with
            | ConcFunctor(_) ->
                raise_error (NotAStructureSignature(rngpre, modsig))

            | ConcStructure(sigr) ->
                begin
                  match sigr |> SigRecord.find_module modnm with
                  | None            -> raise_error (UnboundModuleName(rng, modnm))
                  | Some(modsig, _) -> (rng, modsig)
                end
          ) (rng0, modsig0)
        in
        match modsiglast with
        | ConcFunctor(_)          -> raise_error (NotAStructureSignature(rnglast, modsiglast))
        | ConcStructure(sigrlast) -> sigrlast
      in
      let (tydefs, _ctordefs) = bind_types address tyenv tybinds in
      let (wtmap, oidset) =
        tydefs |> List.fold_left (fun (wtmap, oidset) (tyident1, (tyid, pkd_actual)) ->
          let (rng1, tynm1) = tyident1 in
          let (oid, pkd_expected) =
            match sigrlast |> SigRecord.find_type tynm1 with
            | None ->
                raise_error (UndefinedTypeName(rng1, tynm1))

            | Some(TypeID.Opaque(oid), pkd) ->
                assert (oidset0 |> OpaqueIDSet.mem oid);
(*
                Format.printf "SigWith> %a --> %a\n"
                  TypeID.Opaque.pp oid
                  TypeID.pp tyid;  (* for debug *)
*)
                (oid, pkd)

            | Some(tyopac) ->
                raise_error (CannotRestrictTransparentType(rng1, tyopac))
          in
          unify_kind rng1 tynm1 ~actual:pkd_actual ~expected:pkd_expected;
          let wtmap = wtmap |> WitnessMap.add_opaque oid tyid in
          let oidset = oidset |> OpaqueIDSet.remove oid in
          (wtmap, oidset)

        ) (WitnessMap.empty, oidset0)
      in
      let (modsigret, _) = substitute_concrete address wtmap modsig0 in
      (oidset, modsigret)


(* Checks that `pkd1` and `pkd2` is the same kind. *)
and unify_kind (rng : Range.t) (tynm : type_name) ~actual:(pkd1 : poly_kind) ~expected:(pkd2 : poly_kind) : unit =
  let Kind(bkdsdom1, bkdcod1) = pkd1 in
  let Kind(bkdsdom2, bkdcod2) = pkd2 in
  match List.combine bkdsdom1 bkdsdom2 with
  | exception Invalid_argument(_) ->
      let arity_actual = List.length bkdsdom1 in
      let arity_expected = List.length bkdsdom2 in
      raise_error (InvalidNumberOfTypeArguments(rng, tynm, arity_expected, arity_actual))

  | bkddomzips ->
      let bdom = bkddomzips |> List.for_all (fun (bkd1, bkd2) -> base_kind_equal bkd1 bkd2) in
      if bdom && base_kind_equal bkdcod1 bkdcod2 then
        ()
      else
        raise_error (KindContradiction(rng, tynm, pkd1, pkd2))


and base_kind_equal (bkd1 : poly_base_kind) (bkd2 : poly_base_kind) =
  match (bkd1, bkd2) with
  | (UniversalKind, UniversalKind)               -> true
  | (RecordKind(plabmap1), RecordKind(plabmap2)) -> poly_label_assoc_equal plabmap1 plabmap2
  | _                                            -> false


and typecheck_binding (address : address) (tyenv : Typeenv.t) (utbind : untyped_binding) : SigRecord.t abstracted * binding list =
  let (_, utbindmain) = utbind in
  match utbindmain with
  | BindVal(External(extbind)) ->
      let mty = extbind.ext_type_annot in
      let (rngv, x) = extbind.ext_identifier in
      let arity = extbind.ext_arity in
      let pty =
        let pre =
          let pre_init =
            {
              level                 = 0;
              tyenv                 = tyenv;
              local_type_parameters = TypeParameterMap.empty;
              local_row_parameters  = RowParameterMap.empty;
            }
          in
          let (pre, _) = make_type_parameter_assoc pre_init extbind.ext_type_params in
          { pre with level = 1 } |> add_local_row_parameter extbind.ext_row_params
        in
        let ty = decode_manual_type pre mty in
        match TypeConv.generalize 0 ty with
        | Ok(pty)  -> pty
        | Error(_) -> assert false
            (* Type parameters occurring in handwritten types cannot be cyclic. *)
      in
      let has_option = extbind.ext_has_option in
      let gname = generate_global_name ~arity:arity ~has_option:has_option rngv x in
      let sigr = SigRecord.empty |> SigRecord.add_val x pty gname in
      ((OpaqueIDSet.empty, sigr), [IBindVal(IExternal(gname, extbind.ext_code))])

  | BindVal(Internal(rec_or_nonrec)) ->
      let pre_init =
        {
          level                 = 0;
          tyenv                 = tyenv;
          local_type_parameters = TypeParameterMap.empty;
          local_row_parameters  = RowParameterMap.empty;
        }
      in
      let (sigr, i_rec_or_nonrec) =
        match rec_or_nonrec with
        | Rec([]) ->
            assert false

        | Rec(valbinds) ->
            let proj gname = OutputIdentifier.Global(gname) in
            let recbinds = typecheck_letrec_mutual global_name_scheme proj pre_init valbinds in
            let (sigr, irecbindacc) =
              recbinds |> List.fold_left (fun (sigr, irecbindacc) (x, pty, gname_outer, _, e) ->
                let sigr = sigr |> SigRecord.add_val x pty gname_outer in
                let irecbindacc = Alist.extend irecbindacc (x, gname_outer, pty, e) in
                (sigr, irecbindacc)
              ) (SigRecord.empty, Alist.empty)
            in
            (sigr, IRec(Alist.to_list irecbindacc))

        | NonRec(valbind) ->
            let (pty, gname, e) =
              let arity = List.length valbind.vb_parameters + List.length valbind.vb_mandatories in
              let has_option = (List.length valbind.vb_optionals > 0) in
              let gnamef = generate_global_name ~arity:arity ~has_option:has_option in
              typecheck_let gnamef pre_init valbind
            in
            let (_, x) = valbind.vb_identifier in
            let sigr = SigRecord.empty |> SigRecord.add_val x pty gname in
            (sigr, INonRec(x, gname, pty, e))
      in
      ((OpaqueIDSet.empty, sigr), [IBindVal(i_rec_or_nonrec)])

  | BindType([]) ->
      assert false

  | BindType((_ :: _) as tybinds) ->
      let (tydefs, _ctordefs) = bind_types address tyenv tybinds in
      let tydefs = tydefs |> List.map (fun ((_, tynm), tyopac) -> (tynm, tyopac)) in
      let sigr = SigRecord.empty |> SigRecord.add_types tydefs in
      ((OpaqueIDSet.empty, sigr), [])

  | BindModule(modident, utsigopt2, utmod1) ->
      let (rngm, m) = modident in
      let (absmodsig1, ibindssub) = typecheck_module (Alist.extend address m) tyenv utmod1 in
      let (oidset, modsig) =
        match utsigopt2 with
        | None ->
            absmodsig1

        | Some(utsig2) ->
            let (_, modsig1) = absmodsig1 in
            let absmodsig2 = typecheck_signature (Alist.extend address m) tyenv utsig2 in
            coerce_signature address rngm modsig1 absmodsig2
      in
      let sname = get_space_name rngm m in
      let sigr = SigRecord.empty |> SigRecord.add_module m modsig sname in
      let ibinds =
        match ibindssub with
        | []     -> []
        | _ :: _ -> [IBindModule(sname, ibindssub)]
      in
      ((oidset, sigr), ibinds)

  | BindInclude(utmod) ->
      let (absmodsig, ibinds) = typecheck_module address tyenv utmod in
      let (oidset, modsig) = absmodsig in
      begin
        match modsig with
        | ConcFunctor(_) ->
            let (rng, _) = utmod in
            raise_error (NotOfStructureType(rng, modsig))

        | ConcStructure(sigr) ->
            ((oidset, sigr), ibinds)
      end

  | BindSig(sigident, sigbind) ->
      let (_, signm) = sigident in
      let absmodsig = typecheck_signature address tyenv sigbind in
      let sigr = SigRecord.empty |> SigRecord.add_signature signm absmodsig in
      ((OpaqueIDSet.empty, sigr), [])


and bind_types (address : address) (tyenv : Typeenv.t) (tybinds : type_binding list) : (type_name ranged * type_opacity) list * (TypeID.Variant.t * BoundID.t list * constructor_branch_map) list =
  let pre_init =
    {
      level                 = 0;
      tyenv                 = tyenv;
      local_type_parameters = TypeParameterMap.empty;
      local_row_parameters  = RowParameterMap.empty;
    }
  in

  (* First, add the arity of each type to be defined. *)
  let (synacc, vntacc, vertices, graph, tyenv) =
    tybinds |> List.fold_left (fun (synacc, vntacc, vertices, graph, tyenv) (tyident, tyvars, syn_or_vnt) ->
      let (_, tynm) = tyident in
      let pkd =
        let bkddoms =
          tyvars |> List.map (fun (_, kdannot) ->
            match kdannot with
            | None        -> UniversalKind
            | Some(mnbkd) -> decode_manual_base_kind pre_init mnbkd
          )
        in
        let kd = Kind(bkddoms, UniversalKind) in
        TypeConv.lift_kind kd
      in
      match syn_or_vnt with
      | BindSynonym(synbind) ->
          let sid = TypeID.Synonym.fresh (Alist.to_list address) tynm in
          let graph = graph |> DependencyGraph.add_vertex sid tyident in
          let tyenv = tyenv |> Typeenv.add_type_for_recursion tynm (TypeID.Synonym(sid)) pkd in
          let synacc = Alist.extend synacc (tyident, tyvars, synbind, sid, pkd) in
          (synacc, vntacc, vertices |> SynonymIDSet.add sid, graph, tyenv)

      | BindVariant(vntbind) ->
          let vid = TypeID.Variant.fresh (Alist.to_list address) tynm in
          let tyenv = tyenv |> Typeenv.add_type_for_recursion tynm (TypeID.Variant(vid)) pkd in
          let vntacc = Alist.extend vntacc (tyident, tyvars, vntbind, vid, pkd) in
          (synacc, vntacc, vertices, graph, tyenv)
    ) (Alist.empty, Alist.empty, SynonymIDSet.empty, DependencyGraph.empty, tyenv)
  in
  let pre = { pre_init with tyenv = tyenv } in

  (* Second, traverse each definition of the synonym types.
     Here, the dependency among synonym types are extracted. *)
  let (graph, tydefacc) =
    synacc |> Alist.to_list |> List.fold_left (fun (graph, tydefacc) syn ->
      let (tyident, tyvars, mtyreal, sid, pkd) = syn in
      let (pre, typaramassoc) = make_type_parameter_assoc pre tyvars in
      let typarams = typaramassoc |> TypeParameterAssoc.values |> List.map MustBeBoundID.to_bound in
      let (tyreal, dependencies) = decode_manual_type_and_get_dependency vertices pre mtyreal in
      let ptyreal =
        match TypeConv.generalize 0 tyreal with
        | Ok(ptyreal) -> ptyreal
        | Error(_)    -> assert false
            (* Type parameters occurring in handwritten types cannot be cyclic. *)
      in
      let graph =
        graph |> SynonymIDSet.fold (fun siddep graph ->
          graph |> DependencyGraph.add_edge sid siddep
        ) dependencies
      in
      TypeDefinitionStore.add_synonym_type sid typarams ptyreal;
      let tydefacc = Alist.extend tydefacc (tyident, (TypeID.Synonym(sid), pkd)) in
      (graph, tydefacc)
    ) (graph, Alist.empty)
  in

  (* Third, traverse each definition of the variant types. *)
  let (tydefacc, ctordefacc) =
    vntacc |> Alist.to_list |> List.fold_left (fun (tydefacc, ctordefacc) vnt ->
      let (tyident, tyvars, ctorbrs, vid, pkd) = vnt in
      let (pre, typaramassoc) = make_type_parameter_assoc pre tyvars in
      let typarams = typaramassoc |> TypeParameterAssoc.values |> List.map MustBeBoundID.to_bound in
      let ctorbrmap =
        make_constructor_branch_map pre ctorbrs
      in
      TypeDefinitionStore.add_variant_type vid typarams ctorbrmap;
      let tydefacc = Alist.extend tydefacc (tyident, (TypeID.Variant(vid), pkd)) in
      let ctordefacc = Alist.extend ctordefacc (vid, typarams, ctorbrmap) in
      (tydefacc, ctordefacc)
    ) (tydefacc, Alist.empty)
  in

  (* Finally, check that no cyclic dependency exists among synonym types
     and make the signature to be returned from the type definitions. *)
  match DependencyGraph.find_cycle graph with
  | Some(cycle) -> raise_error (CyclicSynonymTypeDefinition(cycle))
  | None        -> (Alist.to_list tydefacc, Alist.to_list ctordefacc)


and typecheck_module (address : address) (tyenv : Typeenv.t) (utmod : untyped_module) : module_signature abstracted * binding list =
  let (rng, utmodmain) = utmod in
  match utmodmain with
  | ModVar(m) ->
      let (modsig, _) = find_module tyenv (rng, m) in
      let absmodsig = (OpaqueIDSet.empty, modsig) in
      (absmodsig, [])

  | ModBinds(utbinds) ->
      let (abssigr, ibinds) = typecheck_binding_list address tyenv utbinds in
      let (oidset, sigr) = abssigr in
      let absmodsig = (oidset, ConcStructure(sigr)) in
      (absmodsig, ibinds)

  | ModProjMod(utmod, modident) ->
      let (absmodsig, ibinds) = typecheck_module address tyenv utmod in
      let (oidset, modsig) = absmodsig in
      begin
        match modsig with
        | ConcFunctor(_) ->
            let (rng, _) = utmod in
            raise_error (NotOfStructureType(rng, modsig))

        | ConcStructure(sigr) ->
            let (rng, m) = modident in
            begin
              match sigr |> SigRecord.find_module m with
              | None ->
                  raise_error (UnboundModuleName(rng, m))

              | Some(modsigp, _) ->
                  let absmodsigp = (oidset, modsigp) in
                  (absmodsigp, ibinds)
            end
      end

  | ModFunctor(modident, utsigdom, utmod0) ->
      let (rngm, m) = modident in
      let absmodsigdom = typecheck_signature (Alist.extend Alist.empty m) tyenv utsigdom in
      let (oidset, modsigdom) = absmodsigdom in
      let (absmodsigcod, _) =
        let sname = get_space_name rngm m in
(*
        Printf.printf "MOD-FUNCTOR %s\n" m;  (* for debug *)
        display_signature 0 modsigdom;  (* for debug *)
*)
        let tyenv = tyenv |> Typeenv.add_module m modsigdom sname in
        typecheck_module Alist.empty tyenv utmod0
      in
      let absmodsig =
        begin
          match modsigdom with
          | ConcStructure(sigrdom) ->
              let sigftor =
                {
                  opaques  = oidset;
                  domain   = Domain(sigrdom);
                  codomain = absmodsigcod;
                  closure  = Some(modident, utmod0, tyenv);
                }
              in
              (OpaqueIDSet.empty, ConcFunctor(sigftor))

          | _ ->
              raise_error (SupportOnlyFirstOrderFunctor(rng))
        end
      in
      (absmodsig, [])

  | ModApply(modidentchain1, modidentchain2) ->
      let (modsig1, _) = find_module_from_chain tyenv modidentchain1 in
      let (modsig2, sname2) = find_module_from_chain tyenv modidentchain2 in
      begin
        match modsig1 with
        | ConcStructure(_) ->
            let ((rng1, _), _) = modidentchain1 in
            raise_error (NotOfFunctorType(rng1, modsig1))

        | ConcFunctor(sigftor1) ->
            let oidset           = sigftor1.opaques in
            let Domain(sigrdom1) = sigftor1.domain in
            let absmodsigcod1    = sigftor1.codomain in
            begin
              match sigftor1.closure with
              | None ->
                  assert false

              | Some(modident0, utmodC, tyenv0) ->
                  (* Check the subtype relation between the signature `modsig2` of the argument module
                     and the domain `modsigdom1` of the applied functor. *)
                  let wtmap =
                    let ((rng2, _), _) = modidentchain2 in
                    let modsigdom1 = ConcStructure(sigrdom1) in
                    subtype_signature address rng2 modsig2 (oidset, modsigdom1)
                  in
                  let ((_, modsig0), ibinds) =
                    let tyenv0 =
                      let (_, m0) = modident0 in
                      tyenv0 |> Typeenv.add_module m0 modsig2 sname2
                    in
                    typecheck_module address tyenv0 utmodC
                  in
                  let ((oidset1subst, modsigcod1subst), _wtmap) = absmodsigcod1 |> substitute_abstract address wtmap in
                  let absmodsig = (oidset1subst, copy_closure modsig0 modsigcod1subst) in
                  (absmodsig, ibinds)
            end
      end

  | ModCoerce(modident1, utsig2) ->
      let (modsig1, _) = find_module tyenv modident1 in
      let (rng1, _) = modident1 in
      let absmodsig2 = typecheck_signature address tyenv utsig2 in
      let absmodsig = coerce_signature address rng1 modsig1 absmodsig2 in
      (absmodsig, [])


and typecheck_binding_list (address : address) (tyenv : Typeenv.t) (utbinds : untyped_binding list) : SigRecord.t abstracted * binding list =
  let (_tyenv, oidsetacc, sigracc, ibindacc) =
    utbinds |> List.fold_left (fun (tyenv, oidsetacc, sigracc, ibindacc) utbind ->
      let (abssigr, ibinds) = typecheck_binding address tyenv utbind in
      let (oidset, sigr) = abssigr in
      let tyenv = tyenv |> update_type_environment_by_signature_record sigr in
      let oidsetacc = OpaqueIDSet.union oidsetacc oidset in
      let sigracc =
        match SigRecord.disjoint_union sigracc sigr with
        | Ok(sigr) -> sigr
        | Error(s) -> let (rng, _) = utbind in raise_error (ConflictInSignature(rng, s))
          (* In the original paper "F-ing modules" [Rossberg, Russo & Dreyer 2014],
             this operation is not disjoint union, but union with right-hand side precedence.
             For the sake of clarity, however, we adopt disjoint union here, at least for now.
          *)
      in
      let ibindacc = Alist.append ibindacc ibinds in
      (tyenv, oidsetacc, sigracc, ibindacc)
    ) (tyenv, OpaqueIDSet.empty, SigRecord.empty, Alist.empty)
  in
  ((oidsetacc, sigracc), Alist.to_list ibindacc)


and coerce_signature (address : address) (rng : Range.t) (modsig1 : module_signature) (absmodsig2 : module_signature abstracted) =
  let _wtmap = subtype_signature address rng modsig1 absmodsig2 in
  let (oidset2, modsig2) = absmodsig2 in
  (oidset2, copy_closure modsig1 modsig2)


let main (tyenv : Typeenv.t) (modident : module_name ranged) (absmodsigopt2 : (module_signature abstracted) option) (utmod1 : untyped_module) : Typeenv.t * SigRecord.t abstracted * space_name * binding list =
  let (rng, modnm) = modident in
  let sname = get_space_name rng modnm in
  let address = Alist.extend Alist.empty modnm in
  let (absmodsig1, ibinds) = typecheck_module address tyenv utmod1 in
  let (oidset, modsig) =
    match absmodsigopt2 with
    | None             -> absmodsig1
    | Some(absmodsig2) -> let (_, modsig1) = absmodsig1 in coerce_signature address rng modsig1 absmodsig2
  in
  match modsig with
  | ConcFunctor(_) ->
      let (rng, _) = utmod1 in
      raise_error (RootModuleMustBeStructure(rng))

  | ConcStructure(sigr) ->
      let tyenv = tyenv |> Typeenv.add_module modnm modsig sname in
      (tyenv, (oidset, sigr), sname, ibinds)
