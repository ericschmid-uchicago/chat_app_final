open Lwt.Infix

(* Connect to a remote host on [port]. *)
let connect_to_server host port =
  let sock = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.gethostbyname host >>= fun he ->
  if Array.length he.Unix.h_addr_list = 0 then
    Lwt.fail_with ("No IP found for host: " ^ host)
  else
    let addr = Unix.ADDR_INET (he.Unix.h_addr_list.(0), port) in
    Lwt_unix.connect sock addr >>= fun () ->
    Lwt.return sock

let main_client host port =
  connect_to_server host port >>= fun sock ->
  Lwt_io.printf "Connected to %s:%d\n%!" host port >>= fun () ->

  let in_chan  = Lwt_io.of_fd ~mode:Lwt_io.input  sock in
  let out_chan = Lwt_io.of_fd ~mode:Lwt_io.output sock in

  let pending : (int, float) Hashtbl.t = Hashtbl.create 16 in
  let next_id = ref 0 in

  let rec recv_loop () =
    Lwt_io.read_line_opt in_chan >>= function
    | None ->
      Lwt_io.printl "Server closed the connection."
    | Some line ->
      (match String.split_on_char ' ' line with
       | "MSG" :: id_str :: rest ->
         (try
            let id = int_of_string id_str in
            let content = String.concat " " rest in
            Lwt_io.printf "Received (id=%d): %S\n%!" id content >>= fun () ->
            Lwt_io.write_line out_chan (Printf.sprintf "ACK %d" id)
          with _ ->
            Lwt_io.printl "Malformed MSG line.")
       | "ACK" :: id_str :: [] ->
         (try
            let id = int_of_string id_str in
            match Hashtbl.find_opt pending id with
            | Some t_sent ->
              let rtt = (Unix.gettimeofday () -. t_sent) *. 1000.0 in
              Hashtbl.remove pending id;
              Lwt_io.printf "Received ACK for id=%d. Roundtrip: %.2f ms\n%!"
                id rtt
            | None ->
              Lwt_io.printl "ACK for unknown id (ignored)."
          with _ ->
            Lwt_io.printl "Malformed ACK line.")
       | _ ->
         Lwt_io.printl "Unknown line received (ignored).")
      >>= recv_loop
  in

  let rec send_loop () =
    Lwt_io.read_line_opt Lwt_io.stdin >>= function
    | None ->
      Lwt_io.printl "Client console closed."
    | Some line ->
      if line = "exit" then (
        Lwt_io.printl "Exiting chat..." >>= fun () ->
        Lwt_unix.close sock
      ) else (
        let id = !next_id in
        incr next_id;
        let t_sent = Unix.gettimeofday () in
        Hashtbl.replace pending id t_sent;
        let wire = Printf.sprintf "MSG %d %s" id line in
        Lwt_io.write_line out_chan wire >>= send_loop
      )
  in

  Lwt.pick [recv_loop (); send_loop ()]

let () =
  match Sys.argv with
  | [| _; host; port_str |] ->
    let port = int_of_string port_str in
    Lwt_main.run (main_client host port)
  | _ ->
    prerr_endline "Usage: client <host> <port>";
    exit 1
