open Lwt.Infix

open Show_uwt

type h = {
  ai : addr_info;
  ni : name_info;
} [@@deriving show]

let getaddrinfo ~ip6 host =
  let opts = [ Unix.AI_FAMILY (if ip6 then Unix.PF_INET6 else Unix.PF_INET);
               Unix.AI_SOCKTYPE Unix.SOCK_DGRAM  ] in
  Uwt.Dns.getaddrinfo ~host ~service:"" opts

let get_infos (hosts:string list) =
  let s = ref [] in
  let help ip6 host =
    Lwt.catch ( fun () ->
        getaddrinfo ~ip6 host >>= fun l ->
        Lwt_list.map_p ( fun ai ->
            Uwt.Dns.getnameinfo ai.ai_addr [] >>= fun ni ->
            Lwt.return ({ ai ; ni }) ) l
        >>= fun l ->
        s := (host,l) :: ! s;
        Lwt.return_unit )
      (function (* not all domains have ip6 entries. error codes differs
                   from operating system to operating system, ... *)
      | Uwt.Uwt_error((Uwt.EAI_NONAME|Uwt.ENOENT|Uwt.EAI_NODATA),_,_)
        when ip6 = true ->
        Lwt.return_unit
      | x -> Lwt.fail x )
  in
  Lwt_list.iter_p ( fun s -> Lwt.join [ help true s ; help false s ] ) hosts
  >>= fun () -> Lwt.return (List.rev !s)

let () =
  let t =
    get_infos [ "google.de" ; "ocaml.org" ; "caml.inria.fr" ;
                "theguardian.com" ; "camlcity.org" ] >>= fun l ->
    Lwt_list.iter_s ( fun (s,l) ->
        Uwt_io.printl s >>= fun () ->
        Lwt_list.iter_s ( fun l ->
            show_h l |> Uwt_io.printl
          ) l
      ) l
  in
  Uwt.Main.run t

let () = Uwt.valgrind_happy ()
