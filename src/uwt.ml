(* Libuv bindings for OCaml
 * http://github.com/fdopen/uwt
 * Module Uwt
 * Copyright (C) 2015 Andreas Hauptmann
 * All rights reserved.
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * * Redistributions of source code must retain the above copyright
 *   notice, this list of conditions and the following disclaimer.
 *
 * * Redistributions in binary form must reproduce the above copyright
 *   notice, this list of conditions and the following disclaimer in
 *   the documentation and/or other materials provided with the
 *   distribution.
 *
 * * Neither the name of the author nor the names of its contributors
 *   may be used to endorse or promote products derived from this
 *   software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
 * COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
 * OF THE POSSIBILITY OF SUCH DAMAGE.
 *)

#define DEFINE_MUTEXES 1
#include "config.inc"

open Lwt.Infix
external init_stacks : unit -> unit = "uwt_init_stacks_na" "noalloc"
let () = init_stacks ()

#if HAVE_WINDOWS <> 0
external init_unix_windows : unit -> unit = "uwt_unix_windows_init_na" "noalloc"
let () = init_unix_windows ()
#endif

include Uwt_base

module LInt_result = struct

  let mfail ~name ~param (x: 'a Int_result.t) =
    Lwt.fail(Int_result.to_exn ~param ~name x)

  let fail ?(name="") ?(param="") (x:'a Int_result.t) =
    if Int_result.is_error x then
      mfail ~name ~param x
    else
      Lwt.fail_invalid_arg "Uwt.Int_result.fail"
end

type 'a cb = 'a result Lwt.u

type int_cb = Int_result.int Lwt.u
type unit_cb = Int_result.unit Lwt.u
type loop

(*
type loop_mode =
  | Sync
  | Lwt
  | Cb
*)
type uv_run_mode =
  | Run_once
  | Run_nowait
  (* | Run_default *)

module Exception = struct
  let exceptions = ref []

  let add_exception (e:exn) =
    let bt = Printexc.get_raw_backtrace () in
    exceptions := (e,bt)::!exceptions

  let () = Callback.register "uwt.add_exception" add_exception
end

(* not sure, if I can leave it that simple. Lwt.wakeup will
   raise an exception, if the corresponding thread is neither sleeping
   nor canceled *)
let () = Callback.register "uwt.wakeup" Lwt.wakeup

(* external uv_loop_close: loop -> Int_result.unit = "uwt_loop_close" *)
external uv_run_loop: loop -> uv_run_mode -> Int_result.int = "uwt_run_loop"

external uv_default_loop: int -> loop result = "uwt_default_loop"
let loop =
  match uv_default_loop 1 with (* Lwt of disabled loop_mode *)
  | Error _ ->
    prerr_endline "uwt error: can't initialize default loop";
    exit(3)
  | Ok x -> x

let param = ""

let efail ?(param="") name x = Lwt.fail (Uwt_error(x,name,param))
let eraise ?(param="") name x = raise (Uwt_error(x,name,param))

module Req = struct
  type t
  type type' =
    | Fs
    | Getaddr
    | Getname
    | Work

  external create: loop -> type' -> t = "uwt_req_create"
  external cancel_noerr: t -> unit = "uwt_req_cancel_noerr"
  external finalize: t -> unit = "uwt_req_finalize_na" "noalloc"

  let canceled = Lwt.fail Lwt.Canceled
  let ql ~typ ~f ~name ~param =
    let sleeper,waker = Lwt.task ()
    and wait_sleeper,wait_waker = Lwt.wait ()
    and req = create loop typ in
    let (x: Int_result.unit) = f loop req wait_waker in
    if Int_result.is_error x then
      LInt_result.mfail ~name ~param x
    else
      let t = wait_sleeper >>= fun x ->
        finalize req;
        if Lwt.is_sleeping sleeper then (
          (match x with
          | Ok x -> Lwt.wakeup waker x
          | Error x -> Lwt.wakeup_exn waker (Uwt_error(x,name,param)));
          canceled)
        else
          match x with
          | Ok x -> Lwt.return x
          | Error ECANCELED -> canceled
          | Error x -> efail ~param name x
      in
      Lwt.catch (fun () -> sleeper) (function
        | Lwt.Canceled ->
          cancel_noerr req;
          t
        | x -> Lwt.fail x)

  let qli ~typ ~f ~name ~param =
    let wait_sleeper,wait_waker = Lwt.wait ()
    and sleeper,waker = Lwt.task ()
    and req = create loop typ in
    let (x: Int_result.unit) = f loop req wait_waker in
    if Int_result.is_error x then
      LInt_result.mfail ~name ~param x
    else
      let t = wait_sleeper >>= fun x ->
        finalize req;
        if Lwt.is_sleeping sleeper then (
          if Int_result.is_ok x then
            Lwt.wakeup waker x
          else
            Int_result.to_exn ~param ~name x |> Lwt.wakeup_exn waker;
          canceled
        )
        else (
          if Int_result.is_ok x then
            Lwt.return x
          else if Int_result.plain x = (Int_result.ecanceled :> int) then
            canceled
          else
            Int_result.to_exn ~param ~name x |> Lwt.fail
        )
      in
      Lwt.catch (fun () -> sleeper) (function
        | Lwt.Canceled ->
          cancel_noerr req;
          t
        | x -> Lwt.fail x)

  let qlu ~typ ~f ~name ~param =
    qli ~typ ~f ~name ~param >>= fun (_:unit Int_result.t) ->
    Lwt.return_unit

  let qli ~typ ~f ~name ~param =
    qli ~typ ~f ~name ~param >|= fun (x:int Int_result.t) -> (x :> int)
end

let qsu_common ~name sleeper (x: Int_result.unit) =
  if (x :> int) < 0 then
    LInt_result.mfail ~name ~param x
  else
    sleeper >>= fun (x: Int_result.unit) ->
    if (x :> int) < 0 then
      LInt_result.mfail ~name ~param x
    else
      Lwt.return_unit

let qsu1 ~f ~name a =
  let sleeper,waker = Lwt.wait () in
  let (x: Int_result.unit) = f a waker in
  qsu_common ~name sleeper x

let qsu2 ~f ~name a b =
  let sleeper,waker = Lwt.wait () in
  let (x: Int_result.unit) = f a b waker in
  qsu_common ~name sleeper x

(*let qsu3 ~f ~name a b c =
  let sleeper,waker = Lwt.task () in
  let (x: Int_result.unit) = f a b c waker in
  qsu_common ~name sleeper x *)

let qsu4 ~f ~name a b c d =
  let sleeper,waker = Lwt.wait () in
  let (x: Int_result.unit) = f a b c d waker in
  qsu_common ~name sleeper x

let qsu5 ~f ~name a b c d e =
  let sleeper,waker = Lwt.wait () in
  let (x: Int_result.unit) = f a b c d e waker in
  qsu_common ~name sleeper x

let to_exn n = function
| Ok x -> x
| Error x -> raise (Uwt_error(x,n,param))

let to_exni name (n: Int_result.int) =
  if Int_result.is_error n then
    Int_result.raise_exn ~name ~param n
  else
    let n : int = (n :> int) in
    (n :> int)

let to_exnu name (n: Int_result.unit) =
  if Int_result.is_error n then
    Int_result.raise_exn ~name ~param n
  else
    ()

type u

module Handle = struct
  type t = u

  external close_wait: t -> unit_cb -> Int_result.unit = "uwt_close_wait"
  let close_wait t = qsu1 ~f:close_wait ~name:"uv_close" t

  external close: t -> Int_result.unit = "uwt_close_nowait"
  let close_noerr t =  ignore ( close t )

  external is_active: t -> bool = "uwt_is_active_na" "noalloc"

  external ref': t -> unit = "uwt_ref_na" "noalloc"
  external unref: t -> unit = "uwt_unref_na" "noalloc"
  external has_ref: t -> bool = "uwt_has_ref_na" "noalloc"
end

external get_buffer_size_common:
  u -> bool -> Int_result.int = "uwt_get_buffer_size_common_na" "noalloc"

external set_buffer_size_common:
  u -> int -> bool -> Int_result.unit =
  "uwt_set_buffer_size_common_na" "noalloc"

module Handle_ext = struct
  type t = u
  let get_send_buffer_size (s:t) = get_buffer_size_common s false
  let get_send_buffer_size_exn s =
    get_send_buffer_size s |> to_exni "uv_send_buffer_size"

  let get_recv_buffer_size s = get_buffer_size_common s true
  let get_recv_buffer_size_exn s =
    get_recv_buffer_size s |> to_exni "uv_recv_buffer_size"

  let set_send_buffer_size s l = set_buffer_size_common s l false
  let set_send_buffer_size_exn s l =
    set_send_buffer_size s l |> to_exnu "uv_send_buffer_size"

  let set_recv_buffer_size s l = set_buffer_size_common s l true
  let set_recv_buffer_size_exn s l =
    set_send_buffer_size s l |> to_exnu "uv_recv_buffer_size"
end

module Handle_fileno = struct
  type t = u
  external fileno: u -> Unix.file_descr result = "uwt_fileno"
  let fileno_exn s = fileno s |> to_exn "uv_fileno"
end

module Stream = struct
  type t = u
  include (Handle: (module type of Handle) with type t := t )
  external to_handle : t -> Handle.t = "%identity"

  external write_queue_size : t -> int = "uwt_write_queue_size_na" "noalloc"

  external read_start:
    t  -> cb:(Bytes.t result -> unit) -> Int_result.unit = "uwt_read_start"
  let read_start_exn a ~cb = read_start a ~cb |> to_exnu "uv_read_start"

  external iread_stop: t -> bool -> Int_result.unit = "uwt_read_stop"
  let read_stop a = iread_stop a false
  let read_stop_exn a = iread_stop a false |> to_exnu "read_stop"

  external write:
    t -> 'a -> int -> int -> unit_cb -> Int_result.unit =
    "uwt_write"

  let write_raw ?(pos=0) ?len s ~buf ~dim =
    let len =
      match len with
      | None -> dim - pos
      | Some x -> x
    in
    let name = "write" in
    if pos < 0 || len < 0 || pos > dim - len then
      Lwt.fail (Invalid_argument "Uwt.Stream.write_raw")
    else
      qsu4 ~name ~f:write s buf pos len

  let write_raw_ba ?pos ?len t ~(buf:buf) =
    let dim = Bigarray.Array1.dim buf in
    write_raw ~dim ?pos ?len t ~buf

  let write_raw_string ?pos ?len t ~buf =
    let dim = String.length buf in
    write_raw ~dim ?pos ?len t ~buf

  let write_raw ?pos ?len t ~buf =
    let dim = Bytes.length buf in
    write_raw ~dim ?pos ?len t ~buf

  external try_write:
    t -> 'a -> int -> int -> Int_result.int = "uwt_try_write_na" "noalloc"

  let try_write ?(pos=0) ?len s ~buf ~dim =
    let len =
      match len with
      | None -> dim - pos
      | Some x -> x
    in
    if pos < 0 || len < 0 || pos > dim - len then
      Int_result.uwt_einval
    else
      try_write s buf pos len

  let write ?(pos=0) ?len s ~buf ~dim =
    let len =
      match len with
      | None -> dim - pos
      | Some x -> x
    in
    let name = "write" in
    if pos < 0 || len < 0 || pos > dim - len then
      Lwt.fail (Invalid_argument "Uwt.Stream.write")
    else if len > 131072 then
      qsu4 ~name ~f:write s buf pos len
    else
      (* always us try_write first, perhaps we don't need to create
         a sleeping thread at all. It's faster for small write requests *)
      let x' = try_write ~pos ~len s ~buf ~dim in
      let x = ( x' :> int ) in
      if x < 0 then
        if x' = Int_result.eagain then
          qsu4 ~name ~f:write s buf pos len
        else
          LInt_result.mfail ~name ~param x'
      else if x = len then
        Lwt.return_unit
      else if x > len then
        efail name UWT_EFATAL
      else
        let pos = pos + x
        and len = len - x in
        qsu4 ~name ~f:write s buf pos len

  let write_ba ?pos ?len t ~(buf:buf) =
    let dim = Bigarray.Array1.dim buf in
    write ~dim ?pos ?len t ~buf

  let write_string ?pos ?len t ~buf =
    let dim = String.length buf in
    write ~dim ?pos ?len t ~buf

  let write ?pos ?len t ~buf =
    let dim = Bytes.length buf in
    write ~dim ?pos ?len t ~buf

  let try_write_ba ?pos ?len t ~(buf:buf) =
    let dim = Bigarray.Array1.dim buf in
    try_write ~dim ?pos ?len t ~buf

  let try_write_string ?pos ?len t ~buf =
    let dim = String.length buf in
    try_write ~dim ?pos ?len t ~buf

  let try_write ?pos ?len t ~buf =
    let dim = Bytes.length buf in
    try_write ~dim ?pos ?len t ~buf

  external read:
    t -> 'a -> int -> int -> int_cb -> Int_result.unit = "uwt_read_own"

  let read ?(pos=0) ?len t ~buf ~dim =
    let len =
      match len with
      | None -> dim - pos
      | Some x -> x
    in
    if pos < 0 || len < 0 || pos > dim - len then
      Lwt.fail (Invalid_argument "Uwt.Stream.read")
    else if len = 0 then
      Lwt.return 0
    else
      let sleeper,waker = Lwt.task () in
      let (x: Int_result.unit) = read t buf pos len waker in
      if Int_result.is_error x then
        LInt_result.fail ~name:"uwt_read" ~param x
      else
        let () = Lwt.on_cancel sleeper (fun () -> ignore(iread_stop t true)) in
        sleeper >>= fun ( x: Int_result.int ) ->
        if Int_result.is_error x then
          LInt_result.fail ~name:"uwt_read" ~param x
        else
          let x : int = (x :> int) in
          Lwt.return ( x :> int )

  let read_ba ?pos ?len t ~(buf:buf) =
    let dim = Bigarray.Array1.dim buf in
    read ?pos ?len ~dim ~buf t

  let read ?pos ?len t ~buf =
    let dim = Bytes.length buf in
    read ?pos ?len ~dim ~buf t

  external write2:
    t -> t -> 'a -> int -> int -> unit_cb -> Int_result.unit =
    "uwt_write2_byte" "uwt_write2_native"

  let write2 ?(pos=0) ?len ~buf ~send ~dim s =
    let len =
      match len with
      | None -> dim - pos
      | Some x -> x
    in
    if pos < 0 || len < 0 || pos > dim - len then
      Lwt.fail (Invalid_argument "Uwt.Stream.write2")
    else
      qsu5 ~name:"write2" ~f:write2 s send buf pos len

  let write2_ba ?pos ?len ~(buf:buf) ~send t =
    let dim = Bigarray.Array1.dim buf in
    write2 ?pos ?len ~buf ~send ~dim t

  let write2_string ?pos ?len ~buf ~send t =
    let dim = String.length buf in
    write2 ?pos ?len ~buf ~send ~dim t

  let write2 ?pos ?len ~buf ~send t =
    let dim = Bytes.length buf in
    write2 ?pos ?len ~buf ~send ~dim t

  external is_readable : t -> bool = "uwt_is_readable_na" "noalloc"
  external is_writable : t -> bool = "uwt_is_writable_na" "noalloc"

  external listen:
    t -> max:int -> cb:( t -> Int_result.unit -> unit ) -> Int_result.unit =
    "uwt_listen"
  let listen_exn a ~max ~cb = listen a ~max ~cb |> to_exnu "listen"

  external shutdown: t -> unit_cb -> Int_result.unit = "uwt_shutdown"
  let shutdown s = qsu1 ~name:"shutdown" ~f:shutdown s

  external accept_raw:
    server:t -> client:t -> Int_result.unit = "uwt_accept_raw_na" "noalloc"

  let accept_raw_exn ~server ~client =
    accept_raw ~server ~client |> to_exnu "accept_raw"

end

module Pipe = struct
  type t = u
  include (Stream: (module type of Stream) with type t := t )
  external to_stream : t -> Stream.t = "%identity"

  include (Handle_ext: (module type of Handle_ext) with type t := t)
  include (Handle_fileno: (module type of Handle_fileno) with type t := t)

  external e_openpipe : loop -> Unix.file_descr -> bool -> t result = "uwt_pipe_open"
  let openpipe_exn ?(ipc=false) f = e_openpipe loop f ipc |> to_exn "pipe_open"
  let openpipe ?(ipc=false) f = e_openpipe loop f ipc

  external e_init : loop -> bool -> t result = "uwt_pipe_init"
  let init ?(ipc=false) () =
    match e_init loop ipc with
    | Ok x -> x
    | Error ENOMEM -> raise Out_of_memory
    | Error x ->
      (* this can currently not happen. loop is initialized at program
         start - and will never be closed (UWT_EFATAL not possible).
         And uv_pipe_init always returns zero. But the libuv internals
         might change in future versions,... *)
      eraise "pipe_init" x

  external bind:
    t -> path:string -> Int_result.unit = "uwt_pipe_bind_na" "noalloc"
  let bind_exn a ~path = bind a ~path |> to_exnu "pipe_bind"

  external getsockname: t -> string result = "uwt_pipe_getsockname"
  let getsockname_exn a = getsockname a |> to_exn "pipe_getsockname"

  external pending_instances:
    t -> int -> Int_result.unit = "uwt_pipe_pending_instances_na" "noalloc"
  let pending_instances_exn a b =
    pending_instances a b |> to_exnu "pipe_pending_instances"

  external connect:
    t -> string -> unit_cb -> Int_result.unit = "uwt_pipe_connect"
  let connect p ~path:s = qsu2 ~name:"pipe_connect" ~f:connect p s

  external pending_count:
    t -> Int_result.int = "uwt_pipe_pending_count_na" "noalloc"
  let pending_count_exn a = pending_count a |> to_exni "pipe_pending_count"

  type pending_type =
    | Unknown
    | Tcp
    | Udp
    | Pipe

  external pending_type:
    t -> pending_type = "uwt_pipe_pending_type_na" "noalloc"

  let with_pipe ?ipc f =
    let t = init ?ipc () in
    Lwt.finalize ( fun () -> f t )
      (fun () -> close_noerr t ; Lwt.return_unit)

  let with_connect ?ipc ~path f =
    let t = init ?ipc () in
    Lwt.finalize (fun () ->
        connect t ~path >>= fun () ->
        f t
      )(fun () -> close_noerr t ; Lwt.return_unit)

  let with_open ?ipc fd f =
    match openpipe ?ipc fd with
    | Error x -> efail "openpipe" x
    | Ok t ->
      Lwt.finalize (fun () -> f t)
        (fun () -> close_noerr t ; Lwt.return_unit)
end

module Tty = struct
  type t = u
  include (Stream: (module type of Stream) with type t := t )
  include (Handle_fileno: (module type of Handle_fileno) with type t := t)
  external to_stream : t -> Stream.t = "%identity"

  external init: loop -> file -> bool -> t result = "uwt_tty_init"
  let init_exn f ~read = init loop f read |> to_exn "tty_init"
  let init f ~read = init loop f read

  type mode =
    | Normal
    | Raw
    | Io

  external set_mode:
    t -> mode -> Int_result.unit = "uwt_tty_set_mode_na" "noalloc"
  let set_mode_exn t ~mode = set_mode t mode |> to_exnu "tty_set_mode"
  let set_mode t ~mode =  set_mode t mode

  external reset_mode:
    unit -> Int_result.unit = "uwt_tty_reset_mode_na" "noalloc"
  let reset_mode_exn x = reset_mode x |> to_exnu "tty_reset_mode"

  type winsize = {
    width: int;
    height: int;
  }
  external get_winsize:  t -> winsize result = "uwt_tty_get_winsize"
  let get_winsize_exn t = get_winsize t |> to_exn "tty_get_winsize"
end

module Tcp = struct
  type t = u
  include (Stream: (module type of Stream) with type t := t )
  include (Handle_ext: (module type of Handle_ext) with type t := t)
  include (Handle_fileno: (module type of Handle_fileno) with type t := t)
  external to_stream : t -> Stream.t = "%identity"

  type mode =
    | Ipv6_only

  external init_raw: loop -> t result = "uwt_tcp_init"
  let init () =
    match init_raw loop with
    | Ok x -> x
    | Error ENOMEM -> raise Out_of_memory
    | Error x -> eraise "tcp_init" x

  external opentcp:
    t -> Unix.file_descr -> Int_result.unit = "uwt_tcp_open_na" "noalloc"

  let opentcp s =
    let x = init_raw loop in
    match x with
    | Error _ -> x
    | Ok t ->
      let r = opentcp t s in
      if Int_result.is_ok r then
        x
      else
        Error(Int_result.to_error r)

  let opentcp_exn s = opentcp s |> to_exn "tcp_open"

  external bind:
    t -> sockaddr -> mode list -> Int_result.unit = "uwt_tcp_bind_na" "noalloc"
  let bind_exn ?(mode=[]) t ~addr () = bind t addr mode |> to_exnu "tcp_bind"
  let bind ?(mode=[]) t ~addr () = bind t addr mode

  external nodelay: t -> bool -> Int_result.unit = "uwt_tcp_nodelay_na" "noalloc"
  let nodelay_exn t x = nodelay t x |> to_exnu "tcp_nodelay"

  external keepalive:
    t -> bool -> Int_result.unit = "uwt_tcp_keepalive_na" "noalloc"
  let keepalive_exn t x = keepalive t x |> to_exnu "tcp_keepalive"

  external simultaneous_accepts: t -> bool -> Int_result.unit =
    "uwt_tcp_simultaneous_accepts_na"
  let simultaneous_accepts_exn t x =
    simultaneous_accepts t x |> to_exnu "tcp_simultaneous_accepts"

  external getsockname: t -> sockaddr result = "uwt_tcp_getsockname"
  let getsockname_exn t = getsockname t |> to_exn "tcp_getsockname"

  external getpeername: t -> sockaddr result = "uwt_tcp_getpeername"
  let getpeername_exn t = getpeername t |> to_exn "tcp_getpeername"

  external connect:
    t -> sockaddr -> unit_cb -> Int_result.unit = "uwt_tcp_connect"
  let connect p ~addr = qsu2 ~name:"tcp_connect" ~f:connect p addr

  let accept server =
    let x = init_raw loop in
    match x with
    | Error _ -> x
    | Ok client  ->
      let p = accept_raw ~server ~client in
      if Int_result.is_ok p then
        x
      else
        let () = close_noerr client in
        Error(Int_result.to_error p)

  let accept_exn server =
    accept server |> to_exn "accept"

  let with_tcp f =
    let t = init () in
    Lwt.finalize (fun () -> f t)
      (fun () -> close_noerr t; Lwt.return_unit)

  let with_open fd f =
    match opentcp_exn fd with
    | exception x -> Lwt.fail x
    | t ->
      Lwt.finalize (fun () -> f t)
        (fun () -> close_noerr t; Lwt.return_unit)

  let with_connect ~addr f =
    let t = init () in
    Lwt.finalize (fun () -> connect t ~addr >>= fun () -> f t)
      (fun () -> close_noerr t; Lwt.return_unit)

  let with_accept server f =
    let t = init () in
    let r = accept_raw ~server ~client:t in
    if Int_result.is_error r then
      let () = close_noerr t in
      LInt_result.mfail ~param ~name:"accept" r
    else
      Lwt.finalize (fun () -> f t)
        (fun () -> close_noerr t; Lwt.return_unit)
end

module Udp = struct
  type t = u
  include (Handle: (module type of Handle) with type t := t )
  include (Handle_ext: (module type of Handle_ext) with type t := t)
  include (Handle_fileno: (module type of Handle_fileno) with type t := t)
  external to_handle : t -> Handle.t = "%identity"

  external send_queue_size: t -> int = "uwt_udp_send_queue_size_na" "noalloc"
  external send_queue_count: t -> int = "uwt_udp_send_queue_count_na" "noalloc"

  external init_raw: loop -> t result = "uwt_udp_init"
  let init () =
    match init_raw loop with
    | Ok x -> x
    | Error ENOMEM -> raise Out_of_memory
    | Error x -> eraise "init_tcp" x

  external openudp: t -> Unix.file_descr -> Int_result.unit = "uwt_udp_open_na" "noalloc"
  let openudp s =
    let x = init_raw loop in
    match x with
    | Error _ -> x
    | Ok t ->
      let r = openudp t s in
      if Int_result.is_ok r then
        x
      else
        Error(Int_result.to_error r)

  let openudp_exn s = openudp s |> to_exn "udp_open"

  type mode =
    | Ipv6_only
    | Reuse_addr

  external bind:
    t -> sockaddr -> mode list -> Int_result.unit = "uwt_udp_bind_na" "noalloc"
  let bind_exn ?(mode=[]) t ~addr () = bind t addr mode |> to_exnu "udp_bind"
  let bind ?(mode=[]) t ~addr () = bind t addr mode

  external getsockname: t -> sockaddr result = "uwt_udp_getsockname"
  let getsockname_exn t = getsockname t |> to_exn "udp_getsockname"

  type membership =
    | Leave_group
    | Join_group

  external set_membership:
    t -> multicast:string -> interface:string -> membership -> Int_result.unit =
    "uwt_udp_set_membership_na" "noalloc"

  let set_membership_exn t ~multicast ~interface m =
    set_membership t ~multicast ~interface m |> to_exnu "udp_set_membership"

  external set_multicast_loop:
    t -> bool -> Int_result.unit = "uwt_udp_set_multicast_loop_na" "noalloc"
  let set_multicast_loop_exn a b =
    set_multicast_loop a b |> to_exnu "udp_set_multicast_loop"

  external set_multicast_ttl:
    t -> int -> Int_result.unit = "uwt_udp_set_multicast_ttl_na" "noalloc"
  let set_multicast_ttl_exn a b =
    set_multicast_ttl a b |> to_exnu "udp_set_multicast_ttl"

  external set_multicast_interface:
    t -> string -> Int_result.unit =
    "uwt_udp_set_multicast_interface_na" "noalloc"
  let set_multicast_interface_exn a b =
    set_multicast_interface a b |> to_exnu "udp_set_multicast_interface"

  external set_broadcast:
    t -> bool -> Int_result.unit =
    "uwt_udp_set_broadcast_na" "noalloc"
  let set_broadcast_exn a b =
    set_broadcast a b |> to_exnu "udp_set_broadcast"

  external set_ttl:
    t -> int -> Int_result.unit = "uwt_udp_set_ttl_na" "noalloc"
  let set_ttl_exn a b =
    set_ttl a b |> to_exnu "udp_set_ttl"

  external try_send:
    t -> 'a -> int -> int -> sockaddr -> Int_result.int =
    "uwt_udp_try_send_na" "noalloc"

  let try_send ?(pos=0) ?len ~buf ~dim t s =
    let len = match len with
    | None -> dim - pos
    | Some x -> x
    in
    if pos < 0 || len < 0 || pos > dim - len then
      Int_result.uwt_einval
    else
      try_send t buf pos len s

  external send:
    t -> 'a -> int -> int -> sockaddr -> unit_cb -> Int_result.unit =
    "uwt_udp_send_byte" "uwt_udp_send_native"

  let send_raw ?(pos=0) ?len ~buf ~dim s addr =
    let name = "udp_send" in
    let len =
      match len with
      | None -> dim - pos
      | Some x -> x
    in
    if pos < 0 || len < 0 || pos > dim - len then
      Lwt.fail (Invalid_argument "Uwt.Udp.send_raw")
    else
      qsu5 ~name ~f:send s buf pos len addr

  let send_raw_ba ?pos ?len ~(buf:buf) t addr =
    let dim = Bigarray.Array1.dim buf in
    send_raw ~dim ?pos ?len ~buf t addr

  let send_raw_string ?pos ?len ~buf t addr =
    let dim = String.length buf in
    send_raw ~dim ?pos ?len ~buf t addr

  let send_raw ?pos ?len ~buf t addr =
    let dim = Bytes.length buf in
    send_raw ~dim ?pos ?len ~buf t addr

  let send ?(pos=0) ?len ~buf ~dim s addr =
    let name = "udp_send" in
    let len =
      match len with
      | None -> dim - pos
      | Some x -> x
    in
    if pos < 0 || len < 0 || pos > dim - len then
      Lwt.fail (Invalid_argument "Uwt.Udp.send")
#if HAVE_WINDOWS <> 0
    else (* windows doesn't support try_send *)
      qsu5 ~name ~f:send s buf pos len addr
#else
    else
      let x' = try_send ~pos ~len ~buf ~dim s addr in
      let x = ( x' :> int ) in
      if x < 0 then
        if x' = Int_result.eagain || x' = Int_result.enosys then
          qsu5 ~name ~f:send s buf pos len addr
        else
          LInt_result.mfail ~name ~param x'
      else if x = len then
        Lwt.return_unit
      else if x > len then
        efail name UWT_EFATAL
      else
        let pos = pos + x
        and len = len - x in
        qsu5 ~name ~f:send s buf pos len addr
#endif

  let send_ba ?pos ?len ~(buf:buf) t addr =
    let dim = Bigarray.Array1.dim buf in
    send ~dim ?pos ?len ~buf t addr

  let send_string ?pos ?len ~buf t addr =
    let dim = String.length buf in
    send ~dim ?pos ?len ~buf t addr

  let send ?pos ?len ~buf t addr =
    let dim = Bytes.length buf in
    send ~dim ?pos ?len ~buf t addr

  let try_send_string ?pos ?len ~buf t s =
    let dim = String.length buf in
    try_send ?pos ?len ~buf t s ~dim

  let try_send_ba ?pos ?len ~buf t s =
    let dim = Bigarray.Array1.dim buf in
    try_send ?pos ?len ~buf t s ~dim

  let try_send ?pos ?len ~buf t s =
    let dim = Bytes.length buf in
    try_send ?pos ?len ~buf t s ~dim

  type recv_result =
    | Data of Bytes.t * sockaddr option
    | Partial_data of Bytes.t * sockaddr option
    | Empty_from of sockaddr
    | Transmission_error of error

  external recv_start:
    t -> cb:(recv_result -> unit) -> Int_result.unit = "uwt_udp_recv_start"
  let recv_start_exn a ~cb = recv_start a ~cb |> to_exnu "udp_recv_start"

  external irecv_stop: t -> bool -> Int_result.unit = "uwt_udp_recv_stop"
  let recv_stop a = irecv_stop a false
  let recv_stop_exn a = irecv_stop a false |> to_exnu "udp_recv_stop"

  type recv = {
    recv_len: int;
    is_partial: bool;
    sockaddr: sockaddr option;
  }

  external recv:
    t -> 'a -> int -> int -> recv cb
    -> Int_result.unit = "uwt_udp_recv_own"

  let recv ?(pos=0) ?len ~buf ~dim t =
    let name = "uwt_udp_recv" in
    let len = match len with
    | None -> dim - pos
    | Some x -> x
    in
    if pos < 0 || len < 0 || pos > dim - len then
      Lwt.fail (Invalid_argument "Uwt.Udp.recv")
    else if len = 0 then
      Lwt.return ({ recv_len = 0; is_partial = false ; sockaddr = None })
    else
      let sleeper,waker = Lwt.task () in
      let x = recv t buf pos len waker in
      if Int_result.is_error x then
        LInt_result.fail ~name ~param x
      else
        let () = Lwt.on_cancel sleeper (fun () -> ignore (irecv_stop t true)) in
        sleeper >>= function
        | Ok x -> Lwt.return x
        | Error x -> efail ~param name x

  let recv_ba ?pos ?len ~(buf:buf) t =
    let dim = Bigarray.Array1.dim buf in
    recv ~dim ?pos ?len ~buf t

  let recv ?pos ?len ~buf t =
    let dim = Bytes.length buf in
    recv ~dim ?pos ?len ~buf t

end

module Timer = struct
  type t = u
  include (Handle: (module type of Handle) with type t := t )
  external to_handle : t -> Handle.t = "%identity"

  external start:
    loop -> ( t -> unit ) -> int -> int -> t result = "uwt_timer_start"

  let start ~repeat ~timeout ~cb =
    if repeat < 0 || timeout < 0 then
      Error UWT_EINVAL
    else
      start loop cb timeout repeat

  let start_exn ~repeat ~timeout ~cb =
    start ~cb ~timeout ~repeat |> to_exn "timer_start"

  let sleep s =
    let sleeper,waker = Lwt.task () in
    let cb (_:t) = Lwt.wakeup waker () in
    match start ~repeat:0 ~timeout:s ~cb with
    | Error x -> efail "timer_start" x
    | Ok t ->
      Lwt.on_cancel sleeper ( fun () -> close_noerr t );
      sleeper
end

module Signal = struct
  type t = u
  include (Handle: (module type of Handle) with type t := t )
  external to_handle : t -> Handle.t = "%identity"

  external start:
    loop -> int -> (t -> int -> unit) -> t result = "uwt_signal_start"

  let sigbreak = -50
  let sigwinch = -51

  let start_exn i ~cb = start loop i cb |> to_exn "signal_start"
  let start i ~cb = start loop i cb
end

module Poll = struct
  type t = u
  include ( Handle: (module type of Handle) with type t := t )
  include (Handle_fileno: (module type of Handle_fileno) with type t := t)
  external to_handle : t -> Handle.t = "%identity"

  type event =
    | Readable
    | Writable
    | Readable_writable

  external start:
    loop -> Unix.file_descr -> event -> ( t -> event result -> unit ) -> t result
    = "uwt_poll_start"

  let start_exn f e ~cb = start loop f e cb |> to_exn "poll_start"
  let start f e ~cb = start loop f e cb
end

module Fs_event = struct
  type t = u
  include ( Handle: (module type of Handle) with type t := t )
  external to_handle : t -> Handle.t = "%identity"

  type event =
    | Rename
    | Change

  type flags =
    | Entry
    | Stat
    | Recursive

  type cb = t -> (string * event list) result -> unit

  external start:
    loop -> string -> flags list -> cb -> t result =
    "uwt_fs_event_start"

  let start_exn s fl ~cb = start loop s fl cb |> to_exn "fs_event_start"
  let start s fl ~cb = start loop s fl cb
end

module Dns = struct

  type socket_domain = Unix.socket_domain =
    | PF_UNIX | PF_INET | PF_INET6
  type socket_type = Unix.socket_type =
    | SOCK_STREAM | SOCK_DGRAM | SOCK_RAW | SOCK_SEQPACKET

  type getaddrinfo_option = Unix.getaddrinfo_option =
    | AI_FAMILY of socket_domain
    | AI_SOCKTYPE of socket_type
    | AI_PROTOCOL of int
    | AI_NUMERICHOST
    | AI_CANONNAME
    | AI_PASSIVE

  type addr_info = {
    ai_family : socket_domain;
    ai_socktype : socket_type;
    ai_protocol : int;
    ai_addr : sockaddr;
    ai_canonname : string;
  }

  external getaddrinfo:
    string -> string -> getaddrinfo_option list ->
    loop -> Req.t -> addr_info list cb -> Int_result.unit
    = "uwt_getaddrinfo_byte" "uwt_getaddrinfo_native"

  let getaddrinfo ~host ~service options =
    Req.ql
      ~typ:Req.Getaddr
      ~f:(getaddrinfo host service options)
      ~name:"getaddrinfo"
      ~param

  type name_info = Unix.name_info = {
    ni_hostname : string;
    ni_service : string ;
  }

  type getnameinfo_option = Unix.getnameinfo_option =
    | NI_NOFQDN | NI_NUMERICHOST | NI_NAMEREQD | NI_NUMERICSERV | NI_DGRAM

  external getnameinfo :
    sockaddr -> getnameinfo_option list ->
    loop -> Req.t -> name_info cb -> Int_result.unit
    = "uwt_getnameinfo"

  let getnameinfo sock options =
    Req.ql
      ~typ:Req.Getname
      ~f:(getnameinfo sock options)
      ~name:"getnameinfo"
      ~param

end

module Process = struct
  type t = u
  include (Handle: (module type of Handle) with type t := t )
  external to_handle : t -> Handle.t = "%identity"

  type stdio =
    | Inherit_file of file
    | Create_pipe of Pipe.t
    | Inherit_pipe of Pipe.t
    | Inherit_stream of Stream.t

  type stdio_args = stdio option * stdio option * stdio option
  type uid_gid = int * int
  type exit_cb = t -> exit_status:int -> term_signal:int -> unit

  external spawn:
    loop * stdio_args * uid_gid * int ->
    string array * string option ->
    exit_cb option ->
    string * string array ->
    t result = "uwt_spawn"

  let spawn ?stdin ?stdout ?stderr ?uid ?gid ?(verbatim_arguments=false)
      ?(detach=false) ?(hide=true) ?(env=[]) ?cwd ?exit_cb exe args
    =
    let stdio = (stdin,stdout,stderr) in
    let flags =
      (match uid with
       | None -> 0
       | Some _ -> 1 ) lor
      (match gid with
       | None -> 0
       | Some _ -> 2 ) lor
      (match verbatim_arguments with
       | false -> 0
       | true -> 4 ) lor
      (match detach with
       | false -> 0
       | true -> 8 ) lor
      (match hide with
       | false -> 0
       |  true -> 16)
    in
    let uid_gid = ((match uid with
      | None -> 0
      | Some x -> x ),(match gid with
      | None -> 0
      | Some x -> x))
    in
    let p1 = loop,stdio,uid_gid,flags in
    spawn p1 (Array.of_list env,cwd) exit_cb (exe,Array.of_list args)

  let spawn_exn ?stdin ?stdout ?stderr ?uid ?gid ?verbatim_arguments
      ?detach ?hide ?env ?cwd ?exit_cb exe args =
    spawn ?stdin ?stdout ?stderr ?uid ?gid ?verbatim_arguments
      ?detach ?hide ?env ?cwd ?exit_cb exe args |> to_exn "spawn"

  external disable_stdio_inheritance: unit -> unit =
    "uwt_disable_stdio_inheritance_na" "noalloc"

  external pid: t -> Int_result.int = "uwt_pid_na" "noalloc"
  let pid_exn t = pid t |> to_exni "uwt_pid" (* yes uwt, it's not a function
                                                of libuv *)
  external process_kill: t -> int -> Int_result.unit = "uwt_process_kill_na"
  let process_kill_exn t s = process_kill t s |> to_exnu "process_kill"

  external kill:
    pid:int -> signum:int -> Int_result.unit = "uwt_kill_na" "noalloc"
  let kill_exn ~pid ~signum = kill ~pid ~signum |> to_exnu "kill"
end

module Async = struct
  type t = u
  include (Handle: (module type of Handle) with type t := t )
  external to_handle : t -> Handle.t = "%identity"

  external create: loop -> ( t -> unit ) -> t result = "uwt_async_create"
  let create cb = create loop cb

  external start: t -> Int_result.unit = "uwt_async_start_na" "noalloc"
  external stop: t -> Int_result.unit = "uwt_async_stop_na" "noalloc"

  external send: t -> Int_result.unit = "uwt_async_send_na" "noalloc"
end

module C_worker = struct
  type t = unit Int_result.t
  type 'a u = loop * Req.t * 'a result Lwt.u

  let call_internal ?(param="") ?(name="") (f: 'a -> 'b u -> t) (a:'a) : 'b Lwt.t =
    let sleeper,waker = Lwt.task ()
    and wait_sleeper,wait_waker = Lwt.wait ()
    and req = Req.create loop Req.Work in
    match f a (loop,req,wait_waker) with
    | exception x ->
      Req.finalize req;
      Lwt.fail x
    | x ->
      if Int_result.is_error x then
        LInt_result.mfail ~name ~param x
      else
        let t = wait_sleeper >>= fun x ->
          Req.finalize req;
          if Lwt.is_sleeping sleeper then (
            (match x with
            | Ok x -> Lwt.wakeup waker x
            | Error x -> Lwt.wakeup_exn waker (Uwt_error(x,name,param)));
            Req.canceled)
          else
            match x with
            | Ok x -> Lwt.return x
            | Error ECANCELED -> Req.canceled
            | Error x -> efail ~param name x
        in
        Lwt.catch (fun () -> sleeper) (function
          | Lwt.Canceled ->
            Req.cancel_noerr req;
            t
          | x -> Lwt.fail x)

  let call a b = call_internal a b
end

module Unix = struct
  type seek_command = Unix.seek_command = SEEK_SET | SEEK_CUR | SEEK_END
  external lseek:
    file -> int64 -> seek_command -> loop -> Req.t -> int64 cb ->
    Int_result.unit = "uwt_lseek_byte" "uwt_lseek_native"

  let lseek f o m  =
    Req.ql
      ~typ:Req.Work
      ~f:(lseek f o m)
      ~name:"lseek"
      ~param

  external gethostname:
    unit -> string C_worker.u -> C_worker.t = "uwt_gethostname"
  let gethostname () =
    C_worker.call_internal ~name:"gethostname" gethostname ()

  type socket_domain = Unix.socket_domain = PF_UNIX | PF_INET | PF_INET6
  type host_entry = Unix.host_entry = {
    h_name : string;
    h_aliases : string array;
    h_addrtype : socket_domain;
    h_addr_list : Unix.inet_addr array;
  }
  external gethostbyname:
    string -> host_entry C_worker.u -> C_worker.t = "uwt_gethostbyname"
  let gethostbyname s =
    host_protect(
      C_worker.call_internal ~name:"gethostbyname" ~param:s gethostbyname s)

  external gethostbyaddr:
    Unix.inet_addr -> host_entry C_worker.u -> C_worker.t = "uwt_gethostbyaddr"
  let gethostbyaddr p =
    host_protect(C_worker.call_internal ~name:"gethostbyaddr" gethostbyaddr p)

  type service_entry = Unix.service_entry = {
    s_name : string;
    s_aliases : string array;
    s_port : int;
    s_proto : string;
  }
  external getservbyname:
    string * string -> service_entry C_worker.u -> C_worker.t =
    "uwt_getservbyname"
  let getservbyname ~name ~protocol =
    let p = name,protocol in
    serv_protect(
      C_worker.call_internal ~name:"getservbyname" ~param:name getservbyname p)

  external getservbyport:
    int * string -> service_entry C_worker.u -> C_worker.t =
    "uwt_getservbyport"
  let getservbyport port proto =
    let p = port,proto in
    serv_protect(
      C_worker.call_internal ~name:"getservbyport" ~param:proto getservbyport p)

  type protocol_entry = Unix.protocol_entry = {
    p_name : string;
    p_aliases : string array;
    p_proto : int;
  }
  external getprotobyname:
    string -> protocol_entry C_worker.u -> C_worker.t =
    "uwt_getprotobyname"
  let getprotobyname p =
    proto_protect(
      C_worker.call_internal ~name:"getprotobyname" ~param:p getprotobyname p)

  external getprotobynumber:
    int -> protocol_entry C_worker.u -> C_worker.t =
    "uwt_getprotobynumber"
  let getprotobynumber p =
    proto_protect(
      C_worker.call_internal ~name:"getprotobynumber" getprotobynumber p)

  external getcwd:
    unit -> string C_worker.u -> C_worker.t = "uwt_getcwd"
  let getcwd () = C_worker.call_internal ~name:"getcwd" getcwd ()

  external chdir:
    string -> unit C_worker.u -> C_worker.t = "uwt_chdir"
  let chdir s = C_worker.call_internal ~name:"chdir" ~param:s chdir s

  external getlogin:
    unit -> string C_worker.u -> C_worker.t = "uwt_getlogin"
  let getlogin () =
    getlogin_protect(C_worker.call_internal ~name:"getlogin" getlogin ())

  type passwd_entry = Unix.passwd_entry = {
    pw_name : string;
    pw_passwd : string;
    pw_uid : int;
    pw_gid : int;
    pw_gecos : string;
    pw_dir : string;
    pw_shell : string;
  }
  external getpwnam:
    string -> passwd_entry C_worker.u -> C_worker.t = "uwt_getpwnam"
  let getpwnam s =
    passwd_protect(C_worker.call_internal ~name:"getpwnam" ~param:s getpwnam s)

  external getpwuid:
    int -> passwd_entry C_worker.u -> C_worker.t = "uwt_getpwuid"
  let getpwuid s =
    passwd_protect(C_worker.call_internal ~name:"getpwuid" getpwuid s)

  type group_entry = Unix.group_entry = {
      gr_name : string;
      gr_passwd : string;
      gr_gid : int;
      gr_mem : string array;
    }
  external getgrnam:
    string -> group_entry C_worker.u -> C_worker.t = "uwt_getgrnam"
  let getgrnam s =
    passwd_protect(
      C_worker.call_internal ~name:"getgrnam" ~param:s getgrnam s)

  external getgrgid:
    int -> group_entry C_worker.u -> C_worker.t = "uwt_getgrgid"
  let getgrgid s =
    passwd_protect(C_worker.call_internal ~name:"getgrgid" getgrgid s)

  external chroot:
    string -> unit C_worker.u -> C_worker.t = "uwt_chroot"
  let chroot s = C_worker.call_internal ~name:"chroot" ~param:s chroot s

  type lock_command = Unix.lock_command =
    | F_ULOCK | F_LOCK | F_TLOCK | F_TEST | F_RLOCK | F_TRLOCK
  external lockf:
    file * lock_command * int64 -> unit C_worker.u -> C_worker.t = "uwt_lockf"
  let lockf a b c =
    C_worker.call_internal ~name:"lockf" lockf (a,b,c)

  let max_sleep = float_of_int (max_int / 1_000)
  let sleep s =
    let msi =
      if s <= 0. then
        0
      else if s >= max_sleep then
        max_int
      else
        int_of_float (s *. 1_000.)
    in
    Timer.sleep msi

  external pipe:
    bool -> (Unix.file_descr * Unix.file_descr) result = "uwt_pipe"

  let close_noerr x =
    try Unix.close x with Unix.Unix_error _ -> ()

  let pipe_exn ?(cloexec=true) () =
    match pipe cloexec with
    | Error x -> eraise "pipe" x
    | Ok(fd1,fd2) ->
      try
        Pipe.(openpipe_exn fd1, openpipe_exn fd2)
      with
      | exn ->
        close_noerr fd1;
        close_noerr fd2;
        raise exn

  let pipe ?(cloexec=true) () =
    match pipe cloexec with
    | (Error _) as x -> x
    | Ok(fd1,fd2) ->
      match Pipe.(openpipe fd1, openpipe fd2) with
      | Ok p1, Ok p2 -> Ok(p1,p2)
      | x,y ->
        close_noerr fd1;
        close_noerr fd2;
        match x,y with
        | ((Error _) as x) , _
        | _ , ((Error _) as x) -> x
        | Ok _, Ok _ -> assert false

#if HAVE_UV_REALPATH = 0
  external realpath: string -> string C_worker.u -> C_worker.t = "uwt_realpath"
  let realpath s = C_worker.call_internal ~name:"realpath" ~param:s realpath s
#else
  external realpath:
    string -> loop -> Req.t -> string cb -> Int_result.unit = "uwt_fs_realpath"
#if HAVE_WINDOWS <> 0
  external realpath_o: string -> string C_worker.u -> C_worker.t = "uwt_realpath"
  let use_own_realpath = ref (
      match Uwt_base.Sys_info.win_version () with
      | Ok(x) when x.Uwt_base.Sys_info.major_version < 6 -> true
      | _ -> false )
  let realpath param =
    match !use_own_realpath with
    | true -> realpath_o param
    | false ->
      Lwt.catch (fun () ->
          Req.ql ~typ:Req.Fs ~f:(realpath param) ~name:"realpath" ~param)
        (function
        | Uwt_error((UWT_EUNAVAIL|ENOSYS),"realpath",x) when x = param ->
          use_own_realpath := true;
          realpath_o param
        | x -> Lwt.fail x)
#else
  let realpath param = Req.ql ~typ:Req.Fs ~f:(realpath param) ~name:"realpath" ~param
#endif
#endif
end

module Fs = struct
  include Fs_types

  let typ = Req.Fs

  external openfile:
    string -> uv_open_flag list -> int ->
    loop -> Req.t -> file cb ->
    Int_result.unit =
    "uwt_fs_open_byte" "uwt_fs_open_native"

  let openfile ?(perm=0o644) ~mode fln =
    Req.ql ~typ ~name:"uv_fs_open" ~param:fln ~f:(openfile fln mode perm)

  external read:
    file -> 'a -> int -> int ->
    loop -> Req.t -> int_cb ->
    Int_result.unit =
    "uwt_fs_read_byte" "uwt_fs_read_native"

  let read ?(pos=0) ?len t ~buf ~dim =
    let len =
      match len with
      | None -> dim - pos
      | Some x -> x
    in
    if pos < 0 || len < 0 || pos > dim - len then
      Lwt.fail (Invalid_argument "Uwt.Fs.read")
    else
      Req.qli ~typ ~name:"uv_fs_read" ~param ~f:(read t buf pos len)

  let read_ba ?pos ?len t ~(buf:buf) =
    let dim = Bigarray.Array1.dim buf in
    read ?pos ?len ~dim ~buf t

  let read ?pos ?len t ~buf =
    let dim = Bytes.length buf in
    read ?pos ?len ~dim ~buf t

  external write:
    file -> 'a -> int -> int ->
    loop -> Req.t -> int_cb ->
    Int_result.unit =
    "uwt_fs_write_byte" "uwt_fs_write_native"

  let write ?(pos=0) ?len ~dim t ~buf =
    let len =
      match len with
      | None -> dim - pos
      | Some x -> x
    in
    if pos < 0 || len < 0 || pos > dim - len then
      Lwt.fail (Invalid_argument "Uwt.Fs.write")
    else
      Req.qli ~typ ~name:"uv_fs_write" ~param ~f:(write t buf pos len)

  let write_ba ?pos ?len t ~(buf:buf) =
    let dim = Bigarray.Array1.dim buf in
    write ~dim ?pos ?len t ~buf

  let write_string ?pos ?len t ~buf =
    let dim = String.length buf in
    write ~dim ?pos ?len t ~buf

  let write ?pos ?len t ~buf =
    let dim = Bytes.length buf in
    write ~dim ?pos ?len t ~buf

  external close:
    file -> loop -> Req.t -> unit_cb -> Int_result.unit =
    "uwt_fs_close"

  let close fd = Req.qlu ~typ ~f:(close fd) ~name:"close" ~param

  external unlink:
    string -> loop -> Req.t -> unit_cb -> Int_result.unit = "uwt_fs_unlink"
  let unlink param = Req.qlu ~typ ~f:(unlink param) ~name:"unlink" ~param

  external mkdir:
    string -> int -> loop -> Req.t -> unit_cb -> Int_result.unit =
    "uwt_fs_mkdir"
  let mkdir ?(perm=0o777) param =
    Req.qlu ~typ ~f:(mkdir param perm) ~name:"mkdir" ~param

  external rmdir:
    string -> loop -> Req.t -> unit_cb -> Int_result.unit = "uwt_fs_rmdir"
  let rmdir param =
    Req.qlu ~typ ~f:(rmdir param) ~name:"rmdir" ~param

  external rename:
    string -> string -> loop -> Req.t -> unit_cb -> Int_result.unit =
    "uwt_fs_rename"
  let rename ~src ~dst =
    Req.qlu ~typ ~f:(rename src dst) ~name:"rename" ~param:src

  external link:
    string -> string -> loop -> Req.t -> unit_cb -> Int_result.unit =
    "uwt_fs_link"
  let link ~target ~link_name =
    Req.qlu ~typ ~f:(link target link_name) ~name:"link" ~param:target

  external fsync: file -> loop -> Req.t -> unit_cb -> Int_result.unit =
    "uwt_fs_fsync"
  let fsync file =
    Req.qlu ~typ ~f:(fsync file) ~name:"fsync" ~param

  external fdatasync:
    file -> loop -> Req.t -> unit_cb -> Int_result.unit = "uwt_fs_fsync"
  let fdatasync file =
    Req.qlu ~typ ~f:(fdatasync file) ~name:"fdatasync" ~param

  external ftruncate:
    file -> int64 -> loop -> Req.t -> unit_cb -> Int_result.unit =
    "uwt_fs_ftruncate"
  let ftruncate file ~len =
    Req.qlu ~typ ~f:(ftruncate file len) ~name:"ftruncate" ~param

  external stat:
    string -> loop -> Req.t -> stats cb -> Int_result.unit = "uwt_fs_stat"
  let stat param = Req.ql ~typ ~f:(stat param) ~name:"stat" ~param

  external lstat:
    string -> loop -> Req.t -> stats cb -> Int_result.unit = "uwt_fs_lstat"
  let lstat param = Req.ql ~typ ~f:(lstat param) ~name:"stat" ~param

  external fstat:
    file -> loop -> Req.t -> stats cb -> Int_result.unit = "uwt_fs_fstat"
  let fstat fd = Req.ql ~typ ~f:(fstat fd) ~name:"fstat" ~param

  external symlink:
    string -> string -> symlink_mode -> loop -> Req.t -> unit_cb ->
    Int_result.unit = "uwt_fs_symlink_byte" "uwt_fs_symlink_native"
  let symlink ?(mode=S_Default) ~src ~dst () =
    Req.qlu ~typ ~f:(symlink src dst mode) ~name:"symlink" ~param:dst

  external mkdtemp:
    string -> loop -> Req.t -> string cb -> Int_result.unit = "uwt_fs_mkdtemp"
  let mkdtemp param =
    Req.ql ~typ ~f:(mkdtemp param) ~name:"mkdtemp" ~param

  external sendfile:
    file -> file -> int64 -> nativeint -> loop -> Req.t -> nativeint cb ->
    Int_result.unit = "uwt_fs_sendfile_byte" "uwt_fs_sendfile_native"
  let sendfile ?(pos=0L) ?(len=Nativeint.max_int)  ~dst ~src () =
    Req.ql ~typ ~f:(sendfile dst src pos len) ~name:"sendfile" ~param

  external utime:
    string -> float -> float -> loop -> Req.t -> unit_cb -> Int_result.unit =
    "uwt_fs_utime_byte" "uwt_fs_utime_native"
  let utime s ~access ~modif =
    Req.qlu ~typ ~f:(utime s access modif) ~name:"utime" ~param:s

  external futime:
    file -> float -> float -> loop -> Req.t -> unit_cb -> Int_result.unit =
    "uwt_fs_futime_byte" "uwt_fs_futime_native"
  let futime fd ~access ~modif =
    Req.qlu ~typ ~f:(futime fd access modif) ~name:"futime" ~param

  external readlink:
    string -> loop -> Req.t -> string cb -> Int_result.unit = "uwt_fs_readlink"
  let readlink param =
    Req.ql ~typ ~f:(readlink param) ~name:"readlink" ~param

  external access:
    string -> access_permission list -> loop -> Req.t -> unit_cb ->
    Int_result.unit = "uwt_fs_access"
  let access s al = Req.qlu ~typ ~f:(access s al) ~name:"access" ~param:s

  external chmod:
    string -> int -> loop -> Req.t -> unit_cb -> Int_result.unit =
    "uwt_fs_chmod"
  let chmod param ~perm =
    Req.qlu ~typ ~f:(chmod param perm) ~name:"chmod" ~param

  external fchmod:
    file -> int -> loop -> Req.t -> unit_cb -> Int_result.unit = "uwt_fs_fchmod"
  let fchmod fd ~perm =
    Req.qlu ~typ ~f:(fchmod fd perm) ~name:"fchmod" ~param

  external chown:
    string -> int -> int -> loop -> Req.t -> unit_cb -> Int_result.unit =
    "uwt_fs_chown_byte" "uwt_fs_chown_native"
  let chown s ~uid ~gid =
    Req.qlu ~typ ~f:(chown s uid gid) ~name:"chown" ~param:s

  external fchown:
    file -> int -> int -> loop -> Req.t -> unit_cb -> Int_result.unit =
    "uwt_fs_fchown_byte" "uwt_fs_fchown_native"
  let fchown fd ~uid ~gid =
    Req.qlu ~typ ~f:(fchown fd uid gid) ~name:"fchown" ~param

  external scandir:
    string -> loop -> Req.t -> (file_kind * string) array cb ->
    Int_result.unit = "uwt_fs_scandir"
  let scandir param =
    Req.ql ~typ ~f:(scandir param) ~name:"scandir" ~param

  let realpath = Unix.realpath
end

module Fs_poll = struct
  type t = u
  include ( Handle: (module type of Handle) with type t := t )
  external to_handle : t -> Handle.t = "%identity"

  type report = {
    prev: Fs.stats;
    curr: Fs.stats
  }

  external start:
    loop -> string -> int -> (t -> report result -> unit) -> t result =
    "uwt_fs_poll_start"

  let start_exn s fl ~cb = start loop s fl cb |> to_exn "fs_poll_start"
  let start s fl ~cb = start loop s fl cb
end

module Main = struct

  open Exception

  let fatal_found = ref false (* information for exit_hook and run *)


  exception Main_error of error * string
  exception Deferred of (exn * Printexc.raw_backtrace) list
  exception Fatal of exn * Printexc.raw_backtrace

  let enter_iter_hooks = Lwt_sequence.create ()
  let leave_iter_hooks = Lwt_sequence.create ()
  let yielded = Lwt_sequence.create ()
  let yield () = Lwt.add_task_r yielded

  let rec run ~nothing_cnt task =
    Lwt.wakeup_paused ();
    match Lwt.poll task with
    | Some x -> x
    | None ->
      (* 255 is certainly too high. But I will perhaps postpone certain tasks
         to the next loop iteration *)
      if nothing_cnt > 255 then
        raise (Main_error(EOF,"nothing to do in run"))
      else (
        (* Call enter hooks. *)
        Lwt_sequence.iter_l (fun f -> f ()) enter_iter_hooks;
        (* Do the main loop call. *)
        let mode =
          if Lwt.paused_count () = 0 && Lwt_sequence.is_empty yielded then
            Run_once
          else
            Run_nowait
        in
        let lr = match uv_run_loop loop mode with
        | lr -> lr
        | exception e ->
          fatal_found := true;
          let bt = Printexc.get_raw_backtrace () in
          raise (Fatal(e,bt))
        in
        (match !exceptions with
         | [] -> ()
         | l ->
           exceptions:= [];
           let l = List.rev l in
           let l =
             if Int_result.is_error lr then
               (Main_error(Int_result.to_error lr,"run"),
                Printexc.get_callstack 0)::l
             else
               l
           in
           raise (Deferred l));
        if Int_result.is_error lr then
          raise (Main_error(Int_result.to_error lr,"run"));
        let nothing_cnt =
          let lr : int = (lr :> int) in
          if lr = 0 && mode = Run_once then
            nothing_cnt + 1
          else
            0
        in
        Lwt.wakeup_paused ();
        (* Wakeup yielded threads now. *)
        if not (Lwt_sequence.is_empty yielded) then begin
          let tmp = Lwt_sequence.create () in
          Lwt_sequence.transfer_r yielded tmp;
          Lwt_sequence.iter_l (fun wakener -> Lwt.wakeup wakener ()) tmp
        end;
        (* Call leave hooks. *)
        Lwt_sequence.iter_l (fun f -> f ()) leave_iter_hooks;
        run ~nothing_cnt task
      )

  external cleanup: unit -> unit = "uwt_cleanup_na" "noalloc"

  let run (t:'a Lwt.t) : 'a =
    if !fatal_found then
      failwith "uwt loop unusuable";
    run ~nothing_cnt:0 t

  let exit_hooks = Lwt_sequence.create ()

  let rec call_hooks () =
    match Lwt_sequence.take_opt_l exit_hooks with
    | None -> Lwt.return_unit
    | Some f ->
      Lwt.catch
        (fun () -> f ())
        (fun _  -> Lwt.return_unit) >>= fun () ->
      call_hooks ()

  let () = at_exit ( fun () ->
      if !fatal_found then ()
      else
        try
          run (call_hooks ())
        with
        | Main_error(UWT_EBUSY,"run") -> () )
  (* The user has probably called Pervasives.exit inside a
     lwt thread. I can't do anything. *)

  let at_exit f = ignore (Lwt_sequence.add_l f exit_hooks)

end

module Valgrind = struct
  let help () =
    let len = int_of_float (2. ** 18.) in
    let t =
      Array.init len ( fun _x ->
        Random.int 1024 |> Bytes.create )
    in
    ignore t
  let lwt_cleanup () =
    let rec iter n =
      if n <= 0 then
        Lwt.return_unit
      else
        Main.yield () >>= fun () ->
        iter (pred n)
    in
    Main.run (iter 99)

  external global_cleanup:
    unit -> unit = "uwt_free_all_memory"

  let valgrind_happy () =
    Gc.compact ();
    help ();
    Gc.compact ();
    let () = Main.run (Main.call_hooks ()) in
    lwt_cleanup ();
    global_cleanup ()

end

let valgrind_happy = Valgrind.valgrind_happy

let () =
  Printexc.register_printer
    (function
    | Uwt_error (e, s, s') ->
      let msg = err_name e in
      Some (Printf.sprintf "Uwt.Uwt_error(Uwt.%s, %S, %S)" msg s s')
    | Main.Main_error(e,s) ->
      let msg = err_name e in
      Some (Printf.sprintf "Uwt.Main.Main_error(Uwt.%s, %S)" msg s)
    | Main.Deferred(l) ->
      let l =
        List.map ( fun (exn,bt) ->
            "(" ^ (Printexc.to_string exn) ^ ",\n" ^
            (Printexc.raw_backtrace_to_string bt) ^ ");")
          l
      in
      let s = "Uwt.Main.Deferred([\n" ^ String.concat "\n" l ^ "\n])" in
      Some s
    | Main.Fatal(e,bt) ->
      let s =
        "Uwt.Main.Fatal(" ^
        (Printexc.to_string e) ^ ",\n" ^
        (Printexc.raw_backtrace_to_string bt) ^ ")"
      in
      Some s
    | _ -> None)
