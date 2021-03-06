(* Copyright (C) 2011 Rory Geoghegan - r.geoghegan@gmail.com
   Released under the BSD license. See the LICENSE.txt file for more info.

   Tests for "Persistence control commands" *)

open Script;;

let test_save () =
    let test_func connection =
        Redis.save connection;
    in
    use_test_script
        [
            ReadThisLine("SAVE");
            WriteThisLine("+OK");
        ]
        test_func;;

let test_bgsave () =
    let test_func connection =
        Redis.bgsave connection;
    in
    use_test_script
        [
            ReadThisLine("BGSAVE");
            WriteThisLine("+Background saving started");
        ]
        test_func;;

let test_lastsave () =
    let test_func connection =
        assert ( 42.0 = Redis.lastsave connection )
    in
    use_test_script
        [
            ReadThisLine("LASTSAVE");
            WriteThisLine(":42");
        ]
        test_func;;

let test_shutdown () =
    let function_read, tester_write = Script.piped_channel ()
    in
    let tester_read, function_write = Script.piped_channel ()
    in
    begin
        close_out tester_write;
        Redis.shutdown (function_read, function_write);
        assert ("SHUTDOWN\r" = input_line tester_read)
    end;;

let test_bgrewriteaof () =
    let test_func connection =
        assert ( () = Redis.bgrewriteaof connection )
    in
    use_test_script
        [
            ReadThisLine("BGREWRITEAOF");
            WriteThisLine("+Background append only file rewriting started")
        ]
        test_func;;
