#!/usr/bin/env ruby
require "erb"

MODULE_NAMER = /([^\/]*)\.ml$/
tests = {}
ARGV.each do |filename|
    module_name = MODULE_NAMER.match(filename)[1].capitalize
    File.new(filename, "r").each_line do |line|
        if line =~ /^let (test_\S+) \(\) =/
        then
            if not tests.key? module_name then
                tests[module_name] = []
            end
            tests[module_name] << $1
        end
    end
end

template_text = %q{
let execute_test test_name test_func =
    begin
        print_string ("    " ^ test_name ^ "... ");
        test_func ();
        print_endline "passed"
    end;;

let main () =
    begin
        print_newline ();
% tests.each_pair do |mod_name, test_names|
        print_endline "In module <%=mod_name%>:";
% test_names.each do |name|
            execute_test "<%=name%>" <%=mod_name%>.<%=name%>;
% end
% end
        print_newline ();
        print_endline "All Done!";
    end;;

let _ = main();;
}
template = ERB.new(template_text, 0, "%")
puts template.result