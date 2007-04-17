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

%%---------------------------------------------------------------
%% Basic negotiated options with Telnet (RFC 854)
%%
%% Side A request: I WILL set option Opt.
%% Side B answer:  DO go ahead, or no, DON'T set it.
%% 
%% Side A request: Please DO set this option. 
%% Side B answer:  Ok I WILL, or no, I WON'T set it.
%%
%% "Enable option" requests may be rejected. 
%% "Disable option" requests must not.
%%---------------------------------------------------------------

-module(telnet_client).

-export([open/1, open/2, open/3, close/1]).
-export([send_data/2, get_data/1]).

-define(DBG, false).

-define(TELNET_PORT, 23).
-define(OPEN_TIMEOUT,10000).

%% telnet control characters
-define(SE,	240).
-define(NOP,	241).
-define(DM,	242).
-define(BRK,	243).
-define(IP,	244).
-define(AO,	245).
-define(AYT,	246).
-define(EC,	247).
-define(EL,	248).
-define(GA,	249).
-define(SB,	250).
-define(WILL,	251).
-define(WONT,	252).
-define(DO,	253).
-define(DONT,	254).
-define(IAC,	255).

%% telnet options
-define(BINARY,            0).
-define(ECHO,	           1).
-define(SUPPRESS_GO_AHEAD, 3).
-define(TERMINAL_TYPE,     24).  
-define(WINDOW_SIZE,       31).

-record(state,{waiting}).

open(Server) ->
    open(Server, ?TELNET_PORT, true).

open(Server, Port) ->
    open(Server, Port, true).

open(Server, Port, Printer) ->
    Self = self(),
    Pid = spawn(fun() -> init(Self, Server, Port) end),
    receive 
	{open,Pid} ->
	    case Printer of
		true -> spawn(fun() -> printer(Pid) end);
		false -> ok
	    end,
	    {ok,Pid};
	{Error,Pid} ->
	    Error
    end.

close(Pid) ->
    Pid ! close.

send_data(Pid, Data) ->
    Pid ! {send_data, Data++"\r\n"},
    ok.

get_data(Pid) ->
    Pid ! {get_data, self()},
    receive 
	{data,Data} ->
	    {ok, Data};
	Error ->
	    Error
    end.

%%%-----------------------------------------------------------------
%%% Printer process
printer(TelnetPid) ->
    process_flag(trap_exit, true),
    link(TelnetPid),		      % always finish with telnet process
    printer_loop(TelnetPid).

printer_loop(TelnetPid) ->
    case get_data(TelnetPid) of
	{ok,[]} ->
	    timer:sleep(2000);
	{ok,Str} ->
	    io:format("~s~n", [Str]);
	{'EXIT',TelnetPid,_} ->
	    exit(telnet_process_died)
    end,
    printer_loop(TelnetPid).

%%%-----------------------------------------------------------------
%%% Internal telnet client process functions
init(Parent, Server, Port) ->
    case gen_tcp:connect(Server, Port, [list,{packet,0}], ?OPEN_TIMEOUT) of
	{ok,Sock} ->
	    dbg("Connected to: ~p\n", [Server]),
	    send([?IAC,?DO,?SUPPRESS_GO_AHEAD], Sock),	      
	    Parent ! {open,self()},
	    loop(#state{}, Sock, []),
	    gen_tcp:close(Sock);
        Error ->
	    Parent ! {Error,self()}
    end.

loop(State, Sock, Acc) ->
    receive
	{send_data,Data} ->
	    send(Data, Sock),
	    loop(State, Sock, Acc);
	{get_data,Pid} ->
	    %% dbg("get_data\n",[]),
	    Pid ! {data,lists:reverse(lists:append(Acc))},
	    loop(State, Sock, []);
	{tcp_closed,_} ->
	    dbg("Connection closed\n", []),
	    receive
		{get_data,Pid} ->
		    Pid ! closed
	    after 100 ->
		    ok
	    end;
	{tcp,_,Msg0} ->
	    dbg("tcp msg: ~p~n",[Msg0]),
	    Msg = check_msg(Sock,Msg0,[]),
	    loop(State, Sock, [Msg | Acc]);
	close ->
	    dbg("Closing connection\n", []),
	    gen_tcp:close(Sock),
	    ok
    end.

send(Data, Sock) ->
    dbg("Sending: ~p\n", [Data]),
    gen_tcp:send(Sock, Data),
    ok.

check_msg(Sock,[?IAC | Cs], Acc) ->
    case get_cmd(Cs) of
	{Cmd,Cs1} ->
	    dbg("Got ", []), 
	    cmd_dbg(Cmd),
	    respond_cmd(Cmd, Sock),
	    check_msg(Sock, Cs1, Acc); 
	error ->
	    Acc
    end;
check_msg(Sock,[H|T],Acc) ->
    check_msg(Sock,T,[H|Acc]);
check_msg(_Sock,[],Acc) ->
    Acc.

%% Positive responses (WILL and DO).

respond_cmd([?WILL,?ECHO], Sock) ->
    R = [?IAC,?DO,?ECHO],
    cmd_dbg(R),
    gen_tcp:send(Sock, R);

respond_cmd([?DO,?ECHO], Sock) ->
    R = [?IAC,?WILL,?ECHO],
    cmd_dbg(R),
    gen_tcp:send(Sock, R);

%% Answers from server

respond_cmd([?WILL,?SUPPRESS_GO_AHEAD], Sock) ->
    dbg("Server will suppress-go-ahead\n", []);

respond_cmd([?WONT,?SUPPRESS_GO_AHEAD], Sock) ->
    dbg("Warning! Server won't suppress-go-ahead\n", []);

respond_cmd([?DONT | Opt], Sock) ->		% server ack?
    ok;						
respond_cmd([?WONT | Opt], Sock) ->		% server ack?
    ok;						

%% Negative responses (WON'T and DON'T). These are default!

respond_cmd([?WILL,Opt], Sock) ->
    R = [?IAC,?DONT,Opt],
    cmd_dbg(R),
    gen_tcp:send(Sock, R);

respond_cmd([?DO | Opt], Sock) ->
    R = [?IAC,?WONT | Opt],
    cmd_dbg(R),
    gen_tcp:send(Sock, R);

%% Unexpected messages.

respond_cmd([Cmd | Opt], _Sock) when Cmd >= 240, Cmd =< 255 ->
    dbg("Received cmd: ~w. Ignored!\n", [[Cmd | Opt]]);

respond_cmd([Cmd | Opt], _Sock)  ->
    dbg("WARNING: Received unknown cmd: ~w. Ignored!\n", [[Cmd | Opt]]);

respond_cmd([], _Sock) ->
    ok.


get_cmd([Cmd | Rest]) when Cmd == ?SB ->
    get_subcmd(Rest, []);

get_cmd([Cmd,Opt | Rest]) ->
    {[Cmd,Opt], Rest};

get_cmd(_Other) ->
    error.

get_subcmd([?SE | Rest], Acc) ->
    {[?SE | lists:reverse(Acc)], Rest};

get_subcmd([Opt | Rest], Acc) ->
    get_subcmd(Rest, [Opt | Acc]).


dbg(Str,Args) ->
    if ?DBG -> io:format(Str,Args);
       true -> ok
    end.

cmd_dbg(Cmd) ->
    if ?DBG ->
	case Cmd of
	    [?IAC|Cmd1] ->
		cmd_dbg(Cmd1);
	    [Ctrl|Opts] ->
		CtrlStr = 
		    case Ctrl of
			?DO ->   "DO";
			?DONT -> "DONT";
			?WILL -> "WILL";
			?WONT -> "WONT";
			_ ->     "CMD"
		    end,
		Opts1 =
		    case Opts of 
			[Opt] -> Opt;
			_ -> Opts
		    end,
		io:format("~s(~w): ~w\n", [CtrlStr,Ctrl,Opts1])
	end;
       true -> ok
    end.
