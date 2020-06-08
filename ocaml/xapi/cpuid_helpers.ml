(*
 * Copyright (C) 2006-2012 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

open Xapi_globs

module D=Debug.Make(struct let name="cpuid_helpers" end)
open D

let string_of_features features =
  Array.map (Printf.sprintf "%08Lx") features
  |> Array.to_list
  |> String.concat "-"

exception InvalidFeatureString of string
let features_of_string str =
  let scanf fmt s = Scanf.sscanf s fmt (fun x -> x) in
  try String.split_on_char '-' str
      |> (fun lst -> if lst = [""] then [] else lst)
      |> Array.of_list
      |> Array.map (scanf "%08Lx%!")
  with _ -> raise (InvalidFeatureString str)

(** If arr0 is shorter than arr1, extend arr0 with elements from arr1 up to the
 *  length of arr1. Otherwise, truncate arr0 to the length of arr1. *)
let extend arr0 arr1 =
  let new_arr = Array.copy arr1 in
  let len = min (Array.length arr0) (Array.length arr1) in
  Array.blit arr0 0 new_arr 0 len;
  new_arr

(** If arr is shorter than len elements, extend with zeros up to len elements.
 *  Otherwise, truncate arr to len elements. *)
let zero_extend arr len =
  let zero_arr = Array.make len 0L in
  extend arr zero_arr

let features_op2 f a b =
  let n = max (Array.length a) (Array.length b) in
  Array.map2 f (zero_extend a n) (zero_extend b n)

(** Calculate the intersection of two feature sets.
 *  Intersection with the empty set is treated as identity, so that intersection
 *  can be folded easily starting with an accumulator of [||].
 *  If both sets are non-empty and of differing lengths, and one set is longer
 *  than the other, the shorter one is zero-extended to match it.
 *  The returned set is the same length as the longer of the two arguments.  *)
let intersect left right =
  match left, right with
  | [| |], _ -> right
  | _, [| |] -> left
  | _, _ -> features_op2 Int64.logand left right

(** Calculate the features that are missing from [right],
  * but present in [left] *)
let diff left right =
  let diff64 a b = Int64.(logand a (lognot b)) in
  features_op2 diff64 left right

(** equality check that zero-extends if lengths differ *)
let is_equal left right =
  let len = max (Array.length left) (Array.length right) in
  (zero_extend left len) = (zero_extend right len)

(** is_subset left right returns true if left is a subset of right *)
let is_subset left right =
  is_equal (intersect left right) left

(** is_strict_subset left right returns true if left is a strict subset of right
    (left is a subset of right, but left and right are not equal) *)
let is_strict_subset left right =
  (is_subset left right) && (not (is_equal left right))

(** Field definitions for checked string map access *)
let features_t        = Map_check.pickler features_of_string string_of_features
let features          = Map_check.field Xapi_globs.cpu_info_features_key features_t
let features_pv       = Map_check.field Xapi_globs.cpu_info_features_pv_key features_t
let features_hvm      = Map_check.field Xapi_globs.cpu_info_features_hvm_key features_t
let features_pv_host  = Map_check.field Xapi_globs.cpu_info_features_pv_host_key features_t
let features_hvm_host = Map_check.field Xapi_globs.cpu_info_features_hvm_host_key features_t
let cpu_count    = Map_check.(field "cpu_count" int)
let socket_count = Map_check.(field "socket_count" int)
let vendor       = Map_check.(field "vendor" string)

let get_flags_for_vm ~__context vm cpu_info =
  let features_field, features_field_boot =
    match Helpers.domain_type ~__context ~self:vm with
    | `hvm | `pv_in_pvh -> features_hvm, features_hvm_host
    | `pv -> features_pv, features_pv_host
  in
  let vendor = List.assoc cpu_info_vendor_key cpu_info in
  let migration = Map_check.getf features_field cpu_info in
  let onboot = Map_check.getf ~default:migration features_field_boot cpu_info in
  (vendor, migration, onboot)

(** Upgrade a VM's feature set based on the host's one, if needed.
 *  The output will be a feature set that is the same length as the host's
 *  set, with a prefix equal to the VM's set, and extended where needed.
 *  If the current VM set has 4 words, then we assume it was last running on
 *  a host that did not support "feature levelling v2". In that case, we cannot
 *  be certain about which host features it was using, so we'll extend the set
 *  with all current host features. Otherwise we'll zero-extend. *)
let upgrade_features ~__context ~vm host_features vm_features =
  let len = Array.length vm_features in
  let upgraded_features =
    if len <= 4 then
      let open Xapi_xenops_queue in
      let dbg = Context.string_of_task __context in
      let module Client = (val make_client (default_xenopsd ()): XENOPS) in
      let uses_hvm_features =
        match Helpers.domain_type ~__context ~self:vm with
        | `hvm | `pv_in_pvh -> true
        | `pv -> false
      in
      let vm_features' = Client.HOST.upgrade_cpu_features dbg vm_features uses_hvm_features in
      extend vm_features' host_features
    else
      zero_extend vm_features (Array.length host_features)
  in
  if vm_features <> upgraded_features then begin
    debug "VM featureset upgraded from %s to %s"
      (string_of_features vm_features)
      (string_of_features upgraded_features);
  end;
  upgraded_features

let set_flags ~__context self vendor features =
  let features = features |> snd features_t in
  let value = [
    cpu_info_vendor_key, vendor;
    cpu_info_features_key, features;
  ] in
  debug "VM's CPU features set to: %s" features;
  Db.VM.set_last_boot_CPU_flags ~__context ~self ~value

(* Reset last_boot_CPU_flags with the vendor and feature set.
 * On VM.start, the feature set is inherited from the pool level (PV or HVM) *)
let reset_cpu_flags ~__context ~vm =
  let pool_vendor, _, pool_features =
    let pool = Helpers.get_pool ~__context in
    let pool_cpu_info = Db.Pool.get_cpu_info ~__context ~self:pool in
    get_flags_for_vm ~__context vm pool_cpu_info
  in
  set_flags ~__context vm pool_vendor pool_features

(* Update last_boot_CPU_flags with the vendor and feature set.
 * On VM.resume or migrate, the field is kept intact, and upgraded if needed. *)
let update_cpu_flags ~__context ~vm ~host =
  let current_features =
    let flags = Db.VM.get_last_boot_CPU_flags ~__context ~self:vm in
    Map_check.getf ~default:[||] features flags
  in
  debug "VM last boot CPU features: %s" (string_of_features current_features);
  try
    let host_vendor, host_features, _ =
      let host_cpu_info = Db.Host.get_cpu_info ~__context ~self:host in
      get_flags_for_vm ~__context vm host_cpu_info
    in
    let new_features = upgrade_features ~__context ~vm
        host_features current_features in
    if new_features <> current_features then
      set_flags ~__context vm host_vendor new_features
  with Not_found ->
    (* pre-Dundee? *)
    failwith "Host does not have new leveling feature keys"

let get_host_cpu_info ~__context ~vm ~host ?remote () =
  match remote with
  | None -> Db.Host.get_cpu_info ~__context ~self:host
  | Some (rpc, session_id) -> Client.Client.Host.get_cpu_info rpc session_id host

let get_host_compatibility_info ~__context ~vm ~host ?remote () =
  get_host_cpu_info ~__context ~vm ~host ?remote ()
  |> get_flags_for_vm ~__context vm

(* Compare the CPU on which the given VM was last booted to the CPU of the given host. *)
let assert_vm_is_compatible ~__context ~vm ~host ?remote () =
  let fail msg =
    raise (Api_errors.Server_error(Api_errors.vm_incompatible_with_this_host,
                                   [Ref.string_of vm; Ref.string_of host; msg]))
  in
  if Db.VM.get_power_state ~__context ~self:vm <> `Halted then begin
    try
      let host_cpu_vendor, host_cpu_features', _ = get_host_compatibility_info ~__context ~vm ~host ?remote () in
      let vm_cpu_info = Db.VM.get_last_boot_CPU_flags ~__context ~self:vm in
      if List.mem_assoc cpu_info_vendor_key vm_cpu_info then begin
        (* Check the VM was last booted on a CPU with the same vendor as this host's CPU. *)
        let vm_cpu_vendor = List.assoc cpu_info_vendor_key vm_cpu_info in
        debug "VM last booted on CPU of vendor %s; host CPUs are of vendor %s" vm_cpu_vendor host_cpu_vendor;
        if vm_cpu_vendor <> host_cpu_vendor then
          fail "VM last booted on a host which had a CPU from a different vendor."
      end;
      if List.mem_assoc cpu_info_features_key vm_cpu_info then begin
        (* Check the VM was last booted on a CPU whose features are a subset of the features of this host's CPU. *)
        let vm_cpu_features = Map_check.getf features vm_cpu_info in
        debug "VM last booted on CPU with features %s; host CPUs have migration features %s"
		(string_of_features vm_cpu_features) (string_of_features host_cpu_features');
        let vm_cpu_features' =
          vm_cpu_features
          |> upgrade_features ~__context ~vm host_cpu_features'
        in
        if not (is_subset vm_cpu_features' host_cpu_features') then begin
          debug "VM CPU features (%s) are not compatible with host CPU features (%s)\n" (string_of_features vm_cpu_features') (string_of_features host_cpu_features');
          debug "Host is missing these CPU features required by the VM: %s" (string_of_features (diff vm_cpu_features' host_cpu_features'));
          fail "VM last booted on a CPU with features this host's CPU does not have."
        end
      end
    with Not_found ->
      fail "Host does not have new leveling feature keys - not comparing VM's flags"
  end

