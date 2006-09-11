(*
 * Copyright (c) 2005 Anil Madhavapeddy <anil@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 
 * $Id: deens.ml,v 1.15 2006/04/23 12:55:43 tjd Exp $
 *)

open Unix
open Printf
open Dns
open Dns_rr

module M = Mpl_stdlib

module DL = Dnsloader
module DQ = Dnsquery
module DR = Dnsrr

let dnstrie = DL.state.DL.db.DL.trie

(* Specialise dns packet to a smaller closure *)
let dnsfn = Dns.t ~qr:`Answer ~opcode:`Query ~truncation:0 ~rd:0 ~ra:0 
    
let get_answer env (qname,qtype) id =
    let qname = List.map String.lowercase qname in  
    let ans = DQ.answer_query qname qtype dnstrie in
    let aa = if ans.DQ.aa then 1 else 0 in
    let qs = [Dns.Questions.t ~qname:qname ~qtype:qtype ~qclass:`IN] in
    let rcode = (ans.DQ.rcode :> Dns.rcode_t) in
    ignore(dnsfn ~id:id ~authoritative:aa ~rcode:rcode
        ~questions:qs ~answers:ans.DQ.answer
        ~authority:ans.DQ.authority
        ~additional:ans.DQ.additional env) 

(* utility function for non-polymorphic comparison of string lists *)
let string_list_equals a b = 
    try
        List.for_all2 (fun a b -> String.compare a b = 0) a b
    with _ -> false

(* Space leaking hash table cache, always grows *)
module Leaking_cache = Hashtbl.Make (struct
    type t = string list * Dns.Questions.qtype_t
    let equal ((a,q1):t) ((b,q2):t) = (q1 = q2) && (string_list_equals a b)
    let hash = Hashtbl.hash
end)
let cache = Leaking_cache.create 1
let memofn env s frm qargs id =
    let resp = try Leaking_cache.find cache qargs
    with Not_found -> begin
        get_answer env qargs id;
        let str = M.string_of_env env in
        Leaking_cache.add cache qargs str;
        str
    end in
    String.set resp 0 (char_of_int ((id lsr 8) land 255));
    String.set resp 1 (char_of_int (id land 255));
    ignore(s#sendto resp 0 (String.length resp) [] frm)

(* Weak cache, may be cleared out on every garbage collection as space
   is needed but does not leak space *)
module Query_res = struct
    type t = ((string list * Dns.Questions.qtype_t) * string option)
    let equal (((sl1,qt1),_):t) (((sl2,qt2),_):t) =
        (qt1 = qt2) && (string_list_equals sl1 sl2)
    let hash ((a,_):t) = Hashtbl.hash a
end     
module Cache_hash = Weak.Make(Query_res)
let weak_cache = Cache_hash.create 1
let weak_memofn env s frm qargs id =
    let resp = try
        let _,x = Cache_hash.find weak_cache (qargs,None) in
        let x = match x with
        |Some x -> x
        |None -> failwith "memo fail"
        in x
    with Not_found -> begin
        get_answer env qargs id;
        let str = M.string_of_env env in
        Cache_hash.add weak_cache (qargs, (Some str));
        str
    end in
    String.set resp 0 (char_of_int ((id lsr 8) land 255));
    String.set resp 1 (char_of_int (id land 255));
    ignore(s#sendto resp 0 (String.length resp) [] frm)
    
(* No caching, just return the evaluated result directly *)
let evalfn env s frm qargs id =
    get_answer env qargs id;
    M.env_send_fn env (fun buf off len -> ignore(s#sendto buf off len [] frm))
 
let _ =

(* GC hacks thet don't really make sense with memoization *)
(*    let c = Gc.get () in              *)
(*    c.Gc.max_overhead <- 1000001;	*)
(*    c.Gc.space_overhead <- 1000001; 	*)
(*    Gc.set c;                         *)

    let fname = ref (Some "default.zones") in
    let memo = ref `None in
    let port = ref 5353 in 
    let parse = [
        "-f", Arg.String (fun x -> fname := Some x),
        "Filename for zones";
        "-p", Arg.Int (fun x -> port := x),
        "Filename for zones";
        "-m", Arg.Unit (fun () -> memo := `Memo),
        "Memoize responses";
        "-w", Arg.Unit (fun () -> memo := `Weak),
        "Weakly memoize responses";
    ] in
    let usagestr = "Usage: deens <options>" in    
    Arg.parse parse (fun _ -> ()) usagestr;
    let fin = open_in (match !fname with |None -> failwith "Need -f"
        |Some x -> x) in
    let num_zones = ref 0 in
    try while true do
        let fl = input_line fin in
        let dom = input_line fin in 
        Dnsserver.load_zone (Str.split (Str.regexp_string ".") dom) fl;
        incr num_zones;
    done with End_of_file -> ();
    prerr_endline (sprintf "Loaded %d zones" !num_zones);
    let udp_descr = Unix.handle_unix_error Ounix.udp_listener !port in
    let senv = M.new_env (String.make 4000 '\000') in
    let env = M.new_env (String.make 4000 '\000') in
    let pid = Unix.getpid () in
    let pidf = open_out "deens.pid" in
    output_string pidf (sprintf "%d" pid);
    close_out pidf;
    let fn = match !memo with |`None -> evalfn |`Weak -> weak_memofn |`Memo -> memofn in
    let recvfn buf off len = udp_descr#recvfrom buf off len [] in
    let replyfn = fn senv udp_descr in

    Gc.compact ();
    prerr_endline "Ready";

    while true do
      try
        M.reset env;
        M.reset senv;
        M.Mpl_dns_label.init_unmarshal env;
        M.Mpl_dns_label.init_marshal senv;
        Gc.minor (); (* Poor man's region allocation *)
        let frm = M.env_recv_fn env recvfn in
        let d = Dns.unmarshal env in
        let q = d#questions.(0) in
        replyfn frm (q#qname,q#qtype) d#id;
      with e -> prerr_endline ("Error: " ^ (Printexc.to_string e)) 
    done
