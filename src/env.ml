
open MyUtil
open Syntax

type val_entry = {
  typ  : poly_type;
  name : name;
  mutable is_used : bool;
}

type type_entry =
  | Defining       of TypeID.t
  | DefinedVariant of TypeID.Variant.t
  | DefinedSynonym of TypeID.Synonym.t
  | DefinedOpaque  of TypeID.Opaque.t

type variant_entry = {
  v_type_parameters : BoundID.t list;
  v_branches        : constructor_branch_map;
}

type opaque_entry = {
  o_kind : kind;
}

type module_signature =
  | ConcStructure of record_signature
  | ConcFunctor   of functor_signature

and functor_signature = {
  opaques  : OpaqueIDSet.t;
  domain   : functor_domain;
  codomain : OpaqueIDSet.t * module_signature;
  closure  : (module_name ranged * untyped_module * environment) option;
}

and functor_domain =
  | Domain of record_signature

and module_entry = {
  mod_name      : name;
  mod_signature : module_signature;
}

and signature_entry = {
  sig_signature : module_signature abstracted;
}

and environment = {
  vals         : val_entry ValNameMap.t;
  type_names   : (type_entry * int) TypeNameMap.t;
  opaques      : opaque_entry OpaqueIDMap.t;
  constructors : constructor_entry ConstructorMap.t;
  modules      : module_entry ModuleNameMap.t;
  signatures   : signature_entry SignatureNameMap.t;
}

and record_signature =
  record_signature_entry Alist.t

and record_signature_entry =
  | SRVal      of identifier * (poly_type * name)
  | SRRecTypes of (type_name * type_opacity) list
  | SRModule   of module_name * (module_signature * name)
  | SRSig      of signature_name * module_signature abstracted
  | SRCtor     of constructor_name * constructor_entry


module Typeenv = struct

  type t = environment

  let empty = {
    vals         = ValNameMap.empty;
    type_names   = TypeNameMap.empty;
    opaques      = OpaqueIDMap.empty;
    constructors = ConstructorMap.empty;
    modules      = ModuleNameMap.empty;
    signatures   = SignatureNameMap.empty;
  }


  let add_val x pty name tyenv =
    let entry =
      {
        typ  = pty;
        name = name;

        is_used = false;
      }
    in
    let vals = tyenv.vals |> ValNameMap.add x entry in
    { tyenv with vals = vals; }


  let find_val x tyenv =
    tyenv.vals |> ValNameMap.find_opt x |> Option.map (fun entry ->
      entry.is_used <- true;
      (entry.typ, entry.name)
    )


  let is_val_properly_used x tyenv =
    tyenv.vals |> ValNameMap.find_opt x |> Option.map (fun entry ->
      entry.is_used
    )


  let fold_val f tyenv acc =
    ValNameMap.fold (fun x entry acc -> f x entry.typ acc) tyenv.vals acc


  let add_variant_type (tynm : type_name) (vid : TypeID.Variant.t) (arity : int) (tyenv : t) : t =
    { tyenv with
      type_names = tyenv.type_names |> TypeNameMap.add tynm (DefinedVariant(vid), arity);
    }


  let add_constructor (ctornm : constructor_name) (ctorentry : constructor_entry) (tyenv : t) : t =
    { tyenv with
      constructors = tyenv.constructors |> ConstructorMap.add ctornm ctorentry;
    }


  let add_synonym_type (tynm : type_name) (sid : TypeID.Synonym.t) (arity : int) (tyenv : t) : t =
    { tyenv with
      type_names = tyenv.type_names |> TypeNameMap.add tynm (DefinedSynonym(sid), arity);
    }


  let add_opaque_type (tynm : type_name) (oid : TypeID.Opaque.t) (kind : kind) (tyenv : t) : t =
    let oentry =
      {
        o_kind = kind;
      }
    in
    { tyenv with
      type_names = tyenv.type_names |> TypeNameMap.add tynm (DefinedOpaque(oid), kind);
      opaques    = tyenv.opaques |> OpaqueIDMap.add oid oentry;
    }


  let add_type_for_recursion (tynm : type_name) (tyid : TypeID.t) (arity : int) (tyenv : t) : t =
    { tyenv with
      type_names = tyenv.type_names |> TypeNameMap.add tynm (Defining(tyid), arity);
    }


  let find_constructor (ctornm : constructor_name) (tyenv : t) =
    tyenv.constructors |> ConstructorMap.find_opt ctornm |> Option.map (fun entry ->
      (entry.belongs, entry.constructor_id, entry.type_variables, entry.parameter_types)
    )


  let find_type (tynm : type_name) (tyenv : t) : (TypeID.t * int) option =
    tyenv.type_names |> TypeNameMap.find_opt tynm |> Option.map (fun (tyentry, arity) ->
      match tyentry with
      | Defining(tyid)      -> (tyid, arity)
      | DefinedVariant(vid) -> (TypeID.Variant(vid), arity)
      | DefinedSynonym(sid) -> (TypeID.Synonym(sid), arity)
      | DefinedOpaque(oid)  -> (TypeID.Opaque(oid), arity)
    )


  let add_module (modnm : module_name) (modsig : module_signature) (name : name) (tyenv : t) : t =
    let modentry =
      {
        mod_name      = name;
        mod_signature = modsig;
      }
    in
    { tyenv with
      modules = tyenv.modules |> ModuleNameMap.add modnm modentry;
    }


  let find_module (modnm : module_name) (tyenv : t) : (module_signature * name) option =
    tyenv.modules |> ModuleNameMap.find_opt modnm |> Option.map (fun modentry ->
      (modentry.mod_signature, modentry.mod_name)
    )


  let add_signature (signm : signature_name) (absmodsig : module_signature abstracted) (tyenv : t) : t =
    let sigentry =
      {
        sig_signature = absmodsig;
      }
    in
    { tyenv with
      signatures = tyenv.signatures |> SignatureNameMap.add signm sigentry;
    }


  let find_signature (signm : signature_name) (tyenv : t) : (module_signature abstracted) option =
    tyenv.signatures |> SignatureNameMap.find_opt signm |> Option.map (fun sigentry ->
      sigentry.sig_signature
    )

end


module SigRecord = struct

  type t = record_signature

  let empty : t =
    Alist.empty


  let add_val (x : identifier) (pty : poly_type) (name : name) (sigr : t) : t =
    Alist.extend sigr (SRVal(x, (pty, name)))


  let find_val (x0 : identifier) (sigr : t) : (poly_type * name) option =
    sigr |> Alist.to_rev_list |> List.find_map (function
    | SRVal(x, ventry) -> if String.equal x x0 then Some(ventry) else None
    | _                -> None
    )


  let add_types (tydefs : (type_name * type_opacity) list) (sigr : t) : t =
    Alist.extend sigr (SRRecTypes(tydefs))


  let add_constructors (vid : TypeID.Variant.t) (typarams : BoundID.t list) (ctorbrs : constructor_branch_map) (sigr : t) : t =
    ConstructorMap.fold (fun ctornm (ctorid, ptys) sigr ->
      let ctorentry =
        {
          belongs         = vid;
          constructor_id  = ctorid;
          type_variables  = typarams;
          parameter_types = ptys;
        }
      in
      Alist.extend sigr (SRCtor(ctornm, ctorentry))
    ) ctorbrs sigr


  let find_constructor (ctornm0 : constructor_name) (sigr : t) : constructor_entry option =
    sigr |> Alist.to_rev_list |> List.find_map (function
    | SRCtor(ctornm, entry) -> if String.equal ctornm ctornm0 then Some(entry) else None
    | _                     -> None
    )


  let find_type (tynm0 : type_name) (sigr : t) : type_opacity option =
    sigr |> Alist.to_rev_list |> List.find_map (function
    | SRRecTypes(tydefs) ->
        tydefs |> List.find_map (fun (tynm, tyopac) ->
          if String.equal tynm tynm0 then Some(tyopac) else None
        )

    | _ ->
        None
    )


  let add_opaque_type (tynm : type_name) (oid : TypeID.Opaque.t) (kd : kind) (sigr : t) : t =
    Alist.extend sigr (SRRecTypes[ (tynm, (TypeID.Opaque(oid), kd)) ])


  let add_module (modnm : module_name) (modsig : module_signature) (name : name) (sigr : t) : t =
    Alist.extend sigr (SRModule(modnm, (modsig, name)))


  let find_module (modnm0 : module_name) (sigr : t) : (module_signature * name) option =
    sigr |> Alist.to_list |> List.find_map (function
    | SRModule(modnm, mentry) -> if String.equal modnm modnm0 then Some(mentry) else None
    | _                       -> None
    )


  let add_signature (signm : signature_name) (absmodsig : module_signature abstracted) (sigr : t) : t =
    Alist.extend sigr (SRSig(signm, absmodsig))


  let find_signature (signm0 : signature_name) (sigr : t) : (module_signature abstracted) option =
    sigr |> Alist.to_list |> List.find_map (function
    | SRSig(signm, absmodsig) -> if String.equal signm signm0 then Some(absmodsig) else None
    | _                       -> None
    )


  let fold (type a)
      ~v:(fv : identifier -> poly_type * name -> a -> a)
      ~t:(ft : (type_name * type_opacity) list -> a -> a)
      ~m:(fm : module_name -> module_signature * name -> a -> a)
      ~s:(fs : signature_name -> module_signature abstracted -> a -> a)
      ~c:(fc : constructor_name -> constructor_entry -> a -> a)
      (init : a) (sigr : t) : a =
    sigr |> Alist.to_list |> List.fold_left (fun acc entry ->
      match entry with
      | SRVal(x, ventry)        -> fv x ventry acc
      | SRRecTypes(tydefs)      -> ft tydefs acc
      | SRModule(modnm, mentry) -> fm modnm mentry acc
      | SRSig(signm, absmodsig) -> fs signm absmodsig acc
      | SRCtor(ctor, ctorentry) -> fc ctor ctorentry acc
    ) init


  let map_and_fold (type a)
      ~v:(fv : poly_type * name -> a -> (poly_type * name) * a)
      ~t:(ft : type_opacity list -> a -> type_opacity list * a)
      ~m:(fm : module_signature * name -> a -> (module_signature * name) * a)
      ~s:(fs : module_signature abstracted -> a -> module_signature abstracted * a)
      ~c:(fc : constructor_entry -> a -> constructor_entry * a)
      (init : a) (sigr : t) : t * a =
      sigr |> Alist.to_list |> List.fold_left (fun (sigracc, acc) entry ->
        match entry with
        | SRVal(x, ventry) ->
            let (ventry, acc) = fv ventry acc in
            (Alist.extend sigracc (SRVal(x, ventry)), acc)

        | SRRecTypes(tydefs) ->
            let tynms = tydefs |> List.map fst in
            let (tyopacs, acc) = ft (tydefs |> List.map snd) acc in
            (Alist.extend sigracc (SRRecTypes(List.combine tynms tyopacs)), acc)

        | SRModule(modnm, mentry) ->
            let (mentry, acc) = fm mentry acc in
            (Alist.extend sigracc (SRModule(modnm, mentry)), acc)

        | SRSig(signm, absmodsig) ->
            let (absmodsig, acc) = fs absmodsig acc in
            (Alist.extend sigracc (SRSig(signm, absmodsig)), acc)

        | SRCtor(ctor, ctorentry) ->
            let (ctorentry, acc) = fc ctorentry acc in
            (Alist.extend sigracc (SRCtor(ctor, ctorentry)), acc)
      ) (Alist.empty, init)

(*
  let overwrite (superior : t) (inferior : t) : t =
    let left _ x _ = Some(x) in
    let sr_vals    = ValNameMap.union       left superior.sr_vals    inferior.sr_vals in
    let sr_types   = TypeNameMap.union      left superior.sr_types   inferior.sr_types in
    let sr_modules = ModuleNameMap.union    left superior.sr_modules inferior.sr_modules in
    let sr_sigs    = SignatureNameMap.union left superior.sr_sigs    inferior.sr_sigs in
    let sr_ctors   = ConstructorMap.union   left superior.sr_ctors   inferior.sr_ctors in
    { sr_vals; sr_types; sr_modules; sr_sigs; sr_ctors }
*)

  let disjoint_union (rng : Range.t) (sigr1 : t) (sigr2 : t) : t =
    let check_none s opt =
      match opt with
      | None    -> ()
      | Some(_) -> raise (ConflictInSignature(rng, s))
    in
    sigr2 |> Alist.to_list |> List.fold_left (fun sigracc entry ->
      let () =
        match entry with
        | SRVal(x, _)        -> check_none x (find_val x sigr1)
        | SRRecTypes(tydefs) -> tydefs |> List.iter (fun (tynm, _) -> check_none tynm (find_type tynm sigr1))
        | SRModule(modnm, _) -> check_none modnm (find_module modnm sigr1)
        | SRSig(signm, _)    -> check_none signm (find_signature signm sigr1)
        | SRCtor(ctor, _)    -> check_none ctor (find_constructor ctor sigr1)
      in
      Alist.extend sigracc entry
    ) sigr1

end
