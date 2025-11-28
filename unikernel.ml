module Mem = Irmin_mem.KV.Make(Irmin.Contents.String)

let now clock = Eio.Time.now clock |> Int64.of_float

let (let@) = (@@)

open Lwt.Infix

module Make(Tcp : Tcpip.Tcp.S with type ipaddr = Ipaddr.t) = struct
  let start tcp =
    Eio_unikraft.run @@ fun env ->
    Lwt_eio.with_event_loop ~clock:env#clock @@ fun () ->
    Tcp.listen tcp ~port:9999 (fun flow ->
      Tcp.write flow (Cstruct.of_string "aaa") >|= Result.get_ok);
    Logs.info (fun f -> f "Hello");
    Eio.traceln "Started!!!";
    let repo = Mem.Repo.v (Irmin_mem.config ()) in
    let main = Mem.main repo in
    let info () =
      Irmin.Info.Default.v ~author:"test" ~message:"test" (now env#clock)
    in
    Eio.Switch.run @@ fun _ ->
    Logs.info (fun f -> f "Hello");
    let () = Mem.set_exn main ~info ["greeting"] "Hello from Irmin!" in
    let rec loop = function
      | 0 -> Lwt.return ()
      | n ->
          Logs.info (fun f -> f "%s" (Mem.get main ["greeting"]));
          Eio.Time.sleep env#clock 1.0;
          loop (n - 1)
    in
    loop 100
end
