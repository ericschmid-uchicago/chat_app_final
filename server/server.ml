open Lwt.Infix

let port = 9000

(* Handle one connected client *)
let handle_client client_sock =
  let in_chan  = Lwt_io.of_fd ~mode:Lwt_io.input  client_sock in
  let out_chan = Lwt_io.of_fd ~mode:Lwt_io.output client_sock in

  (* Track [message_id -> time_sent] so we can measure round-trip. *)
  let pending : (int, float) Hashtbl.t = Hashtbl.create 16 in
  let next_id = ref 0 in

  let rec recv_loop () =
    Lwt_io.read_line_opt in_chan >>= function
    | None ->
      Lwt_io.printl "Client disconnected."
    | Some line ->
      (match String.split_on_char ' ' line with
       | "MSG" :: id_str :: rest ->
         (try
            let id = int_of_string id_str in
            let content = String.concat " " rest in
            Lwt_io.printf "Received (id=%d): %S\n%!" id content >>= fun () ->
            (* Automatically ACK back *)
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
      Lwt_io.printl "Server console closed."
    | Some line ->
      if line = "exit" then (
        Lwt_io.printl "Exiting chat..." >>= fun () ->
        Lwt_unix.close client_sock
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

(* Main server that waits for clients on 0.0.0.0:9000 *)
let main_server () =
  let sock = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.setsockopt sock Unix.SO_REUSEADDR true;

  (* Bind to "0.0.0.0" so other machines on the LAN can connect. *)
  let addr = Unix.ADDR_INET (Unix.inet_addr_any, port) in
  Lwt_unix.bind sock addr >>= fun () ->
  Lwt_unix.listen sock 1;
  Lwt_io.printf "Server listening on 0.0.0.0:%d.\nWaiting for client...\n%!" port >>= fun () ->

  let rec accept_loop () =
    Lwt_unix.accept sock >>= fun (client_sock, client_addr) ->
    Lwt_io.printf "Accepted connection from %s\n%!"
      (match client_addr with
       | Unix.ADDR_INET (ip, p) ->
         Printf.sprintf "%s:%d" (Unix.string_of_inet_addr ip) p
       | _ -> "Unknown") >>= fun () ->
    handle_client client_sock >>= fun () ->
    Lwt_io.printl "Client session ended. Waiting for next client..." >>= accept_loop
  in
  accept_loop ()

let () =
  Lwt_main.run (main_server ())
