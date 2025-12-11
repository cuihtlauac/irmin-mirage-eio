module Make(Stack : Tcpip.Stack.V4V6) = struct
  module Tcp = Stack.TCP
 
  let start stack =
    let _tcp = Stack.tcp stack in
    Eio_unikraft.run @@ fun env ->
    Eio.Switch.run @@ fun _ ->
    Bench.main env;
    Lwt.return_unit
end
