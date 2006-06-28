(*
 * Copyright (c) 2006 David Scott <dave@recoil.org>
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
 
 * $Id:$
 *)

(** Utility functions to handle multicast DNS and Bonjour *)

let ip = "224.0.0.251"
let port = 5353
let addr = Unix.ADDR_INET (Unix.inet_addr_of_string ip, port)

(** Return a socket connected to the mDNS multicast group *)
let connect () = 
  (* Bind a local socket (any port) *)
  let s = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.handle_unix_error (Unix.bind s) (Unix.ADDR_INET (Unix.inet_addr_any, 0));
  (* Join the socket to the multicast group *)
  Ounix.set_ip_multicast_ttl s 1;
  Ounix.set_ip_multicast_loop s 1;
  Ounix.join_multicast_group s addr;
  s

(** Query which returns all services on the network *)
let all_services = "_services._dns-sd._udp.local"
