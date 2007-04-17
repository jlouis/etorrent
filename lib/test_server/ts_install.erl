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

-module(ts_install).


-export([install/2, platform_id/1]).

-include("ts.hrl").

install(install_local, Options) ->
    install(os:type(), Options);

install(TargetSystem, Options) ->
    io:format("Running configure for cross architecture, network target name~n"
	      "~p~n", [TargetSystem]),
    case autoconf(TargetSystem) of
	{ok, Vars0} ->
	    OsType = os_type(TargetSystem),
	    Vars1 = ts_erl_config:variables(merge(Vars0,Options),OsType),
	    {Options1, Vars2} = add_vars(Vars1, Options),
	    Vars3 = lists:flatten([Options1|Vars2]),
	    write_terms(?variables, Vars3);
	{error, Reason} ->
	    {error, Reason}
    end.

os_type({unix,_}=OsType) -> OsType;
os_type({win32,_}=OsType) -> OsType;
os_type({"ose",_}) -> ose;
os_type(_Other) -> vxworks.

merge(Vars,[]) ->
    Vars;
merge(Vars,[{crossroot,X}| Tail]) ->
    merge([{crossroot, X} | Vars], Tail);
merge(Vars,[_X | Tail]) ->
    merge(Vars,Tail).

%% Autoconf for various platforms.
%% unix uses the configure script
%% win32 uses ts_autoconf_win32
%% VxWorks uses ts_autoconf_vxworks.

autoconf(TargetSystem) ->
    case autoconf1(TargetSystem) of
	ok ->
	    autoconf2(file:read_file("conf_vars"));
	Error ->
	    Error
    end.

autoconf1({win32, _}) ->
    ts_autoconf_win32:configure();
autoconf1({unix, _}) ->
    unix_autoconf();
autoconf1({"ose",_}=TargetSystem) ->
    ts_autoconf_ose:configure(TargetSystem);
autoconf1(Other) ->
    ts_autoconf_vxworks:configure(Other).

autoconf2({ok, Bin}) ->
    get_vars(binary_to_list(Bin), name, [], []);
autoconf2(Error) ->
    Error.

get_vars([$:|Rest], name, Current, Result) ->
    Name = list_to_atom(lists:reverse(Current)),
    get_vars(Rest, value, [], [Name|Result]);
get_vars([$\r|Rest], value, Current, Result) ->
    get_vars(Rest, value, Current, Result);
get_vars([$\n|Rest], value, Current, [Name|Result]) ->
    Value = lists:reverse(Current),
    get_vars(Rest, name, [], [{Name, Value}|Result]);
get_vars([C|Rest], State, Current, Result) ->
    get_vars(Rest, State, [C|Current], Result);
get_vars([$ |Rest], name, [], Result) ->
    get_vars(Rest, name, [], Result);
get_vars([$\t|Rest], name, [], Result) ->
    get_vars(Rest, name, [], Result);
get_vars([$\n|Rest], name, [], Result) ->
    get_vars(Rest, name, [], Result);
get_vars([], name, [], Result) ->
    {ok, Result};
get_vars(_, _, _, _) ->
    {error, fatal_bad_conf_vars}.

unix_autoconf() ->
    Configure = filename:absname("configure"),
    Args = case catch erlang:system_info(threads) of
	       false -> "";
	       _ -> " --enable-shlib-thread-safety"
	   end,
    case filelib:is_file(Configure) of
	true ->
	    Port = open_port({spawn, Configure ++ Args}, [stream, eof]),
	    ts_lib:print_data(Port);
	false ->
	    {error, no_configure_script}
    end.

write_terms(Name, Terms) ->
    case file:open(Name, [write]) of
	{ok, Fd} ->
	    Result = write_terms1(Fd, Terms),
	    file:close(Fd),
	    Result;
	{error, Reason} ->
	    {error, Reason}
    end.

write_terms1(Fd, [Term|Rest]) ->
    ok = io:format(Fd, "~p.\n", [Term]),
    write_terms1(Fd, Rest);
write_terms1(_, []) ->
    ok.

add_vars(Vars0, Opts0) ->
    {Opts,LongNames} =
	case lists:keymember(longnames, 1, Opts0) of
	    true ->
		{lists:keydelete(longnames, 1, Opts0),true};
	    false ->
		{Opts0,false}
	end,
    {PlatformId, PlatformLabel, PlatformFilename, Version} =
	platform([{longnames, LongNames}|Vars0]),
    {Opts, [{longnames, LongNames},
	    {platform_id, PlatformId},
	    {platform_filename, PlatformFilename},
	    {rsh_name, get_rsh_name()},
	    {platform_label, PlatformLabel},
	    {erl_flags, []},
	    {erl_release, Version}|Vars0]}.

get_rsh_name() ->
    case os:getenv("ERL_RSH") of
	false ->
	    case ts_lib:erlang_type() of
		{clearcase, _} ->
		    "ctrsh";
		{_, _} ->
		    "rsh"
	    end;
	Str ->
	    Str
    end.

platform_id(Vars) ->
    {Id, _, _, _} = platform(Vars),
    Id.
    
platform(Vars) ->
    {Type, Version} = ts_lib:erlang_type(),
    Cpu = ts_lib:var('CPU', Vars),
    Os = ts_lib:var(os, Vars),

    ErlType = to_upper(atom_to_list(Type)),
    OsType = ts_lib:initial_capital(Os),
    CpuType = ts_lib:initial_capital(Cpu),
    SrcLabel = case ts_lib:var(is_source_build, Vars) of
		   true -> "/Src";
		   false -> []
	       end,
    ExtraLabel = extra_platform_label(),
    Common = lists:concat(["/", OsType, "/", CpuType, SrcLabel, ExtraLabel]),
    PlatformId = lists:concat([ErlType, " ", Version, Common]),
    PlatformLabel = ErlType ++ Common,
    PlatformFilename = platform_as_filename(PlatformId),
    {PlatformId, PlatformLabel, PlatformFilename, Version}.

platform_as_filename(Label) ->
    lists:map(fun($ ) -> $_;
		 ($/) -> $_;
		 (C) when $A =< C, C =< $Z -> C - $A + $a;
		 (C) -> C end,
	      Label).

to_upper(String) ->
    lists:map(fun(C) when $a =< C, C =< $z -> C - $a + $A;
		 (C) -> C end,
	      String).

extra_platform_label() ->
    case os:getenv("TS_EXTRA_PLATFORM_LABEL") of
	"" ->
	    "";
	Label when list(Label) ->
	    "/" ++ Label;
	false -> ""
    end.
    
