(********************************************************************************)
(********************************************************************************)
(********************************************************************************)
(* A schema checking entry:
   An entry which validates its validity against the server's
   schema *)
(* schema checking flavor *)
type scflavor = Optimistic (* attempt to find objectclasses which make illegal
			      attributes legal, delete them if no objectclass can
			      be found *)
		| Pessimistic (* delete any illegal attributes, do not add 
				 objectclasses to make them legal*)

(* for the schema checker, should never be seen by
   the user *)
exception Single_value of string
exception Objectclass_is_required

module OrdOid =
struct
  type t = Oid.t
  let compare = Oid.compare
end

module Setstr = Set.Make (OrdOid)

let rec setOfList ?(set=Setstr.empty) list = 
  match list with
      a :: tail -> setOfList ~set:(Setstr.add a set) tail
    | []  -> set

class scldapentry schema =
object (self)
  inherit ldapentry as super
  val schemaAttrs = Hashtbl.create 50
  val schema = schema
  val mutable consistent = false
    (* the set of all attibutes actually present *)
  val mutable present       = Setstr.empty
    (* the set of all musts from all objectclasses on the entry *)
  val mutable must          = Setstr.empty
    (* the set of all mays from all objectclasses on the entry *)
  val mutable may           = Setstr.empty
    (* the set of required objectclasses *)
  val mutable requiredOcs   = Setstr.empty
    (* present objectclasses *)
  val mutable presentOcs    = Setstr.empty

  (* must + may *)
  val mutable all_allowed   = Setstr.empty
    (* must - (present * must) *)
  val mutable missingAttrs  = Setstr.empty
    (* requiredOcs - (presentOcs * requiredOcs) *)
  val mutable missingOcs    = Setstr.empty
    (* any objectclass which depends on a missing objectclass *)
  val mutable illegalOcs    = Setstr.empty
    (* present - (present * all_allowed) *)
  val mutable illegalAttrs  = Setstr.empty

  (* schema checking is best expressed as set manipulations.
     I can ascert this having implimented it in other ways *)
  method private update_condition =
    let rec generate_mustmay ocs schema set must =
      match ocs with
	  oc :: tail -> 
	    let musts = setOfList 
	      (List.rev_map 
		 (fun attr -> attrToOid schema attr)
		 (if must then (getOc schema oc).oc_must
		  else (getOc schema oc).oc_may))
	    in
	      generate_mustmay tail schema (Setstr.union musts set) must
	| [] -> set
    in
    let rec lstRequired schema (oc: Lcstring.t) =
      oc :: (List.flatten (List.rev_map 
			     (fun sup -> lstRequired schema sup) 
			     (getOc schema oc).oc_sup))
    in
    let rec generate_requiredocs schema ocs =
      setOfList 
	(List.rev_map 
	   (ocToOid schema)
	   (List.flatten (List.rev_map (lstRequired schema) ocs)))
    in
    let generate_illegal_oc missing schema ocs =
      let is_illegal_oc missing schema oc =
	let supchain = lstRequired schema oc in
	  List.exists
	    (fun mis ->
	       List.exists ((=) mis)
		 supchain)
	    missing
      in
	List.filter (is_illegal_oc missing schema) ocs
    in

      present      <- (setOfList (List.rev_map Oid.of_string super#attributes));
      must         <- (generate_mustmay 
			 (List.rev_map 
			    (Oid.of_string) 
			    (try super#get_value "2.5.4.0" (* objectclass *) 
			     with Not_found -> raise Objectclass_is_required))
			 schema
			 Setstr.empty
			 true);
      may          <- (generate_mustmay 
			 (List.rev_map 
			    (Lcstring.of_string) 
			    (try super#get_value "2.5.4.0" (* objectclass *)
			     with Not_found -> raise Objectclass_is_required))
			 schema
			 Setstr.empty
			 false);
      all_allowed  <- Setstr.union must may;
      missingAttrs <- Setstr.diff must (Setstr.inter must present);
      illegalAttrs <- Setstr.diff present (Setstr.inter all_allowed present);
      requiredOcs  <- (generate_requiredocs 
			 schema 
			 (List.rev_map
			    (Lcstring.of_string) 
			    (try super#get_value "objectclass" 
			     with Not_found -> raise Objectclass_is_required)));
      presentOcs   <- (setOfList 
			 (List.rev_map 
			    (fun attr -> ocToOid schema (Lcstring.of_string attr)) 
			    (try super#get_value "objectclass" 
			     with Not_found -> raise Objectclass_is_required)));
      missingOcs   <- Setstr.diff requiredOcs (Setstr.inter requiredOcs presentOcs);
      illegalOcs   <- (setOfList
			 (List.rev_map
			    (ocToOid schema)
			    (generate_illegal_oc 
			       (List.rev_map 
				  (fun x -> Lcstring.of_string (oidToOc schema x))
				  (Setstr.elements missingOcs))
			       schema
			       (List.rev_map
				  (Lcstring.of_string)
				  (try super#get_value "objectclass" 
				   with Not_found -> raise Objectclass_is_required)))));
      if Setstr.is_empty (Setstr.union missingAttrs illegalAttrs) then
	consistent <- true
      else
	consistent <- false

  method private drive_updatecon =
    try self#update_condition
    with 
	Invalid_objectclass(s) -> super#delete [("2.5.4.0",[s])];self#drive_updatecon
      | Invalid_attribute(s) -> super#delete [(s,[])];self#drive_updatecon
      | Objectclass_is_required -> super#add [("2.5.4.0", ["top"])]

  method private reconsile_illegal flavor =
    let find_in_oc oc attr = (List.exists
				((=) (Lcstring.of_string attr)) 
				oc.oc_must) || 
      (List.exists
	 ((=) (Lcstring.of_string attr))
	 oc.oc_may) in
    let find_oc schema attr = 
      let oc = ref (Lcstring.of_string "") in
	Hashtbl.iter 
	  (fun key valu -> 
	     if (find_in_oc valu attr) then oc := key)
	  schema.objectclasses;
	if !oc = (Lcstring.of_string "") then raise Not_found;
	!oc
    in
      match flavor with 
	  Optimistic ->
	    if not (Setstr.is_empty illegalAttrs) then
	      ((List.iter (* add necessary objectclasses *)
		  (fun oc -> super#add [("objectclass",[(Lcstring.to_string oc)])])
		  (List.rev_map
		     (fun attr -> 
			try find_oc schema attr 
			with Not_found -> raise (Invalid_attribute attr))
		     (List.rev_map (oidToAttr schema) (Setstr.elements illegalAttrs))));
	       self#drive_updatecon);
	    (* add any objectclasses the ones we just added are dependant on *)
	    if not (Setstr.is_empty missingOcs) then
	      ((List.iter
		  (fun oc -> super#add [("objectclass", [oc])])
		  (List.rev_map (oidToOc schema) (Setstr.elements missingOcs)));
	       self#drive_updatecon);
	| Pessimistic ->
	    (List.iter
	       (fun oc -> super#delete [("objectclass",[oc])])
	       (List.rev_map (oidToOc schema) (Setstr.elements illegalOcs)));
	    self#drive_updatecon;
	    (List.iter (* remove disallowed attributes *)
	       (fun attr -> super#delete [(attr, [])])
	       (List.rev_map (oidToAttr schema) (Setstr.elements illegalAttrs)));
	    self#drive_updatecon

  method private drive_reconsile flavor =
    try self#reconsile_illegal flavor
    with Invalid_attribute(a) -> (* remove attributes for which there is no objectclass *)
      (super#delete [(a, [])];
       self#drive_updatecon;
       self#drive_reconsile flavor)

  (* for debugging *)
  method private getCondition = 
    let printLst lst = List.iter print_endline lst in
      print_endline "MAY";
      printLst (List.rev_map (oidToAttr schema) (Setstr.elements may));
      print_endline "PRESENT";
      printLst (List.rev_map (oidToAttr schema) (Setstr.elements present));
      (*      printLst (Setstr.elements present);*)
      print_endline "MUST";
      printLst (List.rev_map (oidToAttr schema) (Setstr.elements must));
      (*      printLst (Setstr.elements must);*)
      print_endline "MISSING";
      printLst (List.rev_map (oidToAttr schema) (Setstr.elements missingAttrs));
      (*      printLst (Setstr.elements missingAttrs);*)
      print_endline "ILLEGAL";
      printLst (List.rev_map (oidToAttr schema) (Setstr.elements illegalAttrs));
      print_endline "REQUIREDOCS";
      (*      printLst (List.rev_map (oidToOc schema) (Setstr.elements requiredOcs));*)
      printLst (List.rev_map Oid.to_string (Setstr.elements requiredOcs));
      print_endline "PRESENTOCS";
      (*      printLst (List.rev_map (oidToOc schema) (Setstr.elements presentOcs));*)
      printLst (List.rev_map Oid.to_string (Setstr.elements presentOcs));
      print_endline "MISSINGOCS";
      (*      printLst (List.rev_map (oidToOc schema) (Setstr.elements missingOcs));*)
      printLst (List.rev_map Oid.to_string (Setstr.elements missingOcs));
      print_endline "ILLEGALOCS";
      (*      printLst (List.rev_map (oidToOc schema) (Setstr.elements illegalOcs))*)
      printLst (List.rev_map Oid.to_string (Setstr.elements illegalOcs));

  (* for debugging *)
  method private getData = (must, may, present, missingOcs)

  method of_entry ?(scflavor=Pessimistic) (e:ldapentry) =
    super#set_dn (e#dn);
    super#set_changetype `ADD;
    (List.iter
       (fun attr -> 
	  try
	    let oid = Oid.to_string (attrToOid schema (Lcstring.of_string attr)) in
	      (super#add 
		 (try 
		    self#single_val_check [(oid, (e#get_value attr))] true;
		    [(oid, (e#get_value attr))]
		  with (* remove single valued attributes *)
		      Single_value _ -> [(oid, [List.hd (e#get_value attr)])]))
	  with (* single_val_check may encounter unknown attributes *)
	      Invalid_attribute _ | Invalid_objectclass _ -> ())
       e#attributes);
    self#drive_updatecon;
    self#drive_reconsile scflavor

  (* raise an exception if the user attempts to have more than
     one value in a single valued attribute. *)
  method private single_val_check (x:op_lst) consider_present =
    let check op =
      let attr = oidToAttr schema (Oid.of_string (fst op)) in
	(if attr.at_single_value then
	   (match op with
		(attr, v1 :: v2 :: tail) -> false
	      | (attr, v1 :: tail) -> 
		  (if consider_present && (super#exists attr) then
		     false
		   else true)
	      | _ -> true)
	 else true)
    in
      match x with
	  op :: tail -> (if not (check op) then
			   raise (Single_value (fst op))
			 else self#single_val_check tail consider_present)
	|  [] -> ()

  method add x = 
    self#single_val_check x true;super#add x;
    self#drive_updatecon;self#drive_reconsile Optimistic
      
  method delete x = 
    super#delete x;self#drive_updatecon;self#drive_reconsile Pessimistic

  method replace x = 
    self#single_val_check x false;super#replace x;
    self#drive_updatecon;self#drive_reconsile Optimistic

  method modify x = 
    let filter_mod x op = 
      List.rev_map
	(fun (_, a, v) -> (a, v))
	(List.filter 
	   (function (the_op, _, _) when the_op = op -> true | _ -> false) x)
    in
      self#single_val_check (filter_mod x `ADD) true;
      self#single_val_check (filter_mod x `REPLACE) false;
      super#modify x;
      self#drive_updatecon;
      self#drive_reconsile Pessimistic

  method get_value x =
    let values = 
      List.fold_left
	(fun v name -> 
	   try super#get_value name 
	   with Not_found ->
	     if (Setstr.mem (attrToOid schema (Lcstring.of_string name)) missingAttrs) then
	       ["required"]
	     else v)
	[]
	(getAttr (Lcstring.of_string x)).at_name
    in
      match values with
	  [] -> raise Not_found
	| values -> values

  method attributes =
    List.rev_append
      super#attributes
      (List.rev_map
	 (fun a -> oidToAttr schema a) 
	 (Setstr.elements missingAttrs))

  method list_missing = Setstr.elements missingAttrs
  method list_allowed = Setstr.elements all_allowed
  method list_present = Setstr.elements present
  method is_missing x = 
    Setstr.mem (attrToOid schema (Lcstring.of_string x)) missingAttrs
  method is_allowed x = 
    Setstr.mem (attrToOid schema (Lcstring.of_string x)) all_allowed
end;;

(********************************************************************************)
(********************************************************************************)
(********************************************************************************)
(* a high level interface for accounts, and services in the directory *)

type generator = {gen_name:string;
		  required:string list;
		  genfun:(ldapentry_t -> string list)};;

type service = {svc_name: string;
		static_attrs: (string * (string list)) list;
		generate_attrs: string list;
		depends: string list};;

type generation_error = Missing_required of string list
			| Generator_error of string

exception No_generator of string;;
exception Generation_failed of generation_error;;
exception No_service of string;;
exception Service_dep_unsatisfiable of string;;
exception Generator_dep_unsatisfiable of string * string;;
exception Cannot_sort_dependancies of (string list);;

let diff_values convert_to_oid convert_from_oid attr attrvals svcvals =
    (attr, (List.rev_map
	      convert_from_oid
	      (Setstr.elements
		 (Setstr.diff
		    svcvals
		    (Setstr.inter svcvals attrvals)))))

(* compute the intersection of values between an attribute and a service,
   you need to pass this function as an argument to apply_set_op_to_values *)
let intersect_values convert_to_oid convert_from_oid attr attrvals svcvals =
  (attr, (List.rev_map
	    convert_from_oid
	    (Setstr.elements
	       (Setstr.inter svcvals attrvals))))

(* this function allows you to apply a set operation to the values of an attribute, and 
   the static values on a service *)
let apply_set_op_to_values schema (attr:string) e svcval opfun =
  let lc = String.lowercase in
  let convert_to_oid = (match lc ((getAttr schema (Lcstring.of_string attr)).at_equality) with
			    "objectidentifiermatch" -> 
			      (fun oc -> ocToOid schema (Lcstring.of_string oc))
			  | "caseexactia5match" -> Oid.of_string
			  | _ -> (fun av -> Oid.of_string (lc av)))
  in
  let convert_from_oid = (match lc ((getAttr schema (Lcstring.of_string attr)).at_equality) with
			      "objectidentifiermatch" -> (fun av -> oidToOc schema av)
			    | "caseexactia5match" -> Oid.to_string
			    | _ -> Oid.to_string)
  in
  let attrvals = setOfList
		   (List.rev_map
		      convert_to_oid
		      (try e#get_value attr with Not_found -> []))
  in
  let svcvals = setOfList (List.rev_map convert_to_oid (snd svcval))
  in
    opfun convert_to_oid convert_from_oid attr attrvals svcvals

class ldapaccount 
  schema 
  (generators:(string, generator) Hashtbl.t)
  (services:(string, service) Hashtbl.t) =
object (self)
  inherit scldapentry schema as super
  val mutable toGenerate = Setstr.empty
  val mutable neededByGenerators = Setstr.empty
  val services = services
  val generators = generators

(* evaluates the set of missing attributes to see if any of
   them can be generated, if so, it adds them to be generated *)
  method private resolve_missing =
    (* computes the set of generateable attributes *)
    let generate_togenerate generators missing togenerate =
      (* generators have dependancies. Some of the dependancies can
	 also be generated. We can generate a dependancy if the following
	 conditions are met. 
	 1. The dependancy is in the generators hash (it has a generation function)
	 2. The dependancy is allowed by the schema (it is either a must or may of
	 an objectclass currently on the object)
	 3. The dependancy is not already present (if it is present already then it
	 has already been satisfied, and there is no need to generate it) *)
      let find_generatable_dep generators generator =
	(List.rev_map
	   (fun e -> attrToOid schema (Lcstring.of_string e))
	   (List.filter
	      (fun g ->
		 if ((Hashtbl.mem generators g) && 
		     (not (Setstr.mem
			     (attrToOid schema (Lcstring.of_string g))
			     (setOfList self#list_present)))) then
		   true
		 else false)
	      (List.filter (* we can only add it if it is allowed by the schema *)
		 (fun attr -> super#is_allowed attr)
		 (Hashtbl.find generators generator).required)))
      in
	(* collect a flat list of all generatable dependancies *)
      let rec find_generatable_deps generators genlst =
	(List.flatten
	   (List.rev_map
	      (find_generatable_dep generators)
	      genlst))
      in
	(* the set we are currently generating, union the set of missing attributes which we
	   can generate. *)
      let generateing = (List.filter
			   (fun gen -> 
			      if (Hashtbl.mem generators (lowercase (oidToAttr schema gen))) then
				true
			      else false)
			   (List.rev_append
			      missing
			      (Setstr.elements togenerate)))
      in
	(* the total set of generatable at any point in time is. The set
	   we are already generating, unioned with any generatable dependancies, unioned
	   with the set of missing attributes (required by the schema) which can be generated. 
	   Note, the last union is done in the generateing expression above. *)
	setOfList
	  (List.rev_append generateing (find_generatable_deps
					  generators
					  (List.rev_map
					     (fun e -> lowercase (oidToAttr schema e))
					     generateing)))
    in
    let generate_missing togen generators =
      setOfList
	(Hashtbl.fold 
	   (fun key valu requiredlst -> 
	      if Setstr.mem (attrToOid schema (Lcstring.of_string valu.gen_name)) togen then
		List.rev_append
		  requiredlst
		  (List.rev_map
		     (fun x -> try
			attrToOid schema (Lcstring.of_string x)
		      with Invalid_attribute a -> 
			raise (Generator_dep_unsatisfiable (key, a)))
		     valu.required)
	      else
		requiredlst)
	   generators [])
    in
      toGenerate <- generate_togenerate generators super#list_missing toGenerate;
      neededByGenerators <- generate_missing toGenerate generators;

  method list_missing = 
    let allmissing = 
      Setstr.union neededByGenerators (setOfList super#list_missing) 
    in
      Setstr.elements
	(Setstr.diff
	   allmissing 
	   (Setstr.inter
	      allmissing
	      (Setstr.union 
		 toGenerate 
		 (setOfList super#list_present))))

  method attributes =
    (List.rev_map (oidToAttr schema)
       (Setstr.elements
	  (Setstr.union toGenerate
	     (setOfList 
		(List.rev_map
		   (fun a -> attrToOid schema (Lcstring.of_string a))
		   super#attributes)))))

  method is_missing x = (not (Setstr.mem
				(attrToOid schema (Lcstring.of_string x)) 
				toGenerate)) 
			|| (super#is_missing x)

  method generate =
    let sort_genlst generators unsatisfied =
      let satisfied alreadysatisfied present deps =
	List.for_all
	  (fun dep -> 
	     (List.mem dep alreadysatisfied) || 
	     (List.mem (attrToOid schema (Lcstring.of_string dep)) (present)))
	  deps
      in
      let rec sort present ordtogen unsatisfied =
	match unsatisfied with
	    [] -> ordtogen
	  | todo ->
	      let (aresat, notyet) =
		(List.partition
		   (fun attr ->
		      (satisfied ordtogen present
			 (Hashtbl.find generators attr).required))
		   todo)
	      in
		match aresat with
		    [] -> raise (Cannot_sort_dependancies notyet)
		  | _ -> sort present (ordtogen @ aresat) notyet
      in
	sort (self#list_present) [] unsatisfied
    in
      match self#list_missing with
	  [] -> 
	    (List.iter
	       (fun attr ->
		  self#add [(attr, (Hashtbl.find generators attr).genfun (self:>ldapentry_t))])
	       (sort_genlst generators
		  (List.rev_map
		     (fun elt -> String.lowercase (oidToAttr schema elt))
		     (Setstr.elements toGenerate))));
	    toGenerate <- Setstr.empty
	| a  -> raise (Generation_failed
			 (Missing_required (List.rev_map (oidToAttr schema) a)))

  method get_value x =
    if (Setstr.mem (attrToOid schema (Lcstring.of_string x)) toGenerate) then
      ["generate"]
    else
      super#get_value x

(* adapt the passed in service to the current state of the entry
   this may result in a service with applies no changes. The entry
   may already have the service. *)
  method adapt_service svc =    
      {svc_name=svc.svc_name;
       static_attrs=(List.filter
			  (fun cons ->
			     match cons with
				 (attr, []) -> false
			       | _          -> true)
			  (List.rev_map
			     (fun cons -> apply_set_op_to_values schema (fst cons) self cons diff_values)
			     svc.static_attrs));
       generate_attrs=(List.filter
			 (fun attr -> 
			    (try (ignore (super#get_value attr));false
			     with Not_found -> true))			
			 svc.generate_attrs);
       depends=svc.depends}

(* add a service to the account, if they already satisfy the service
   then do nothing *)			     
  method add_service svc =
    let service = try Hashtbl.find services (lowercase svc)
    with Not_found -> raise (No_service svc) in
      (try List.iter (self#add_service) service.depends
       with (No_service x) -> raise (Service_dep_unsatisfiable x));
      let adaptedsvc = self#adapt_service service in
	(let do_adds a =
	   let singlevalu = 
	     (List.filter 
		(fun attr -> (getAttr schema
			     (Lcstring.of_string (fst attr))).at_single_value) a)
	   in
	   let multivalued = 
	     (List.filter 
		(fun attr -> not (getAttr schema
				 (Lcstring.of_string (fst attr))).at_single_value) a)
	   in
	     self#add multivalued;
	     self#replace singlevalu
	 in
	   do_adds adaptedsvc.static_attrs);
	(match adaptedsvc.generate_attrs with
	     [] -> ()
	   | a  -> List.iter (self#add_generate) a)

  method delete_service svc =
    let find_deps services service =
      (Hashtbl.fold
	 (fun serv svcstruct deplst ->
	    if (List.exists ((=) service) svcstruct.depends) then
	      serv :: deplst
	    else
	      deplst)
	 services [])
    in
    let service = try Hashtbl.find services (lowercase svc)
    with Not_found -> raise (No_service svc) in
      (List.iter (self#delete_service) (find_deps services svc));
      (List.iter
	 (fun e -> match e with
	      (attr, []) -> ()
	    | a -> (try (ignore (super#get_value (fst a)));super#delete [a]
		    with Not_found -> ()))
	 (List.rev_map
	    (fun cons ->
	       apply_set_op_to_values schema (fst cons) self cons intersect_values)
	    service.static_attrs));
      (List.iter
	 (fun attr -> 
	    (try (match self#get_value attr with
		      ["generate"] -> self#delete_generate attr
		    | _ -> super#delete [(attr, [])])
	     with Not_found -> ()))
	 service.generate_attrs)	     	     

  method service_exists service =
    let service = (try (Hashtbl.find services service) 
		   with Not_found -> raise (No_service service))
    in
      match self#adapt_service service with
	  {svc_name=s;
	   static_attrs=[];
	   generate_attrs=[];
	   depends=d} -> (match d with
			      [] -> true
			    | d  -> List.for_all self#service_exists d)
	| _ -> false

  method services_present =
    Hashtbl.fold
      (fun k v l -> 
	 if self#service_exists v.svc_name then
	   v.svc_name :: l
	 else l)
      services []
      
  method of_entry ?(scflavor=Pessimistic) e = super#of_entry ~scflavor e;self#resolve_missing

  method add_generate x = 
    (if (Hashtbl.mem generators (lowercase x)) then
       toGenerate <- Setstr.add (attrToOid schema (Lcstring.of_string x)) toGenerate
     else raise (No_generator x));
    self#resolve_missing
  method delete_generate x =
    let find_dep attr generators =
      (Hashtbl.fold
	 (fun key valu deplst ->
	    if (List.exists ((=) attr) valu.required) then
	      key :: deplst
	    else
	      deplst)
	 generators [])
    in
      (List.iter (self#delete_generate) (find_dep x generators));
      toGenerate <- 
      Setstr.remove
	(attrToOid schema (Lcstring.of_string x)) toGenerate

  method add x = (* add x, remove all attributes in x from the list of generated attributes *)
    super#add x; 
    (List.iter 
      (fun a -> 
	 toGenerate <- (Setstr.remove
			  (attrToOid schema (Lcstring.of_string (fst a)))
			  toGenerate))
       x);
    self#resolve_missing
  method delete x = super#delete x;self#resolve_missing
  method replace x = (* replace x, removeing it from the list of generated attrs *)
    super#replace x;
    (List.iter
       (fun a -> 
	  toGenerate <- (Setstr.remove
			   (attrToOid schema (Lcstring.of_string (fst a)))
			   toGenerate))
       x);
    self#resolve_missing
end;;