
type t = {
  ncommits : int;
  depth : int;
  tree_add : int;
  display : int;
  clear : bool;
  gc : int;
}

let t = {
  ncommits = 1000;
  depth = 16;
  tree_add = 150;
  display = 10;
  clear = true;
  gc = 100;
}

module Store = Irmin_mem.KV.Make(Irmin.Contents.String)
let info () = Store.Info.v ~author:"author" ~message:"commit message" 0L

let times ~n ~init f =
  let rec go i k =
    if i = 0 then k init else go (i - 1) (fun r -> k (f i r))
  in
  go n Fun.id

let path ~depth n =
  let rec aux acc = function
    | i when i = depth -> List.rev (string_of_int n :: acc)
    | i -> aux (string_of_int i :: acc) (i + 1)
  in
  aux [] 0

let plot_progress n t = Fmt.epr "\rcommits: %4d/%d%!" n t

(* init: create a tree with [t.depth] levels and each levels has
   [t.tree_add] files + one directory going to the next level. *)
let init r =
  let tree = Store.Tree.empty () in
  let v = Store.main r in
  let tree =
    times ~n:t.depth ~init:tree (fun depth tree ->
        let paths = Array.init (t.tree_add + 1) (path ~depth) in
        times ~n:t.tree_add ~init:tree (fun n tree ->
            Store.Tree.add tree paths.(n) "init"))
  in
  Store.set_tree_exn v ~info [] tree;
  Fmt.epr "[init done]\n%!"

let run config =
  let v = Store.main config in
  Store.Tree.reset_counters ();
  let paths = Array.init (t.tree_add + 1) (path ~depth:t.depth) in
  let () =
    times ~n:t.ncommits ~init:() (fun i () ->
        let tree = Store.get_tree v [] in
        if i mod t.gc = 0 then Gc.full_major ();
        if i mod t.display = 0 then plot_progress i t.ncommits;
        let tree =
          times ~n:t.tree_add ~init:tree (fun n tree ->
              Store.Tree.add tree paths.(n) (string_of_int i))
        in
        Store.set_tree_exn v ~info [] tree;
        if t.clear then Store.Tree.clear tree)
  in
  Store.Repo.close config;
  Fmt.epr "\n[run done]\n%!"

let main _env =
  let config = Irmin_mem.config () in
  let r = Store.Repo.v config in
  init r;
  run r
