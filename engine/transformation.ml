open Common open Commonop

module A = Ast_cocci
module B = Ast_c
module F = Control_flow_c

module D = Distribute_mcodekind

(*****************************************************************************)
(* For some nodes I dont have all the info, for instance for } I need
 * to modify the node of the start, it is where the info is. Same for
 * Else. *)
(*****************************************************************************)

type sequence_processing_style = Ordered | Unordered

let term ((s,_,_) : 'a Ast_cocci.mcode) = s
let mcodekind (_,i,mc) = mc
let wrap_mcode (_,i,mc) = ("fake", i, mc)

(*****************************************************************************)
(* Binding combinators *)
(*****************************************************************************)

(* todo: Must do some try, for instance when f(...,X,Y,...) have to
 * test the transfo for all the combinaitions (and if multiple transfo
 * possible ? pb ? => the type is to return a expression option ? use
 * some combinators to help ?
 *)

type ('a, 'b) transformer = 'a -> 'b -> Lib_engine.metavars_binding -> 'b

exception NoMatch 

(*****************************************************************************)
(* Metavariable and environments handling *)
(*****************************************************************************)
let find_env x env = 
  try List.assoc x env 
  with Not_found -> 
    pr2 ("Don't find value for metavariable " ^ x ^ " in the environment");
    raise NoMatch

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

let mcode_contain_plus = function
  | Ast_cocci.CONTEXT (_,Ast_cocci.NOTHING) -> false
  | Ast_cocci.CONTEXT _ -> true
  | Ast_cocci.MINUS (_,[]) -> false
  | Ast_cocci.MINUS (_,x::xs) -> true
  | Ast_cocci.PLUS -> raise Impossible

let mcode_simple_minus = function
  | Ast_cocci.MINUS (_,[]) -> true
  | _ -> false


let transform_option f t1 t2 =
  match (t1,t2) with
  | (Some t1, Some t2) -> Some (f t1 t2)
  | (None, None) -> None
  | _ -> raise NoMatch

let tag_one_symbol = fun ia ib  binding -> 
  let (s1,_,x) = ia in
  D.tag_with_mck x ib binding


let (tag_symbols: ('a A.mcode) list -> B.il -> B.metavars_binding -> B.il) =
  fun xs ys binding ->
    assert (List.length xs = List.length ys);
    Common.zip xs ys +> List.map (fun (a, b) -> tag_one_symbol a b binding)



(*****************************************************************************)
(* The transform functions, "Cocci vs C" *) 
(*****************************************************************************)

let rec (transform_e_e: (Ast_cocci.expression, Ast_c.expression) transformer) =
  fun ep ec -> 
    fun binding -> 
      
      match A.unwrap ep, ec with

      (* general case: a MetaExpr can match everything *)
      | A.MetaExpr(ida,A.Saved,opttypa,_inherited),
	(((expr, opttypb), ii) as expb) ->
          (match opttypa, opttypb with
          | None, _ -> ()
          | Some tas, Some tb -> 
              if (not (tas +> List.exists (fun ta ->  Types.compatible_type ta tb)))
              then raise NoMatch
          | Some _, None -> 
              (*pr2 ("I have not the type information. Certainly a pb in " ^
                           "annotate_typer.ml") *)
              raise NoMatch
          );


          (* get binding, assert =*=,  distribute info in ida *)
          let v = binding +> find_env (term ida) in
          (match v with
          | B.MetaExprVal expa -> 
              if (Lib_parsing_c.al_expr expa =*= Lib_parsing_c.al_expr expb)
              then D.distribute_mck (mcodekind ida) D.distribute_mck_e expb binding
              else raise NoMatch
          | _ -> raise Impossible
          )
      (* BUG ? because if have not tagged SP, then transform without doing
       * any checks ! 
       *)
      | A.MetaExpr(ida,keep,opttypa,_inherited), expb
	    when keep = A.Unitary or keep = A.Nonunitary ->
          D.distribute_mck (mcodekind ida) D.distribute_mck_e expb binding

      (* todo: in fact can also have the Edots family inside nest, as in 
         if(<... x ... y ...>) or even in simple expr as in x[...] *)
      | A.Edots (mcode, None), expb    -> 
          D.distribute_mck (mcodekind mcode) D.distribute_mck_e expb   binding

      | A.Edots (_, Some expr), _    -> failwith "not handling when on Edots"


      | A.MetaConst _, _ -> failwith "not handling MetaConst"
      | A.MetaErr _, _ -> failwith "not handling MetaErr"
          
      | A.Ident ida,                ((B.Ident idb, typ),ii) ->
          let (idb', ii') = transform_ident Pattern.DontKnow ida (idb, ii) binding 
          in
          (B.Ident idb', typ),ii'


      | A.Constant ((A.Int ia,_,_) as i1), ((B.Constant (B.Int ib) , typ),ii)
          when Pattern.equal_c_int ia ib ->  
          (B.Constant (B.Int ib), typ), 
            tag_symbols [i1] ii binding

      | A.Constant ((A.Char ia,_,_) as i1), ((B.Constant (B.Char (ib,t)), typ),ii)
          when ia =$= ib ->  
          (B.Constant (B.Char (ib, t)), typ), 
            tag_symbols [i1] ii binding

      | A.Constant ((A.String ia,_,_)as i1),((B.Constant (B.String (ib,t)),typ),ii)
          when ia =$= ib ->  
          (B.Constant (B.String (ib, t)), typ),
            tag_symbols [i1] ii binding

      | A.Constant ((A.Float ia,_,_) as i1),((B.Constant (B.Float (ib,t)),typ),ii)
          when ia =$= ib ->  
          (B.Constant (B.Float (ib,t)), typ),
            tag_symbols [i1] ii binding


      | A.FunCall (ea, i2, eas, i3),  ((B.FunCall (eb, ebs), typ),ii) -> 
          let seqstyle = 
            (match A.unwrap eas with 
            | A.DOTS _ -> Ordered 
            | A.CIRCLES _ -> Unordered 
            | A.STARS _ -> failwith "not handling stars"
            )  
          in
          
          (B.FunCall (transform_e_e ea eb binding,  
                     transform_arguments seqstyle (A.undots eas) ebs binding),typ),
          tag_symbols [i2;i3] ii  binding


      | A.Assignment (ea1, opa, ea2), ((B.Assignment (eb1, opb, eb2), typ),ii) -> 
          if Pattern.equal_assignOp (term opa) opb 
          then
            (B.Assignment (transform_e_e ea1 eb1 binding, 
                          opb, 
                          transform_e_e ea2 eb2 binding), typ),
          tag_symbols [opa] ii  binding
          else raise NoMatch

      | A.CondExpr (ea1,i1,ea2opt,i2,ea3),((B.CondExpr (eb1,eb2opt,eb3),typ),ii) ->
          (B.CondExpr (transform_e_e ea1 eb1  binding,
                      transform_option (fun a b -> transform_e_e a b binding) 
                        ea2opt eb2opt,
                      transform_e_e ea3 eb3 binding),typ),
          tag_symbols [i1;i2] ii   binding

      | A.Postfix (ea, opa), ((B.Postfix (eb, opb), typ),ii) -> 
          if (Pattern.equal_fixOp (term opa) opb)
          then (B.Postfix (transform_e_e ea eb binding, opb), typ),
          tag_symbols [opa] ii  binding
          else raise NoMatch
            
            
      | A.Infix (ea, opa), ((B.Infix (eb, opb), typ),ii) -> 
          if (Pattern.equal_fixOp (term opa) opb)
          then (B.Infix (transform_e_e ea eb binding, opb), typ),
          tag_symbols [opa] ii  binding
          else raise NoMatch

      | A.Unary (ea, opa), ((B.Unary (eb, opb), typ),ii) -> 
          if (Pattern.equal_unaryOp (term opa) opb)
          then (B.Unary (transform_e_e ea eb binding, opb), typ),
          tag_symbols [opa] ii  binding
          else raise NoMatch


      | A.Binary (ea1, opa, ea2), ((B.Binary (eb1, opb, eb2), typ),ii) -> 
          if (Pattern.equal_binaryOp (term opa) opb)
          then (B.Binary (transform_e_e ea1 eb1   binding, 
                         opb,  
                         transform_e_e ea2 eb2  binding), typ),
          tag_symbols [opa] ii binding
          else raise NoMatch


      | A.ArrayAccess (ea1, i1, ea2, i2), ((B.ArrayAccess (eb1, eb2), typ),ii) -> 
          (B.ArrayAccess (transform_e_e ea1 eb1 binding,
                         transform_e_e ea2 eb2 binding),typ),
          tag_symbols [i1;i2] ii  binding
            
      | A.RecordAccess (ea, dot, ida), ((B.RecordAccess (eb, idb), typ),ii) ->
          (match ii with
          | [i1;i2] -> 
              let (idb', i2') = 
                transform_ident Pattern.DontKnow ida (idb, [i2])   binding 
              in
              let i1' = tag_symbols [dot] [i1] binding in
              (B.RecordAccess (transform_e_e ea eb binding, idb'), typ), i1' ++ i2'
          | _ -> raise Impossible
          )


      | A.RecordPtAccess (ea,fleche,ida),((B.RecordPtAccess (eb, idb), typ), ii) ->
          (match ii with
          | [i1;i2] -> 
              let (idb', i2') = 
                transform_ident Pattern.DontKnow ida (idb, [i2])   binding 
              in
              let i1' = tag_symbols [fleche] [i1] binding in
              (B.RecordPtAccess (transform_e_e ea eb binding,idb'),typ), i1' ++ i2'
          | _ -> raise Impossible
          )

      | A.Cast (i1, typa, i2, ea), ((B.Cast (typb, eb), typ),ii) -> 
          (B.Cast (transform_ft_ft typa typb  binding,
                  transform_e_e ea eb binding),typ),
          tag_symbols [i1;i2]  ii binding

      | A.SizeOfExpr (i1, ea), ((B.SizeOfExpr (eb), typ),ii) -> 
          (B.SizeOfExpr (transform_e_e ea eb binding), typ),
          tag_symbols [i1]  ii binding

      | A.SizeOfType (i1, i2, typa, i3), ((B.SizeOfType typb, typ),ii) -> 
          (B.SizeOfType (transform_ft_ft typa typb  binding),typ),
          tag_symbols [i1;i2;i3]  ii binding


      | A.Paren (i1, ea, i2), ((B.ParenExpr (eb), typ),ii) -> 
          (B.ParenExpr (transform_e_e ea eb  binding), typ),
          tag_symbols [i1;i2] ii  binding


      | A.NestExpr _, _ -> failwith "not my job to handle NestExpr"


      | A.MetaExprList _, _   -> raise Impossible (* only in arg lists *)
      | A.TypeExp _, _  -> raise Impossible
      | A.EComma _, _   -> raise Impossible (* EComma only in arg lists *)
      | A.Ecircles _, _ -> raise Impossible (* EComma only in arg lists *)
      | A.Estars _, _   -> raise Impossible (* EComma only in arg lists *)


      | A.DisjExpr eas, eb -> 
          eas +> Common.fold_k (fun acc ea k -> 
            try transform_e_e ea acc  binding
            with NoMatch -> k acc
          ) 
            (fun _ -> raise NoMatch)
            eb

      | A.MultiExp _, _ | A.UniqueExp _,_ | A.OptExp _,_ -> 
          failwith "not handling Opt/Unique/Multi on expr"



      (* Because of Exp cant put a raise Impossible; have to put a raise
         NoMatch; *)

      (* have not a counter part in coccinelle, for the moment *) 
      | _, ((B.Sequence _,_),_) 

      | _, ((B.StatementExpr _,_),_) 
      | _, ((B.Constructor,_),_) 
          -> raise NoMatch

      | _, _ -> raise NoMatch


(* ------------------------------------------------------------------------- *)
and (transform_ident: 
        Pattern.semantic_info_ident -> 
      (Ast_cocci.ident, (string * Ast_c.il)) transformer) = 
  fun seminfo_idb ida (idb, ii) -> 
    fun binding -> 
      match A.unwrap ida with
      | A.Id sa -> 
          if (term sa) =$= idb
          then idb, tag_symbols [sa] ii binding
          else raise NoMatch
	    
      | A.MetaId(ida,A.Saved,_inherited) -> 
          (* get binding, assert =*=,  distribute info in i1 *)
	  let v = binding +> find_env ((term ida) : string) in
	  (match v with
	  | B.MetaIdVal sa -> 
              if(sa =$= idb) 
              then idb, tag_symbols [ida] ii binding
              else raise NoMatch
	  | _ -> raise Impossible
	  )

      | A.MetaFunc(ida,A.Saved,_inherited) -> 
	  (match seminfo_idb with 
	  | Pattern.LocalFunction | Pattern.Function -> 
              let v = binding +> find_env ((term ida) : string) in
              (match v with
              | B.MetaFuncVal sa -> 
		  if(sa =$= idb) 
		  then idb, tag_symbols [ida] ii binding
		  else raise NoMatch
              | _ -> raise Impossible
	      )
	  | Pattern.DontKnow -> 
              failwith
		"MetaFunc and MetaLocalFunc, need more semantic info about id")

      | A.MetaLocalFunc(ida,A.Saved,_inherited) -> 
	  (match seminfo_idb with
	  | Pattern.LocalFunction -> 
              let v = binding +> find_env ((term ida) : string) in
              (match v with
              | B.MetaLocalFuncVal sa -> 
		  if(sa =$= idb) 
		  then idb, tag_symbols [ida] ii binding
		  else raise NoMatch
              | _ -> raise Impossible
	      )
		
		
	  | Pattern.Function -> raise NoMatch
	  | Pattern.DontKnow -> 
              failwith
		"MetaFunc and MetaLocalFunc, need more semantic info about id")
	    
      | A.MetaId(ida,keep,_inherited)
      | A.MetaFunc(ida,keep,_inherited)
      | A.MetaLocalFunc(ida,keep,_inherited)
	when keep = A.Unitary or keep = A.Nonunitary ->
	  idb, tag_symbols [ida] ii binding
	    
      | A.OptIdent _ | A.UniqueIdent _ | A.MultiIdent _ -> 
	  failwith "not handling Opt/Unique/Multi for ident"

      |	_ -> failwith "cannot occur"
	    
(* ------------------------------------------------------------------------- *)
	    
and (transform_arguments: sequence_processing_style -> 
      (Ast_cocci.expression list, Ast_c.argument Ast_c.wrap2 list) transformer) = 
  fun seqstyle eas ebs ->
    fun binding -> 
      let unwrapper xs = xs +> List.map (fun ea -> A.unwrap ea, ea) in
      let rewrapper xs = xs +> List.map snd in
      
      match unwrapper eas, ebs with
      | [],   [] -> []
      | [A.Edots (mcode, None), ea], [] -> 
          if mcode_contain_plus (mcodekind mcode)
          then failwith "todo:I have no token that I could accroche myself on"
          else []
      | _, [] -> raise NoMatch
      | [], eb::ebs -> raise NoMatch
	  
      (* special case. todo: generalize *)
      | [A.Edots (mcode, None), ea], ebs -> 
          D.distribute_mck (mcodekind mcode) D.distribute_mck_arge ebs binding
	    
	    
      | (A.EComma i1, _)::(A.Edots (mcode, None),ea)::[], (eb, ii)::ebs -> 
          let ii' = tag_symbols [i1] ii   binding in
          (match 
              D.distribute_mck (mcodekind mcode) D.distribute_mck_arge 
                ((eb, [](*subtil*))::ebs)
                binding
            with
            | (eb, [])::ebs -> (eb, ii')::ebs
            | _ -> raise Impossible)
            
	    
      | (A.EComma i1, _)::(una,ea)::eas, (eb, ii)::ebs -> 
          let ii' = tag_symbols [i1] ii   binding in
          (transform_argument  ea eb binding, ii')::
	    transform_arguments seqstyle (rewrapper eas) ebs   binding

      (* The first argument is handled here. Then cocci will always contain
       * some EComma and a following expression, so the previous case will
       * handle that.
       *)
      | (una, ea)::eas, (eb, ii)::ebs -> 
          assert (null ii);
          (transform_argument  ea eb binding, [])::
	    transform_arguments seqstyle (rewrapper eas) ebs   binding


and transform_argument arga argb = 
  fun binding -> 

    match A.unwrap arga, argb with

    | A.TypeExp tya,  Right (B.ArgType (tyb, (sto, iisto))) ->
        if sto <> (B.NoSto, false)
        then failwith "the argument have a storage and ast_cocci does not have"
        else 
          Right (B.ArgType (transform_ft_ft tya tyb binding, (sto, iisto)))

    | unwrapx, Left y ->  Left (transform_e_e arga y binding)
    | unwrapx, Right (B.ArgAction y) -> raise NoMatch

    | _, _ -> raise NoMatch


(* ------------------------------------------------------------------------- *)

and (transform_params: sequence_processing_style -> 
      (Ast_cocci.parameterTypeDef list, Ast_c.parameterType Ast_c.wrap2 list)
        transformer) = 
 fun seqstyle pas pbs ->
  fun binding -> 
    let unwrapper xs = xs +> List.map (fun pa -> A.unwrap pa, pa) in
    let rewrapper xs = xs +> List.map snd in

    match unwrapper pas, pbs with
    | [], [] -> []
    | [A.Pdots (mcode), pa], [] -> 
        if mcode_contain_plus (mcodekind mcode)
        then failwith "todo:I have no token that I could accroche myself on"
        else []
    | _, [] -> raise NoMatch
    | [], eb::ebs -> raise NoMatch

    (* special case. todo: generalize *)
    | [A.Pdots (mcode), pa], pbs -> 
        D.distribute_mck (mcodekind mcode) D.distribute_mck_params pbs  binding

    | (A.PComma i1, _)::(una,pa)::pas, (pb, ii)::pbs -> 
        let ii' = tag_symbols [i1] ii binding in
        (transform_param pa pb binding, ii')::
	transform_params seqstyle (rewrapper pas) pbs  binding

    | (unpa,pa)::pas, (pb, ii)::pbs -> 
        assert (null ii);
        ((transform_param pa pb binding),[])::
        transform_params seqstyle (rewrapper pas) pbs binding


and (transform_param: 
     (Ast_cocci.parameterTypeDef, (Ast_c.parameterType)) transformer) = 
 fun pa pb  -> 
  fun binding -> 
    match A.unwrap pa, pb with
    | A.Param (typa, Some ida), ((hasreg, idb, typb), ii_b_s) -> 
        
        let kindparam = 
          (match hasreg, idb,  ii_b_s with
          | false, Some s, [i1] -> Left (s, [], i1)
          | true, Some s, [i1;i2] -> Left (s, [i1], i2)
          | _, None, ii -> 
              pr2 "NORMALLY IMPOSSIBLE. The Cocci Param has an ident but not the C";
              Right ii
              
              
          | _ -> raise Impossible
          )
        in
        (match kindparam with
        | Left (idb, iihasreg, iidb) -> 
            let (idb', iidb') = 
              transform_ident Pattern.DontKnow ida (idb, [iidb])   binding 
            in
            let typb' = transform_ft_ft typa typb binding in
            (hasreg, Some idb', typb'), (iihasreg++iidb') 
         (* why handle this case ? because of transform_proto ? we may not
          *  have an ident in the proto.
          *)
        | Right iihasreg -> 
            let typb' = transform_ft_ft typa typb binding in
            (hasreg, None, typb'), (iihasreg) 
        )
            
    | A.Param (typa, None), ((hasreg, idb, typb), ii_b_s) -> 
	failwith "TODO: Cocci parameter has no name, what to do in this case?"
        
    | A.PComma _, _ -> raise Impossible
    | _ -> raise Todo

(* ------------------------------------------------------------------------- *)
and transform_de_de = fun mckstart decla declb -> 
  fun binding -> 
  match declb with
  (* TODO iisto *)
  | (B.DeclList ([var], iiptvirgb::iifakestart::iisto)) -> 
      let (var', iiptvirgb') = transform_onedecl decla (var, iiptvirgb) binding
      in
      let iifakestart' = D.tag_with_mck mckstart iifakestart binding in 
      B.DeclList ([var'], iiptvirgb'::iifakestart'::iisto)

  | (B.DeclList (x::y::xs, iiptvirgb::iifake::iisto)) -> 
      failwith "More that one variable in decl. Have to split to transform."
  
  | _ -> raise Impossible                

and transform_onedecl = fun decla declb -> 
 fun binding -> 
   match A.unwrap decla, declb with
   | A.MetaDecl(ida,_,_inherited), _ -> 
       failwith "impossible. We can't transform a MetaDecl"

   | A.UnInit (stoa, typa, ida, ptvirga), 
     (((Some ((idb, None),iidb::iini), typb, stob), iivirg), iiptvirgb) -> 
       assert (null iini);

       let iiptvirgb' = tag_symbols [ptvirga] [iiptvirgb] binding  in

       let typb' = transform_ft_ft typa typb  binding in
       let (idb', iidb') = 
         transform_ident Pattern.DontKnow ida (idb, [iidb])  binding 
       in
       ((Some ((idb', None), iidb'++iini), typb', stob), iivirg), 
       List.hd iiptvirgb'

   | A.Init (stoa, typa, ida, eqa, inia, ptvirga), 
     (((Some ((idb, Some ini),[iidb;iieqb]), typb, stob), iivirg),iiptvirgb) ->

       let iiptvirgb' = tag_symbols [ptvirga] [iiptvirgb] binding  in
       let iieqb' = tag_symbols [eqa] [iieqb] binding in
       let typb' = transform_ft_ft typa typb  binding in
       let (idb', iidb') = 
         transform_ident Pattern.DontKnow ida (idb, [iidb])  binding 
       in
       let ini' = transform_initialiser inia ini  binding in
       ((Some ((idb', Some ini'), iidb'++iieqb'), typb', stob), iivirg), 
        List.hd iiptvirgb'

   | A.TyDecl (typa, _), _ ->
       failwith "fill something in for a declaration that is just a type"
       
   | _, (((None, typb, sto), _),_) -> raise NoMatch


   | A.DisjDecl xs, declb -> 
       xs +> Common.fold_k (fun acc decla k -> 
         try transform_onedecl decla acc  binding
         with NoMatch -> k acc
        )
        (fun _ -> raise NoMatch)
        declb

            
   | A.OptDecl _, _ | A.UniqueDecl _, _ | A.MultiDecl _, _ -> 
       failwith "not handling Opt/Unique/Multi Decl"
   | _, _ -> raise NoMatch


(* ------------------------------------------------------------------------- *)
and (transform_initialiser: 
        (Ast_cocci.initialiser, Ast_c.initialiser) transformer) = 
fun inia ini -> 
 fun binding -> 
   match (A.unwrap inia,ini) with
   | (A.InitExpr expa,(B.InitExpr expb, ii)) -> 
       assert (null ii);
       B.InitExpr (transform_e_e expa  expb binding), ii

    | (A.InitList (i1, ias, i2, []), (B.InitList ibs, ii)) -> 
        let ii' = 
          (match ii with 
          | ii1::ii2::iicommaopt -> 
              tag_symbols [i1;i2] [ii1;ii2] binding ++ iicommaopt
          | _ -> raise Impossible
          )
        in
        B.InitList 
          (Ast_c.unsplit_comma
             (transform_initialisers ias (Ast_c.split_comma ibs) binding
          )),
        ii'

    | (A.InitList (i1, ias, i2, whencode), (B.InitList ibs, ii)) -> 
        failwith "TODO: not handling whencode in initialisers"

    | (A.InitGccDotName (i1, ida, i2, inia), (B.InitGcc (idb, inib), ii)) -> 
        (match ii with 
        | [iidot;iidb;iieq] -> 

            let (_, iidb') = 
              transform_ident Pattern.DontKnow ida (idb, [iidb])  binding 
            in
            let ii' = 
              tag_symbols [i1] [iidot] binding ++
              iidb' ++
              tag_symbols [i2] [iieq] binding
            in
            B.InitGcc (idb,  transform_initialiser inia inib  binding), ii'
        | _ -> raise NoMatch
        )

    | (A.InitGccName (ida, i1, inia), (B.InitGcc (idb, inib), ii)) -> 

        (match ii with 
        | [iidb;iicolon] -> 

            let (_, iidb') = 
              transform_ident Pattern.DontKnow ida (idb, [iidb])  binding 
            in
            let ii' = iidb' ++  tag_symbols [i1] [iicolon] binding
            in
            B.InitGcc (idb,  transform_initialiser inia inib  binding), ii'
        | _ -> raise NoMatch
        )


    | (A.InitGccIndex (i1,ea,i2,i3,inia), (B.InitGccIndex (eb, inib), ii)) -> 
        B.InitGccIndex 
          (transform_e_e ea eb  binding,
           transform_initialiser inia inib binding),
        tag_symbols [i1;i2;i3]  ii  binding

    | (A.InitGccRange (i1,e1a,i2,e2a,i3,i4,inia), 
      (B.InitGccRange (e1b, e2b, inib), ii)) -> 
        B.InitGccRange 
          (transform_e_e e1a e1b  binding,
           transform_e_e e2a e2b  binding,
           transform_initialiser inia inib  binding),
        tag_symbols [i1;i2;i3;i4] ii binding
        

    | A.MultiIni _, _ | A.UniqueIni _,_ | A.OptIni _,_ -> 
      failwith "not handling Opt/Unique/Multi on initialisers"
          
    | _, _ -> raise NoMatch




and transform_initialisers = fun ias ibs ->
 fun binding -> 
  match ias, ibs with
  | [], ys -> ys
  | x::xs, ys -> 
      let permut = Common.uncons_permut ys in
      permut +> Common.fold_k (fun acc ((e, pos), rest) k -> 
        try (
          let e' = 
            match e with 
            | Left y -> Left (transform_initialiser x y binding)
            | Right y -> raise NoMatch
          in
          let rest' = transform_initialisers xs rest binding in
          Common.insert_elem_pos (e', pos) rest'
        ) 
        with NoMatch -> k acc
      )
        (fun _ -> raise NoMatch)
        ys
        
            


(* ------------------------------------------------------------------------- *)
and (transform_ft_ft: (Ast_cocci.fullType, Ast_c.fullType) transformer) = 
 fun typa typb -> 
  fun binding -> 
    match A.unwrap typa, typb with
    | A.Type(cv,ty1), ((qu,il),ty2) ->

	(match cv with
          (* "iso-by-absence" *)
        | None -> transform_t_t ty1 typb  binding
        | Some x -> raise Todo
        )

    | A.DisjType typas, typb -> 
        typas +> Common.fold_k (fun acc typa k -> 
          try transform_ft_ft typa acc  binding
          with NoMatch -> k acc) 
          (fun _ -> raise NoMatch)
          typb

    | A.OptType(_), _  | A.UniqueType(_), _ | A.MultiType(_), _ 
      -> failwith "not handling Opt/Unique/Multi on type"



and (transform_t_t: (Ast_cocci.typeC, Ast_c.fullType) transformer) = 
 fun typa typb -> 
  fun binding -> 
    match A.unwrap typa, typb with

     (* cas general *)
    | A.MetaType(ida,A.Saved,_inherited),  typb -> 
        (* get binding, assert =*=,  distribute info in ida *)
        (match binding +> find_env (term ida) with
        | B.MetaTypeVal typa -> 
          if (Lib_parsing_c.al_type typa =*= Lib_parsing_c.al_type typb)
          then 
            D.distribute_mck (mcodekind ida) D.distribute_mck_type typb binding
          else raise NoMatch
        | _ -> raise Impossible
      )
    | A.MetaType(ida,keep,_inherited),  typb 
      when keep = A.Unitary or keep = A.Nonunitary ->
	D.distribute_mck (mcodekind ida) D.distribute_mck_type typb binding

    | A.MetaType(ida,keep,_inherited),  typb  -> failwith "cannot occur"

    | A.BaseType (basea, signaopt),   (qu, (B.BaseType baseb, ii)) -> 
       (* In ii there is a list, sometimes of length 1 or 2 or 3.
        * And even if in baseb we have a Signed Int, that does not mean
        * that ii is of length 2, cos Signed is the default, so if in signa
        * we have Signed explicitely ? we cant "accrocher" this mcode to 
        * something :( So for the moment when there is signed in cocci,
        * we force that there is a signed in c too (done in pattern.ml).
        *)
        let split_signb_baseb_ii (baseb, ii) = 
          let iis = ii +> List.map (fun (ii,mc) -> ii.Common.str, (ii,mc)) in
          match baseb, iis with

          | B.Void, ["void",i1] -> None, [i1]

          | B.FloatType (B.CFloat),["float",i1] -> None, [i1]
          | B.FloatType (B.CDouble),["double",i1] -> None, [i1]
          | B.FloatType (B.CLongDouble),["long",i1;"double",i2] -> None,[i1;i2]

          | B.IntType (B.CChar), ["char",i1] -> None, [i1]


          | B.IntType (B.Si (sign, base)), xs -> 
              (match sign, base, xs with
              | B.Signed, B.CChar2,   ["signed",i1;"char",i2] -> 
                  Some (B.Signed, i1), [i2]
              | B.UnSigned, B.CChar2,   ["unsigned",i1;"char",i2] -> 
                  Some (B.UnSigned, i1), [i2]

              | B.Signed, B.CShort, ["short",i1] -> None, [i1]
              | B.Signed, B.CShort, ["signed",i1;"short",i2] -> 
                  Some (B.Signed, i1), [i2]
              | B.UnSigned, B.CShort, ["unsigned",i1;"short",i2] -> 
                  Some (B.UnSigned, i1), [i2]

              | B.Signed, B.CInt, ["int",i1] -> None, [i1]
              | B.Signed, B.CInt, ["signed",i1;"int",i2] -> 
                  Some (B.Signed, i1), [i2]
              | B.UnSigned, B.CInt, ["unsigned",i1;"int",i2] -> 
                  Some (B.UnSigned, i1), [i2]

              | B.UnSigned, B.CInt, ["unsigned",i1;] -> 
                  Some (B.UnSigned, i1), []

              | B.Signed, B.CLong, ["long",i1] -> None, [i1]
              | B.Signed, B.CLong, ["signed",i1;"long",i2] -> 
                  Some (B.Signed, i1), [i2]
              | B.UnSigned, B.CLong, ["unsigned",i1;"long",i2] -> 
                  Some (B.UnSigned, i1), [i2]

              | B.Signed, B.CLongLong, ["long",i1;"long",i2] -> None, [i1;i2]
              | B.Signed, B.CLongLong, ["signed",i1;"long",i2;"long",i3] -> 
                  Some (B.Signed, i1), [i2;i3]
              | B.UnSigned, B.CLongLong, ["unsigned",i1;"long",i2;"long",i3] -> 
                  Some (B.UnSigned, i1), [i2;i3]
              | _ -> failwith "strange type1, maybe because of weird order"
              )

          | _ -> failwith "strange type2, maybe because of weird order"
        in
        let signbopt, iibaseb = split_signb_baseb_ii (baseb, ii) in

	let transform_sign signa signb = 
          match signa, signb with
          | None, None -> []
          | Some signa,  Some (signb, ib) -> 
              if Pattern.equal_sign (term signa) signb
              then [tag_one_symbol signa ib  binding]
              else raise NoMatch
          | _, _ -> raise NoMatch
        in
        
        let qu' = qu in (* todo ? or done in transform_ft_ft ? *)
        qu', 
	(match term basea, baseb with
        |  A.VoidType,  B.Void -> 
            assert (signaopt = None); 
            let ii' = tag_symbols [basea] ii binding in
            (B.BaseType B.Void, ii')
	| A.CharType,  B.IntType B.CChar when signaopt = None -> 
            let ii' = tag_symbols [basea] ii binding in
            (B.BaseType (B.IntType B.CChar), ii')


        | A.CharType,  B.IntType (B.Si (sign, B.CChar2)) when signaopt <> None
          -> 
            let ii' = 
              transform_sign signaopt signbopt ++ 
              tag_symbols [basea] iibaseb  binding 
            in
            B.BaseType (B.IntType (B.Si (sign, B.CChar2))), ii'

	| A.ShortType, B.IntType (B.Si (signb, B.CShort)) ->
            let ii' = 
              transform_sign signaopt signbopt ++ 
              tag_symbols [basea] iibaseb  binding 
            in
            B.BaseType (B.IntType (B.Si (signb, B.CShort))), ii'
	| A.IntType,   B.IntType (B.Si (signb, B.CInt))   ->
            let ii' = 
              transform_sign signaopt signbopt ++ 
              tag_symbols [basea] iibaseb  binding 
            in
            B.BaseType (B.IntType (B.Si (signb, B.CInt))), ii'
	| A.LongType,  B.IntType (B.Si (signb, B.CLong))  ->
            let ii' = 
              transform_sign signaopt signbopt ++ 
              tag_symbols [basea] iibaseb  binding 
            in
            B.BaseType (B.IntType (B.Si (signb, B.CLong))), ii'

	| A.FloatType, B.FloatType (B.CFloat) -> 
            raise Todo
	| A.DoubleType, B.FloatType (B.CDouble) -> 
            raise Todo

        | _, B.IntType (B.Si (_, B.CLongLong)) 
        | _, B.FloatType B.CLongDouble 
           -> raise NoMatch
              

        | _ -> raise NoMatch
            

        )

    | A.ImplicitInt (signa),   _ -> 
	failwith "implicitInt pattern not supported"

    | A.Pointer (typa, imult),            (qu, (B.Pointer typb, ii)) -> 
        let ii' = tag_symbols [imult] ii binding in
        let typb' = transform_ft_ft typa typb  binding in
        (qu, (B.Pointer typb', ii'))

    | A.FunctionPointer(ty,lp1,star,rp1,lp2,params,rp2), _ ->
	failwith "TODO: transformation for function pointer"
	          
    | A.Array (typa, _, eaopt, _), (qu, (B.Array (ebopt, typb), _)) -> 
        raise Todo
    | A.StructUnionName(sua, sa), (qu, (B.StructUnionName (sub, sb), ii)) -> 
        (* sa is now an ident, not an mcode, old: ... && (term sa) =$= sb *)
        (match ii with
        | [i1;i2] -> 
            if Pattern.equal_structUnion  (term sua) sub 
            then
              let (sb', i2') = 
                transform_ident Pattern.DontKnow sa (sb, [i2])   binding 
              in
              let i1' = tag_symbols [wrap_mcode sua] [i1]  binding in
              (qu, (B.StructUnionName (sub, sb'), i1' ++ i2'))
            else raise NoMatch
      | _ -> raise Impossible
        )


        

    | A.StructUnionDef(sua, sa, lb, decls, rb), _ -> 
	failwith "to be filled in"

    | A.TypeName sa,  (qu, (B.TypeName sb, ii)) ->
        if (term sa) =$= sb
        then
          let ii' = tag_symbols  [sa] ii binding in
          qu, (B.TypeName sb, ii')
        else raise NoMatch
        
        

    | _ -> raise NoMatch


(*****************************************************************************)
let (transform_re_node: (Ast_cocci.rule_elem, Control_flow_c.node) transformer)
= fun re node -> 
  fun binding -> 

  F.rewrap node (
  match A.unwrap re, F.unwrap node with

  | _, F.Enter | _, F.Exit | _, F.ErrorExit -> raise Impossible

  | A.MetaRuleElem(mcode,_,_inherited), unwrap_node -> 
     (match unwrap_node with
     | F.CaseNode _
     | F.TrueNode | F.FalseNode | F.AfterNode | F.FallThroughNode
       -> 
         if mcode_contain_plus (mcodekind mcode)
         then failwith "try add stuff on fake node";

         (* minusize or contextize a fake node is ok *)
         unwrap_node
     | F.EndStatement None -> 
         if mcode_contain_plus (mcodekind mcode)
         then
           let fake_info = Ast_c.fakeInfo ()  in
           D.distribute_mck (mcodekind mcode) D.distribute_mck_node 
             (F.EndStatement (Some fake_info)) binding
         else unwrap_node
         
     | F.EndStatement (Some _) -> raise Impossible (* really ? *)

     | F.FunHeader _ -> failwith "a MetaRuleElem can't transform a headfunc"
     | n -> D.distribute_mck (mcodekind mcode) D.distribute_mck_node n binding
     )


  (* rene cant have found that a state containing a fake/exit/... should be 
   * transformed 
   * TODO: and F.Fake ?
   *)
  | _, F.EndStatement _ | _, F.CaseNode _
  | _, F.TrueNode | _, F.FalseNode | _, F.AfterNode | _, F.FallThroughNode
    -> raise Impossible
 

  | A.MetaStmt _,  _ -> 
      failwith "I cant have been called. I can only transform MetaRuleElem."
  | A.MetaStmtList _, _ -> 
      failwith "not handling MetaStmtList"

  (* It is important to put this case before the one that follows, cos
     want to transform a switch, even if cocci does not have a switch
     statement, because we may have put an Exp, and so have to
     transform the expressions inside the switch. *)

  | A.Exp exp, nodeb -> 
      let bigf = { 
        Visitor_c.default_visitor_c_s with 
        Visitor_c.kexpr_s = (fun (k,_) e -> 
          try transform_e_e exp e   binding 
          with NoMatch -> k e
        )
      }
      in
      F.unwrap (Visitor_c.vk_node_s bigf node)

  | A.Ty ty, nodeb -> 
      let bigf = { 
        Visitor_c.default_visitor_c_s with 
        Visitor_c.ktype_s = (fun (k,_) t -> 
          try transform_ft_ft ty t   binding 
          with NoMatch -> k t
        )
      }
      in
      F.unwrap (Visitor_c.vk_node_s bigf node)


  | A.FunHeader (mckstart, allminus, stoa, tya, ida, oparen, paramsa, cparen),
    F.FunHeader ((idb, (retb, (paramsb, (isvaargs, iidotsb))), stob), ii) -> 
      (match ii with
      | iidb::ioparenb::icparenb::iifakestart::iistob -> 
          (* ugly trick for use_ref, important to first do this
           * and only after trying to transform the other tokens.
           * this for transform_proto
           *)
          let (idb', iidb') = 
            transform_ident Pattern.LocalFunction ida (idb, [iidb])   binding 
          in

          let iifakestart' = D.tag_with_mck mckstart iifakestart binding in 
          
          let stob' = stob in
          let (iistob') = 
            match stoa, fst stob, iistob with
            | None, _, _ -> 
                if allminus 
                then 
                  let minusizer = iistob +> List.map (fun _ -> 
                    "fake", 
                    {Ast_cocci.line = 0; column =0},
                    (Ast_cocci.MINUS(Ast_cocci.NoPos, []))
                  ) in
                  tag_symbols minusizer iistob binding
                else iistob
            | Some x, B.Sto B.Static, stostatic::stoinline -> 
                assert (term x = A.Static);
                tag_symbols [wrap_mcode x] [stostatic] binding ++ stoinline
                  
            | _ -> raise NoMatch
                
          in
          let retb' = 
            match tya with
            | None -> 
                if allminus 
                then
		  (* perhaps things have to be done differently here for pos
		     argument of MINUS *)
		  D.distribute_mck (Ast_cocci.MINUS(Ast_cocci.NoPos,[]))
		    D.distribute_mck_type
                    retb binding       
                else retb
            | Some tya -> transform_ft_ft tya retb binding
          in
          
      
          let iiparensb' = tag_symbols [oparen;cparen] [ioparenb;icparenb] binding
          in
          
          let seqstyle = 
            (match A.unwrap paramsa with 
            | A.DOTS _ -> Ordered 
            | A.CIRCLES _ -> Unordered 
            | A.STARS _ -> failwith "not yet handling stars (interprocedural stuff)"
            ) 
          in
          let paramsb' = 
            transform_params seqstyle (A.undots paramsa) paramsb    binding 
          in
          
          if isvaargs then failwith "not handling variable length arguments func";
          let iidotsb' = iidotsb in (* todo *)

          F.FunHeader 
            ((idb', (retb', (paramsb', (isvaargs, iidotsb'))), stob'), 
            (iidb'++iiparensb'++[iifakestart']++iistob'))
      | _ -> raise Impossible
      )
      

  | A.Decl (mck,decla), F.Decl declb -> 
      F.Decl (transform_de_de mck decla declb  binding) 

  | A.SeqStart mcode, F.SeqStart (st, level, i1) -> 
      F.SeqStart (st, level, tag_one_symbol mcode i1 binding)

  | A.SeqEnd mcode, F.SeqEnd (level, i2) -> 
      F.SeqEnd (level, tag_one_symbol mcode i2 binding)


  | A.ExprStatement (ea, i1), F.ExprStatement (st, (Some eb, ii)) -> 
      F.ExprStatement (st, (Some (transform_e_e ea eb  binding), 
                            tag_symbols [i1] ii  binding ))

  | A.IfHeader (i1,i2, ea, i3), F.IfHeader (st, (eb,ii)) -> 
      F.IfHeader (st, (transform_e_e ea eb  binding,
                       tag_symbols [i1;i2;i3] ii binding))
  | A.Else ia, F.Else ib -> F.Else (tag_one_symbol ia ib binding)
  | A.WhileHeader (i1, i2, ea, i3), F.WhileHeader (st, (eb, ii)) -> 
      F.WhileHeader (st, (transform_e_e ea eb  binding, 
                          tag_symbols [i1;i2;i3] ii  binding))
  | A.DoHeader ia, F.DoHeader (st, ib) -> 
      F.DoHeader (st, tag_one_symbol ia ib  binding)
  | A.WhileTail (i1,i2,ea,i3,i4), F.DoWhileTail (eb, ii) -> 
      F.DoWhileTail (transform_e_e ea eb binding, 
                     tag_symbols [i1;i2;i3;i4] ii  binding)
  | A.ForHeader (i1, i2, ea1opt, i3, ea2opt, i4, ea3opt, i5), 
    F.ForHeader (st, (((eb1opt,ib1), (eb2opt,ib2), (eb3opt,ib3)), ii))
    -> 
      let transform (ea, ia) (eb, ib) = 
        transform_option (fun ea eb -> transform_e_e ea eb binding) ea eb, 
        tag_symbols ia ib   binding
      in
      F.ForHeader (st,
            ((transform (ea1opt, [i3]) (eb1opt, ib1),
              transform (ea2opt, [i4]) (eb2opt, ib2),
              transform (ea3opt, []) (eb3opt, ib3)),
            tag_symbols [i1;i2;i5] ii  binding))

  | A.SwitchHeader(i1, i2, ea, i3), F.SwitchHeader _ ->
      failwith "switch not supported"

  | A.Break (i1, i2), F.Break (st, ((),ii)) -> 
      F.Break (st, ((), tag_symbols [i1;i2] ii   binding))
  | A.Continue (i1, i2), F.Continue (st, ((),ii)) -> 
      F.Continue (st, ((), tag_symbols [i1;i2] ii   binding))
  | A.Return (i1, i2), F.Return (st, ((),ii)) -> 
      F.Return (st, ((), tag_symbols [i1;i2] ii   binding))
  | A.ReturnExpr (i1, ea, i2), F.ReturnExpr (st, (eb, ii)) -> 
      F.ReturnExpr (st, (transform_e_e ea eb binding, 
                         tag_symbols [i1;i2] ii   binding))

  | A.Include(incl,filea), F.CPPInclude (fileb, ii) ->
      if ((term filea) =$= fileb)
      then 
        F.CPPInclude (fileb, tag_symbols [incl;filea] ii binding)
      else raise NoMatch
  
  | A.Define(define,ida,bodya), F.CPPDefine ((idb, bodyb), ii) ->
      (match ii with 
      | [iidefine;iidb;iibody] -> 
          let (idb', iidb') = 
            transform_ident Pattern.DontKnow ida (idb, [iidb])   binding 
          in
          let iidefine' = tag_symbols [define] [iidefine] binding in
          let iibody' = 
            (match A.unwrap bodya with
            | A.DMetaId (idbodya, keep) -> 
                if keep = A.Unitary
                then tag_symbols [idbodya] [iibody] binding
                else 
                  let v = binding +> find_env ((term idbodya) : string) in
	          (match v with
	          | B.MetaTextVal sa -> 
                    if (sa =$= bodyb) 
                    then tag_symbols [idbodya] [iibody] binding
                    else raise NoMatch
	        | _ -> raise Impossible
	        )

                
            | A.Ddots (dots) -> 
                tag_symbols [dots] [iibody] binding
            )
          in
          F.CPPDefine ((idb, bodyb), iidefine'++iidb'++iibody')

      | _ -> raise Impossible
      )
      
  | A.Default(def,colon), F.Default _ -> failwith "switch not supported"
  | A.Case(case,ea,colon), F.Case _ -> failwith "switch not supported"

  | _, F.ExprStatement (_, (None, ii)) -> raise NoMatch (* happen ? *)

  (* have not a counter part in coccinelle, for the moment *)
  | _, F.Label _
  | _, F.CaseRange _
  | _, F.Goto _ (* goto is just created by asttoctl2, with no +- info *)
  | _, F.Asm
  | _, F.IfCpp _
    -> raise Impossible

  | _, _ -> raise NoMatch
  )

  
(* ------------------------------------------------------------------------- *)
let transform_proto2 a b binding (qu, iiptvirg) infolastparen = 
  let node' = transform_re_node a b binding in
  match F.unwrap node' with
  | F.FunHeader 
      ((s, ft, storage), iis::iioparen::iicparen::iifake::iisto) -> 

        (* Also delete the ';' at the end of the proto.
         * The heuristic is to see if the ')' was deleted. Buggy but
         * first step.
         * todo: what if SP is '-f(int i) { +f(int i, char j) { ' 
         * I will not accuratly modify the proto.
         * todo?: maybe can use the allminusinfo of Ast_cocci.FunHeader ?
         *)
        let iiptvirg' = 
          if mcode_simple_minus (mcodekind infolastparen)
          then tag_one_symbol infolastparen iiptvirg  binding
          else iiptvirg
        in
        B.Declaration 
          (B.DeclList 
             ([((Some ((s, None), [iis])), 
                (qu, (B.FunctionType ft, [iioparen;iicparen])), 
                storage),
               []
             ], iiptvirg'::iifake::iisto)) 
          
  | _ -> 
      raise Impossible
let transform_proto a b c d e = 
  Common.profile_code "Transformation.transform(proto)?" 
   (fun () -> transform_proto2 a b c d e)


(*****************************************************************************)
(* Entry points *)
(*****************************************************************************)

let (transform2: Lib_engine.transformation_info -> F.cflow -> F.cflow) = 
 fun xs cflow -> 
  (* find the node, transform, update the node,  and iter for all elements *)

   xs +> List.fold_left (fun acc (nodei, binding, rule_elem) -> 
      (* subtil: not cflow#nodes but acc#nodes *)
      let node  = acc#nodes#assoc nodei in 

      if !Flag_engine.show_misc then pr2 "transform one node";
      let node' = transform_re_node rule_elem node binding in

      (* assert that have done something. But with metaruleElem sometimes 
         dont modify fake nodes. So special case before on Fake nodes. *)
      (match F.unwrap node with
      | F.Enter | F.Exit | F.ErrorExit
      | F.EndStatement _ | F.CaseNode _        
      | F.Fake
      | F.TrueNode | F.FalseNode | F.AfterNode | F.FallThroughNode 
          -> ()
      | _ -> () (* assert (not (node =*= node')); *)
      );

      acc#replace_node (nodei, node')
     ) cflow

let transform a b = 
  Common.profile_code "Transformation.transform(proto)?" 
    (fun () -> transform2 a b)
