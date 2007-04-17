%% ``The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved via the world wide web at http://www.erlang.org/.
%% 
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%% 
%% The Initial Developer of the Original Code is Ericsson Utvecklings AB.
%% Portions created by Ericsson are Copyright 1999, Ericsson Utvecklings
%% AB. All Rights Reserved.''
%% 
%%     $Id$
%%
-module(ts_lib).

-include_lib("kernel/include/file.hrl").
-include("ts.hrl").

-export([error/1, var/2, erlang_type/0,
	 initial_capital/1, interesting_logs/1, 
	 specs/1, suites/2, last_test/1,
	 force_write_file/2, force_delete/1,
	 subst_file/3, subst/2, print_data/1,
	 maybe_atom_to_list/1, progress/4
	]).

error(Reason) ->
    throw({error, Reason}).

%% Returns the value for a variable

var(Name, Vars) ->
    case lists:keysearch(Name, 1, Vars) of
	{value, {Name, Value}} ->
	    Value;
	false ->
	    error({bad_installation, {undefined_var, Name, Vars}})
    end.

%% Returns the level of verbosity (0-X)
verbosity(Vars) ->
    % Check for a single verbose option.
    case lists:member(verbose, Vars) of
	true ->
	    1;
	false ->
	    case lists:keysearch(verbose, 1, Vars) of
		{value, {verbose, Level}} ->
		    Level;
		_ ->
		    0
	    end
    end.

% Displays output to the console if verbosity is equal or more
% than Level.
progress(Vars, Level, Format, Args) ->
    V=verbosity(Vars),
    if
	V>=Level ->
	    io:format(Format, Args);
	true ->
	    ok
    end.

%% Returns: {Type, Version} where Type is otp|src

erlang_type() ->
    {_, Version} = init:script_id(),
    RelDir = filename:join([code:root_dir(), "releases"]), % Only in installed
    SysDir = filename:join([code:root_dir(), "system"]),   % Nonexisting link/dir outside ClearCase 
    case {filelib:is_file(RelDir),filelib:is_file(SysDir)} of
	{true,_} -> {otp,       Version};	% installed OTP
	{_,true} -> {clearcase, Version};
	_        -> {srctree,   Version}
    end.
	        
%% Upcases the first letter in a string.

initial_capital([C|Rest]) when $a =< C, C =< $z ->
    [C-$a+$A|Rest];
initial_capital(String) ->
    String.

%% Returns a list of the "interesting logs" in a directory,
%% i.e. those that correspond to spec files.

interesting_logs(Dir) ->
    Logs = filelib:wildcard(filename:join(Dir, [$*|?logdir_ext])),
    Interesting =
	case specs(Dir) of
	    [] ->
		Logs;
	    Specs0 ->
		Specs = ordsets:from_list(Specs0),
		[L || L <- Logs, ordsets:is_element(filename_to_atom(L), Specs)]
	end,
    sort_tests(Interesting).

specs(Dir) ->
    Specs = filelib:wildcard(filename:join([filename:dirname(Dir),
					    "*_test", "*.spec"])), 
    sort_tests([filename_to_atom(Name) || Name <- Specs]).

suites(Dir, Spec) ->
    Glob=filename:join([filename:dirname(Dir), Spec++"_test",
			"*_SUITE.erl"]),
    Suites=filelib:wildcard(Glob),
    [filename_to_atom(Name) || Name <- Suites].
    
filename_to_atom(Name) ->
    list_to_atom(filename:rootname(filename:basename(Name))).

%% Sorts a list of either log files directories or spec files.

sort_tests(Tests) ->
    Sorted = lists:sort([{suite_order(filename_to_atom(X)), X} || X <- Tests]),
    [X || {_, X} <- Sorted].

%% This defines the order in which tests should be run and be presented
%% in index files.

suite_order(test_server) -> 0;
suite_order(emulator) -> 2;
suite_order(kernel) -> 4;
suite_order(stdlib) -> 6;
suite_order(compiler) -> 8;
suite_order(system) -> 10;
suite_order(erl_interface) -> 12;
suite_order(ig) -> 14;
suite_order(sasl) -> 16;
suite_order(tools) -> 18;
suite_order(pman) -> 20;
suite_order(debugger) -> 22;
suite_order(toolbar) -> 23;
suite_order(ic) -> 24;
suite_order(orber) -> 26;
suite_order(inets) -> 28;
suite_order(asn1) -> 30;
suite_order(os_mon) -> 32;
suite_order(eva) -> 34;
suite_order(jive) -> 36;
suite_order(snmp) -> 38;
suite_order(mnemosyne) -> 40;
suite_order(mnesia_session) -> 42;
suite_order(mnesia) -> 44;
suite_order(_) -> 200.

last_test(Dir) ->
    last_test(filelib:wildcard(filename:join(Dir, "run.[1-2]*")), false).

last_test([Run|Rest], false) ->
    last_test(Rest, Run);
last_test([Run|Rest], Latest) when Run > Latest ->
    last_test(Rest, Run);
last_test([_|Rest], Latest) ->
    last_test(Rest, Latest);
last_test([], Latest) ->
    Latest.

%% Do the utmost to ensure that the file is written, by deleting or
%% renaming an old file with the same name.

force_write_file(Name, Contents) ->
    force_delete(Name),
    file:write_file(Name, Contents).

force_delete(Name) ->
    case file:delete(Name) of
	{error, eacces} ->
	    force_rename(Name, Name ++ ".old.", 0);
	Other ->
	    Other
    end.

force_rename(From, To, Number) ->
    Dest = [To|integer_to_list(Number)],
    case file:read_file_info(Dest) of
	{ok, _} ->
	    force_rename(From, To, Number+1);
	{error, _} ->
	    file:rename(From, Dest)
    end.

%% Substitute all occurrences of @var@ in the In file, using
%% the list of variables in Vars, producing the output file Out.
%% Returns: ok | {error, Reason}

subst_file(In, Out, Vars) ->
    case file:read_file(In) of
	{ok, Bin} ->
	    Subst = subst(binary_to_list(Bin), Vars, []),
	    case file:write_file(Out, Subst) of
		ok ->
		    ok;
		{error, Reason} ->
		    {error, {file_write, Reason}}
	    end;
	Error ->
	    Error
    end.

subst(String, Vars) ->
    subst(String, Vars, []).

subst([$@, C|Rest], Vars, Result) when $A =< C, C =< $Z ->
    subst_var([C|Rest], Vars, Result, []);
subst([$@, C|Rest], Vars, Result) when $a =< C, C =< $z ->
    subst_var([C|Rest], Vars, Result, []);
subst([C|Rest], Vars, Result) ->
    subst(Rest, Vars, [C|Result]);
subst([], _Vars, Result) ->
    lists:reverse(Result).

subst_var([$@|Rest], Vars, Result, VarAcc) ->
    Key = list_to_atom(lists:reverse(VarAcc)),
    case lists:keysearch(Key, 1, Vars) of
	{value, {Key, Value}} ->
	    subst(Rest, Vars, lists:reverse(Value, Result));
	false ->
	    subst(Rest, Vars, [$@|VarAcc++[$@|Result]])
    end;
subst_var([C|Rest], Vars, Result, VarAcc) ->
    subst_var(Rest, Vars, Result, [C|VarAcc]);
subst_var([], Vars, Result, VarAcc) ->
    subst([], Vars, [VarAcc++[$@|Result]]).

print_data(Port) ->
    receive
	{Port, {data, Bytes}} ->
	    io:put_chars(Bytes),
	    print_data(Port);
	{Port, eof} ->
	    Port ! {self(), close}, 
	    receive
		{Port, closed} ->
		    true
	    end, 
	    receive
		{'EXIT',  Port,  _} -> 
		    ok
	    after 1 ->				% force context switch
		    ok
	    end
    end.

maybe_atom_to_list(To_list) when list(To_list) ->
    To_list;
maybe_atom_to_list(To_list) when atom(To_list)->
    atom_to_list(To_list).
