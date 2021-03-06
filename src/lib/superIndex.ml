open Parser
open Core
open Core.Std

module NameKey = struct
  type t = string list * string (* list of namespaces and classes (reversed) and concatenated string *)
  type sexpable = t
  let sexp_of_t t = String.sexp_of_t (snd t)

  let key_of_fullname b =
    let a = Str.split (Str.regexp "::")  b |> List.rev in
    (a,b)

  let key_of_prefix lst = match lst with
    | [] -> raise (Invalid_argument "NameKey.key_of_prefix: []")
    | lst -> (lst, List.rev lst |> String.concat ~sep:"::")

  let t_of_sexp s = String.t_of_sexp s |> key_of_fullname

  let compare a b = String.compare (snd a) (snd b)

  let make_key ~name ~prefix = (* classname and reverted prefix *)
    let lst = name::prefix in
    (lst, String.concat ~sep:"::" (List.rev lst) )
  let hash (_,b) = String.hash b
  let equal (_,b) (_,d) = String.equal b d
  let to_string (lst,_) = String.concat ~sep:"::" (List.rev lst)
end

type index_data =
  | Class of clas * MethSet.t (* class data with all virtuals *)
  | Enum of enum

module StringLabeledGraph = Graph.Imperative.Digraph.Concrete(String)
module SuperIndex = Map.Make(NameKey)

type index_t = index_data SuperIndex.t

let is_enum_exn ~key t = match SuperIndex.find_exn t key with
  | Class _ -> false
  | Enum _ -> true

let is_class_exn ~key t = match SuperIndex.find_exn t key with
  | Class _ -> true
  | Enum _ -> false

let to_channel t ch =
  let of_modif xs =
    if xs = [] then ""
    else
      let f = function
        | `Abstract -> "abstract"
        | `Const    -> "const"
        | `Explicit -> "explicit"
        | `Inline   -> "inline"
        | `Static   -> "static"
        | `Virtual  -> "virtual"
      in
      List.map xs ~f |> String.concat ~sep:" "
  in
  let of_access = function
    | `Public -> "public   " | `Private -> "private  " | `Protected -> "protected" in
  let print_enum ~key {e_name;e_items; e_access; e_flag_name} =
    sprintf "Enum  %s %s with flag=%s,name=%s"
      (snd key) (String.concat ~sep:"," e_items) e_flag_name e_name in
  SuperIndex.iter t ~f:(fun ~key ~data -> match data with
    | Enum e -> fprintf ch "%s\n" (print_enum ~key e)
    | Class (c,set) -> begin
      fprintf ch "Class %s (virts count = %d)\n" (NameKey.to_string key) (MethSet.length set);
      List.iter c.c_enums ~f:(fun e -> fprintf ch "  %s\n"  (print_enum ~key e));
      fprintf ch "  Constructors\n";
      List.iter c.c_constrs ~f:(fun lst -> fprintf ch "    %s\n"
        (meth_of_constr ~classname:c.c_name lst |> string_of_meth )
      );
      fprintf ch "  Normal meths\n";
      MethSet.iter c.c_meths ~f:(fun m ->
        fprintf ch "    %s %s %s with out_name = %s, declared in %s\n"
          (of_access m.m_access) (of_modif m.m_modif)
          (string_of_meth m) m.m_out_name m.m_declared
      );
      fprintf ch "  slots\n";
      MethSet.iter c.c_slots ~f:(fun slt ->
        fprintf ch "    %s %s %s declared in %s\n"
          (of_access slt.m_access) (of_modif slt.m_modif)
            (string_of_meth slt) c.c_name
      );
      fprintf ch "  signals:\n";
      List.iter c.c_sigs ~f:(fun (name,args) ->
        fprintf ch "    (void) %s(%s)\n" name
          (List.map args ~f:(fun x -> string_of_type x.arg_type) |> String.concat ~sep:",")
      );
      fprintf ch "************************************************** \n"
    end
  )

module Evaluated = Set.Make(NameKey)
module V = NameKey

module G = struct
  include Graph.Imperative.Digraph.Concrete(V) (* from base to subclasses *)
  let graph_attributes (_:t) = []
  let default_vertex_attributes _ = []
  let get_subgraph _ = None
  let default_edge_attributes _ = []
  let edge_attributes _ = []

  let vertex_name v = snd (V.label v)
    |> Str.global_replace (Str.regexp "::") "_"
    |> Str.global_replace (Str.regexp "<") "_"
    |> Str.global_replace (Str.regexp ">") "_"
    |> Str.global_replace (Str.regexp ",") "_"
    |> Str.global_replace (Str.regexp "*") "_"
    |> Str.global_replace (Str.regexp "&amp;") "_AMP_"

  let vertex_attributes v = [`Label (snd (V.label v)) ]

  let kill_and_fall g ?(index=SuperIndex.empty) root =
    let ans = ref index in
    let rec helper node =
      if mem_vertex g node then (
        let lst = succ g node in
        remove_vertex g root;
        Ref.replace ans (fun map -> SuperIndex.remove map node);
        List.iter lst ~f:helper
      )
    in
    helper root;
    !ans

  let rec remove_subtrees ~cond ?(index=SuperIndex.empty) g =
    let lst = fold_vertex (fun v acc -> if cond v then v::acc else acc) g [] in
    List.fold_left ~init:index lst ~f:(fun acc x -> kill_and_fall ~index:acc g x)

end
module GraphPrinter = Graph.Graphviz.Dot(G)

(* function to test does method a overrides method  ~base *)
let overrides subclass_of a ~base =
  let len = List.length in
  let b = base in
  let open With_return in
  With_return.with_return (fun r ->
    if a.m_name <> b.m_name then r.return false;
    if len a.m_args <> len b.m_args then r.return false;
    List.iter2_exn  a.m_args b.m_args ~f:(fun {arg_type=a;_} {arg_type=b;_} ->
      if compare_cpptype a b = 0 then ()
      else if (subclass_of a.t_name ~base:b.t_name) && (a.t_indirections=b.t_indirections) then ()
      else r.return false
    );
    true
  )

let names_print_helper s ~set =
  printf "%s: %s\n\n" s
    (List.to_string (MethSet.elements set) ~f:(fun m -> m.m_out_name) )

(* At the beginning we have abstract and normal methods in current class.
   Need to split them in three groups:
   * methods which implements abstract methods
   * normal methods
   * abstract meths which are not implemented by abstract methods in this class
 *)
let super_filter_meths subclass_of ~base ~cur =
  let (<=<) : MethSet.Elt.t -> base:MethSet.Elt.t -> bool = overrides subclass_of in

  let base_not_impl = ref MethSet.empty in (* abstract meths which are not implemented here *)
  let cur_impl = ref MethSet.empty in (* abstract meths which are implemented here *)
  let cur_new = ref MethSet.empty in (* methods declared in current class *)
  let rec loop base cur =
(*    printf "Inside loo: (cur.length, cur_new.length)  = (%d,%d)\n"
      (MethSet.length cur) (MethSet.length !cur_new); *)
    if MethSet.is_empty base then cur_new := MethSet.union !cur_new cur
    else if MethSet.is_empty cur then base_not_impl := MethSet.union !base_not_impl base
    else begin
      let cur_el = MethSet.min_elt_exn cur  in (* the `newest` method in heirarchy *)
      let (a,b) = MethSet.partition_tf ~f:(fun m -> cur_el <=< m) base in
      assert (MethSet.length a <= 1);
      if MethSet.is_empty a then begin
        (* метод cur_el не реализует ни одного абстрактного *)
        Ref.replace cur_new (fun set -> MethSet.add set cur_el)
      end else begin
        (* we found abstract method just implemented in cur_el *)
        let el = MethSet.min_elt_exn a in
        (*if el.m_out_name = "rowCount"
        then begin
          printf "\t\tFound method columnCount:\n";
          printf "\t\t\tbase  : %s %s\n" (string_of_m_access     el.m_access) (string_of_meth el);
          printf "\t\t\tcur_el: %s %s\n" (string_of_m_access cur_el.m_access) (string_of_meth cur_el);
          flush stdout
        end;*)
        Ref.replace cur_impl (fun set -> MethSet.add set { cur_el with m_out_name = el.m_out_name })
      end;
      loop b (MethSet.remove cur cur_el)
    end
  in
  loop base cur;
  assert (let len = MethSet.length !cur_impl in
          let x = MethSet.length !base_not_impl and y = MethSet.length !cur_new in
(*        printf "(x,y,len) = (%d,%d,%d)\n" x y len;
          printf "(base_len, cur_len) = (%d, %d)\n" (MethSet.length base) (MethSet.length cur); *)
          (x+len = MethSet.length base) && (y+len = MethSet.length cur));
  (* ФИШКА: нельзя будет менять генерируемые имена у cur_impl, иначе не будет согласоваться
     наследование с базовым (абстрактным) классом *)
  (!base_not_impl,!cur_impl,!cur_new)

let build_graph root_ns : index_t * G.t =
  let index = ref SuperIndex.empty in
  let g = G.create () in

  let on_enum_found prefix e =
    let key = NameKey.make_key ~name:e.e_flag_name ~prefix in
    let data = Enum e in
    index := SuperIndex.add ~key ~data !index
  in
  let on_class_found prefix name c =
    let key = NameKey.make_key ~name ~prefix in
    let data = Class ({c with c_enums=[]}, MethSet.empty) in

    let curvertex = G.V.create key in
    G.add_vertex g curvertex;
    let bases = List.map c.c_inherits ~f:(fun basename ->
      let k = NameKey.key_of_fullname basename in
      G.V.create k
    ) in

    List.iter bases ~f:(fun from -> G.add_edge g from curvertex);

    List.iter c.c_enums ~f:(on_enum_found (c.c_name::prefix));
    index := SuperIndex.add ~key ~data !index
  in
  let rec iter_ns prefix ns =
    let new_prefix = ns.ns_name :: prefix in
    List.iter ~f:(iter_ns new_prefix) ns.ns_ns;
    List.iter ~f:(iter_class new_prefix) ns.ns_classes;
    List.iter ~f:(on_enum_found new_prefix) ns.ns_enums
  and iter_class prefix c =
    on_class_found prefix c.c_name c
  in

  print_endline "iterating root namespace";
  List.iter ~f:(iter_ns []) root_ns.ns_ns;
  List.iter ~f:(iter_class []) root_ns.ns_classes;
  List.iter ~f:(on_enum_found []) root_ns.ns_enums;

  (* simplify_graph *)
(*
  let dead_roots = List.map ~f:NameKey.key_of_fullname
    [
     (* to avoid bugs *)
     "QIntegerForSize>"; "QtSharedPointer::ExternalRefCountWithDestroyFn";
     (* i think this class is useless in OCaml *)
     "QNoDebug"; "QDebug"; "QBool"; "QFlag"; "QForeachContainerBase"; "QBitRef";
     "QByteRef"; "QCharRef"; "QTemporaryFile";
     (* class feom Network namespace. implement later *)
     "QAbstractSocket"; "QAbstractXmlNodeModel"; "QAbstractXmlReceiver"; "QAuthenticator";
     "QFtp"; "QIPv6Address"; "QLocalSocket"; "QAbstractNetworkCache"; "QLocalServer"; "QTcpServer";
     (* to speed up remove not the most useful classes *)
     "QFactoryInterface";
     (* QtXmlPatterns module *)
     "QSourceLocation";
     (* part of QtWebKit namespace *)
     "QGraphicsWebView"
      ] in
  List.iter dead_roots ~f:(fun x -> index := G.kill_and_fall ~index:(!index) g x); *)
(*
  let prefixes = ["QXml"; "QHost"; "QHttp"; "QNetwork"; "QScript"; "QSsl";
  "QUrl"; "QGL"; "QThread"; "QVFb" ] @
  ["QIconEngine"; "QWeb"] (* QWebKit namespace *) in

  Ref.replace index
    (fun index -> G.remove_subtrees g ~index ~cond:(
      function
        | (name::_,_) ->
          List.fold_left ~init:false ~f:(fun acc prefix -> acc or (String.is_prefix ~prefix name)) prefixes
        | _ -> assert false)
    ); *)
  (!index,g)

let build_superindex root_ns =
  let (index,g) =
    let (a,b) = build_graph root_ns in
    let a' = ref a in
    (a',b)
  in
  let h = open_out "./outgraph.dot" in
  GraphPrinter.output_graph h g;
  Out_channel.close h;
  (* returns true if b is subclass of b in graph g *)
  let checker a b =
    (G.mem_vertex g a) && (G.mem_vertex g b) && (
      let module M = Graph.Path.Check(G) in
      let checker = M.create g in
      M.check_path checker a b (* checks if path exists from a to b *)
     )
  in
  let subclass_of a ~base:b =
    let ak = NameKey.key_of_fullname a
    and bk = NameKey.key_of_fullname b in
    let ans = checker bk ak in
    ans
  in
  let module Top = Graph.Topological.Make(G) in
  (* so we have classes topologically sorted. Base classes are before *)

  (* Evaluating virtuals *)
  let evaluated = ref Evaluated.empty in
  let module Q = Core.Core_queue in (* keys queue *)
  let ans_queue = Ref.create (Q.create ()) in

  print_endline "Evaluating virtuals";
  g |> Top.iter (fun v ->
    let key = G.V.label v in
    match SuperIndex.find !index key with
      | None ->
        evaluated := Evaluated.add !evaluated key;
        printf "base class of %s is not in index. skipped\n" (snd key)
      | Some (Enum _) -> print_endline "In graph exists enum. nonsense"
      | Some (Class (c,_)) -> begin
        let base_keys = List.map c.c_inherits ~f:NameKey.key_of_fullname in
        assert (List.for_all base_keys ~f:(Evaluated.mem !evaluated));
        evaluated := Evaluated.add !evaluated key;
        printf "\nEvaluating class %s\n" c.c_name;
(*      names_print_helper "Normal meths" c.c_meths_normal;
        printf "Base classes are: %s\n" (List.to_string snd base_keys);
        names_print_helper "Abstract meths" c.c_meths_abstr; *)

        let bases_data = List.filter_map base_keys ~f:(fun key -> match SuperIndex.find !index key with
          | Some (Class (y,set) ) -> Some y
          | None ->
            printf "WARNING! Base class %s of %s is not in index. Suppose that it is not abstract\n"
              (snd key) c.c_name;
            None
          | Some (Enum _) -> print_endline "nonsense"; assert false
        ) in
        let module S = String.Set in
        let cache = ref S.empty in
        let put_cache s = cache := S.add !cache s in
        let rec make_name s = if S.mem !cache s then make_name (s^"_") else s in

        let fix_names set = MethSet.map set ~f:(fun m ->
          if S.mem !cache m.m_out_name then begin
            let new_name = make_name m.m_out_name in
            put_cache new_name;
            {m with m_out_name=new_name}
          end else begin
            put_cache m.m_out_name;
            m
          end
        ) in

        let add2name_set set =
          let f m =
            if S.mem !cache m.m_out_name then begin
              printf "Current method:\n%s\n" (string_of_meth m);
              printf "declared in %s\n" m.m_declared;
              printf "Cache is: %s\n" (S.elements !cache |> String.concat ~sep:",");
              print_endline m.m_out_name;
              Core.Exn.backtrace () |> print_endline;
              assert false
            end;
            put_cache m.m_out_name
          in
          MethSet.iter set ~f
        in

        let module MS = MethSet in
        let base_meths = List.map bases_data ~f:(fun c -> c.c_meths) |> MethSet.union_list in
        let base_slots = List.map bases_data ~f:(fun c -> c.c_slots) |> MethSet.union_list in
        add2name_set base_meths;
        add2name_set base_slots;

        let f (a,b) el =
          if List.mem el.m_modif `Abstract then (MS.add a el,b)
          else if List.mem el.m_modif `Static then (a,b)
          else (a,MS.add b el)
        in

        let base_abstr_meths,base_normal_meths = MethSet.fold ~init:(MS.empty,MS.empty) ~f base_meths in
        let base_abstr_slots,base_normal_slots = MethSet.fold ~init:(MS.empty,MS.empty) ~f base_slots in

        (* base abstracts meths can be overrided in any way *)
(*      print_endline "Fixing base abstr meths"; *)
        let filter_meths = super_filter_meths subclass_of in
        let (meths_abstr_not_impl,meths_abstr_implemented, meths_last) =
          filter_meths ~base:base_abstr_meths ~cur:c.c_meths in

        let (meths_normal_inherited, meths_overriden, meths_last) =
          filter_meths ~base:base_normal_meths ~cur:meths_last in

        let (slots_abstr_inherited, slots_implemented, meths_last) =
          filter_meths ~base:base_abstr_slots ~cur:meths_last in

        let (slots_inherited, slots_overriden, meths_last) =
          filter_meths ~base:base_normal_slots ~cur:meths_last in

        let meths_last = fix_names meths_last in
        let my_slots = fix_names c.c_slots in

        let ans_slots = MS.union_list
          [slots_abstr_inherited; slots_implemented;
           slots_inherited; slots_overriden;
           my_slots] in

        let ans_meths = MS.union_list
          [meths_abstr_not_impl; meths_abstr_implemented;
           meths_normal_inherited; meths_overriden;
           meths_last] in

        let ans_signals = List.map bases_data ~f:(fun c -> c.c_sigs)
          |> List.concat |>  ((@) c.c_sigs) |> List.dedup in

        let ans_class = {
          c_inherits = c.c_inherits;
          c_props = c.c_props;
          c_sigs = ans_signals;
          c_slots = ans_slots;
          c_meths = ans_meths;
          c_enums = [];
          c_constrs = c.c_constrs;
          c_name = c.c_name
        }
        in

        let data = Class (ans_class, MS.empty) in
        index := SuperIndex.add !index ~key ~data;
        Q.enqueue !ans_queue key
      end
  );
  SuperIndex.iter !index ~f:(fun ~key ~data -> match data with
    | Class _ -> ()
    | Enum _ -> Q.enqueue !ans_queue key
  );
  (!index,g, !ans_queue)
