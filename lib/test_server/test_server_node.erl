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
-module(test_server_node).

%% Test Controller interface
-export([start_remote_main_target/1,stop/1]).
-export([start_tracer_node/2,trace_nodes/2,stop_tracer_node/1]).
-export([start_node/5, stop_node/2]).
-export([kill_nodes/1, nodedown/2]).
%% Internal export
-export([node_started/1,trc/1,handle_debug/4]).

-include("test_server_internal.hrl").
-record(slave_info, {name,socket,client}).
-define(VXWORKS_ACCEPT_TIMEOUT,?ACCEPT_TIMEOUT).
-define(OSE_ACCEPT_TIMEOUT,(6*?ACCEPT_TIMEOUT)).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%                                                                  %%%
%%% All code in this module executes on the test_server_ctrl process %%%
%%% except for node_started/1 and trc/1 which execute on a new node. %%%
%%%                                                                  %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Start main target node on remote host
%%% The target node must not know the controller node via erlang distribution.
start_remote_main_target(Parameters) ->
    #par{type=TargetType,
	 target=TargetHost,
	 naming=Naming,
	 master=MasterNode,
	 cookie=MasterCookie,
	 slave_targets=SlaveTargets} = Parameters,

    lists:foreach(fun(T) -> maybe_reboot_target({TargetType,T}) end,
		  [list_to_atom(TargetHost)|SlaveTargets]),

    % Must give the targets a chance to reboot...
    case TargetType of
	vxworks ->
	    receive after 15000 -> ok end;
	_ ->
	    ok
    end,

    Cmd0 = get_main_target_start_command(TargetType,TargetHost,Naming,
					 MasterNode,MasterCookie),
    Cmd = 
	case os:getenv("TEST_SERVER_FRAMEWORK") of
	    false -> Cmd0;
	    FW -> Cmd0 ++ " -env TEST_SERVER_FRAMEWORK " ++ FW
	end,
	
    {ok,LSock} = gen_tcp:listen(?MAIN_PORT,[binary,{reuseaddr,true},{packet,2}]),
    case start_target(TargetType,TargetHost,Cmd) of
	{ok,TargetClient,AcceptTimeout} ->
	    case gen_tcp:accept(LSock,AcceptTimeout) of
		{ok,Sock} -> 
		    receive 
			{tcp,Sock,<<1,Result/binary>>} ->
			    put(test_server_free_targets,SlaveTargets),
			    {target_info,TI} = binary_to_term(Result),
			    {ok, TI#target_info{where=Sock,
						host=TargetHost,
						naming=Naming,
						master=MasterNode,
						target_client=TargetClient,
						slave_targets=SlaveTargets}};
			{tcp_closed,Sock} ->
			    gen_tcp:close(Sock),
			    close_target_client(TargetClient),
			    {error,could_not_contact_target}
		    after AcceptTimeout ->
			    gen_tcp:close(Sock),
			    close_target_client(TargetClient),
			    {error,timeout}
		    end;
		Error -> 
		    %%! maybe something like kill_target(...)???
		    gen_tcp:close(LSock),
		    close_target_client(TargetClient),
		    {error,{could_not_contact_target,Error}}
	    end;
	Error ->
	    gen_tcp:close(LSock),
	    {error,{could_not_start_target,Error}}
    end.

stop(TI) ->
    kill_nodes(TI),
    case TI#target_info.where of
	local -> % there is no remote target to stop
	    ok;
	Sock ->  % stop remote target
	    gen_tcp:close(Sock),
	    close_target_client(TI#target_info.target_client)	    
    end.

nodedown(Sock, TI) ->
    Match = #slave_info{name='$1',socket=Sock,client='$2',_='_'},
    case ets:match(slave_tab,Match) of
	[[Node,Client]] -> % Slave node died
	    gen_tcp:close(Sock),
	    ets:delete(slave_tab,Node),
	    close_target_client(Client),
	    HostAtom = test_server_sup:hostatom(Node),
	    case lists:member(HostAtom,TI#target_info.slave_targets) of
		true -> 
		    put(test_server_free_targets,
			get(test_server_free_targets) ++ [HostAtom]);
		false -> ok
	    end,
	    slave_died;
	[] -> 
	    case TI#target_info.where of
		Sock ->
		    %% test_server_ctrl will do the cleanup
		    target_died;
		_ -> 
		    ignore
	    end
    end.





%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Start trace node
%%%
start_tracer_node(TraceFile,TI) ->
    Match = #slave_info{name='$1',_='_'},
    SlaveNodes = lists:map(fun([N]) -> [" ",N] end,
			   ets:match(slave_tab,Match)),
    TargetNode = case TI#target_info.where of
		     local -> node();
		     _ -> "test_server@" ++ TI#target_info.host
		 end,
    Cookie = TI#target_info.cookie,
    {ok,LSock} = gen_tcp:listen(0,[binary,{reuseaddr,true},{packet,1}]),
    {ok,TracePort} = inet:port(LSock),
    Prog = pick_erl_program(default),
    Cmd = lists:concat([Prog, " -sname tracer -hidden -setcookie ", Cookie, 
			" -s ", ?MODULE, " trc ", TraceFile, " ", 
			TracePort, " ", TI#target_info.os_family]),
    spawn(fun() -> ts_lib:print_data(open_port({spawn,Cmd},[stream])) end),
%!    open_port({spawn,Cmd},[stream]),
    case gen_tcp:accept(LSock,?ACCEPT_TIMEOUT) of
	{ok,Sock} -> 
	    receive 
		{tcp,Sock,<<1,Result/binary>>} ->
		    case binary_to_term(Result)of
			started -> 
			    trace_nodes(Sock,[TargetNode | SlaveNodes]),
			    {ok,Sock};
			Error -> Error
		    end;
		{tcp_closed,Sock} ->
		    gen_tcp:close(Sock),
		    {error,could_not_start_tracernode}
	    after ?ACCEPT_TIMEOUT ->
		    gen_tcp:close(Sock),
		    {error,timeout}
	    end;
	Error -> 
	    gen_tcp:close(LSock),
	    {error,{could_not_start_tracernode,Error}}
    end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Start a tracer on each of these nodes and set flags and patterns
%%%
trace_nodes(Sock,Nodes) ->
    Bin = term_to_binary({add_nodes,Nodes}),
    ok = gen_tcp:send(Sock,<<1,Bin/binary>>),
    receive {tcp,Sock,<<1,_Result/binary>>} -> ok end.
    

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Stop trace node
%%%
stop_tracer_node(Sock) ->
    Bin = term_to_binary(stop),
    ok = gen_tcp:send(Sock,<<1,Bin/binary>>),
    receive {tcp_closed,Sock} -> gen_tcp:close(Sock) end,
    ok.
    



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% trc([TraceFile,Nodes]) -> ok
%%
%% Start tracing on the given nodes
%%
%% This function executes on the new node
%%
trc([TraceFile, PortAtom, Type]) ->
    {Result,Patterns,Fd} = 
	case file:consult(TraceFile) of
	    {ok,TI} ->
		Pat = parse_trace_info(lists:flatten(TI)),
		Fd0 = 
		    case Type of
			ose -> 
			    {ok,F} = file:open("allnodes-test_server",[write]),
			    dbg:tracer(process,{fun handle_debug/2,
						{F,initial}}),
			    F;
			_ -> 
			    undefined
		    end,
		{started,Pat,Fd0};
	    Error ->
		{Error,[],undefined}
	end,
    Port = list_to_integer(atom_to_list(PortAtom)),
    case catch gen_tcp:connect("localhost", Port, [binary, 
						   {reuseaddr,true}, 
						   {packet,1}]) of
	{ok,Sock} -> 
	    BinResult = term_to_binary(Result),
	    ok = gen_tcp:send(Sock,<<1,BinResult/binary>>),
	    trc_loop(Sock,Patterns,Type);
	_else ->
	    ok
    end,
    case Fd of
	undefined -> ok;
	_ -> file:close(Fd)
    end,
    erlang:halt().
trc_loop(Sock,Patterns,Type) ->
    receive
	{tcp,Sock,<<1,Request/binary>>} ->
	    case binary_to_term(Request) of
		{add_nodes,Nodes} -> 
		    add_nodes(Nodes,Patterns,Type),
		    Bin = term_to_binary(ok),
		    ok = gen_tcp:send(Sock,<<1,Bin/binary>>),
		    trc_loop(Sock,Patterns,Type);
		stop -> 
		    case Type of
			ose -> dbg:stop_clear();
			_ -> ttb:stop()
		    end,
		    gen_tcp:close(Sock)
	    end;
	{tcp_closed,Sock} ->
	    case Type of
		ose -> dbg:stop_clear();
		_ -> ttb:stop()
	    end,
	    gen_tcp:close(Sock)
    end.
add_nodes(Nodes,Patterns,Type) ->
    case Type of
	ose -> 
	    lists:foreach(fun(N) -> dbg:n(N) end, Nodes),
	    dbg:p(all,[call,timestamp]),
	    lists:foreach(fun({TP,M,F,A,Pat}) -> dbg:TP(M,F,A,Pat) end,Patterns);
	_ -> 
	    ttb:tracer(Nodes,[{file,{local, test_server}},
			     {handler, {{?MODULE,handle_debug},initial}}]),
	    ttb:p(all,[call,timestamp]),
	    lists:foreach(fun({TP,M,F,A,Pat}) -> ttb:TP(M,F,A,Pat);
			     ({CTP,M,F,A}) -> ttb:CTP(M,F,A) 
			  end,
			  Patterns)
    end.

parse_trace_info([{TP,M,Pat}|Pats]) when TP=:=tp; TP=:=tpl ->
    [{TP,M,'_','_',Pat}|parse_trace_info(Pats)];
parse_trace_info([{TP,M,F,Pat}|Pats]) when TP=:=tp; TP=:=tpl ->
    [{TP,M,F,'_',Pat}|parse_trace_info(Pats)];
parse_trace_info([{TP,M,F,A,Pat}|Pats]) when TP=:=tp; TP=:=tpl ->
    [{TP,M,F,A,Pat}|parse_trace_info(Pats)];
parse_trace_info([CTP|Pats]) when CTP=:=ctp; CTP=:=ctpl; CTP=:=ctpg ->
    [{CTP,'_','_','_'}|parse_trace_info(Pats)];
parse_trace_info([{CTP,M}|Pats]) when CTP=:=ctp; CTP=:=ctpl; CTP=:=ctpg ->
    [{CTP,M,'_','_'}|parse_trace_info(Pats)];
parse_trace_info([{CTP,M,F}|Pats]) when CTP=:=ctp; CTP=:=ctpl; CTP=:=ctpg ->
    [{CTP,M,F,'_'}|parse_trace_info(Pats)];
parse_trace_info([{CTP,M,F,A}|Pats]) when CTP=:=ctp; CTP=:=ctpl; CTP=:=ctpg ->
    [{CTP,M,F,A}|parse_trace_info(Pats)];
parse_trace_info([]) ->
    [];
parse_trace_info([_other|Pats]) -> % ignore
    parse_trace_info(Pats).


handle_debug(Trace,{Out,State}) ->
    State1=handle_debug(Out,Trace,ti,State),
    {Out,State1}.
handle_debug(Out,Trace,TI,initial) ->
    handle_debug(Out,Trace,TI,0);
handle_debug(_Out,end_of_trace,_TI,N) ->
    N;
handle_debug(Out,Trace,_TI,N) ->
    print_trc(Out,Trace,N),
    N+1.

print_trc(Out,{trace_ts,P,call,{M,F,A},C,Ts},N) ->
    io:format(Out,
	      "~w: ~s~n"
	      "Process   : ~w~n"
	      "Call      : ~w:~w/~w~n"
	      "Arguments : ~p~n"
	      "Caller    : ~w~n~n",
	      [N,ts(Ts),P,M,F,length(A),A,C]);
print_trc(Out,{trace_ts,P,call,{M,F,A},Ts},N) ->
    io:format(Out,
	      "~w: ~s~n"
	      "Process   : ~w~n"
	      "Call      : ~w:~w/~w~n"
	      "Arguments : ~p~n~n",
	      [N,ts(Ts),P,M,F,length(A),A]);
print_trc(Out,{trace_ts,P,return_from,{M,F,A},R,Ts},N) ->
    io:format(Out,
	      "~w: ~s~n"
	      "Process      : ~w~n"
	      "Return from  : ~w:~w/~w~n"
	      "Return value : ~p~n~n",
	      [N,ts(Ts),P,M,F,A,R]);
print_trc(Out,{drop,X},N) ->
    io:format(Out,
	      "~w: Tracer dropped ~w messages - too busy~n~n",
	      [N,X]);
print_trc(Out,Trace,N) ->
    Ts = element(size(Trace),Trace),
    io:format(Out,
	      "~w: ~s~n"
	      "Trace        : ~p~n~n",
	      [N,ts(Ts),Trace]).
ts({_, _, Micro} = Now) ->
    {{Y,M,D},{H,Min,S}} = calendar:now_to_local_time(Now),
    io_lib:format("~4.4.0w-~2.2.0w-~2.2.0w ~2.2.0w:~2.2.0w:~2.2.0w,~6.6.0w",
		  [Y,M,D,H,Min,S,Micro]).




%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Start slave/peer nodes (initiated by test_server:start_node/5)
%%%
start_node(SlaveName, slave, Options, From, TI) when list(SlaveName) ->
    start_node_slave(list_to_atom(SlaveName), Options, From, TI);
start_node(SlaveName, slave, Options, From, TI) ->
    start_node_slave(SlaveName, Options, From, TI);
start_node(SlaveName, peer, Options, From, TI) when atom(SlaveName) ->
    start_node_peer(atom_to_list(SlaveName), Options, From, TI);
start_node(SlaveName, peer, Options, From, TI) ->
    start_node_peer(SlaveName, Options, From, TI);
start_node(_SlaveName, _Type, _Options, _From, _TI) ->
    not_implemented_yet.

%%
%% Peer nodes are always started on the same host as test_server_ctrl
%% Socket communication is used in case target and controller is
%% not the same node (target must not know the controller node
%% via erlang distribution)
%%
start_node_peer(SlaveName, OptList, From, TI) ->
    SuppliedArgs = start_node_get_option_value(args, OptList, []),
    Cleanup = start_node_get_option_value(cleanup, OptList, true),
    HostStr = test_server_sup:hoststr(),
    {ok,LSock} = gen_tcp:listen(0,[binary,
				   {reuseaddr,true},
				   {packet,1}]),
    {ok,WaitPort} = inet:port(LSock),
    NodeStarted = lists:concat([" -s ", ?MODULE, " node_started ",
				      HostStr, " ", WaitPort]),

    % Support for erl_crash_dump files..
    CrashFile = filename:join([TI#target_info.test_server_dir,
			       "erl_crash_dump."++cast_to_list(SlaveName)]),
    CrashArgs = lists:concat([" -env ERL_CRASH_DUMP ",CrashFile," "]),
    FailOnError = start_node_get_option_value(fail_on_error, OptList, true),
    Pa = TI#target_info.test_server_dir,
    Prog0 = start_node_get_option_value(erl, OptList, default),
    Prog = pick_erl_program(Prog0),
    Args = 
	case string:str(SuppliedArgs,"-setcookie") of
	    0 -> "-setcookie " ++ TI#target_info.cookie ++ " " ++ SuppliedArgs;
	    _ -> SuppliedArgs
	end,
    Cmd = lists:concat([Prog,
			" -detached ",
			TI#target_info.naming, " ", SlaveName,
			" -pa ", Pa,
			NodeStarted,
			CrashArgs,
			" ", Args]),
    open_port({spawn, Cmd}, [stream]), % peer is always started on localhost
    
    case start_node_get_option_value(wait, OptList, true) of
	true ->
	    Ret = wait_for_node_started(LSock,60000,undefined,Cleanup,TI,self()),
	    case {Ret,FailOnError} of
		{{{ok, Node}, Warning},_} ->
		    gen_server:reply(From,{{ok,Node},HostStr,Cmd,[],Warning});
		{_,false} ->
		    gen_server:reply(From,{Ret, HostStr, Cmd});
		{_,true} ->
		    gen_server:reply(From,{fail,{Ret, HostStr, Cmd}})
	    end;
	false ->
	    Nodename = list_to_atom(SlaveName ++ "@" ++ HostStr),
	    I = "=== Not waiting for node",
	    gen_server:reply(From,{{ok, Nodename}, HostStr, Cmd, I, []}),
	    Self = self(),
	    spawn_link(
	      fun() -> 
		      wait_for_node_started(LSock,60000,undefined,
					    Cleanup,TI,Self),
		      receive after infinity -> ok end
	      end),
	    ok
    end.

%%
%% Slave nodes are started on a remote host if
%% - the option remote is given when calling test_server:start_node/3
%% or
%% - the target type is ose or vxworks, because only one erlang node
%%   can be started on each ose or vxworks host.
%%
start_node_slave(SlaveName, OptList, From, TI) ->
    SuppliedArgs = start_node_get_option_value(args, OptList, []),
    Cleanup = start_node_get_option_value(cleanup, OptList, true),

    CrashFile = filename:join([TI#target_info.test_server_dir,
			       "erl_crash_dump."++cast_to_list(SlaveName)]),
    CrashArgs = lists:concat([" -env ERL_CRASH_DUMP ",CrashFile," "]),
    Pa = TI#target_info.test_server_dir,
    Args = lists:concat([" -pa ", Pa, " ", SuppliedArgs, CrashArgs]),

    Prog0 = start_node_get_option_value(erl, OptList, default),
    Prog = pick_erl_program(Prog0),
    Ret = 
	case start_which_node(OptList) of
	    {error,Reason} -> {{error,Reason},undefined,undefined};
	    Host0 -> do_start_node_slave(Host0,SlaveName,Args,Prog,Cleanup,TI)
	end,
    gen_server:reply(From,Ret).


do_start_node_slave(Host0, SlaveName, Args, Prog, Cleanup, TI) ->
    case TI#target_info.where of
	local ->
	    Host = 
		case Host0 of
		    local -> test_server_sup:hoststr();
		    _ -> cast_to_list(Host0)
		end,
	    Cmd = Prog ++ " " ++ Args,
	    %% Can use slave.erl here because I'm both controller and target
	    %% so I will ping the new node anyway
	    case slave:start(Host, SlaveName, Args, no_link, Prog) of
		{ok,Nodename} -> 
		    case Cleanup of
			true -> ets:insert(slave_tab,#slave_info{name=Nodename});
			false -> ok
		    end,
		    {{ok,Nodename}, Host, Cmd, [], []};
		Ret -> 
		    {Ret, Host, Cmd}
	    end;
    
	_Sock ->
	    %% Cannot use slave.erl here because I'm only controller, and will
	    %% not ping the new node. Only target shall contact the new node!!
	    no_contact_start_slave(Host0,SlaveName,Args,Prog,Cleanup,TI)
    end.



no_contact_start_slave(Host, Name, Args0, Prog, Cleanup,TI) ->
    Args1 = case string:str(Args0,"-setcookie") of
		0 -> "-setcookie " ++ TI#target_info.cookie ++ " " ++ Args0;
		_ -> Args0
	    end,
    Args = TI#target_info.naming ++ " " ++ cast_to_list(Name) ++ " " ++ Args1,
    case Host of
	local ->
	    case get(test_server_free_targets) of
		[] ->
		    io:format("Starting slave ~p on HOST~n", [Name]),
		    TargetType = test_server_sup:get_os_family(),
		    Cmd0 = get_slave_node_start_command(TargetType,
							Prog,
							TI#target_info.master),
		    Cmd = Cmd0 ++ " " ++ Args,
		    do_no_contact_start_slave(TargetType,
					      test_server_sup:hoststr(),
					      Cmd, Cleanup,TI, false);
		[H|T] ->
		    TargetType = TI#target_info.os_family,
		    Cmd0 = get_slave_node_start_command(TargetType,
							Prog,
							TI#target_info.master),
		    Cmd = Cmd0 ++ " " ++ Args,
		    case do_no_contact_start_slave(TargetType,H,Cmd,Cleanup,
						   TI,true) of
			{error,remove} ->
			    io:format("Cannot start node on ~p, "
				      "removing from slave "
				      "target list.", [H]),
			    put(test_server_free_targets,T),
			    no_contact_start_slave(Host,Name,Args,Prog,
						   Cleanup,TI);
			{error,keep} ->
			    %% H is added to the END OF THE LIST 
			    %% in order to avoid the same target to
			    %% be selected each time
			    put(test_server_free_targets,T++[H]),
			    no_contact_start_slave(Host,Name,Args,Prog,
						   Cleanup,TI);
			R ->
			    put(test_server_free_targets,T),
			    R
		    end
	    end;
	_ -> 
	    TargetType = TI#target_info.os_family,
	    Cmd0 = get_slave_node_start_command(TargetType,
						Prog,
						TI#target_info.master),
	    Cmd = Cmd0 ++ " " ++ Args,
	    do_no_contact_start_slave(TargetType, Host, Cmd, Cleanup, TI, false)
    end.

do_no_contact_start_slave(TargetType,Host0,Cmd0,Cleanup,TI,Retry) ->
    %% Must use TargetType instead of TI#target_info.os_familiy here 
    %% because if there were no free_targets we will be starting the 
    %% slave node on host which might have a different os_familiy
    Host = cast_to_list(Host0),
    {ok,LSock} = gen_tcp:listen(0,[binary,
				    {reuseaddr,true},
				    {packet,1}]),
    {ok,WaitPort} = inet:port(LSock),
    Cmd = lists:concat([Cmd0, " -s ", ?MODULE, " node_started ", 
			test_server_sup:hoststr(), " ", WaitPort]),

    case start_target(TargetType,Host,Cmd) of
	{ok,Client,AcceptTimeout} ->
	    case wait_for_node_started(LSock,AcceptTimeout,
				       Client,Cleanup,TI,self()) of
		{error,_}=WaitError -> 
		    if Retry ->
			    case maybe_reboot_target(Client) of
				{error,_} -> {error,remove};
				ok -> {error,keep}
			    end;
		       true ->
			    {WaitError,Host,Cmd}
		    end;
		{Ok,Warning} -> 
		    {Ok,Host,Cmd,[],Warning}
	    end;
	StartError ->
	    gen_tcp:close(LSock),
	    if Retry -> {error,remove};
	       true -> {{error,{could_not_start_target,StartError}},Host,Cmd}
	    end
    end.


wait_for_node_started(LSock,Timeout,Client,Cleanup,TI,CtrlPid) ->
    case gen_tcp:accept(LSock,Timeout) of
	{ok,Sock} -> 
	    receive 
		{tcp,Sock,<<1,Started0/binary>>} ->
		    Started = binary_to_term(Started0),
		    Version = TI#target_info.otp_release,
		    VsnStr = TI#target_info.system_version,
		    {ok,Nodename, W} = 
			handle_start_node_return(Version,
						 VsnStr,
						 Started),
		    case Cleanup of
			true ->
			    ets:insert(slave_tab,#slave_info{name=Nodename,
							     socket=Sock,
							     client=Client});
			false -> ok
		    end,
		    gen_tcp:controlling_process(Sock,CtrlPid),
		    test_server_ctrl:node_started(Nodename),
		    {{ok,Nodename},W};
		{tcp_closed,Sock} ->
		    gen_tcp:close(Sock),
		    {error, connection_closed}
	    after Timeout ->
		    gen_tcp:close(Sock),
		    {error, timeout}
	    end;
	{error,Reason} -> 
	    gen_tcp:close(LSock),
	    {error, {no_connection,Reason}}
    end.



handle_start_node_return(Version,VsnStr,{started, Node, Version, VsnStr}) ->
    {ok, Node, []};
handle_start_node_return(Version,VsnStr,{started, Node, OVersion, OVsnStr}) ->
    Str = io_lib:format("WARNING: Started node "
			"reports different system "
			"version than current node! "
			"Current node version: ~p, ~p "
			"Started node version: ~p, ~p",
			[Version, VsnStr, 
			 OVersion, OVsnStr]),
    Str1 = lists:flatten(Str),
    {ok, Node, Str1}.


%%
%% This function executes on the new node
%%
node_started([Host,PortAtom]) ->
    %% Must spawn a new process because the boot process should not 
    %% hang forever!!
    spawn(fun() -> node_started(Host,PortAtom) end).

%% This process hangs forever, just waiting for the socket to be
%% closed and terminating the node
node_started(Host,PortAtom) ->
    {_, Version} = init:script_id(),
    VsnStr = erlang:system_info(system_version),
    Port = list_to_integer(atom_to_list(PortAtom)),
    case catch gen_tcp:connect(Host,Port, [binary, 
				     {reuseaddr,true}, 
				     {packet,1}]) of
	
	{ok,Sock} -> 
	    Started = term_to_binary({started, node(), Version, VsnStr}),
	    ok = gen_tcp:send(Sock,<<1,Started/binary>>),
	    receive _Anyting ->
		    gen_tcp:close(Sock),
		    erlang:halt()
	    end;
	_else ->
	    erlang:halt()
    end.





% start_which_node(Optlist) -> hostname
start_which_node(Optlist) ->
    case start_node_get_option_value(remote, Optlist) of
	undefined ->
	    local;
	true ->
	    case find_remote_host() of
		{error, Other} ->
		    {error, Other};
		RHost ->
		    RHost
	    end
    end.
 
find_remote_host() ->
    HostList=test_server_ctrl:get_hosts(),
    case lists:delete(test_server_sup:hoststr(), HostList) of
	[] ->
	    {error, no_remote_hosts};
	[RHost|_Rest] ->
	    RHost
    end.

start_node_get_option_value(Key, List) ->
    start_node_get_option_value(Key, List, undefined).

start_node_get_option_value(Key, List, Default) ->
    case lists:keysearch(Key, 1, List) of
	{value, {Key, Value}} ->
	    Value;
	false ->
	    Default
    end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% stop_node(Name) -> ok | {error,Reason}
%%
%% Clean up - test_server will stop this node
stop_node(Name, TI) ->
    case ets:lookup(slave_tab,Name) of
	[#slave_info{client=Client}] -> 
	    ets:delete(slave_tab,Name),
	    HostAtom = test_server_sup:hostatom(Name),
	    case lists:member(HostAtom,TI#target_info.slave_targets) of
		true -> 
		    put(test_server_free_targets,
			get(test_server_free_targets) ++ [HostAtom]);
		false -> ok
	    end,
	    close_target_client(Client),
	    ok;
	[] -> 
	    {error, not_a_slavenode}
    end.
	    
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% kill_nodes(TI) -> ok
%%
%% Brutally kill all slavenodes that were not stopped by test_server
kill_nodes(TI) ->
    case ets:match_object(slave_tab,'_') of
	[] -> [];
	List ->
	    lists:map(fun(SI) -> kill_node(SI,TI) end, List)
    end.

kill_node(SI,TI) ->
    Name = SI#slave_info.name,
    ets:delete(slave_tab,Name),
    HostAtom = test_server_sup:hostatom(Name),
    case lists:member(HostAtom,TI#target_info.slave_targets) of
	true ->
	    put(test_server_free_targets,
		get(test_server_free_targets) ++ [HostAtom]);
	false -> ok
    end,
    case SI#slave_info.socket of
	undefined ->
	    catch rpc:call(Name,erlang,halt,[]);
	Sock ->
	    gen_tcp:close(Sock)
    end,
    close_target_client(SI#slave_info.client),
    Name.



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Platform specific code

start_target(vxworks,TargetHost,Cmd) ->
    case vxworks_client:open(TargetHost) of
	{ok,P} ->
	    case vxworks_client:send_data(P,Cmd,"start_erl called") of
		{ok,_} -> 
		    {ok,{vxworks,P},?VXWORKS_ACCEPT_TIMEOUT};
		Error -> 
		    Error
	    end;
	Error ->
	    Error
    end;
start_target(ose,TargetHost,Cmd) ->
    case telnet_client:open(TargetHost) of
	{ok,P} ->
	    telnet_client:send_data(P,Cmd),
	    {ok,{ose,P},?OSE_ACCEPT_TIMEOUT};
	Error ->
	    Error
    end;
start_target(unix,TargetHost,Cmd0) ->
    Cmd = 
	case test_server_sup:hoststr() of
	    TargetHost -> Cmd0;
	    _ -> lists:concat(["rsh ",TargetHost, " ", Cmd0])
	end,
    open_port({spawn, Cmd}, [stream]),
    {ok,undefined,?ACCEPT_TIMEOUT}.

maybe_reboot_target({vxworks,P}) when is_pid(P) ->
    %% Reboot the vxworks card.
    %% Client is also closed after this, even if reboot fails
    vxworks_client:send_data_wait_for_close(P,"q");
maybe_reboot_target({vxworks,T}) when is_atom(T) ->
    %% Reboot the vxworks card.
    %% Client is also closed after this, even if reboot fails
    vxworks_client:reboot(T);
maybe_reboot_target(_) ->
    {error, cannot_reboot_target}.

close_target_client({vxworks,P}) ->
    vxworks_client:close(P);
close_target_client({ose,P}) ->
    telnet_client:close(P);
close_target_client(undefined) ->
    ok.



%%
%% Command for starting main target
%% 
get_main_target_start_command(vxworks,_TargetHost,Naming,
			      _MasterNode,_MasterCookie) ->
    "e" ++ Naming ++ " test_server -boot start_sasl"
	" -sasl errlog_type error"
	" -s test_server start " ++ test_server_sup:hoststr();
get_main_target_start_command(ose,TargetHost,Naming,MasterNode,MasterCookie) ->
    MasterIP = get_ip(test_server_sup:hoststr(MasterNode)),
    case atom_to_list(node()) of
	MasterNode -> erl_boot_server:start([get_ip(TargetHost)]);
	_otherNode -> ok
    end,
    "start_erl " ++ Naming ++ " test_server -noshell"
        " -kernel raw_files false" ++
	" -master " ++ MasterNode ++ 
	" -loader ose_inet -hosts " ++ MasterIP ++ 
	" -setcookie " ++ MasterCookie ++ 
	" -init_debug -s test_server start " ++ test_server_sup:hoststr();
get_main_target_start_command(unix,_TargetHost,Naming,
			      _MasterNode,_MasterCookie) ->
    Prog = pick_erl_program(default),
    Prog ++ " " ++  Naming ++ " test_server" ++
	" -boot start_sasl -sasl errlog_type error"
	" -s test_server start " ++ test_server_sup:hoststr().

%% 
%% Command for starting slave nodes
%% 
get_slave_node_start_command(vxworks, _Prog, _MasterNode) ->
    "e";
    %"e-noinput -master " ++ MasterNode;
get_slave_node_start_command(ose, _Prog, MasterNode) ->
    MasterIP = get_ip(test_server_sup:hoststr(MasterNode)),
    "start_erl -noinput -master " ++ MasterNode ++ " -loader ose_inet"
	" -hosts " ++ MasterIP ++ " -init_debug";
get_slave_node_start_command(unix, Prog, MasterNode) ->
    cast_to_list(Prog) ++ " -detached -master " ++ MasterNode.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Internal library functions
get_ip(Host) ->
    {ok,{_,_,_,_,_,[{A,B,C,D}|_]}} = inet_res:gethostbyname(Host),
    integer_to_list(A) ++ "." ++ integer_to_list(B) ++ "." ++
	integer_to_list(C) ++ "." ++ integer_to_list(D).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% cast_to_list(X) -> string()
%%% X = list() | atom() | void()
%%% Returns a string representation of whatever was input

cast_to_list(X) when list(X) -> X;
cast_to_list(X) when atom(X) -> atom_to_list(X);
cast_to_list(X) -> lists:flatten(io_lib:format("~w", [X])).


%%% L contains elements of the forms
%%%  {prog, String}
%%%  {release, Rel} where Rel = String | latest | previous
%%%  this
%%%
pick_erl_program(default) ->
    cast_to_list(lib:progname());
pick_erl_program(L) ->
    P = random_element(L),
    case P of
	{prog, S} ->
	    S;
	{release, S} ->
	    find_release(S);
	this ->
	    lib:progname()
    end.

random_element(L) ->
    {A,B,C} = now(),
    E = (A+B+C) rem length(L),
    lists:nth(E+1, L).

find_release(latest) ->
    "/usr/local/otp/releases/latest/bin/erl";
find_release(previous) ->
    "kaka";
find_release(Rel) ->
%% beam only
    "/usr/local/otp/releases/otp_beam_" ++ os(Rel) ++ "_" ++ Rel ++ "/bin/erl".

os(Rel) when Rel=="r5b01_patched";
	     Rel=="r6b_patched";
	     Rel=="r7b";
	     Rel=="r7b01";
	     Rel=="r7b01_patched";
	     Rel=="r7b_patched";
	     Rel=="r8b";
	     Rel=="r8b_hipe";
	     Rel=="r8b_oldsparc";
	     Rel=="r8b_patched";
	     Rel=="r9b";
	     Rel=="r9b_patched" ->
    "sunos5";
os(_Rel) ->
    "solaris8".

