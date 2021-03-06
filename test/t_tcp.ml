open Lwt.Infix

let server_port = 9004
let server_ip = "127.0.0.1"
let server_backlog = 8

let server6_port = 9006
let server6_ip = "::1"

module U = Uwt
open Uwt.Tcp
open Common


module type Sockaddr =
sig
  val sockaddr : Uwt.sockaddr
end

let bind_exn s addr =
  if  Unix.PF_INET6 = (Uwt.Conv.to_unix_sockaddr_exn addr
                       |> Unix.domain_of_sockaddr)
  then
    bind_exn ~mode:[ Ipv6_only ] s ~addr ()
  else
    bind_exn s ~addr ()

module Echo_server (X: Sockaddr) = struct
  let sockaddr = X.sockaddr

  let echo_client c =
    let buf = Uwt_bytes.create 65_536 in
    let rec iter () =
      read_ba ~buf c >>= function
      | 0 -> close_wait c
      | len ->
        write_ba ~buf ~len c >>= fun () -> iter ()
    in
    Lwt.finalize ( fun () -> iter () )
      ( fun () -> close_noerr c ; Lwt.return_unit )

  let on_listen server x =
    if Uwt.Int_result.is_error x then
      ignore(Uwt_io.printl "listen error")
    else
      match accept server with
      | Uwt.Error _ -> Lwt.ignore_result (Uwt_io.printl "accept error")
      | Uwt.Ok c -> ignore (echo_client c)

  let start () =
    let server = init () in
    Lwt.finalize ( fun () ->
        bind_exn server sockaddr;
        let sockaddr2 = getsockname_exn server in
        (* I'm sure about this test. Does the ocaml unix library
           support equality compare for the abstract type
           Unix.inet_addr ? *)
        if Uwt.Conv.to_unix_sockaddr_exn sockaddr <>
           Uwt.Conv.to_unix_sockaddr_exn sockaddr2 then
          failwith "server sockaddr differ";
        listen_exn server ~max:server_backlog ~cb:on_listen;
        let (s:unit Lwt.t),_ = Lwt.task () in
        s
      ) ( fun () -> close_noerr server ; Lwt.return_unit )
end

module Client = struct

  let test raw addr =
    let buf_write = Buffer.create 128 in
    let buf_read = Buffer.create 128 in
    let t = Uwt.Tcp.init () in
    Uwt.Tcp.connect t ~addr >>= fun () ->

    let rec really_read len =
      let buf = Bytes.create len in
      Uwt.Tcp.read t ~buf >>= fun len' ->
      if len' = 0 || len' > len then (
        Uwt.Tcp.close_noerr t ;
        Lwt.return_unit
      )
      else (
        Buffer.add_subbytes buf_read buf 0 len';
        let len'' = len - len' in
        if len'' = 0 then
          Lwt.return_unit
        else
          really_read len''
      )
    in

    let tcp_write = match raw with
    | true -> Uwt.Tcp.write_raw
    | false -> Uwt.Tcp.write
    in
    let rec write i =
      if i <= 0 then
        Lwt.return_unit
      else
        let buf_len = Random.int 934 + 1 in
        let buf = rbytes_create buf_len in
        Buffer.add_bytes buf_write buf;
        Lwt.join [tcp_write t ~buf ; really_read buf_len] >>= fun () ->
        write (pred i)
    in
    write 1024 >>= fun () ->
    Uwt.Tcp.close_wait t >>= fun () ->
    Lwt.return ((Buffer.contents buf_write) = (Buffer.contents buf_read))
end

module Server = Echo_server (
  struct
    let sockaddr = Uwt_base.Misc.ip4_addr_exn server_ip server_port
  end)

module Server6 = Echo_server (
  struct
    let sockaddr = Uwt_base.Misc.ip6_addr_exn server6_ip server6_port
  end)

let server_thread = ref None
let server_init () =
  match !server_thread with
  | None -> server_thread := Some( Server.start () )
  | Some _ -> ()

let server6_thread = ref None
let server6_init () =
  match !server6_thread with
  | None -> server6_thread := Some( Server6.start () )
  | Some _ -> ()

let close_servers () =
  let stop x =
    match !x with
    | None -> ();
    | Some t ->
      x := None;
      Lwt.cancel t
  in
  stop server_thread ;
  stop server6_thread;
  Lwt.return_unit

let () = Uwt.Main.at_exit close_servers

let write_much client =
  let buf = rba_create 32_768 in
  let rec iter n =
    if n = 0 then
      write_ba client ~buf >>= fun () ->
      Lwt.fail (Failure "everything written!")
    else (
      ignore (write_ba client ~buf);
      iter (pred n)
    )
  in
  iter 100

let with_client f = server_init (); with_tcp f

let with_client_c4 f =
  server_init ();
  let t = with_connect ~addr:Server.sockaddr @@ fun t -> f t in
  m_true t

open OUnit2
let test_port = 8931
let l = [
  ("echo_server">::
   fun ctx ->
     server_init ();
     m_true ( Client.test true Server.sockaddr );
     m_true ( Client.test false Server.sockaddr );
     ip6_only ctx;
     server6_init ();
     m_true ( Client.test true Server6.sockaddr );
     m_true ( Client.test false Server6.sockaddr ));
  ("connect_timeout">::
   fun _ctx -> (* an unreachable address should not block the event loop *)
     let addr = Uwt_base.Misc.ip4_addr_exn "8.8.8.8" 9999 in
     let t = with_client @@ fun client ->
       let p1 = connect client ~addr >|= fun () -> false in
       let p2 = Uwt.Timer.sleep 50 >|= fun () -> true in
       Lwt.pick [ p1 ; p2 ]
     in
     m_true t);
  ("bind_error">::
   fun ctx ->
     let l sockaddr =
       with_tcp @@ fun s1 ->
       with_tcp @@ fun s2 ->
       let cb _ _ = () in
       bind_exn s1 sockaddr;
       bind_exn s2 sockaddr;
       let () = listen_exn ~max:8 ~cb s1 in
       let () = listen_exn ~max:8 ~cb s2 in
       Lwt.return_unit
     in
     let sockaddr = Uwt_base.Misc.ip4_addr_exn "0.0.0.0" test_port in
     m_raises (Uwt.EADDRINUSE,"listen","") (l sockaddr);
     ip6_only ctx;
     let sockaddr = Uwt_base.Misc.ip6_addr_exn "::0" test_port in
     m_raises (Uwt.EADDRINUSE,"listen","") (l sockaddr));
  ("write_allot">::
   fun ctx ->
     let l addr = with_client @@ fun client ->
       connect client ~addr >>= fun () ->
       let buf_len = 65_536 in
       let x = max 1 (multiplicand ctx) in
       let buf_cnt = 64 * x in
       let bytes_read = ref 0 in
       let bytes_written = ref 0 in
       let buf = Uwt_bytes.create buf_len in
       for i = 0 to pred buf_len do
         buf.{i} <- Char.chr (i land 255);
       done;
       let sleeper,waker = Lwt.task () in
       let cb_read = function
       | Uwt.Ok b ->
         for i = 0 to Bytes.length b - 1 do
           if Bytes.unsafe_get b i <> Char.chr (!bytes_read land 255) then
             Lwt.wakeup_exn waker (Failure "read wrong content");
           incr bytes_read;
         done
       | Uwt.Error Uwt.EOF -> Lwt.wakeup waker ()
       | Uwt.Error _ -> Lwt.wakeup_exn waker (Failure "fatal error!")
       in
       let cb_write () =
         bytes_written := buf_len + !bytes_written;
         Lwt.return_unit
       in
       for _i = 1 to buf_cnt do
         ignore ( write_ba client ~buf >>= cb_write );
       done;
       if write_queue_size client = 0 then
         Lwt.wakeup_exn waker
           (Failure "write queue size empty after write requests");
       read_start_exn client ~cb:cb_read;
       let t_shutdown = shutdown client >>= fun () ->
         if write_queue_size client <> 0 then
           Lwt.fail (Failure "write queue size not empty after shutdown")
         else
           Lwt.return_unit
       in
       Lwt.join [ t_shutdown ; sleeper ] >>= fun () ->
       close_wait client >|= fun () ->
       !bytes_read = !bytes_written &&
       !bytes_read = buf_len * buf_cnt
     in
     m_true (l Server.sockaddr);
     ip6_only ctx;
     m_true (l Server6.sockaddr));
  ("write_abort">::
   fun _ctx ->
     with_client_c4 @@ fun client ->
     let write_thread = write_much client in
     Uwt.Tcp.read_start_exn client ~cb:(fun _ -> ());
     close_wait client >>= fun () ->
     Lwt.catch ( fun () -> write_thread )
       ( function
       | Uwt.Uwt_error(Uwt.ECANCELED,_,_) -> Lwt.return_true
       | x -> Lwt.fail x ));
  ("read_abort">::
   fun _ctx ->
     with_client_c4 @@ fun client ->
     let read_thread =
       let buf = Bytes.create 128 in
       read client ~buf >>= fun _ ->
       Lwt.fail (Failure "read successful!")
     in
     let _:unit Lwt.t = Uwt.Timer.sleep 40 >|= fun () -> close_noerr client in
     Lwt.catch ( fun () -> read_thread )(function
       | Uwt.Uwt_error(Uwt.ECANCELED,_,_) -> Lwt.return_true
       | x -> Lwt.fail x ));
  ("getpeername">::
   fun _ctx ->
     with_client_c4 @@ fun client ->
     match getpeername_exn client |> Uwt.Conv.to_unix_sockaddr_exn with
     | Unix.ADDR_INET(y,x) ->
       Lwt.return (server_port = x && server_ip = Unix.string_of_inet_addr y)
     | Unix.ADDR_UNIX _ -> Lwt.return_false);
  (* The following test the same as 'write_abort' above (regarding TCP).
     The intention is to ensure, that lwt behaves as expected *)
  ("write_abort_pick">::
   fun _ctx ->
     with_client_c4 @@ fun client ->
     let write_thread =
       Lwt.catch ( fun () -> write_much client )
         ( fun x -> Uwt.Main.yield () >>= fun () -> Lwt.fail x )
     in
     let close_thread = close_wait client >|= fun () -> true in
     Lwt.pick [ close_thread ; write_thread ]);
  ("write_abort_pick2">::
   fun _ctx ->
     with_client_c4 @@ fun client ->
     let write_thread = Lwt.catch ( fun () -> write_much client ) (function
       | Uwt.Uwt_error(Uwt.ECANCELED,_,_) -> Lwt.return_true
       | x -> Lwt.fail x )
     in
     let close_thread = close_wait client >|= fun () -> false in
     Lwt.pick [ close_thread ; write_thread ]);
]

let l  = "Tcp">:::l
