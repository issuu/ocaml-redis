(* Copyright (C) 2011 Rory Geoghegan - r.geoghegan@gmail.com
   Released under the BSD license. See the LICENSE.txt file for more info.

   Utility code used mostly internally to the library. *)

type timeout = 
  | Seconds of int
  | Wait

type limit = 
  | Unlimited
  | Limit of int * int 

type aggregate = 
  | Min
  | Max
  | Sum

type redis_sort_pattern = 
  | KeyPattern of string 
  | FieldPattern of string * string 
  | NoSort 
  | NoPattern

type sort_order = 
  | Asc
  | Desc

type sort_alpha = 
  | Alpha
  | NonAlpha

exception RedisServerError of string

(* This is an internal type used to transform 
   what the Redis server can handle into ocaml types. *)

type response = 
  | Status of string 
  | Integer of int 
  | LargeInteger of int64
  | Bulk of string option
  | MultiBulk of string option list option
  | Error of string

(* Different printing functions for the above types *)

let string_of_response r =
  let bulk_printer = function
    | Some x -> Printf.sprintf "String(%S)" x
    | None   -> "Nil"
  in
  let multi_bulk_printer l = 
    String.concat "; " (List.map bulk_printer l)
  in  match r with
    | Status x           -> Printf.sprintf "Status(%S)" x 
    | Integer x          -> Printf.sprintf "Integer(%d)" x
    | LargeInteger x     -> Printf.sprintf "LargeInteger(%Ld)" x
    | Error x            -> Printf.sprintf "Error(%S)" x
    | Bulk x             -> Printf.sprintf "Bulk(%s)" (bulk_printer x)
    | MultiBulk None     -> Printf.sprintf "MultiBulk(Nil)"
    | MultiBulk (Some x) -> Printf.sprintf "MultiBulk(%s)" (multi_bulk_printer x)

(* Simple function to print out a msg to stdout, should not be used in production code. *)
let debug fmt = 
  Printf.ksprintf (fun s -> print_endline s; flush stdout) fmt

module Value = struct

  type t = 
    | Nil 
    | String 
    | List 
    | Set 
    | SortedSet

  let get = function 
    | Some x -> x
    | None   -> failwith "Value.get: unexpected None"

  let to_string = function
    | Nil       -> "Nil"
    | String    -> "String" 
    | List      -> "List" 
    | Set       -> "Set"
    | SortedSet -> "ZSet"

end
  
(* The Connection module handles some low level operations with the sockets *)
module Connection = struct
    
  type t = {
    mutable pipeline : bool;
    in_ch : in_channel;
    out_ch : out_channel;
    in_buf : Buffer.t;
    out_buf : Buffer.t;
  }

  let create addr port =
    let server = Unix.inet_addr_of_string addr in
    let in_ch, out_ch = Unix.open_connection (Unix.ADDR_INET (server, port)) in
    let pipeline = false
    and in_buf = Buffer.create 100
    and out_buf = Buffer.create 100 in
    { pipeline; in_ch; out_ch; in_buf; out_buf }
      
  (* Read arbitratry length string (hopefully quite short) from current pos in in_chan until \r\n *)
  let read_string conn = 
    let s = input_line conn.in_ch in
    let n = String.length s - 1 in
    if s.[n] = '\r' then 
      String.sub s 0 n
    else 
      s

  (* Read length caracters from in channel and output them as string *)
  let read_fixed_string conn length =
    Buffer.clear conn.in_buf;
    Buffer.add_channel conn.in_buf conn.in_ch (length + 2); (* + \r\n *)
    Buffer.sub conn.in_buf 0 length

  (* Send the given text out to the connection without flushing *)
  let send_text_straight conn text =
    output_string conn.out_ch text;
    output_string conn.out_ch "\r\n"

  (* Send the given text out to the connection *)
  let send_text conn text =
    send_text_straight conn text;
    flush conn.out_ch
      
  (* Retrieve one character from the connection *)
  let get_one_char conn = 
    input_char conn.in_ch

  (* Manually flushes out the outgoing channel *)
  let flush_connection conn =
    flush conn.out_ch

end

module Helpers = struct

  (* Gets the data from a '$x\r\nx\r\n' response, 
     once the first '$' has already been popped off *)
  let get_bulk conn = function
    |  0 -> Bulk (Some (Connection.read_fixed_string conn 0))
    | -1 -> Bulk None
    |  n -> Bulk (Some (Connection.read_fixed_string conn n))

  (* Parse list structure, with first '*' already popped off *)
  let get_multi_bulk conn size =
    match size with
      |  0 -> MultiBulk (Some [])
      | -1 -> MultiBulk None
      |  n -> 
        let acc = ref [] in
        for i = 0 to n - 1 do
          let bulk = match input_char conn.Connection.in_ch with
            | '$' -> begin
              match get_bulk conn (int_of_string (Connection.read_string conn)) with
                | Bulk x -> x
                | _      -> failwith "get_multi_bulk: bulk expected"
            end
            |  c  -> 
              failwith ("get_multi_bulk: unexpected char " ^ (Char.escaped c))
          in 
          acc := bulk :: !acc
        done;
        MultiBulk (Some (List.rev !acc))

  (* Expecting an integer response, will return the right type depending on the size *)
  let parse_integer_response response =
    try
      Integer (int_of_string response)
    with Failure "int_of_string" ->
      LargeInteger (Int64.of_string response)

  (* Filters out any errors and raises them.
     Raises RedisServerError with the error message 
     if getting an explicit error from the server ("-...")
     or a RedisServerError with "Could not decipher response" 
     for an unrecognised response type. *)
  let filter_error = function
    | Error e -> 
      raise (RedisServerError e)
    | x -> x

  (* Get answer back from redis and cast it to the right type *)
  let receive_answer connection =
    let c = Connection.get_one_char connection in
    match c with
      | '+' -> Status (Connection.read_string connection)
      | ':' -> parse_integer_response (Connection.read_string connection)
      | '$' -> get_bulk connection (int_of_string (Connection.read_string connection))
      | '*' -> get_multi_bulk connection (int_of_string (Connection.read_string connection))
      | '-' -> Error (Connection.read_string connection)
      |  c  -> failwith ("receive_answer: unexpected char " ^ (Char.escaped c))

  (* Send command, and receive the result casted to the right type,
     catch and fail on errors *)
  let send connection command =
    Connection.send_text connection command;
    let reply = receive_answer connection in
    filter_error reply

  (* Will send out the command, appended with the length of value, 
     and will then send out value. Also will catch and fail on any errors. 
     I.e., given 'foo' 'bar', will send "foo 3\r\nbar\r\n" *)
  let send_value connection command value =
    Connection.send_text_straight connection command;
    Connection.send_text connection value;
    filter_error (receive_answer connection) 

  (* Given a list of tokens, joins them with command *)
  let aggregate_command command tokens = 
    let joiner buf new_item = 
      Buffer.add_char buf ' ';
      Buffer.add_string buf new_item
    in
    match tokens with 
      | [] -> failwith "Need at least one key"
      | x ->
        let out_buffer = Buffer.create 256 in
        Buffer.add_string out_buffer command;
        List.iter (joiner out_buffer) x;
        Buffer.contents out_buffer

  (* Will send a given list of tokens to send in list
     using the unified request protocol. *)          
  let send_multi connection tokens =
    let token_length = (string_of_int (List.length tokens)) in
    let rec send_in_tokens tokens_left =
      match tokens_left with
        | [] -> ()
        | h :: t -> 
          Connection.send_text_straight connection ("$" ^ (string_of_int (String.length h)));
          Connection.send_text_straight connection h;
          send_in_tokens t
    in
    Connection.send_text_straight connection ("*" ^ token_length);
    send_in_tokens tokens;
    Connection.flush_connection connection;
    let reply = receive_answer connection in
    filter_error reply

  let fail_with_reply name reply = 
    failwith (name ^ ": Unexpected " ^ (string_of_response reply))

  (* For status replies, does error checking and display *)
  let expect_status special_status reply =
    match filter_error reply with
      | Status x when x = special_status -> ()
      | x -> fail_with_reply "expect_status" x
        
  (* The most common case of expect_status is the "OK" status *)
  let expect_success = expect_status "OK"

  (* For integer replies, does error checking and casting to boolean *)
  let expect_bool reply =
    match filter_error reply with
      | Integer 0 -> false
      | Integer 1 -> true
      | x         ->  fail_with_reply "expect_bool" x

  let expect_int = function
    | Integer x -> x
    | x         -> fail_with_reply "expect_int" x

  let expect_large_int = function
    | Integer x      -> Int64.of_int x
    | LargeInteger x -> x
    | x              -> fail_with_reply "expect_large_int" x

  let expect_rank = function
    | Integer x -> Some x
    | Bulk None -> None
    | x         -> fail_with_reply "expect_rank" x

  let expect_bulk = function
    | Bulk x -> x
    | x      -> fail_with_reply "expect_bulk" x

  let rec expect_string = function
    | Bulk (Some x) -> x
    | x             -> fail_with_reply "expect_string" x

  let expect_list = function
      | MultiBulk (Some l) as x -> 
        let f = function
          | Some x -> x
          | None   -> fail_with_reply "expect_list" x
        in
        List.map f l
      | x -> 
        fail_with_reply "expect_list" x

  let expect_multi = function
    | MultiBulk (Some l) -> l
    | x                  -> fail_with_reply "expect_multi" x

  let expect_kv_multi = function
    | MultiBulk Some [Some k; Some v] -> Some (k, v)
    | MultiBulk None                  -> None
    | x                               -> fail_with_reply "expect_kv_multi" x

  (* For list replies that should be floating point numbers, 
     does error checking and casts to float *)
  let expect_float reply =
    match filter_error reply with
      | Bulk (Some x) -> begin
        try
          float_of_string x
        with Failure "float_of_string" ->
          failwith (Printf.sprintf "%S is not a floating point number" x)
      end
      | x -> fail_with_reply "expect_float" x

  let expect_opt_float reply =
    match filter_error reply with
      | Bulk (Some x) -> begin
        try
          Some (float_of_string x)
        with Failure "float_of_string" ->
          failwith (Printf.sprintf "%S is not a floating point number" x)
      end
      | Bulk None -> None
      | x         -> fail_with_reply "expect_opt_float" x

  let rec flatten pairs result =
    match pairs with
      | (key, value) :: t -> flatten t (key :: value :: result)
      | []                -> result

  let expect_type = function
    | Status "string" -> Value.String
    | Status "set"    -> Value.Set
    | Status "zset"   -> Value.SortedSet
    | Status "list"   -> Value.List
    | Status "none"   -> Value.Nil
    | x               -> fail_with_reply "expect_type" x

end
