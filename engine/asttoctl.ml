(* true = don't see all matched nodes, only modified ones *)
let onlyModif = ref true
(* set to true for line numbers in the output of ctl_engine *)
let line_numbers = ref false
(* if true, only eg if header is included in not for ...s *)
let simple_get_end = ref false(*true*)

(* Question: where do we put the existential quantifier for or.  At the
moment, let it float inwards. *)

(* nest shouldn't overlap with what comes after.  not checked for. *)

module Ast = Ast_cocci
module V = Visitor_ast
module CTL = Ast_ctl
module FV = Free_vars

let warning s = Printf.fprintf stderr "warning: %s\n" s

type cocci_predicate = Lib_engine.predicate * string Ast_ctl.modif
type formula =
    (cocci_predicate,string, Wrapper_ctl.info) Ast_ctl.generic_ctl


let aftpred = (Lib_engine.After,CTL.Control)
let retpred = (Lib_engine.Return,CTL.Control)
let exitpred = (Lib_engine.ErrorExit,CTL.Control)

let intersect l1 l2 = List.filter (function x -> List.mem x l2) l1
let subset l1 l2 = List.for_all (function x -> List.mem x l2) l1

(* --------------------------------------------------------------------- *)

let wrap n ctl = (ctl,n)

let aftret =
  wrap 0 (CTL.Or(wrap 0 (CTL.Pred aftpred),wrap 0 (CTL.Pred exitpred)))

let wrapImplies n (x,y) = wrap n (CTL.Implies(x,y))
let wrapExists n (x,y) = wrap n (CTL.Exists(x,y))
let wrapAnd n (x,y) = wrap n (CTL.And(x,y))
let wrapOr n (x,y) = wrap n (CTL.Or(x,y))
let wrapAU n (x,y) = wrap n (CTL.AU(CTL.FORWARD,x,y))
let wrapEU n (x,y) = wrap n (CTL.EU(CTL.FORWARD,x,y))
let wrapAX n (x) = wrap n (CTL.AX(CTL.FORWARD,1,x))
let wrapAXc n count (x) = wrap n (CTL.AX(CTL.FORWARD,count,x))
let wrapEX n (x) = wrap n (CTL.EX(CTL.FORWARD,1,x))
let wrapAG n (x) = wrap n (CTL.AG(CTL.FORWARD,x))
let wrapEG n (x) = wrap n (CTL.EG(CTL.FORWARD,x))
let wrapAF n (x) = wrap n (CTL.AF(CTL.FORWARD,x))
let wrapEF n (x) = wrap n (CTL.EF(CTL.FORWARD,x))
let wrapNot n (x) = wrap n (CTL.Not(x))
let wrapPred n (x) = wrap n (CTL.Pred(x))
let wrapLet n (x,y,z) = wrap n (CTL.Let(x,y,z))
let wrapRef n (x) = wrap n (CTL.Ref(x))

(* --------------------------------------------------------------------- *)

let get_option fn = function
    None -> None
  | Some x -> Some (fn x)

let get_list_option fn = function
    None -> []
  | Some x -> fn x

(* --------------------------------------------------------------------- *)
(* --------------------------------------------------------------------- *)
(* Eliminate OptStm *)

(* for optional thing with nothing after, should check that the optional thing
never occurs.  otherwise the matching stops before it occurs *)
let elim_opt =
  let mcode x = x in
  let donothing r k e = k e in

  let rec dots_list unwrapped wrapped =
    match (unwrapped,wrapped) with
      ([],_) -> []

    | (Ast.Dots(_,_)::Ast.OptStm(stm)::(Ast.Dots(_,_) as u)::urest,
       d0::_::d1::rest)
    | (Ast.Nest(_)::Ast.OptStm(stm)::(Ast.Dots(_,_) as u)::urest,
       d0::_::d1::rest) ->
	let rw = Ast.rewrap stm in
	let rwd = Ast.rewrap stm in
	let new_rest1 = dots_list (u::urest) (d1::rest) in
	let new_rest2 = dots_list urest rest in
	[d0;rw(Ast.Disj[rwd(Ast.DOTS(stm::new_rest1));
			 rwd(Ast.DOTS(new_rest2))])]

    | (Ast.OptStm(stm)::urest,_::rest) ->
	let rw = Ast.rewrap stm in
	let rwd = Ast.rewrap stm in
	let new_rest = dots_list urest rest in
	[rw(Ast.Disj[rwd(Ast.DOTS(stm::new_rest));rwd(Ast.DOTS(new_rest))])]

    | ([Ast.Dots(_,_);Ast.OptStm(stm)],[d1;_]) ->
	let rw = Ast.rewrap stm in
	let rwd = Ast.rewrap stm in
	[d1;rw(Ast.Disj[rwd(Ast.DOTS([stm]));rwd(Ast.DOTS([d1]))])]

    | ([Ast.Nest(_);Ast.OptStm(stm)],[d1;_]) ->
	let rw = Ast.rewrap stm in
	let rwd = Ast.rewrap stm in
	let dots =
	  Ast.Dots(("...",{ Ast.line = 0; Ast.column = 0 },
		    Ast.CONTEXT(Ast.NOTHING)),
		   []) in
	[d1;rw(Ast.Disj[rwd(Ast.DOTS([stm]));rwd(Ast.DOTS([rw dots]))])]

    | (_::urest,stm::rest) -> stm :: (dots_list urest rest)
    | _ -> failwith "not possible" in

  let stmtdotsfn r k d =
    let d = k d in
    Ast.rewrap d
      (match Ast.unwrap d with
	Ast.DOTS(l) -> Ast.DOTS(dots_list (List.map Ast.unwrap l) l)
      | Ast.CIRCLES(l) -> failwith "elimopt: not supported"
      | Ast.STARS(l) -> failwith "elimopt: not supported") in
  
  V.rebuilder
    mcode mcode mcode mcode mcode mcode mcode mcode mcode mcode mcode
    donothing donothing stmtdotsfn
    donothing donothing donothing donothing donothing donothing donothing
    donothing donothing donothing

(* --------------------------------------------------------------------- *)
(* Count depth of braces.  The translation of a closed brace appears deeply
nested within the translation of the sequence term, so the name of the
paren var has to take into account the names of the nested braces.  On the
other hand the close brace does not escape, so we don't have to take into
account other paren variable names. *)

let brace_table =
  (Hashtbl.create(50) :
     (Ast.statement (* always a seq/fundecl *),string (*paren var*)) Hashtbl.t)

let count_nested_braces =
  let bind x y = max x y in
  let option_default = 0 in
  let stmt_count r k s =
    match Ast.unwrap s with
      Ast.Seq(_,_,_,_,_) | Ast.FunDecl(_,_,_,_,_,_) ->
	let nested = k s in
	Hashtbl.add brace_table s ("p"^(string_of_int nested));
	nested + 1
    | _ -> k s in
  let donothing r k e = k e in
  let mcode r x = 0 in
  let recursor = V.combiner bind option_default
      mcode mcode mcode mcode mcode mcode mcode mcode mcode mcode mcode
      donothing donothing donothing
      donothing donothing donothing donothing donothing donothing
      donothing stmt_count donothing donothing in
  recursor.V.combiner_statement

(* --------------------------------------------------------------------- *)
(* Whenify *)
(* For A ... B, neither A nor B should occur in the code matched by the ...
We add these to any when code associated with the dots *)

let rec get_end ((_,extender,_) as fvinfo) f s =
  match Ast.unwrap s with
    Ast.Disj(stmt_dots_list) ->
      List.concat
	(List.map
	   (function x ->
	     match Ast.unwrap x with
	       Ast.DOTS(l) ->
		 (match l with [] -> [] | xs -> get_end fvinfo f (f xs))
	     | _ -> failwith "circles and stars not supported")
	   stmt_dots_list)
  | Ast.IfThen(header,_) (* take header only, for both first and last *)
  | Ast.IfThenElse(header,_,_,_)
  | Ast.While(header,_) -> 
      if !simple_get_end
      then
	let res = Ast.rewrap s (Ast.Atomic header) in
	let _ = extender res in
	[res]
      else [s]
  | Ast.Dots(_,_) -> []
  | Ast.OptStm(stm) -> [stm]
  | Ast.UniqueStm(stm) -> [stm]
  | Ast.MultiStm(stm) -> [stm]
  | _ -> [s]

and get_first fvinfo s =
  get_end fvinfo (function xs -> List.hd xs) s

and get_last fvinfo s =
  get_end fvinfo (function xs -> List.hd (List.rev xs)) s


(* --------------------------------------------------------------------- *)
(* Top-level code *)

let ctr = ref 0
let fresh_var _ =
  let c = !ctr in
  (*ctr := !ctr + 1;*)
  Printf.sprintf "v%d" c

let labctr = ref 0
let fresh_label_var s =
  let c = !labctr in
  labctr := !labctr + 1;
  Printf.sprintf "%s%d" s c

let lctr = ref 0
let fresh_let_var _ =
  let c = !lctr in
  lctr := !lctr + 1;
  Printf.sprintf "l%d" c

let sctr = ref 0
let fresh_metavar _ =
  let c = !sctr in
(*sctr := !sctr + 1;*)
  Printf.sprintf "_S%d" c

let get_unquantified quantified vars =
  List.filter (function x -> not (List.mem x quantified)) vars

type after = After of formula | Guard of formula | Tail

let make_seq n l =
  let rec loop = function
      [] -> failwith "not possible"
    | [x] -> x
    | x::xs -> wrapAnd n (x,wrapAX n (loop xs)) in
  loop l

let make_seq_after2 n first = function
    After rest -> wrapAnd n (first,wrapAXc n 2 rest)
  | _ -> first

let make_seq_after n first = function
    After rest -> make_seq n [first;rest]
  | _ -> first

let a2n = function After f -> Guard f | x -> x

let and_opt n first = function
    After rest -> wrapAnd n (first,rest)
  | _ -> first

let contains_modif =
  let bind x y = x or y in
  let option_default = false in
  let mcode r (_,_,kind) =
    match kind with
      Ast.MINUS(_) -> true
    | Ast.PLUS -> failwith "not possible"
    | Ast.CONTEXT(info) -> not (info = Ast.NOTHING) in
  let do_nothing r k e = k e in
  let recursor =
    V.combiner bind option_default
      mcode mcode mcode mcode mcode mcode mcode mcode mcode mcode mcode
      do_nothing do_nothing do_nothing
      do_nothing do_nothing do_nothing do_nothing do_nothing do_nothing
      do_nothing do_nothing do_nothing do_nothing in
  recursor.V.combiner_rule_elem

let make_match n guard free_table used_after code =
  if guard
  then wrapPred n (Lib_engine.Match(code),CTL.Control)
  else
    let v = fresh_var() in
    if contains_modif code
    then wrapExists n (v,wrapPred n (Lib_engine.Match(code),CTL.Modif v))
    else
      let any_used_after =
	let fvs = Hashtbl.find free_table (FV.Rule_elem code) in
	List.exists (function x -> List.mem x used_after) fvs in
      if !onlyModif && not any_used_after
      then wrapPred n (Lib_engine.Match(code),CTL.Control)
      else wrapExists n (v,wrapPred n (Lib_engine.Match(code),CTL.UnModif v))

let make_raw_match n code = wrapPred n (Lib_engine.Match(code),CTL.Control)

let rec seq_fvs free_table quantified = function
    [] -> []
  | term1::terms ->
      let t1fvs =
	get_unquantified quantified (Hashtbl.find free_table term1) in
      let termfvs =
	List.fold_left Common.union_set []
	  (List.map
	     (function t ->
	       get_unquantified quantified (Hashtbl.find free_table t))
	     terms) in
      let bothfvs = Common.inter_set t1fvs termfvs in
      let t1onlyfvs = Common.minus_set t1fvs bothfvs in
      let new_quantified = Common.union_set bothfvs quantified in
      (t1onlyfvs,bothfvs)::(seq_fvs free_table new_quantified terms)

let seq_fvs2 free_table quantified term1 term2 =
  match seq_fvs free_table quantified [term1;term2] with
    [(t1fvs,bfvs);(t2fvs,[])] -> (t1fvs,bfvs,t2fvs)
  | _ -> failwith "impossible"

let seq_fvs3 free_table quantified term1 term2 term3 =
  match seq_fvs free_table quantified [term1;term2;term3] with
    [(t1fvs,b12fvs);(t2fvs,b23fvs);(t3fvs,[])] ->
      (t1fvs,b12fvs,t2fvs,b23fvs,t3fvs)
  | _ -> failwith "impossible"

let seq_fvs4 free_table quantified term1 term2 term3 term4 =
  match seq_fvs free_table quantified [term1;term2;term3;term4] with
    [(t1fvs,b12fvs);(t2fvs,b23fvs);(t3fvs,b34fvs);(t4fvs,[])] ->
      (t1fvs,b12fvs,t2fvs,b23fvs,t3fvs,b34fvs,t4fvs)
  | _ -> failwith "impossible"

let seq_fvs5 free_table quantified term1 term2 term3 term4 term5 =
  match seq_fvs free_table quantified [term1;term2;term3;term4;term5] with
    [(t1fvs,b12fvs);(t2fvs,b23fvs);(t3fvs,b34fvs);(t4fvs,b45fvs);(t5fvs,[])] ->
      (t1fvs,b12fvs,t2fvs,b23fvs,t3fvs,b34fvs,t4fvs,b45fvs,t5fvs)
  | _ -> failwith "impossible"

let quantify n =
  List.fold_right (function cur -> function code -> wrapExists n (cur,code))

let intersectll lst nested_list =
  List.filter (function x -> List.exists (List.mem x) nested_list) lst

(* --------------------------------------------------------------------- *)
(* annotate dots with before and after neighbors *)

type befaft =
    Paren of Ast.rule_elem * string (*pren_var*)
  | Other of Ast.statement
  | Other_dots of Ast.statement Ast.dots

let before_after_table =
  (Hashtbl.create(50) :
     (Ast.statement (* always a dots *),befaft list ref) Hashtbl.t)

let update e v =
  let cell =
    try Hashtbl.find before_after_table e
    with Not_found ->
      let cell = ref [] in Hashtbl.add before_after_table e cell; cell in
  cell := v @ !cell

let rec get_before sl a =
  match Ast.unwrap sl with
    Ast.DOTS(x) ->
      let rec loop sl a =
	match sl with
	  [] -> a
	| e::sl -> loop sl (get_before_e e a) in
      loop x a
  | Ast.CIRCLES(x) -> failwith "not supported"
  | Ast.STARS(x) -> failwith "not supported"

and get_before_e s a =
  match Ast.unwrap s with
    Ast.Dots(_,_) -> update s a; a
  | Ast.Nest(stmt_dots) ->
      let _ = get_before stmt_dots a in update s a; [Other_dots stmt_dots]
  | Ast.Disj(stmt_dots_list) ->
      List.fold_left
	(function rest -> function cur ->
	  Common.union_set (get_before cur a) rest)
	[] stmt_dots_list
  | Ast.Atomic(ast) -> [Other s]
  | Ast.Seq(lbrace,decls,_,body,rbrace) ->
      let index = Hashtbl.find brace_table s in
      let _ = get_before body (get_before decls [Paren(lbrace,index)]) in
      [Paren(rbrace,index)]
  | Ast.IfThen(ifheader,branch) -> let _ = get_before_e branch [] in [Other s]
  | Ast.IfThenElse(ifheader,branch1,els,branch2) ->
      let _ = get_before_e branch1 [] in
      let _ = get_before_e branch2 [] in
      [Other s]
  | Ast.While(header,body) -> let _ = get_before_e body [] in [Other s]
  | Ast.FunDecl(header,lbrace,decls,_,body,rbrace) ->
      let index = Hashtbl.find brace_table s in
      let _ = get_before body (get_before decls [Paren(lbrace,index)]) in
      []
  | _ -> failwith "not supported"

let rec get_after sl a =
  match Ast.unwrap sl with
    Ast.DOTS(x) ->
      let rec loop sl =
	match sl with
	  [] -> a
	| e::sl -> get_after_e e (loop sl) in
      loop x
  | Ast.CIRCLES(x) -> failwith "not supported"
  | Ast.STARS(x) -> failwith "not supported"

and get_after_e s a =
  match Ast.unwrap s with
    Ast.Dots(_,_) -> update s a; a
  | Ast.Nest(stmt_dots) ->
      let _ = get_after stmt_dots a in update s a; [Other_dots stmt_dots]
  | Ast.Disj(stmt_dots_list) ->
      List.fold_left
	(function rest -> function cur ->
	  Common.union_set (get_after cur a) rest)
	[] stmt_dots_list
  | Ast.Atomic(ast) -> [Other s]
  | Ast.Seq(lbrace,decls,_,body,rbrace) ->
      let index = Hashtbl.find brace_table s in
      let _ = get_after decls (get_after body [Paren(rbrace,index)]) in
      [Paren(lbrace,index)]
  | Ast.IfThen(ifheader,branch) -> let _ = get_after_e branch a in [Other s]
  | Ast.IfThenElse(ifheader,branch1,els,branch2) ->
      let _ = get_after_e branch1 a in
      let _ = get_after_e branch2 a in
      [Other s]
  | Ast.While(header,body) -> let _ = get_after_e body a in [Other s]
  | Ast.FunDecl(header,lbrace,decls,_,body,rbrace) ->
      let index = Hashtbl.find brace_table s in
      let _ = get_after decls (get_after body [Paren(rbrace,index)]) in
      []
  | _ -> failwith "not supported"



let preprocess_dots sl =
  let _ = get_before sl [] in
  let _ = get_after sl [] in
  ()

let preprocess_dots_e sl =
  let _ = get_before_e sl [] in
  let _ = get_after_e sl [] in
  ()

(* --------------------------------------------------------------------- *)
(* the main translation loop *)

let is_dots y = match Ast.unwrap y with Ast.Dots(_,_) -> Some y | _ -> None

let decl_to_not_decl n dots stmt extender make_match f =
  if dots
  then f
  else
    let de =
      Ast.rewrap stmt
	(Ast.Decl (Ast.make_meta_decl "d" (Ast.CONTEXT(Ast.NOTHING)))) in
    let _ = extender (Ast.rewrap stmt (Ast.Atomic(de))) in
    wrap n (CTL.AU(CTL.FORWARD,
		   make_match de,
		   wrap n (CTL.And(wrap n (CTL.Not (make_match de)), f))))

let rec statement_list stmt_list ((free_table,_,_) as fvinfo)
    after quantified guard =
  let n = if !line_numbers then Ast.get_line stmt_list else 0 in
  match Ast.unwrap stmt_list with
    Ast.DOTS(x) ->
      let fvs =
	List.map (function x -> Hashtbl.find free_table (FV.Statement x)) x in
      let rec loop quantified = function
	  ([],_) -> (match after with After f -> f | _ -> wrap n CTL.True)
	| ([e],_) -> statement e fvinfo after quantified guard
	| (e::sl,fv::fvs) ->
	    let shared = intersectll fv fvs in
	    let unqshared = get_unquantified quantified shared in
	    let new_quantified = Common.union_set unqshared quantified in
	    quantify n unqshared
	      (statement e fvinfo (After(loop new_quantified (sl,fvs)))
		 new_quantified guard)
	| _ -> failwith "not possible" in
      loop quantified (x,fvs)
  | Ast.CIRCLES(x) -> failwith "not supported"
  | Ast.STARS(x) -> failwith "not supported"

and statement stmt ((free_table,extender,used_after) as fvinfo)
    after quantified guard =

  let n = if !line_numbers then Ast.get_line stmt else 0 in
  let wrapExists = wrapExists n in
  let wrapAnd = wrapAnd n in
  let wrapOr = wrapOr n in
  let wrapAU = wrapAU n in
  let wrapAX = wrapAX n in
  let wrapEX = wrapEX n in
  let wrapAG = wrapAG n in
  let wrapAF = wrapAF n in
  let wrapNot = wrapNot n in
  let wrapPred = wrapPred n in
  let make_seq = make_seq n in
  let make_seq_after2 = make_seq_after2 n in
  let make_seq_after = make_seq_after n in
  let and_opt = and_opt n in
  let quantify = quantify n in
  let make_match = make_match n guard free_table used_after in
  let make_raw_match = make_raw_match n in

  let make_meta_rule_elem d =
    let re = Ast.make_meta_rule_elem (fresh_metavar()) d in
    let _ = extender (Ast.rewrap stmt (Ast.Atomic(re))) in
    re in

  match Ast.unwrap stmt with
    Ast.Atomic(ast) ->
      (match Ast.unwrap ast with
	Ast.MetaStmt((s,i,(Ast.CONTEXT(Ast.BEFOREAFTER(_,_)) as d)))
      | Ast.MetaStmt((s,i,(Ast.CONTEXT(Ast.AFTER(_)) as d))) ->
	  let label_var = (*fresh_label_var*) "_lab" in
	  let label_pred = wrapPred(Lib_engine.Label(label_var),CTL.Control) in
	  let prelabel_pred =
	    wrapPred(Lib_engine.PrefixLabel(label_var),CTL.Control) in
	  let matcher d = make_match (make_meta_rule_elem d) in
	  let full_metamatch = matcher d in
	  let first_metamatch =
	    matcher
	      (match d with
		Ast.CONTEXT(Ast.BEFOREAFTER(bef,_)) ->
		  Ast.CONTEXT(Ast.BEFORE(bef))
	      |	Ast.CONTEXT(_) -> Ast.CONTEXT(Ast.NOTHING)
	      | Ast.MINUS(_) | Ast.PLUS -> failwith "not possible") in
	  let middle_metamatch =
	    matcher
	      (match d with
		Ast.CONTEXT(_) -> Ast.CONTEXT(Ast.NOTHING)
	      | Ast.MINUS(_) | Ast.PLUS -> failwith "not possible") in
	  let last_metamatch =
	    matcher
	      (match d with
		Ast.CONTEXT(Ast.BEFOREAFTER(_,aft)) ->
		  Ast.CONTEXT(Ast.AFTER(aft))
	      |	Ast.CONTEXT(_) -> d
	      | Ast.MINUS(_) | Ast.PLUS -> failwith "not possible") in
	  
	  let left_or =
	    make_seq
	      [full_metamatch; and_opt (wrapNot(prelabel_pred)) after] in
	  let right_or =
	    make_seq
	      [first_metamatch;
		wrapAU(wrapAnd(middle_metamatch,prelabel_pred),
		       make_seq
			 [wrapAnd(last_metamatch,prelabel_pred);
			   and_opt (wrapNot(prelabel_pred)) after])] in
	  quantify (label_var::get_unquantified quantified [s])
	    (wrapAnd(make_raw_match ast,
		     wrapAnd(label_pred,wrapOr(left_or,right_or))))
	    
      |	Ast.MetaStmt((s,i,d)) ->
	  let label_var = (*fresh_label_var*) "_lab" in
	  let label_pred = wrapPred(Lib_engine.Label(label_var),CTL.Control) in
	  let prelabel_pred =
	    wrapPred(Lib_engine.PrefixLabel(label_var),CTL.Control) in
	  let matcher d = make_match (make_meta_rule_elem d) in
	  let first_metamatch = matcher d in
	  let rest_metamatch =
	    matcher
	      (match d with
		Ast.MINUS(_) -> Ast.MINUS([])
	      | Ast.CONTEXT(_) -> Ast.CONTEXT(Ast.NOTHING)
	      | Ast.PLUS -> failwith "not possible") in
	  (* first_nodea and first_nodeb are separated here and above to
	     improve let sharing - only first_nodea is unique to this site *)
	  let first_nodeb = wrapAnd(first_metamatch,label_pred) in
	  let rest_nodes = wrapAnd(rest_metamatch,prelabel_pred) in
	  let last_node = and_opt (wrapNot(prelabel_pred)) after in
	  quantify (label_var::get_unquantified quantified [s])
	    (wrapAnd(make_raw_match ast,
		     (make_seq [first_nodeb; wrapAU(rest_nodes,last_node)])))
      |	_ ->
	  let stmt_fvs = Hashtbl.find free_table (FV.Statement stmt) in
	  let fvs = get_unquantified quantified stmt_fvs in
	  make_seq_after (quantify fvs (make_match ast)) after)
  | Ast.Seq(lbrace,decls,dots,body,rbrace) ->
      let (lbfvs,b1fvs,_,b2fvs,_,b3fvs,rbfvs) =
	seq_fvs4 free_table quantified
	  (FV.Rule_elem lbrace) (FV.StatementDots decls)
	  (FV.StatementDots body) (FV.Rule_elem rbrace) in
      let v = Hashtbl.find brace_table stmt in
      let paren_pred = wrapPred(Lib_engine.Paren v,CTL.Control) in
      let start_brace =
	wrapAnd(quantify lbfvs (make_match lbrace),paren_pred) in
      let end_brace =
	wrapAnd(quantify rbfvs (make_match rbrace),paren_pred) in
      let new_quantified2 =
	Common.union_set b1fvs (Common.union_set b2fvs quantified) in
      let new_quantified3 = Common.union_set b3fvs new_quantified2 in
      wrapExists
	(v,quantify b1fvs
	   (make_seq
	      [start_brace;
		quantify b2fvs
		  (statement_list decls fvinfo
		     (After
			(decl_to_not_decl n dots stmt extender make_match
			   (quantify b3fvs
			      (statement_list body fvinfo
				 (After (make_seq_after end_brace after))
				 new_quantified3 guard))))
		     new_quantified2 guard)]))
  | Ast.IfThen(ifheader,branch) ->

(* "if (test) thn" becomes:
    if(test) & AX((TrueBranch & AX thn) v FallThrough v After)

    "if (test) thn; after" becomes:
    if(test) & AX((TrueBranch & AX thn) v FallThrough v (After & AXAX after))
             & EX After
*)

       (* free variables *) 
       let (efvs,bfvs,_) =
	 seq_fvs2 free_table quantified
	   (FV.Rule_elem ifheader) (FV.Statement branch) in
       let new_quantified = Common.union_set bfvs quantified in
       (* if header *)
       let if_header = quantify efvs (make_match ifheader) in
       (* then branch and after *)
       let true_branch =
	 make_seq
	   [wrapPred(Lib_engine.TrueBranch,CTL.Control);
	     statement branch fvinfo (a2n after) new_quantified guard] in
       let fall_branch =  wrapPred(Lib_engine.FallThrough,CTL.Control) in
       let after_pred = wrapPred(Lib_engine.After,CTL.Control) in
       let after_branch = make_seq_after2 after_pred after in
       let or_cases = wrapOr(true_branch,wrapOr(fall_branch,after_branch)) in
       (* the code *)
       (match after with
	 After _ -> (* pattern doesn't end here *)
	   quantify bfvs
	     (wrapAnd (if_header, wrapAnd(wrapAX or_cases, wrapEX after_pred)))
       | _ -> quantify bfvs (wrapAnd(if_header, wrapAX or_cases)))
	 
  | Ast.IfThenElse(ifheader,branch1,els,branch2) ->

(*  "if (test) thn else els" becomes:
    if(test) & AX((TrueBranch & AX thn) v
                  (FalseBranch & AX (else & AX els)) v After)
             & EX FalseBranch

    "if (test) thn else els; after" becomes:
    if(test) & AX((TrueBranch & AX thn) v
                  (FalseBranch & AX (else & AX els)) v
                  (After & AXAX after))
             & EX FalseBranch
             & EX After


 Note that we rely on the well-formedness of C programs.  For example, we
 do not use EX to check that there is at least one then branch, because
 there is always one.  And we do not check that there is only one then or
 else branch, because these again are always the case in a well-formed C
 program. *)
       (* free variables *)
       let (e1fvs,b1fvs,s1fvs) =
	 seq_fvs2 free_table quantified
	   (FV.Rule_elem ifheader) (FV.Statement branch1) in
       let (e2fvs,b2fvs,s2fvs) =
	 seq_fvs2 free_table quantified
	   (FV.Rule_elem ifheader) (FV.Statement branch2) in
       let bothfvs =
	 Common.union_set
	   (Common.union_set b1fvs b2fvs)
	   (Common.inter_set s1fvs s2fvs) in
       let exponlyfvs = Common.inter_set e1fvs e2fvs in
       let new_quantified = Common.union_set bothfvs quantified in
       (* if header *)
       let if_header = quantify exponlyfvs (make_match ifheader) in
       (* then and else branches *)
       let true_branch =
	 make_seq
	   [wrapPred(Lib_engine.TrueBranch,CTL.Control);
	     statement branch1 fvinfo (a2n after) new_quantified guard] in
       let false_pred = wrapPred(Lib_engine.FalseBranch,CTL.Control) in
       let false_branch =
     	   make_seq
	   [false_pred; make_match els;
	     statement branch2 fvinfo (a2n after) new_quantified guard] in
       let after_pred = wrapPred(Lib_engine.After,CTL.Control) in
       let after_branch = make_seq_after2 after_pred after in
       let or_cases = wrapOr(true_branch,wrapOr(false_branch,after_branch)) in
       (* the code *)
       (match after with
	After _ -> (* pattern doesn't end here *)
	  quantify bothfvs
	    (wrapAnd
	       (if_header,
		 wrapAnd(wrapAX or_cases,
			 wrapAnd(wrapEX false_pred,wrapEX after_pred))))
      |	_ ->
	  quantify bothfvs
	    (wrapAnd (if_header, wrapAnd(wrapAX or_cases, wrapEX false_pred))))

  | Ast.While(header,body) ->
   (* the translation in this case is similar to that of an if with no else *)
   failwith "while is not supported"
  | Ast.Disj(stmt_dots_list) ->
      let do_one e =
	statement_list e fvinfo (a2n after) quantified true in
      let add_nots l e =
	List.fold_left
	  (function rest -> function cur -> wrapAnd(wrapNot(do_one cur),rest))
	  e l in
      let start_dots x =
	match Ast.undots x with
	  y::_ -> is_dots y
	| _ -> None in
      let process_one nots cur =
	match start_dots cur with
	  Some d ->
	    begin
	      update d (List.map (function x -> Other_dots x) nots);
	      statement_list cur fvinfo after quantified guard
	    end
	| None ->
	    add_nots nots (statement_list cur fvinfo after quantified guard) in
      let rec loop after = function
	  [] -> failwith "disj shouldn't be empty" (*wrap n CTL.False*)
	| [(nots,cur)] -> process_one nots cur
	| (nots,cur)::rest -> wrapOr(process_one nots cur, loop after rest) in
      loop after (preprocess_disj stmt_dots_list)
  | Ast.Nest(stmt_dots) ->
      let dots_pattern =
	statement_list stmt_dots fvinfo (a2n after) quantified guard in
      let udots_pattern =
	statement_list stmt_dots fvinfo (a2n after) quantified true in
      (match after with
	After a ->
	  let left = wrapOr(dots_pattern,wrapNot udots_pattern) in
	  let nots =
	    List.map (process_bef_aft after quantified fvinfo n)
	      !(Hashtbl.find before_after_table stmt) in
	  let left =
	    match nots with
	      [] -> left
	    | x::xs ->
		wrapAnd
		  (wrapNot
		     (List.fold_left
			(function rest -> function cur -> wrapOr(cur,rest))
			x xs),
		   left) in
	  wrapAU(left,wrapOr(a,aftret))
      |	_ -> wrapAG(wrapOr(dots_pattern,wrapNot udots_pattern)))
  | Ast.Dots((_,i,d),whencodes) ->
      let dot_code =
	match d with
	  Ast.MINUS(_) ->
            (* no need for the fresh metavar, but ... is a bit wierd as a
	       variable name *)
	    Some(make_match (make_meta_rule_elem d))
	| _ -> None in
      let whencodes =
	(List.map (process_bef_aft after quantified fvinfo n)
	   !(Hashtbl.find before_after_table stmt)) @
	(List.map
	   (function sl ->
	     statement_list sl fvinfo (a2n after) quantified true)
	   whencodes) in
      let phi2 =
	match whencodes with
	  [] -> None
	| x::xs ->
	    Some
	      (wrapNot
		 (List.fold_left
		    (function rest -> function cur -> wrapOr(cur,rest))
		    x xs)) in
      let phi3 =
	match (dot_code,phi2) with (* add - on dots, if any *)
	  (None,None) -> None
	| (Some dotcode,None) -> Some dotcode
	| (None,Some whencode) -> Some whencode
	| (Some dotcode,Some whencode) -> Some(wrapAnd (dotcode,whencode)) in
      let exit = wrap n (CTL.Pred (Lib_engine.Exit,CTL.Control)) in
      (* add in the after code to make the result *)
      (match (after,phi3) with
	(Tail,Some whencode) -> wrapAU(whencode,wrapOr(exit,aftret))
      |	(Tail,None) -> wrapAF(wrapOr(exit,aftret))
      |	(After f,Some whencode) | (Guard f,Some whencode) ->
	  wrapAU(whencode,wrapOr(f,aftret))
      |	(After f,None) | (Guard f,None) -> wrapAF(wrapOr(f,aftret)))
  | Ast.FunDecl(header,lbrace,decls,dots,body,rbrace) ->
      let (hfvs,b1fvs,lbfvs,b2fvs,_,b3fvs,_,b4fvs,rbfvs) =
	seq_fvs5 free_table quantified
	  (FV.Rule_elem header) (FV.Rule_elem lbrace)
	  (FV.StatementDots decls) (FV.StatementDots body)
	  (FV.Rule_elem rbrace) in
      let function_header = quantify hfvs (make_match header) in
      let v = Hashtbl.find brace_table stmt in
      let paren_pred = wrapPred(Lib_engine.Paren v,CTL.Control) in
      let start_brace =
	wrapAnd(quantify lbfvs (make_match lbrace),paren_pred) in
      let end_brace =
	wrapAnd(quantify rbfvs (make_match rbrace),paren_pred) in
      let new_quantified3 =
	Common.union_set b1fvs
	  (Common.union_set b2fvs (Common.union_set b3fvs quantified)) in
      let new_quantified4 = Common.union_set b4fvs new_quantified3 in
      quantify b1fvs
	(make_seq
	   [function_header;
	     wrapExists
	       (v,
		(quantify b2fvs
		   (make_seq
		      [start_brace;
			quantify b3fvs
			  (statement_list decls fvinfo
			     (After
				(decl_to_not_decl n dots stmt extender
				   make_match
				   (quantify b4fvs
				      (statement_list body fvinfo
					 (After
					    (make_seq_after end_brace after))
					 new_quantified4 guard))))
			     new_quantified3 guard)])))])
  | Ast.OptStm(stm) ->
      failwith "OptStm should have been compiled away\n";
  | Ast.UniqueStm(stm) ->
      failwith "arities not yet supported"
  | Ast.MultiStm(stm) ->
      failwith "arities not yet supported"
  | _ -> failwith "not supported"

and process_bef_aft after quantified fvinfo ln = function
    Paren (re,n) ->
      let paren_pred = wrapPred ln (Lib_engine.Paren n,CTL.Control) in
      wrapAnd ln (make_raw_match ln re,paren_pred)
  | Other s -> statement s fvinfo (a2n after) quantified true
  | Other_dots d -> statement_list d fvinfo (a2n after) quantified true

(* Returns a triple for each disj element.  The first element of the triple is
Some v if the triple element needs a name, and None otherwise.  The second
element is a list of names whose negations should be conjuncted with the
term.  The third element is the original term *)
and (preprocess_disj :
       Ast.statement Ast.dots list ->
	 (Ast.statement Ast.dots list * Ast.statement Ast.dots) list) =
  function
    [] -> []
  | [s] -> [([],s)]
  | cur::rest ->
      let template =
	List.map (function r -> Unify_ast.unify_statement_dots cur r) rest in
      let processed = preprocess_disj rest in
      if List.exists (function Unify_ast.MAYBE -> true | _ -> false) template
      then
	([], cur) ::
	(List.map2
	   (function ((nots,r) as x) ->
	     function
		 Unify_ast.MAYBE -> Printf.printf "does unify\n";
		   Pretty_print_cocci.statement_dots cur;
		   Format.print_newline();
		   Printf.printf "with\n";
		   Pretty_print_cocci.statement_dots r;
		   Format.print_newline();
		   (cur::nots,r)
	       | Unify_ast.NO -> Printf.printf "doesn't unify\n"; x)
	   processed template)
      else ([], cur) :: processed

(* --------------------------------------------------------------------- *)
(* Letify:
Phase 1: Use a hash table to identify formulas that appear more than once.
Phase 2: Replace terms by variables.
Phase 3: Drop lets to the point as close as possible to the uses of their
variables *)

let formula_table =
  (Hashtbl.create(50) :
     ((cocci_predicate,string,Wrapper_ctl.info) CTL.generic_ctl,
      int ref (* count *) * string ref (* name *) * bool ref (* processed *))
     Hashtbl.t)

let add_hash phi =
  let (cell,_,_) =
    try Hashtbl.find formula_table phi
    with Not_found ->
      let c = (ref 0,ref "",ref false) in
      Hashtbl.add formula_table phi c;
      c in
  cell := !cell + 1

let rec collect_duplicates f =
  add_hash f;
  match CTL.unwrap f with
    CTL.False -> ()
  | CTL.True -> ()
  | CTL.Pred(p) -> ()
  | CTL.Not(phi) -> collect_duplicates phi
  | CTL.Exists(v,phi) -> collect_duplicates phi
  | CTL.And(phi1,phi2) -> collect_duplicates phi1; collect_duplicates phi2
  | CTL.Or(phi1,phi2) -> collect_duplicates phi1; collect_duplicates phi2
  | CTL.Implies(phi1,phi2) -> collect_duplicates phi1; collect_duplicates phi2
  | CTL.AF(_,phi) -> collect_duplicates phi
  | CTL.AX(_,_,phi) -> collect_duplicates phi
  | CTL.AG(_,phi) -> collect_duplicates phi
  | CTL.AU(_,phi1,phi2) -> collect_duplicates phi1; collect_duplicates phi2
  | CTL.EF(_,phi) -> collect_duplicates phi
  | CTL.EX(_,_,phi) -> collect_duplicates phi
  | CTL.EG(_,phi) -> collect_duplicates phi
  | CTL.EU(_,phi1,phi2) -> collect_duplicates phi1; collect_duplicates phi2
  | _ -> failwith "not possible"

let assign_variables _ =
  Hashtbl.iter
    (function formula ->
      function (cell,str,_) -> if !cell > 1 then str := fresh_let_var())
    formula_table

let rec replace_formulas dec f =
  let (ct,name,treated) = Hashtbl.find formula_table f in
  let real_ct = !ct - dec in
  if real_ct > 1
  then
    if not !treated
    then
      begin
	treated := true;
	let (acc,new_f) = replace_subformulas (dec + (real_ct - 1)) f in
	((!name,new_f) :: acc, CTL.rewrap f (CTL.Ref !name))
      end
    else ([],CTL.rewrap f (CTL.Ref !name))
  else replace_subformulas dec f

and replace_subformulas dec f =
  match CTL.unwrap f with
    CTL.False -> ([],f)
  | CTL.True -> ([],f)
  | CTL.Pred(p) -> ([],f)
  | CTL.Not(phi) ->
      let (acc,new_phi) = replace_formulas dec phi in
      (acc,CTL.rewrap f (CTL.Not(new_phi)))
  | CTL.Exists(v,phi) -> 
      let (acc,new_phi) = replace_formulas dec phi in
      (acc,CTL.rewrap f (CTL.Exists(v,new_phi)))
  | CTL.And(phi1,phi2) ->
      let (acc1,new_phi1) = replace_formulas dec phi1 in
      let (acc2,new_phi2) = replace_formulas dec phi2 in
      (acc1@acc2,CTL.rewrap f (CTL.And(new_phi1,new_phi2)))
  | CTL.Or(phi1,phi2) ->
      let (acc1,new_phi1) = replace_formulas dec phi1 in
      let (acc2,new_phi2) = replace_formulas dec phi2 in
      (acc1@acc2,CTL.rewrap f (CTL.Or(new_phi1,new_phi2)))
  | CTL.Implies(phi1,phi2) -> 
      let (acc1,new_phi1) = replace_formulas dec phi1 in
      let (acc2,new_phi2) = replace_formulas dec phi2 in
      (acc1@acc2,CTL.rewrap f (CTL.Implies(new_phi1,new_phi2)))
  | CTL.AF(dir,phi) ->
      let (acc,new_phi) = replace_formulas dec phi in
      (acc,CTL.rewrap f (CTL.AF(dir,new_phi)))
  | CTL.AX(dir,count,phi) ->
      let (acc,new_phi) = replace_formulas dec phi in
      (acc,CTL.rewrap f (CTL.AX(dir,count,new_phi)))
  | CTL.AG(dir,phi) ->
      let (acc,new_phi) = replace_formulas dec phi in
      (acc,CTL.rewrap f (CTL.AG(dir,new_phi)))
  | CTL.AU(dir,phi1,phi2) ->
      let (acc1,new_phi1) = replace_formulas dec phi1 in
      let (acc2,new_phi2) = replace_formulas dec phi2 in
      (acc1@acc2,CTL.rewrap f (CTL.AU(dir,new_phi1,new_phi2)))
  | CTL.EF(dir,phi) ->
      let (acc,new_phi) = replace_formulas dec phi in
      (acc,CTL.rewrap f (CTL.EF(dir,new_phi)))
  | CTL.EX(dir,count,phi) ->
      let (acc,new_phi) = replace_formulas dec phi in
      (acc,CTL.rewrap f (CTL.EX(dir,count,new_phi)))
  | CTL.EG(dir,phi) -> 
      let (acc,new_phi) = replace_formulas dec phi in
      (acc,CTL.rewrap f (CTL.EG(dir,new_phi)))
  | CTL.EU(dir,phi1,phi2) ->
      let (acc1,new_phi1) = replace_formulas dec phi1 in
      let (acc2,new_phi2) = replace_formulas dec phi2 in
      (acc1@acc2,CTL.rewrap f (CTL.EU(dir,new_phi1,new_phi2)))
  | _ -> failwith "not possible"

let ctlfv_table =
  (Hashtbl.create(50) :
     ((cocci_predicate,string,Wrapper_ctl.info) CTL.generic_ctl,
      string list (* fvs *) *
	string list (* intersection of fvs of subterms *))
     Hashtbl.t)

let rec ctl_fvs f =
  try let (fvs,_) = Hashtbl.find ctlfv_table f in fvs
  with Not_found ->
    let ((fvs,_) as res) =
      match CTL.unwrap f with
	CTL.False | CTL.True | CTL.Pred(_) -> ([],[])
      | CTL.Not(phi) | CTL.Exists(_,phi)
      | CTL.AF(_,phi) | CTL.AX(_,_,phi) | CTL.AG(_,phi)
      | CTL.EF(_,phi) | CTL.EX(_,_,phi) | CTL.EG(_,phi) -> (ctl_fvs phi,[])
      | CTL.And(phi1,phi2) | CTL.Or(phi1,phi2) | CTL.Implies(phi1,phi2)
      | CTL.AU(_,phi1,phi2) | CTL.EU(_,phi1,phi2) ->
	  let phi1fvs = ctl_fvs phi1 in
	  let phi2fvs = ctl_fvs phi2 in
	  (Common.union_set phi1fvs phi2fvs,intersect phi1fvs phi2fvs)
      | CTL.Ref(v) -> ([v],[v])
      | CTL.Let(v,term,body) ->
	  let phi1fvs = ctl_fvs term in
	  let phi2fvs = Common.minus_set (ctl_fvs body) [v] in
	  (Common.union_set phi1fvs phi2fvs,intersect phi1fvs phi2fvs) in
    Hashtbl.add ctlfv_table f res;
    fvs

let rev_order_bindings b =
  let b =
    List.map
      (function (nm,term) ->
	let (fvs,_) = Hashtbl.find ctlfv_table term in (nm,fvs,term))
      b in
  let rec loop bound = function
      [] -> []
    | unbound ->
	let (now_bound,still_unbound) =
	  List.partition (function (_,fvs,_) -> subset fvs bound)
	    unbound in
	let get_names = List.map (function (x,_,_) -> x) in
	now_bound @ (loop ((get_names now_bound) @ bound) still_unbound) in
  List.rev(loop [] b)

let drop_bindings b f = (* innermost bindings first in b *)
  let process_binary f ffvs inter nm term fail =
    if List.mem nm inter
    then CTL.rewrap f (CTL.Let(nm,term,f))
    else CTL.rewrap f (fail()) in
  let find_fvs f =
    let _ = ctl_fvs f in Hashtbl.find ctlfv_table f in
  let rec drop_one nm term f =
    match CTL.unwrap f with
      CTL.False ->  f
    | CTL.True -> f
    | CTL.Pred(p) -> f
    | CTL.Not(phi) -> CTL.rewrap f (CTL.Not(drop_one nm term phi))
    | CTL.Exists(v,phi) -> CTL.rewrap f (CTL.Exists(v,drop_one nm term phi))
    | CTL.And(phi1,phi2) ->
	let (ffvs,inter) = find_fvs f in
	process_binary f ffvs inter nm term
	  (function _ -> CTL.And(drop_one nm term phi1,drop_one nm term phi2))
    | CTL.Or(phi1,phi2) ->
	let (ffvs,inter) = find_fvs f in
	process_binary f ffvs inter nm term
	  (function _ -> CTL.Or(drop_one nm term phi1,drop_one nm term phi2))
    | CTL.Implies(phi1,phi2) ->
	let (ffvs,inter) = find_fvs f in
	process_binary f ffvs inter nm term
	  (function _ ->
	    CTL.Implies(drop_one nm term phi1,drop_one nm term phi2))
    | CTL.AF(dir,phi) -> CTL.rewrap f (CTL.AF(dir,drop_one nm term phi))
    | CTL.AX(dir,count,phi) ->
	CTL.rewrap f (CTL.AX(dir,count,drop_one nm term phi))
    | CTL.AG(dir,phi) -> CTL.rewrap f (CTL.AG(dir,drop_one nm term phi))
    | CTL.AU(dir,phi1,phi2) ->
	let (ffvs,inter) = find_fvs f in
	process_binary f ffvs inter nm term
	  (function _ ->
	    CTL.AU(dir,drop_one nm term phi1,drop_one nm term phi2))
    | CTL.EF(dir,phi) -> CTL.rewrap f (CTL.EF(dir,drop_one nm term phi))
    | CTL.EX(dir,count,phi) ->
	CTL.rewrap f (CTL.EX(dir,count,drop_one nm term phi))
    | CTL.EG(dir,phi) -> CTL.rewrap f (CTL.EG(dir,drop_one nm term phi))
    | CTL.EU(dir,phi1,phi2) ->
	let (ffvs,inter) = find_fvs f in
	process_binary f ffvs inter nm term
	  (function _ ->
	    CTL.EU(dir,drop_one nm term phi1,drop_one nm term phi2))
    | (CTL.Ref(v) as x) -> process_binary f [v] [v] nm term (function _ -> x)
    | CTL.Let(v,term1,body) ->
	let (ffvs,inter) = find_fvs f in
	process_binary f ffvs inter nm term
	  (function _ ->
	    CTL.Let(v,drop_one nm term term1,drop_one nm term body)) in
  List.fold_left
    (function processed -> function (nm,_,term) -> drop_one nm term processed)
    f b

let letify f =
  Hashtbl.clear formula_table;
  Hashtbl.clear ctlfv_table;
  (* create a count of the number of occurrences of each subformula *)
  collect_duplicates f;
  (* give names to things that appear more than once *)
  assign_variables();
  (* replace duplicated formulas by their variables *)
  let (bindings,new_f) = replace_formulas 0 f in
  (* collect fvs of terms in bindings and new_f *)
  List.iter (function f -> let _ = ctl_fvs f in ())
    (new_f::(List.map (function (_,term) -> term) bindings));
  (* sort bindings with uses before defs *)
  let bindings = rev_order_bindings bindings in
  (* insert bindings as lets into the formula *)
  let res = drop_bindings bindings new_f in
  res

(* --------------------------------------------------------------------- *)
(* Function declaration *)

let top_level free_table extender used_after t =
  Hashtbl.clear before_after_table;
  Hashtbl.clear brace_table;
  match Ast.unwrap t with
    Ast.DECL(decl) -> failwith "not supported decl"
  | Ast.INCLUDE(inc,s) -> failwith "not supported include"
  | Ast.FILEINFO(old_file,new_file) -> failwith "not supported fileinfo"
  | Ast.FUNCTION(stmt) ->
      let unopt = elim_opt.V.rebuilder_statement stmt in
      let _ = extender unopt in
      let _ = count_nested_braces unopt in
      preprocess_dots_e unopt;
      (*letify*)
	(statement unopt (free_table,extender,used_after) Tail [] false)
  | Ast.CODE(stmt_dots) ->
      let unopt = elim_opt.V.rebuilder_statement_dots stmt_dots in
      List.iter
	(function x ->
	  let _ = extender x in
	  let _ = count_nested_braces x in ())
	(Ast.undots unopt);
      preprocess_dots unopt;
      (*letify*)
	(statement_list unopt (free_table,extender,used_after) Tail [] false)
  | Ast.ERRORWORDS(exps) -> failwith "not supported errorwords"

(* --------------------------------------------------------------------- *)
(* Contains dots *)

let contains_dots =
  let bind x y = x or y in
  let option_default = false in
  let mcode r x = false in
  let statement r k s =
    match Ast.unwrap s with Ast.Dots(_,_) -> true | _ -> k s in
  let continue r k e = k e in
  let stop r k e = false in
  let res =
    V.combiner bind option_default
      mcode mcode mcode mcode mcode mcode mcode mcode mcode mcode mcode
      continue continue continue
      stop stop stop stop stop stop stop statement continue continue in
  res.V.combiner_top_level

(* --------------------------------------------------------------------- *)
(* Entry points *)

let asttoctl l free_table extender used_after =
  ctr := 0;
  lctr := 0;
  sctr := 0;
  let l =
    List.filter
      (function t ->
	match Ast.unwrap t with Ast.ERRORWORDS(exps) -> false | _ -> true)
      l in
  List.map (top_level free_table extender used_after) l

let pp_cocci_predicate (pred,modif) =
  Pretty_print_engine.pp_predicate pred

let cocci_predicate_to_string (pred,modif) =
  Pretty_print_engine.predicate_to_string pred
