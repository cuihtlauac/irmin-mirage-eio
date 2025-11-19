module Mem = Irmin_mem.KV.Make(Irmin.Contents.String)

let now clock = Eio.Time.now clock |> Int64.of_float

let (let@) = (@@)

let start () =
  let@ env = Eio_unikraft.run in
  Eio.traceln "Started!!!";
  let repo = Mem.Repo.v (Irmin_mem.config ()) in
  let main = Mem.main repo in
  let info () =
    Irmin.Info.Default.v ~author:"test" ~message:"test" (now env#clock)
  in
  let () = Mem.set_exn main ~info ["greeting"] "Hello from Irmin!" in
  let rec loop = function
    | 0 -> Lwt.return_unit
    | n ->
        Logs.info (fun f -> f "%s" (Mem.get main ["greeting"]));
        Eio.Time.sleep env#clock 1.0;
        loop (n - 1)
  in
  loop 4
