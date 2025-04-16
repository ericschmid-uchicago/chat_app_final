open Lwt.Infix

(* Server listens on this port. Adjust as needed. *)
let port = 9000

(* 
   Handle one connected client: run a bidirectional chat.
   After client disconnects or user types "exit", this returns.
*)
let handle_client client_sock =
  let in_chan  = Lwt_io.of_fd ~mode:Lwt_io.input  client_sock in
  let out_chan = Lwt_io.of_fd ~mode:Lwt_io.output client_sock in

  (* Store [message_id -> time_sent] so we can measure round-trip. *)
  let pending : (int, float) Hashtbl.t = Hashtbl.create 16 in
  (* Each side will track its next outgoing message ID. *)
  let next_id = ref 0 in

  (* 
     Receive loop: read lines from [client_sock]. 
     Protocol:
       - "MSG <id> <content>" means a new message with ID <id>.
         We print it, and automatically send "ACK <id>" back.
       - "ACK <id>" means we measure roundtrip time for that ID.
  *)
  let rec recv_loop () =
    Lwt_io.read_line_opt in_chan >>= function
    | None -> 
      Lwt_io.printl "Client disconnected." 
    | Some line ->
      (match String.split_on_char ' ' line with
       | "MSG" :: id_str :: rest ->
         (* Example: "MSG 5 Hello there" 
            means message ID=5, content="Hello there".
         *)
         (try
            let id = int_of_string id_str in
            let content = String.concat " " rest in
            (* Print the received message *)
            Lwt_io.printf "Received (id=%d): %S\n%!" id content >>= fun () ->
            (* Automatically ACK the message *)
            Lwt_io.write_line out_chan (Printf.sprintf "ACK %d" id)
          with _ ->
            Lwt_io.printl "Malformed MSG line.")
       | "ACK" :: id_str :: [] ->
         (* Example: "ACK 5" acknowledges message with ID=5. *)
         (try
            let id = int_of_string id_str in
            match Hashtbl.find_opt pending id with
            | Some t_sent ->
              let t_now = Unix.gettimeofday () in
              let rtt = (t_now -. t_sent) *. 1000.0 in
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

  (* 
     Send loop: read lines from server’s own stdin. 
     If user types "exit", we close. Otherwise, we send "MSG <id> <content>".
  *)
  let rec send_loop () =
    Lwt_io.read_line_opt Lwt_io.stdin >>= function
    | None ->
      (* EOF from server console *)
      Lwt_io.printl "Goodbye." >>= fun () ->
      Lwt.return_unit
    | Some line ->
      if line = "exit" then (
        Lwt_io.printl "Exiting chat..." >>= fun () ->
        Lwt_unix.close client_sock (* close connection *)
      ) else (
        let id = !next_id in
        incr next_id;
        let t_sent = Unix.gettimeofday () in
        Hashtbl.replace pending id t_sent;
        let wire = Printf.sprintf "MSG %d %s" id line in
        Lwt_io.write_line out_chan wire >>= send_loop
      )
  in

  (* run both loops concurrently; whichever ends first stops the chat *)
  Lwt.pick [recv_loop (); send_loop ()]

(* 
   Main server: bind/listen on [port]. Accept one client at a time. 
   Once the client disconnects, loop and wait for another.
*)
let main_server () =
  let sock = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  let addr = Unix.ADDR_INET (Unix.inet_addr_any, port) in
  Lwt_unix.setsockopt sock Unix.SO_REUSEADDR true;
  Lwt_unix.bind sock addr >>= fun () ->
  Lwt_unix.listen sock 1;
  Lwt_io.printf "Server listening on port %d.\n%!" port >>= fun () ->
  let rec accept_loop () =
    Lwt_io.printl "Waiting for a client..." >>= fun () ->
    Lwt_unix.accept sock >>= fun (client_sock, client_addr) ->
    Lwt_io.printf "Accepted connection from %s\n%!"
      (match client_addr with
       | Unix.ADDR_INET (ip, p) ->
          Printf.sprintf "%s:%d" (Unix.string_of_inet_addr ip) p
       | _ -> "Unknown") >>= fun () ->
    (* Handle the client chat, then loop again after they disconnect. *)
    handle_client client_sock >>= accept_loop
  in
  accept_loop ()

let () = Lwt_main.run (main_server ())
