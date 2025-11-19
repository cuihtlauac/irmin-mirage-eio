open Mirage

let main = main "Unikernel" job ~packages:[
  package "duration";
  package "eio_unikraft";
  package ~sublibs:["mem"] "irmin";
]
let () = register "hello" [ main ]
