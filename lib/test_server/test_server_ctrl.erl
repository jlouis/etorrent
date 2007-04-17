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
-module(test_server_ctrl).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                                                                  %%
%%                      The Erlang Test Server                      %%
%%                                                                  %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
%% MODULE DEPENDENCIES:
%% HARD TO REMOVE: erlang, lists, io_lib, gen_server, file, io, string, 
%%                 code, ets, rpc, gen_tcp, inet, erl_tar, sets,
%%                 test_server, test_server_sup, test_server_node
%% EASIER TO REMOVE: filename, filelib
%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% ARCHITECTURE
%% 
%% The Erlang Test Server can be run on the target machine (local target)
%% or towards a remote target. The execution flow is mainly the same in
%% both cases, but with a remote target the test cases are (obviously)
%% executed on the target machine. Host and target communicates over
%% socket connections because the host should not be introduced as an
%% additional node in the distributed erlang system in which the test
%% cases are run.
%% 
%% 
%% Local Target:
%% =============
%% 
%%   -----
%%   |   |  test_server_ctrl ({global,test_server})
%%   ----- (test_server_ctrl.erl)
%%     |
%%     |
%%   -----
%%   |   | JobProc
%%   ----- (test_server_ctrl.erl and test_server.erl)
%%     |
%%     |
%%   -----
%%   |   | CaseProc
%%   ----- (test_server.erl)
%% 
%% 
%% 
%% test_server_ctrl is the main process in the system. It is a registered
%% process, and it will always be alive when testing is ongoing.
%% test_server_ctrl initiates testing and monitors JobProc(s).
%% 
%% When target is local, the test_server_ctrl process is also globally
%% registered as test_server and simulates the {global,test_server}
%% process on remote target.
%% 
%% JobProc is spawned for each 'job' added to the test_server_ctrl. 
%% A job can mean one test case, one test suite or one spec.
%% JobProc creates and writes logs and presents results from testing.
%% JobProc is the group leader for CaseProc.
%% 
%% CaseProc is spawned for each test case. It runs the test case and
%% sends results and any other information to its group leader - JobProc.
%% 
%% 
%% 
%% Remote Target:
%% ==============
%% 
%% 		HOST				TARGET
%% 
%% 	                   -----  MainSock   -----
%%        test_server_ctrl |   |- - - - - - -|   | {global,test_server}
%%  (test_server_ctrl.erl) -----	     ----- (test_server.erl)
%% 		             |		       |
%% 			     |		       |
%% 		           -----  JobSock    -----
%% 	          JobProcH |   |- - - - - - -|   | JobProcT
%%  (test_server_ctrl.erl) -----	     ----- (test_server.erl)
%% 					       |	
%% 					       |
%% 					     -----
%% 					     |   | CaseProc
%% 					     ----- (test_server.erl)
%% 
%% 
%% 
%% 
%% A separate test_server process only exists when target is remote. It
%% is then the main process on target. It is started when test_server_ctrl
%% is started, and a socket connection is established between
%% test_server_ctrl and test_server. The following information can be sent
%% over MainSock:
%% 
%% HOST			TARGET
%%  -> {target_info, TargetInfo}     (during initiation)
%%  <- {job_proc_killed,Name,Reason} (if a JobProcT dies unexpectedly)
%%  -> {job,Port,Name}               (to start a new JobProcT)
%% 
%% 
%% When target is remote, JobProc is split into to processes: JobProcH
%% executing on Host and JobProcT executing on Target. (The two processes
%% execute the same code as JobProc does when target is local.) JobProcH
%% and JobProcT communicates over a socket connection. The following
%% information can be sent over JobSock:
%% 
%% HOST			TARGET
%%  -> {test_case, Case}          To start a new test case
%%  -> {beam,Mod}                 .beam file as binary to be loaded
%% 				  on target, e.g. a test suite
%%  -> {datadir,Tarfile}          Content of the datadir for a test suite
%%  <- {apply,MFA}                MFA to be applied on host, ignore return;
%% 				  (apply is used for printing information in 
%% 				  log or console) 
%%  <- {sync_apply,MFA}           MFA to be applied on host, wait for return
%% 				  (used for starting and stopping slave nodes)
%%  -> {sync_apply,MFA}           MFA to be applied on target, wait for return
%% 				  (used for cover compiling and analysing)
%% <-> {sync_result,Result}       Return value from sync_apply
%%  <- {test_case_result,Result}  When a test case is finished
%%  <- {crash_dumps,Tarfile}      When a test case is finished
%%  -> job_done			  When a job is finished
%%  <- {privdir,Privdir}          When a job is finished
%% 
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%



%%% SUPERVISOR INTERFACE %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-export([start/0,start/1,start_link/1,stop/0]).

%%% OPERATOR INTERFACE %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-export([add_spec/1,add_dir/2,add_dir/3]).
-export([add_module/1,add_module/2,add_case/2,add_case/3, add_cases/2,
	 add_cases/3]).
-export([jobs/0,run_test/1,wait_finish/0]).
-export([get_levels/0,set_levels/3]).
-export([multiply_timetraps/1]).
-export([cover/2,cover/3,cross_cover_analyse/1,trc/1,stop_trace/0]).

%%% TEST_SERVER INTERFACE %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-export([output/2,print/2,print/3,print_timestamp/2]).
-export([start_node/3, stop_node/1, wait_for_node/1]).
-export([format/1,format/2,format/3]).
-export([get_target_info/0]).
-export([get_hosts/0]).
-export([get_target_os_type/0]).
-export([node_started/1]).

%%% DEBUGGER INTERFACE %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-export([i/0,p/1,p/3,pi/2,pi/4,t/0,t/1]).

%%% PRIVATE EXPORTED %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-export([init/1,terminate/2]).
-export([handle_call/3,handle_cast/2,handle_info/2]).
-export([do_test_cases/4]).
-export([do_spec/2,do_spec_list/2]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-include("test_server_internal.hrl").
-include_lib("kernel/include/file.hrl").
-define(suite_ext,"_SUITE").
-define(log_ext,".log.html").
-define(src_listing_ext, ".src.html").
-define(logdir_ext,".logs").
-define(data_dir_suffix,"_data/").
-define(suitelog_name,"suite.log").
-define(coverlog_name,"cover.html").
-define(cross_coverlog_name,"cross_cover.html").
-define(cover_total,"total_cover.log").
-define(last_file, "last_name").
-define(last_link, "last_link").
-define(last_test, "last_test").
-define(html_ext, ".html").
-define(cross_cover_file, "cross.cover").
-record(state,{jobs=[],levels={1,19,10},multiply_timetraps=1,finish=false,
	       target_info, trc=false, cover=false, wait_for_node=[]}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% OPERATOR INTERFACE

add_dir(Name,[Dir|Dirs]) when list(Dir) ->
    add_job(cast_to_list(Name),
	    [{dir,cast_to_list(Dir)}|
	     lists:map(fun(X)-> {dir,cast_to_list(X)} end,Dirs)]);
add_dir(Name,Dir) -> 
    add_job(cast_to_list(Name),{dir,cast_to_list(Dir)}).

add_dir(Name,[Dir|Dirs],Pattern) when list(Dir) ->
    add_job(cast_to_list(Name),
	    [{dir,cast_to_list(Dir),cast_to_list(Pattern)}|
	     lists:map(fun(X)-> {dir,cast_to_list(X),
				 cast_to_list(Pattern)} end,Dirs)]);
add_dir(Name,Dir,Pattern) -> 
    add_job(cast_to_list(Name),{dir,cast_to_list(Dir),cast_to_list(Pattern)}).

add_module(Mod) when atom(Mod) ->
    add_job(atom_to_list(Mod),{Mod,all}).
add_module(Name,Mods) when list(Mods) ->
    add_job(cast_to_list(Name),lists:map(fun(Mod) -> {Mod,all} end,Mods)).

add_case(Mod,Case) when atom(Mod), atom(Case) ->
    add_job(atom_to_list(Mod),{Mod,Case}).

add_case(Name, Mod,Case) when atom(Mod), atom(Case) ->
    add_job(Name,{Mod,Case}).

add_cases(Mod, Cases) when atom(Mod), list(Cases) ->
    add_job(atom_to_list(Mod), {Mod, Cases}).

add_cases(Name, Mod, Cases) when atom(Mod), list(Cases) ->
    add_job(Name, {Mod,Cases}).

add_spec(Spec) ->
    Name = filename:rootname(Spec,".spec"),
    case filelib:is_file(Spec) of
	true -> add_job(Name, {spec, Spec});
	false -> {error, nofile}
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% COMMAND LINE INTERFACE

parse_cmd_line(Cmds) ->
    parse_cmd_line(Cmds, [], [], local, false, false).

parse_cmd_line(['SPEC',Spec|Cmds],SpecList,Names,Param,Trc,Cov) ->
    case file:consult(Spec) of
	{ok, TermList} ->
	    Name = filename:rootname(Spec),
	    parse_cmd_line(Cmds,TermList++SpecList,[Name|Names],Param,Trc,Cov);
	{error,Reason} ->
	    io:format("Can't open ~s: ~p\n",
		      [cast_to_list(Spec), file:format_error(Reason)]),
	    parse_cmd_line(Cmds,SpecList,Names,Param,Trc,Cov)
    end;
parse_cmd_line(['NAME',Name|Cmds],SpecList,Names,Param,Trc,Cov) ->
    parse_cmd_line(Cmds,SpecList,[{name,Name}|Names],Param,Trc,Cov);
parse_cmd_line(['SKIPMOD',Mod|Cmds],SpecList,Names,Param,Trc,Cov) ->
    parse_cmd_line(Cmds,[{skip,{Mod,"by command line"}}|SpecList],Names,
		   Param,Trc,Cov);
parse_cmd_line(['SKIPCASE',Mod,Case|Cmds],SpecList,Names,Param,Trc,Cov) ->
    parse_cmd_line(Cmds,[{skip,{Mod,Case,"by command line"}}|SpecList],Names,
		   Param,Trc,Cov);
parse_cmd_line(['DIR',Dir|Cmds],SpecList,Names,Param,Trc,Cov) ->
    Name = cast_to_list(filename:basename(Dir)),
    parse_cmd_line(Cmds,[{topcase,{dir,Name}}|SpecList],[Name|Names],
		   Param,Trc,Cov);
parse_cmd_line(['MODULE',Mod|Cmds],SpecList,Names,Param,Trc,Cov) ->
    parse_cmd_line(Cmds,[{topcase,{Mod,all}}|SpecList],[Mod|Names],
		   Param,Trc,Cov);
parse_cmd_line(['CASE',Mod,Case|Cmds],SpecList,Names,Param,Trc,Cov) ->
    parse_cmd_line(Cmds,[{topcase,{Mod,Case}}|SpecList],[Mod|Names],
		   Param,Trc,Cov);
parse_cmd_line(['PARAMETERS',Param|Cmds],SpecList,Names,_Param,Trc,Cov) ->
    parse_cmd_line(Cmds,SpecList,Names,Param,Trc,Cov);
parse_cmd_line(['TRACE',Trc|Cmds],SpecList,Names,Param,_Trc,Cov) ->
    parse_cmd_line(Cmds,SpecList,Names,Param,Trc,Cov);
parse_cmd_line(['COVER',App,CF,Analyse|Cmds],SpecList,Names,Param,Trc,_Cov) ->
    parse_cmd_line(Cmds,SpecList,Names,Param,Trc,{{App,CF},Analyse});
parse_cmd_line([Obj|_Cmds],_SpecList,_Names,_Param,_Trc,_Cov) ->
    io:format("~p: Bad argument: ~p\n", [?MODULE,Obj]),
    io:format(" Use the `ts' module to start tests.\n", []),
    io:format(" (If you ARE using `ts', there is a bug in `ts'.)\n", []),
    halt(1);
parse_cmd_line([], SpecList, Names, Param, Trc,Cov) ->
    NameList = lists:reverse(Names, [suite]),
    Name = case lists:keysearch(name, 1, NameList) of
	       {value,{name,N}} -> N;
	       false -> hd(NameList)
	   end,
    {lists:reverse(SpecList),cast_to_list(Name),Param,Trc,Cov}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% cast_to_list(X) -> string()
%% X = list() | atom() | void()
%% Returns a string representation of whatever was input

cast_to_list(X) when list(X) -> X;
cast_to_list(X) when atom(X) -> atom_to_list(X);
cast_to_list(X) -> lists:flatten(io_lib:format("~w", [X])).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% START INTERFACE

start() ->
    start(local).

start(Param) ->
    case gen_server:start({local,?MODULE},?MODULE,[Param],[]) of
	{ok, Pid} ->
	    {ok, Pid};
	Other ->
	    Other
    end.

start_link(Param) ->
    case gen_server:start_link({local,?MODULE},?MODULE,[Param],[]) of
	{ok, Pid} ->
	    {ok, Pid};
	Other ->
	    Other
    end.

run_test(CommandLine) ->
    process_flag(trap_exit,true),
    {SpecList,Name,Param,Trc,Cov} = parse_cmd_line(CommandLine),
    {ok, _TSPid} = start_link(Param),
    case Trc of
	false -> ok;
	File -> trc(File)
    end,
    case Cov of
	false -> ok;
	{{App,CoverFile},Analyse} -> cover(App,maybe_file(CoverFile),Analyse)
    end,
    add_job(Name,{command_line,SpecList}),
    
    %% adding of jobs involves file i/o which may take long time
    %% when running a nfs mounted file system (VxWorks).
    case controller_call(get_target_info) of
	#target_info{os_family=vxworks} ->
	    receive after 30000 -> ready_to_wait end;
	_ ->
	    wait_now
    end,
    wait_finish().

%% Converted CoverFile to a string unless it is 'none'
maybe_file(none) ->
    none;
maybe_file(CoverFile) ->
    atom_to_list(CoverFile).

wait_finish() ->
    OldTrap = process_flag(trap_exit,true),
    {ok, Pid} = finish(),
    link(Pid),
    receive
	{'EXIT',Pid,_} ->
	    ok
    end,
    process_flag(trap_exit,OldTrap),
    ok.

finish() ->
    controller_call(finish).

stop() ->
    controller_call(stop).

jobs() ->
    controller_call(jobs).

get_levels() ->
    controller_call(get_levels).

set_levels(Show,Major,Minor) ->
    controller_call({set_levels,Show,Major,Minor}).

multiply_timetraps(N) ->
    controller_call({multiply_timetraps,N}).

trc(TraceFile) ->
    controller_call({trace,TraceFile},2*?ACCEPT_TIMEOUT).

stop_trace() ->
    controller_call(stop_trace).

node_started(Node) ->
    gen_server:cast(?MODULE,{node_started,Node}).

cover(App,Analyse) when atom(App) ->
    cover(App,none,Analyse);
cover(CoverFile,Analyse) ->
    cover(none,CoverFile,Analyse).
cover(App,CoverFile,Analyse) ->
    controller_call({cover,{App,CoverFile},Analyse}).


get_hosts() ->
    get(test_server_hosts).

get_target_os_type() ->
    case whereis(?MODULE) of
	undefined ->
	    %% This is probably called on the target node
	    os:type();
	_pid ->
	    %% This is called on the controller, e.g. from a
	    %% specification clause of a test case
	    #target_info{os_type=OsType} = controller_call(get_target_info),
	    OsType
    end.

%% internal
add_job(Name,TopCase) ->
    SuiteName =
	case Name of
	    "." -> "current_dir";
	    ".." -> "parent_dir";
	    Other -> Other
	end,
    Dir = filename:absname(SuiteName),
    controller_call({add_job,Dir,SuiteName,TopCase}).

controller_call(Arg) ->
    case catch gen_server:call(?MODULE,Arg) of
	{'EXIT',{{badarg,_},{gen_server,call,_}}} ->
	    exit(test_server_ctrl_not_running);
	{'EXIT',Reason} ->
	    exit(Reason);
	Other ->
	    Other
    end.
controller_call(Arg,Timeout) ->
    case catch gen_server:call(?MODULE,Arg,Timeout) of
	{'EXIT',{{badarg,_},{gen_server,call,_}}} ->
	    exit(test_server_ctrl_not_running);
	{'EXIT',Reason} ->
	    exit(Reason);
	Other ->
	    Other
    end.
    

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% init([Mode])
%% Mode = lazy | error_logger
%% StateFile = string()
%% ReadMode = ignore_errors | halt_on_errors
%%
%% init() is the init function of the test_server's gen_server.
%% When Mode=error_logger: The init function of the test_server's gen_event
%% event handler used as a replacement error_logger when running test_suites.
%%
%% The init function reads the test server state file, to see what test
%% suites were running when the test server was last running, and which
%% flags that were in effect. If no state file is found, or there are
%% errors in it, defaults are used.
%%
%% Mode 'lazy' ignores (and resets to []) any jobs in the state file
%%

init([Param]) ->
    process_flag(trap_exit, true),
    test_server_sup:cleanup_crash_dumps(),
    State = #state{jobs=[],finish=false},
    put(test_server_free_targets,[]),
    case contact_main_target(Param) of
	{ok,TI} ->
	    ets:new(slave_tab,[named_table,set,public,{keypos,2}]),
	    set_hosts([TI#target_info.host]),
	    {ok,State#state{target_info=TI}};
	{error,Reason} ->
	    {stop,Reason}
    end.
	


%% If the test is to be run at a remote target, this function sets up
%% a socket communication with the target.
contact_main_target(local) ->
    %% Local target! The global test_server process implemented by
    %% test_server.erl will not be started, so we simulate it by 
    %% globally registering this process instead.
    global:register_name(test_server,self()),
    TI = test_server:init_target_info(),
    TargetHost = test_server_sup:hoststr(),
    {ok,TI#target_info{where=local,
		       host=TargetHost,
		       naming=naming(),
		       master=TargetHost}};
contact_main_target(ParameterFile) ->
    case read_parameters(ParameterFile) of
	{ok,Par} ->
	    case test_server_node:start_remote_main_target(Par) of
		{ok,TI} ->
		    {ok,TI};
		{error,Error} ->
		    {error,{could_not_start_main_target,Error}}
	    end;
	{error,Error} ->
	    {error,{could_not_read_parameterfile,Error}}
    end.

read_parameters(File) ->
    case file:consult(File) of
	{ok,Data} ->
	    read_parameters(lists:flatten(Data),#par{naming=naming()});
	Error ->
	    Error
    end.
read_parameters([{type,Type}|Data],Par) -> % mandatory
    read_parameters(Data,Par#par{type=Type});
read_parameters([{target,Target}|Data],Par) -> % mandatory
    read_parameters(Data,Par#par{target=cast_to_list(Target)});
read_parameters([{slavetargets,SlaveTargets}|Data],Par) ->
    read_parameters(Data,Par#par{slave_targets=SlaveTargets});
read_parameters([{longnames,Bool}|Data],Par) ->
    Naming = if Bool->"-name"; true->"-sname" end,
    read_parameters(Data,Par#par{naming=Naming});
read_parameters([{master,{Node,Cookie}}|Data],Par) ->
    read_parameters(Data,Par#par{master=cast_to_list(Node),
				 cookie=cast_to_list(Cookie)});
read_parameters([Other|_Data],_Par) ->
    {error,{illegal_parameter,Other}};
read_parameters([],Par) when Par#par.type==undefined ->
    {error, {missing_mandatory_parameter,type}};
read_parameters([],Par) when Par#par.target==undefined ->
    {error, {missing_mandatory_parameter,target}};
read_parameters([],Par0) ->
    Par = 
	case {Par0#par.type, Par0#par.master} of
	    {ose, undefined} -> 
		%% Use this node as master and bootserver for target
		%% and slave nodes
		Par0#par{master = atom_to_list(node()),
			 cookie = atom_to_list(erlang:get_cookie())};
	    {ose, _Master} ->
		%% Master for target and slave nodes was defined in parameterfile
		Par0;
	    _ -> 
		%% Use target as master for slave nodes,
		%% (No master is used for target)
		Par0#par{master="test_server@" ++ Par0#par.target} 
	end,
    {ok,Par}.

naming() ->
    case lists:member($., test_server_sup:hoststr()) of
	true -> "-name";
	false -> "-sname"
    end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% handle_call(kill_slavenodes, From, State) -> ok
%%
%% Kill all slave nodes that remain after a test case 
%% is completed.
%%
handle_call(kill_slavenodes, _From, State) ->
    Nodes = test_server_node:kill_nodes(State#state.target_info),
    {reply, Nodes, State};

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% handle_call({set_hosts, HostList}, From, State) ->
%%                           ok
%%
%% Set the global hostlist.
%%
handle_call({set_hosts, Hosts}, _From, State) ->
    set_hosts(Hosts),
    {reply, ok, State};

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% handle_call(get_hosts, From, State) -> [Hosts]
%%
%% Returns the lists of hosts that the test server
%% can use for slave nodes. This is primarily used
%% for nodename generation.
%%
handle_call(get_hosts, _From, State) ->
    Hosts = get_hosts(),
    {reply, Hosts, State};

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% handle_call({add_job,Dir,Name,TopCase},_,State) -> ok | {error,Reason}
%% Dir = string()
%% Name = string()
%% TopCase = term()
%%
%% Adds a job to the job queue. The name of the job is Name. A log directory
%% will be created in Dir/Name.logs/ . TopCase may be anything that
%% collect_cases/3 accepts, plus the following:
%%
%% {spec,SpecName} executes the named test suite specification file. Commands
%% in the file should be in the format accepted by do_spec_list/1.
%%
%% {command_line,SpecList} executes the list of specification instructions
%% supplied, which should be in the format accepted by do_spec_list/1.

handle_call({add_job,Dir,Name,TopCase},_From,State) ->
    LogDir = Dir ++ ?logdir_ext,
    ExtraTools = 
	case State#state.cover of
	    false -> [];
	    {App,Analyse} -> [{cover,App,Analyse}]
	end,
    case lists:keysearch(Name,1,State#state.jobs) of
	false ->
	    Pid =
		case TopCase of
		    {spec,SpecName} ->
			spawn_tester(
			  ?MODULE,do_spec,
			  [SpecName,State#state.multiply_timetraps],
			  LogDir,Name,State#state.levels,ExtraTools);
		    {command_line,SpecList} ->
			spawn_tester(
			  ?MODULE,do_spec_list,
			  [SpecList,State#state.multiply_timetraps],
			  LogDir,Name,State#state.levels,ExtraTools);
		    TopCase ->
			spawn_tester(
			  ?MODULE,do_test_cases, 
			  [TopCase,[],make_config([]),
			   State#state.multiply_timetraps],
			  LogDir,Name,State#state.levels,ExtraTools)
		end,
	    NewJobs = [{Name,Pid}|State#state.jobs],
	    {reply, ok, State#state{jobs=NewJobs}};
	_ ->
	    {reply,{error,name_already_in_use},State}
    end;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% handle_call(jobs,_,State) -> JobList
%% JobList = [{Name,Pid}, ...]
%% Name = string()
%% Pid = pid()
%%
%% Return the list of current jobs.

handle_call(jobs,_From,State) ->
    {reply,State#state.jobs,State};


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% handle_call(finish,_,State) -> {ok,Pid}
%%
%% Tells the test_server to stop as soon as there are no test suites
%% running. Immediately if none are running.

handle_call(finish,_From,State) ->
    case State#state.jobs of
	[] ->
	    State2 = State#state{finish=false},
	    {stop,shutdown,{ok,self()}, State2};
	_SomeJobs ->
	    State2 = State#state{finish=true},
	    {reply, {ok,self()}, State2}
    end;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% handle_call(get_levels,_,State) -> {Show,Major,Minor}
%% Show = integer()
%% Major = integer()
%% Minor = integer()
%%
%% Returns a 3-tuple with the logging thresholds.
%% All output and information from a test suite is tagged with a detail
%% level. Lower values are more "important". Text that is output using
%% io:format or similar is automatically tagged with detail level 50.
%%
%% All output with detail level:
%% less or equal to Show is displayed on the screen (default 1)
%% less or equal to Major is logged in the major log file (default 19)
%% greater or equal to Minor is logged in the minor log files (default 10)

handle_call(get_levels,_From,State) ->
    {reply,State#state.levels,State};

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% handle_call({set_levels,Show,Major,Minor},_,State) -> ok
%% Show = integer()
%% Major = integer()
%% Minor = integer()
%%
%% Sets the logging thresholds, see handle_call(get_levels,...) above.

handle_call({set_levels,Show,Major,Minor},_From,State) ->
    {reply,ok,State#state{levels={Show,Major,Minor}}};

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% handle_call({multiply_timetraps,N},_,State) -> ok
%% N = integer() | infinity
%%
%% Multiplies all timetraps set by test cases with N

handle_call({multiply_timetraps,N},_From,State) ->
    {reply,ok,State#state{multiply_timetraps=N}};

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% handle_call({trace,TraceFile},_,State) -> ok | {error,Reason}
%%
%% Starts a separate node (trace control node) which 
%% starts tracing on target and all slave nodes
%% 
%% TraceFile is a text file with elements of type
%% {Trace,Mod,TracePattern}.
%% {Trace,Mod,Func,TracePattern}.
%% {Trace,Mod,Func,Arity,TracePattern}.
%%
%% Trace = tp | tpl;  local or global call trace
%% Mod,Func = atom(), Arity=integer(); defines what to trace
%% TracePattern = [] | match_spec()
%% 
%% The 'call' trace flag is set on all processes, and then
%% the given trace patterns are set.
 
handle_call({trace,TraceFile},_From,State=#state{trc=false}) ->
    TI = State#state.target_info,
    case test_server_node:start_tracer_node(TraceFile,TI) of
	{ok,Tracer} -> {reply,ok,State#state{trc=Tracer}};
	Error -> {reply,Error,State}
    end;
handle_call({trace,_TraceFile},_From,State) ->
    {reply,{error,already_tracing},State};

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% handle_call(stop_trace,_,State) -> ok | {error,Reason}
%%
%% Stops tracing on target and all slave nodes and
%% terminates trace control node

handle_call(stop_trace,_From,State=#state{trc=false}) ->
    {reply,{error,not_tracing},State};
handle_call(stop_trace,_From,State) ->
    R = test_server_node:stop_tracer_node(State#state.trc),
    {reply,R,State#state{trc=false}};

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% handle_call({cover,App,Analyse},_,State) -> ok | {error,Reason}
%%
%% All modules inn application App are cover compiled
%% Analyse indicates on which level the coverage should be analysed

handle_call({cover,App,Analyse},_From,State) ->
    {reply,ok,State#state{cover={App,Analyse}}};

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% handle_call(stop,_,State) -> ok
%%
%% Stops the test server immediately.
%% Some cleanup is done by terminate/2

handle_call(stop,_From,State) ->
    {stop, shutdown, ok, State};

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% handle_call(get_target_info,_,State) -> TI
%%
%% TI = #target_info{}
%%
%% Returns information about target

handle_call(get_target_info,_From,State) ->
    {reply, State#state.target_info, State};

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% handle_call({start_node,Name,Type,Options},_,State) 
%%            -> ok | {error,Reason}
%%
%% Starts a new node (slave or peer)

handle_call({start_node, Name, Type, Options}, From, State) ->
    %% test_server_ctrl does gen_server:reply/2 explicitly
    test_server_node:start_node(Name, Type, Options, From,
				State#state.target_info),
    {noreply,State};


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% handle_call({wait_for_node,Node},_,State) 
%%            -> ok
%%
%% Waits for a new node to take contact. Used if 
%% node is started with option {wait,false}

handle_call({wait_for_node, Node}, From, State) ->
    NewWaitList = 
	case ets:lookup(slave_tab,Node) of
	    [] -> 
		[{Node,From}|State#state.wait_for_node];
	    _ -> 
		gen_server:reply(From,ok),
		State#state.wait_for_node
	end,
    {noreply,State#state{wait_for_node=NewWaitList}};

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% handle_call({stop_node,Name},_,State) -> ok | {error,Reason}
%%
%% Stops a slave or peer node. This is actually only some cleanup
%% - the node is really stopped by test_server when this returns.

handle_call({stop_node, Name}, _From, State) ->
    R = test_server_node:stop_node(Name, State#state.target_info),    
    {reply, R, State}.

%% internal
set_hosts(Hosts) ->
    put(test_server_hosts, Hosts).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% handle_cast({node_started,Name},_,State)
%%
%% Called by test_server_node when a slave/peer node is fully started.

handle_cast({node_started,Node},State) ->
    case State#state.trc of
	false -> ok;
	Trc -> test_server_node:trace_nodes(Trc,[Node])
    end,
    NewWaitList = 
	case lists:keysearch(Node,1,State#state.wait_for_node) of
	    {value,{Node,From}} ->
		gen_server:reply(From,ok),
		lists:keydelete(Node,1,State#state.wait_for_node);
	    false ->
		State#state.wait_for_node
	end,
    {noreply, State#state{wait_for_node=NewWaitList}}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% handle_info({'EXIT',Pid,Reason},State)
%% Pid = pid()
%% Reason = term()
%%
%% Handles exit messages from linked processes. Only test suites and
%% possibly a target client are expected to be linked. 
%% When a test suite terminates, it is removed from the job queue.
%% If a target client terminates it means that we lost contact with
%% target. The test_server_ctrl process is terminated, and teminate/2 
%% will do the cleanup

handle_info({'EXIT',Pid,Reason},State) ->
    case lists:keysearch(Pid,2,State#state.jobs) of
	false ->
	    TI = State#state.target_info,
	    case TI#target_info.target_client of
		Pid -> 
		    %% The target client died - lost contact with target
		    {stop,{lost_contact_with_target,Reason},State};
		_other ->
		    %% not our problem
		    {noreply,State}
	    end;
	{value,{Name,_}} ->
	    NewJobs = lists:keydelete(Pid,2,State#state.jobs),
	    case Reason of
		normal ->
		    fine;
		killed ->
		    io:format("Suite ~s was killed\n",[Name]);
		_Other ->
		    io:format("Suite ~s was killed with reason ~p\n",
			      [Name,Reason])
	    end,
	    State2 = State#state{jobs=NewJobs},
	    case {NewJobs,State2#state.finish} of
		{[],true} ->
		    %% test_server:finish() has been called and there are
		    %% no jobs in the job queue => stop the test_server_ctrl
		    State3 = State2#state{finish=false},
		    {stop,shutdown, State3};
		_ ->
		    {noreply, State2}
	    end
    end;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% handle_info({tcp,Sock,Bin},State)
%%
%% Message from remote main target process
%% Only valid message is 'job_proc_killed', which indicates
%% that a process running a test suite was killed

handle_info({tcp,_MainSock,<<1,Request/binary>>},State) ->
    case binary_to_term(Request) of
	{job_proc_killed,Name,Reason} ->
	    %% The only purpose of this is to inform the user about what
	    %% happened on target. 
	    %% The local job proc will soon be killed by the closed socket or
	    %% because the job is finished. Then the above clause ('EXIT') will 
	    %% handle the problem.
	    io:format("Suite ~s was killed on remote target with reason"
		      " ~p\n",[Name,Reason]);
	_ ->
	    ignore
    end,
    {noreply,State};
    

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% handle_info({tcp_closed,Sock},State)
%%
%% A Socket was closed. This indicates that a node died.
%% This can be 
%% *Target node (if remote)
%% *Slave or peer node started by a test suite
%% *Trace controll node
handle_info({tcp_closed,Sock},State=#state{trc=Sock}) ->
    %% Tracer node died - can't really do anything
    %%! Maybe print something???
    {noreply,State#state{trc=false}};
handle_info({tcp_closed,Sock},State) ->
    case test_server_node:nodedown(Sock,State#state.target_info) of
	target_died -> 
	    %% terminate/2 will do the cleanup
	    {stop,target_died,State};
	_ -> 
	    {noreply,State}
    end;

handle_info(_,State) ->
    %% dummy; accept all, do nothing.
    {noreply, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% terminate(Reason,State) -> ok
%% Reason = term()
%%
%% Cleans up when the test_server is terminating. Kills the running
%% test suites (if any) and terminates the remote target (if is exists)

terminate(_Reason,State) ->
    case State#state.trc of
	false -> ok;
	Sock -> test_server_node:stop_tracer_node(Sock)
    end,
    kill_all_jobs(State#state.jobs),
    test_server_node:stop(State#state.target_info),
    ok.

kill_all_jobs([{_Name,JobPid}|Jobs]) ->
    exit(JobPid,kill),
    kill_all_jobs(Jobs);
kill_all_jobs([]) ->
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% do_spec(SpecName,MultiplyTimetrap) -> {error,Reason} | exit(Result)
%% SpecName = string()
%% MultiplyTimetrap = integer() | infinity
%%
%% Reads the named test suite specification file, and executes it.
%%
%% This function is meant to be called by a process created by 
%% spawn_tester/7, which sets up some necessary dictionary values.

do_spec(SpecName,MultiplyTimetrap) when list(SpecName) ->
    case file:consult(SpecName) of
	{ok,TermList} ->
	    do_spec_list(TermList,MultiplyTimetrap);
	{error,Reason} ->
	    io:format("Can't open ~s: ~p\n",[SpecName,Reason]),
	    {error,{cant_open_spec,Reason}}
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% do_spec_list(TermList) -> exit(Result)
%% TermList = [term()|...]
%% MultiplyTimetrap = integer() | infinity
%%
%% Executes a list of test suite specification commands. The following
%% commands are available, and may occur zero or more times (if several,
%% the contents is appended):
%%
%% {topcase,TopCase} Specifies top level test goals. TopCase has the syntax
%% specified by collect_cases/3.
%%
%% {skip,Skip} Specifies test cases to skip, and lists requirements that
%% cannot be granted during the test run. Skip has the syntax specified
%% by collect_cases/3.
%%
%% {nodes,Nodes} Lists node names avaliable to the test suites. Nodes have
%% the syntax specified by collect_cases/3.
%%
%% {require_nodenames, Num} Specifies how many nodenames the test suite will
%% need. Theese are automaticly generated and inserted into the Config by the
%% test_server. The caller may specify other hosts to run theese nodes by
%% using the {hosts, Hosts} option. If there are no hosts specified, all
%% nodenames will be generated from the local host.
%%
%% {hosts, Hosts} Specifies a list of available hosts on which to start
%% slave nodes. It is used when the {remote, true} option is given to the 
%% test_server:start_node/3 function. Also, if {require_nodenames, Num} is
%% contained in the TermList, the generated nodenames will be spread over 
%% all hosts given in this Hosts list. The hostnames are given as atoms or
%% strings.
%% 
%% {diskless, true}</c></tag> is kept for backwards compatiblilty and
%% should not be used. Use a configuration test case instead.
%% 
%% This function is meant to be called by a process created by 
%% spawn_tester/7, which sets up some necessary dictionary values.

do_spec_list(TermList0,MultiplyTimetrap) ->
    Nodes = [],
    TermList = 
	case lists:keysearch(hosts, 1, TermList0) of
	    {value, {hosts, Hosts0}} ->
		Hosts = lists:map(fun(H) -> cast_to_list(H) end, Hosts0),
		controller_call({set_hosts, Hosts}),
		lists:keydelete(hosts, 1, TermList0);
	    _ ->
		TermList0
	end,
    DefaultConfig = make_config([{nodes,Nodes}]),
    {TopCases,SkipList,Config} = do_spec_terms(TermList,[],[],DefaultConfig),
    do_test_cases(TopCases,SkipList,Config,MultiplyTimetrap).

do_spec_terms([],TopCases,SkipList,Config) ->
    {TopCases,SkipList,Config};
do_spec_terms([{topcase,TopCase}|Terms],TopCases,SkipList,Config) ->
    do_spec_terms(Terms,[TopCase|TopCases],SkipList,Config);
do_spec_terms([{skip,Skip}|Terms],TopCases,SkipList,Config) ->
    do_spec_terms(Terms,TopCases,[Skip|SkipList],Config);
do_spec_terms([{nodes,Nodes}|Terms],TopCases,SkipList,Config) ->
    do_spec_terms(Terms,TopCases,SkipList,
		  update_config(Config,{nodes,Nodes}));
do_spec_terms([{diskless,How}|Terms],TopCases,SkipList,Config) ->
    do_spec_terms(Terms,TopCases,SkipList,
		  update_config(Config,{diskless,How}));
do_spec_terms([{ipv6_hosts,IPv6Hosts}|Terms],TopCases,SkipList,Config) ->
    do_spec_terms(Terms,TopCases,SkipList,
		  update_config(Config,{ipv6_hosts,IPv6Hosts}));
do_spec_terms([{require_nodenames,NumNames}|Terms],TopCases,SkipList,Config) ->
    NodeNames0=generate_nodenames(NumNames),
    NodeNames=lists:delete([], NodeNames0),
    do_spec_terms(Terms,TopCases,SkipList, 
		  update_config(Config,{nodenames,NodeNames})).
    

generate_nodenames(Num) ->
    Hosts = case controller_call(get_hosts) of
		[] -> 
		    TI = controller_call(get_target_info),
		    [TI#target_info.host];
		List -> 
		    List
	    end,
    generate_nodenames2(Num,Hosts,[]).

generate_nodenames2(0, _Hosts, Acc) ->
    Acc;
generate_nodenames2(N, Hosts, Acc) ->
    Host=cast_to_list(lists:nth((N rem (length(Hosts)))+1, Hosts)),
    Name=list_to_atom(temp_nodename("nod",[]) ++ "@" ++ Host),
    generate_nodenames2(N-1, Hosts, [Name|Acc]).

temp_nodename([], Acc) ->
    lists:flatten(Acc);
temp_nodename([Chr|Base], Acc) ->
    {A,B,C} = erlang:now(),
    New = [Chr | integer_to_list(Chr bxor A bxor B+A bxor C+B)],
    temp_nodename(Base, [New|Acc]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% do_test_cases(TopCases,SkipCases,Config,MultiplyTimetrap) -> exit(Result)
%% TopCases = term()      (See collect_cases/3)
%% SkipCases = term()     (See collect_cases/3)
%% Config = term()        (See collect_cases/3)
%% MultiplyTimetrap = integer() | infinity
%%
%% Initializes and starts the test run, for "ordinary" test suites.
%% Creates log directories and log files, inserts initial timestamps and
%% configuration information into the log files.
%%
%% This function is meant to be called by a process created by 
%% spawn_tester/7, which sets up some necessary dictionary values.

do_test_cases(TopCases,SkipCases,Config,MultiplyTimetrap) when list(TopCases) ->
    start_log_file(),
    case collect_all_cases(TopCases, SkipCases) of
	{error,Why} ->
	    print(1,"Error starting: ~p",[Why]),
	    exit(test_suite_done);
	TestSpec0 ->
	    TestSpec = 
		add_init_and_end_per_suite(TestSpec0,undefined,undefined),
	    TI = get_target_info(),
	    put(test_server_cases,length(TestSpec)),
	    put(test_server_case_num,1),
	    N = get(test_server_cases),
	    print(1,"Starting test, ~w test cases",[N]),
	    test_server_sup:framework_call(report,[tests_start,
						   {get(test_server_name),N}]),
	    print(html,
		  "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 3.2 Final//EN\">\n"
		  "<!-- autogenerated by '"++atom_to_list(?MODULE)++"'. -->\n"
		  "<html>\n"
		  "<head><title>Test suite ~p results</title>\n"
		  "<meta http-equiv=\"cache-control\" content=\"no-cache\">\n"
		  "</head>\n"
		  "<body bgcolor=\"white\" text=\"black\" "
		  "link=\"blue\" vlink=\"purple\" alink=\"red\">"
		  "<h2>Results from test suite ~p</h2>\n",
		  [get(test_server_name),get(test_server_name)]),
	    print_timestamp(html,"Suite started at "),

	    print(html, "<p>Host:<br>\n"),
	    print_who(test_server_sup:hoststr(),test_server_sup:get_username()),
	    print(html, "<br>Used Erlang ~s in <tt>~s</tt>.\n",
		  [erlang:system_info(version), code:root_dir()]),

	    print(html, "<p>Target:<br>\n"),
	    print_who(TI#target_info.host,TI#target_info.username),
	    print(html, "<br>Used Erlang ~s in <tt>~s</tt>.\n",
		  [TI#target_info.version, TI#target_info.root_dir]),

	    print(html,
		  "<p><a href=\"~s\">Full textual log</a>\n"
		  "<br><a href=\"~s\">Coverage log</a>\n",
		  [?suitelog_name,?coverlog_name]),
	    print(html,"<p>Suite contains ~p test cases.\n"
		  "<p>\n"
		  "<table border=3 cellpadding=5>"
		  "<tr><th>Num</th><th>Module</th><th>Case</th>"
		  "<th>Time</th><th>Success</th><th>Comment</th></tr>\n",
		  [get(test_server_cases)]),

	    print(major, "=cases        ~p", [get(test_server_cases)]),
	    print(major, "=user         ~s", [TI#target_info.username]),
	    print(major, "=host         ~s", [TI#target_info.host]),

	    %% If there are no hosts specified,use only the local host
	    case controller_call(get_hosts) of
		[] ->
		    print(major, "=hosts        ~s",[TI#target_info.host]),
		    controller_call({set_hosts,[TI#target_info.host]});
		Hosts ->
		    Str = lists:flatten(lists:map(fun(X) -> [X," "] end, Hosts)),
		    print(major, "=hosts        ~s", [Str])
	    end,
	    print(major, "=emulator_vsn ~s", [TI#target_info.version]),
	    print(major, "=emulator     ~s", [TI#target_info.emulator]),
	    print(major, "=otp_release  ~s", [TI#target_info.otp_release]),
	    print(major, "=started      ~s",
		   [lists:flatten(timestamp_get(""))]),
	    run_test_cases(TestSpec,Config,MultiplyTimetrap)
    end;
do_test_cases(TopCase,SkipCases,Config,MultiplyTimetrap) -> 
    %% when not list(TopCase)
    do_test_cases([TopCase],SkipCases,Config,MultiplyTimetrap).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% start_log_file() -> ok | exit({Error,Reason})
%% Stem = string()
%%
%% Creates the log directories, the major log file and the html log file.
%% The log files are initialized with some header information.
%%
%% The name of the log directory will be <Name>.LOGS/run.<Date>/ where
%% Name is the test suite name and Date is the current date and time.

start_log_file() ->
    Dir  = get(test_server_dir),
    case file:make_dir(Dir) of
	ok ->
	    ok;
	{error, eexist} ->
	    ok;
	MkDirError ->
	    exit({cant_create_log_dir,{MkDirError,Dir}})
    end,
    TestDir = timestamp_filename_get(filename:join(Dir, "run.")),
    case file:make_dir(TestDir) of
	ok ->
	    ok;
	MkDirError2 ->
	    exit({cant_create_log_dir,{MkDirError2,TestDir}})
    end,

    ok = file:write_file(filename:join(Dir, ?last_file), TestDir ++ "\n"),
    ok = file:write_file(?last_file, TestDir ++ "\n"),

    put(test_server_log_dir_base,TestDir),
    MajorName = filename:join(TestDir, ?suitelog_name),
    HtmlName = MajorName ++ ?html_ext,
    {ok,Major} = file:open(MajorName, write),
    {ok,Html}  = file:open(HtmlName,  write),
    put(test_server_major_fd,Major),
    put(test_server_html_fd,Html),

    make_html_link(filename:absname(?last_test ++ ?html_ext),
		   HtmlName, filename:basename(Dir)),
    LinkName = filename:join(Dir, ?last_link),
    make_html_link(LinkName ++ ?html_ext, HtmlName,
		   filename:basename(Dir)),

    PrivDir = filename:join(TestDir, ?priv_dir),
    ok = file:make_dir(PrivDir),
    put(test_server_priv_dir,PrivDir),
    print_timestamp(13,"Suite started at "),
    ok.

make_html_link(LinkName, Target, Explanation) ->
    %% If possible use a relative reference to Target.
    TargetL = filename:split(Target), 
    PwdL = filename:split(filename:dirname(LinkName)),
    Href = case lists:prefix(PwdL, TargetL) of
	       true ->
		   filename:join(lists:nthtail(length(PwdL), TargetL));
	       false ->
		   "file:" ++ Target
	   end,
    H = io_lib:format("<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 3.2 Final//EN\">\n"
		      "<!-- autogenerated by '"++atom_to_list(?MODULE)++"'. -->\n"
		      "<html>\n"
		      "<head><title>~s</title></head>\n"
		      "<body bgcolor=\"white\" text=\"black\""
		      " link=\"blue\" vlink=\"purple\" alink=\"red\">\n"
		      "<h1>Last test</h1>\n"
		      "<a href=\"~s\">~s</a>~n"
		      "</body>\n</html>\n",
		      [Explanation,Href,Explanation]),
    ok = file:write_file(LinkName, H).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% start_minor_log_file(Mod,Func) -> AbsName
%% Mod = atom()
%% Func = atom()
%% AbsName = string()
%%
%% Create a minor log file for the test case Mod,Func,Args. The log file
%% will be stored in the log directory under the name <Mod>.<Func>.log.
%% Some header info will also be inserted into the log file.

start_minor_log_file(Mod, Func) ->
    LogDir = get(test_server_log_dir_base),
    Name0 = lists:flatten(io_lib:format("~s.~s~s",[Mod,Func,?html_ext])),
    Name = downcase(Name0),
    AbsName = filename:join(LogDir, Name),
    {ok,Fd} = file:open(AbsName, [write]),
    Lev = get(test_server_minor_level)+1000, %% Far down in the minor levels
    put(test_server_minor_fd, Fd),

    io:fwrite(Fd,
	      "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 3.2 Final//EN\">\n"
	      "<!-- autogenerated by '"++atom_to_list(?MODULE)++"'. -->\n"
	      "<html>\n"
	      "<head><title>"++cast_to_list(Mod)++"</title>\n"
	      "<meta http-equiv=\"cache-control\" content=\"no-cache\">\n"
	      "</head>\n"
	      "<body bgcolor=\"white\" text=\"black\""
	      " link=\"blue\" vlink=\"purple\" alink=\"red\">\n",
	      []),

    SrcListing = downcase(cast_to_list(Mod)) ++ ?src_listing_ext,
    case filelib:is_file(filename:join(LogDir, SrcListing)) of
	true ->
	    print(Lev, "<a href=\"~s#~s\">source code for ~p:~p/1</a>\n",
		  [SrcListing,Func,Mod,Func]);
	false -> ok
    end,

    io:fwrite(Fd, "<pre>\n", []),
% Stupid BUG!
%    case catch apply(Mod, Func, [doc]) of
%	{'EXIT', _Why} -> ok;
%	Comment -> print(Lev, "Comment: ~s~n<br>", [Comment])
%    end,

    AbsName.

stop_minor_log_file() ->
    Fd = get(test_server_minor_fd),
    io:fwrite(Fd, "</pre>\n</body>\n</html>\n", []),
    file:close(Fd),
    put(test_server_minor_fd, undefined).

downcase(S) -> downcase(S, []).
downcase([Uc|Rest], Result) when $A =< Uc, Uc =< $Z ->
    downcase(Rest, [Uc-$A+$a|Result]);
downcase([C|Rest], Result) ->
    downcase(Rest, [C|Result]);
downcase([], Result) ->
    lists:reverse(Result).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% html_convert_modules(TestSpec, Config) -> ok
%%  Isolate the modules affected by TestSpec and
%%  make sure they are converted to html.
%%
%%  Errors are silently ignored.

html_convert_modules(TestSpec, _Config) ->
    Mods = html_isolate_modules(TestSpec),
    html_convert_modules(Mods),
    copy_html_files(get(test_server_dir), get(test_server_log_dir_base)).

%% Retrieve a list of modules out of the test spec.

html_isolate_modules(List) -> html_isolate_modules(List, sets:new()).
    
html_isolate_modules([], Set) -> sets:to_list(Set);
html_isolate_modules([{skip_case,_}|Cases], Set) ->
    html_isolate_modules(Cases, Set);
html_isolate_modules([{conf,_Ref,{Mod,_Func}}|Cases], Set) ->
    html_isolate_modules(Cases, sets:add_element(Mod, Set));
html_isolate_modules([{Mod,_Case}|Cases], Set) ->
    html_isolate_modules(Cases, sets:add_element(Mod, Set));
html_isolate_modules([{Mod,_Case,_Args}|Cases], Set) ->
    html_isolate_modules(Cases, sets:add_element(Mod, Set)).

%% Given a list of modules, convert each module's source code to HTML.

html_convert_modules([Mod|Mods]) ->
    case code:which(Mod) of
	Path when list(Path) ->
	    SrcFile = filename:rootname(Path) ++ ".erl",
	    DestDir = get(test_server_dir),
	    Name = atom_to_list(Mod),
	    DestFile = filename:join(DestDir, downcase(Name) ++ ?src_listing_ext),
	    html_possibly_convert(SrcFile, DestFile),
	    html_convert_modules(Mods);
	_Other -> ok
    end;
html_convert_modules([]) -> ok.

%% Convert source code to HTML if possible and needed.

html_possibly_convert(Src, Dest) ->
    case file:read_file_info(Src) of
	{ok,SInfo} ->
	    case file:read_file_info(Dest) of
		{error,_Reason} ->		%No dest file
		    erl2html2:convert(Src, Dest);
		{ok,DInfo} when DInfo#file_info.mtime < SInfo#file_info.mtime ->
		    erl2html2:convert(Src, Dest);
		{ok,_DInfo} -> ok		%Dest file up to date
	    end;
	{error,_Reason} -> ok			%No source code found
    end.

%% Copy all HTML files in InDir to OutDir.

copy_html_files(InDir, OutDir) ->
    Files = filelib:wildcard(filename:join(InDir, "*" ++ ?src_listing_ext)),
    lists:foreach(fun (Src) -> copy_html_file(Src, OutDir) end, Files).

copy_html_file(Src, DestDir) ->
    Dest = filename:join(DestDir, filename:basename(Src)),
    case file:read_file(Src) of
	{ok,Bin} ->
	    ok = file:write_file(Dest, Bin);
	{error,_Reason} ->
	    io:format("File ~p: read failed\n", [Src])
    end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% run_test_cases(TestSpec,Config,MultiplyTimetrap) -> exit(Result)
%%
%% If remote target, a socket connection is established.
%% Runs the specified tests, then displays/logs the summary.

run_test_cases(TestSpec,Config,MultiplyTimetrap) ->

    maybe_open_job_sock(),

    html_convert_modules(TestSpec, Config),
    run_test_cases_loop(TestSpec,Config,MultiplyTimetrap),

    maybe_get_privdir(),

    Skipped = get(test_server_skipped),
    SkipStr =
	case Skipped of
	    0 -> "";
	    N -> io_lib:format(", ~w skipped",[N])
	end,
    print(1,"TEST COMPLETE, ~w ok, ~w failed~s of ~w test cases",
	  [get(test_server_ok),get(test_server_failed),
	   SkipStr,get(test_server_cases)]),
    test_server_sup:framework_call(report,[tests_done,
					   {get(test_server_ok),
					    get(test_server_failed),
					    Skipped}]),
    print(major, "=finished   ~s", [lists:flatten(timestamp_get(""))]),
    print(major, "=failed     ~p", [get(test_server_failed)]),
    print(major, "=successful ~p", [get(test_server_ok)]),
    print(major, "=skipped    ~p", [Skipped]),
    exit(test_suite_done).


%% If the test is run at a remote target, this function sets up a socket
%% communication with the target for handling this particular job.
maybe_open_job_sock() ->
    TI = get_target_info(),
    case TI#target_info.where of
	local ->
	    %% local target
	    test_server:init_purify();
	MainSock ->
	    %% remote target
	    {ok,LSock} = gen_tcp:listen(0,[binary,
					   {reuseaddr,true},
					   {packet,4},
					   {active,false}]),
	    {ok,Port} = inet:port(LSock),
	    request(MainSock,{job,Port,get(test_server_name)}),
	    case gen_tcp:accept(LSock,?ACCEPT_TIMEOUT) of
		{ok,Sock} -> put(test_server_ctrl_job_sock,Sock);
		{error,Reason} -> exit({no_contact,Reason})
	    end
    end.


%% If the test is run at a remote target, this function waits for a
%% tar packet containing the privdir created by the test case.
maybe_get_privdir() ->
    case get(test_server_ctrl_job_sock) of
	undefined -> 
	    %% local target
	    ok;
	Sock -> 
	    %% remote target
	    request(Sock,job_done),
	    gen_tcp:close(Sock)
    end.


add_init_and_end_per_suite([{make,_,_}=Case|Cases], LastMod, LastRef) ->
    [Case|add_init_and_end_per_suite(Cases,LastMod,LastRef)];
add_init_and_end_per_suite([{skip_case,_}=Case|Cases],LastMod,LastRef)->
    [Case|add_init_and_end_per_suite(Cases,LastMod,LastRef)];
add_init_and_end_per_suite([{conf,_,{Mod,_}}=Case|Cases], LastMod, LastRef) 
  when Mod =/= LastMod ->
    {PreCases, NextMod, NextRef} = 
	do_add_init_and_end_per_suite(LastMod,LastRef,Mod),
    PreCases ++ [Case|add_init_and_end_per_suite(Cases,NextMod,NextRef)];
add_init_and_end_per_suite([{conf,_,_}=Case|Cases], LastMod, LastRef) ->
    [Case|add_init_and_end_per_suite(Cases,LastMod,LastRef)];
add_init_and_end_per_suite([{Mod,_}=Case|Cases], LastMod, LastRef) 
  when Mod =/= LastMod ->
    {PreCases, NextMod, NextRef} = 
	do_add_init_and_end_per_suite(LastMod,LastRef,Mod),
    PreCases ++ [Case|add_init_and_end_per_suite(Cases,NextMod,NextRef)];
add_init_and_end_per_suite([{Mod,_,_}=Case|Cases], LastMod, LastRef)
  when Mod =/= LastMod ->
    {PreCases, NextMod, NextRef} = 
	do_add_init_and_end_per_suite(LastMod,LastRef,Mod),
    PreCases ++ [Case|add_init_and_end_per_suite(Cases,NextMod,NextRef)];
add_init_and_end_per_suite([Case|Cases],LastMod,LastRef)->
    [Case|add_init_and_end_per_suite(Cases,LastMod,LastRef)];
add_init_and_end_per_suite([],_LastMod,undefined) ->
    [];
add_init_and_end_per_suite([],LastMod,LastRef) ->
    [{conf,LastRef,{LastMod,end_per_suite}}].

do_add_init_and_end_per_suite(LastMod,LastRef,Mod) ->
    case code:is_loaded(Mod) of
	false -> code:load_file(Mod);
	_ -> ok
    end,
    {Init,NextMod,NextRef} = 
	case erlang:function_exported(Mod,init_per_suite,1) of
	    true ->
		Ref = make_ref(),
		{[{conf,Ref,{Mod,init_per_suite}}],Mod,Ref};
	    false ->
		{[],Mod,undefined}
	end,
    Cases = 
	if LastRef==undefined ->
		Init;
	   true ->
		%% Adding end_per_suite here without checking if the 
		%% function is actually exported. This is because a
		%% conf case must have an end case - so if it doesn't 
		%% exist, it will only fail...
		[{conf,LastRef,{LastMod,end_per_suite}}|Init]
	end,
    {Cases,NextMod,NextRef}.




%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% run_test_cases_loop(TestCases,Config,MultiplyTimetrap) -> ok
%% TestCases = [Test,...]
%% MultiplyTimetrap = integer() | infinity
%%
%% Execute the TestCases under configuration Config.
%% Test may be one of the following
%%
%% {skip_case,{Case,Comment}} Writes a comment in the log files why
%% the case was skipped.
%%
%% {conf,Ref,{Mod,Func}} Mod:Func is a configuration modification function,
%% call it with the current configurtation as argument. It will return
%% a new configuration.
%%
%% {make,Ref,{Mod,Func,Args}} Mod:Func is a make function, and it is called 
%% with the given arguments. This function will *always* be called on the host 
%% - not on target.
%%
%% {Mod,Case} This is a normal test case. Determine the correct
%% configuration, and insert {Mod,Case,Config} as head of the list,
%% then reiterate.
%%
%% {Mod,Case,Args} A test case with predefined argument (usually a normal
%% test case which just got a fresh configuration (see above)).


run_test_cases_loop([{skip_case,{Case,Comment}}|Cases],Config,MultiplyTimetrap)->
   CaseNum = get(test_server_case_num),
    {Mod,Func} =
	case Case of
	    {M,F,_A} -> {M,F};
	    {M,F} -> {M,F}
	end,
    print(major, "~n=case    ~p:~p", [Mod, Func]),
    print(major, "=started ~s", [lists:flatten(timestamp_get(""))]),
    print(major, "=result  skipped:~s", [Comment]),
    print(2,"*** Skipping test case #~w ~p ***",[CaseNum,{Mod,Func}]),
    print(html,"<tr valign=top><td>~p</td><td>~p</td><td>~p</td>"
	  "<td></td><td>SKIPPED</td><td>~s</td></tr>\n",
	  [CaseNum,Mod,Func,Comment]),
    put(test_server_skipped,get(test_server_skipped)+1),
    put(test_server_case_num,CaseNum+1),
    run_test_cases_loop(Cases,Config,MultiplyTimetrap);
run_test_cases_loop([{conf,Ref,{Mod,Func}}|Cases0], Config0, MultiplyTimetrap) ->
    ActualConfig = 
	update_config(Config0,[{priv_dir,get(test_server_priv_dir)},
			       {data_dir,get_data_dir(Mod)}]),
    case run_test_case(Mod,Func,[ActualConfig], skip_init, target, 
		       MultiplyTimetrap) of
	NewConfig when list(NewConfig) ->
	    print(major, "=result   ok"),
	    run_test_cases_loop(Cases0, NewConfig, MultiplyTimetrap);
	{Skip,Reason} when Skip==skip; Skip==skipped ->
	    print(minor,"*** ~p skipped.\n"
		  "    Skipping all other cases.", [Func]),
	    Cases = skip_cases_upto(Ref, Cases0, Reason),
	    run_test_cases_loop(Cases, Config0, MultiplyTimetrap);
	Fail when element(1,Fail)=='EXIT'; element(1,Fail)==timetrap_timeout ->
	    print(minor,"*** ~p failed.\n"
		  "    Skipping all other cases.", [Func]),
	    Reason = lists:flatten(io_lib:format("~p:~p/1 failed", [Mod,Func])),
	    Cases = skip_cases_upto(Ref, Cases0, Reason),
	    run_test_cases_loop(Cases, Config0, MultiplyTimetrap);
	_Other ->
	    print(minor,"*** ~p failed to return a new config.~n"
		  "    Proceeding with old config.", [Func]),
	    run_test_cases_loop(Cases0, Config0, MultiplyTimetrap)
    end;
run_test_cases_loop([{make,Ref,{Mod,Func,Args}}|Cases0], Config, MultiplyTimetrap) ->
    case run_test_case(Mod, Func, Args, skip_init, host, MultiplyTimetrap) of
	{'EXIT',_} ->
 	    print(minor,"*** ~p failed.\n"
 		  "    Skipping all other cases.", [Func]),
	    Reason = lists:flatten(io_lib:format("~p:~p/1 failed", [Mod,Func])),
	    Cases = skip_cases_upto(Ref, Cases0, Reason),
	    run_test_cases_loop(Cases, Config, MultiplyTimetrap);
	_Whatever ->
	    print(major, "=result   ok"),
	    run_test_cases_loop(Cases0, Config, MultiplyTimetrap)
    end;
run_test_cases_loop([{conf,_Ref,_X}=Conf|_Cases0], Config, _MultiplyTimetrap) ->
    erlang:fault(badarg, [Conf,Config]);
run_test_cases_loop([{Mod,Case}|Cases], Config, MultiplyTimetrap) ->
    ActualConfig = 
	update_config(Config,[{priv_dir,get(test_server_priv_dir)},
			      {data_dir,get_data_dir(Mod)}]),
    run_test_cases_loop([{Mod,Case,[ActualConfig]}|Cases],Config,
			MultiplyTimetrap);
run_test_cases_loop([{Mod,Func,Args}|Cases],Config,MultiplyTimetrap) ->
    run_test_case(Mod, Func, Args, run_init, target, MultiplyTimetrap),
    run_test_cases_loop(Cases,Config,MultiplyTimetrap);
run_test_cases_loop([],_Config,_MultiplyTimetrap) ->
    ok.

%% Skip all cases up to the matching reference.

skip_cases_upto(Ref, [{Type,Ref,MF}|T], Reason) when Type==conf; Type==make ->
    [{skip_case,{MF,Reason}}|T];
skip_cases_upto(Ref, [{_M,_F}=MF|T], Reason) ->
    [{skip_case,{MF,Reason}}|skip_cases_upto(Ref, T, Reason)];
skip_cases_upto(Ref, [_|T], Reason) ->
    skip_cases_upto(Ref, T, Reason);
skip_cases_upto(_Ref, [], _Reason) -> [].

get_data_dir(Mod) ->
    case code:which(Mod) of
	non_existing ->
	    print(12,"The module ~p is not loaded",[Mod]),
	    [];
	FullPath ->
	    filename:dirname(FullPath) ++ "/" ++ cast_to_list(Mod) ++
		?data_dir_suffix
    end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% run_test_case(Mod,Func,Args,Run_init,Where,MultiplyTimetrap) -> RetVal
%% RetVal = term()
%%
%% Creates the minor log file and inserts some test case specific headers
%% and footers into the log files.
%% If remote target, send test suite (binary) and and the content
%% of datadir. 
%% Runs the test suite, and presents information about lingering processes 
%% & slaves in the system.
%% 
%% Run_init decides if the per test case init is to be run (true for all
%% but {conf, ... test cases).
%%
%% Where decides if the test case should be run on target or always on
%% the host. ('make' test cases are always run on host)
%% 
%% RetVal is the value returned by the test suite, or the exit message
%% in case the test suite failed.

run_test_case(Mod, Func, Args, Run_init, Where, MultiplyTimetrap) ->
    case Where of
	target -> 
	    maybe_send_beam_and_datadir(Mod);
	host ->
	    ok
    end,

    test_server_sup:framework_call(report,[tc_start,{Mod,Func}]),

    CaseNum = get(test_server_case_num),
    print(major, "=case    ~p:~p", [Mod, Func]),
    MinorName = start_minor_log_file(Mod,Func),
    print(major, "=logfile ~s", [filename:basename(MinorName)]),
    print(major, "=started ~s", [lists:flatten(timestamp_get(""))]),
    print(html,"<tr valign=top><td>~p</td><td>~p</td><td>"
	  "<a href=\"~s\">~p</a></td>",
	  [CaseNum,Mod,filename:basename(MinorName),Func]),
    file:set_cwd(filename:dirname(get(test_server_dir))),
    {ok,Cwd} = file:get_cwd(),

    receive after 1 -> ok end, %! do I still need this?
    {{Time,RetVal,Loc,Comment},DetectedFail,ProcessesBefore,ProcessesAfter} = 
	run_test_case_apply(CaseNum, Mod, Func, Args, Run_init, 
			    Where, MultiplyTimetrap),
    receive after 1 -> ok end, %! do I still need this?

    print_timestamp(minor, "Ended at "),
    print(major, "=ended   ~s", [lists:flatten(timestamp_get(""))]),
    file:set_cwd(Cwd),           % Mattias
    case {Time,RetVal} of
	{died,{timetrap_timeout, TimetrapTimeout, Line}} ->
	    progress(failed,CaseNum,Mod,Func,Line,
		     timetrap_timeout,TimetrapTimeout,Comment);
	{died,Reason} ->
	    progress(failed,CaseNum,Mod,Func,Loc,Reason,Time,Comment);
	{_,{'EXIT',{Skip,Reason}}} when Skip==skip; Skip==skipped ->
	    progress(skip,CaseNum,Mod,Func,Loc,Reason,Time,Comment);
	{_,{'EXIT',_Pid,{Skip,Reason}}} when Skip==skip; Skip==skipped ->
	    progress(skip,CaseNum,Mod,Func,Loc,Reason,Time,Comment);
	{_,{'EXIT',_Pid,Reason}} ->
	    progress(failed,CaseNum,Mod,Func,Loc,Reason,Time,Comment);
	{_,{'EXIT',Reason}} ->
	    progress(failed,CaseNum,Mod,Func,Loc,Reason,Time,Comment);
	{_, {failed, Reason}} ->
	    progress(failed,CaseNum,Mod,Func,Loc,Reason,Time,Comment);
	{_, {Skip, Reason}} when Skip==skip; Skip==skipped ->
	    progress(skip,CaseNum,Mod,Func,Loc,Reason,Time,Comment);
	{Time,RetVal} ->
	    case DetectedFail of
		[] ->
		    progress(ok,CaseNum,Mod,Func,Loc,RetVal,Time,Comment);
		
		Reason ->
		    progress(failed,CaseNum,Mod,Func,Loc,Reason,Time,Comment)
	    end
    end,
    
    case test_server_sup:framework_call(warn,[processes],true) of
	true ->
	    if ProcessesBefore < ProcessesAfter ->
		    print(minor, 
			  "WARNING: ~w more processes in system after test case",
			  [ProcessesAfter-ProcessesBefore]);
	       ProcessesBefore > ProcessesAfter ->
		    print(minor, 
			  "WARNING: ~w less processes in system after test case",
			  [ProcessesBefore-ProcessesAfter]);
	       true -> ok
	    end;
	false ->
	    ok
    end,
    case test_server_sup:framework_call(warn,[nodes],true) of
	true ->
	    case catch controller_call(kill_slavenodes) of
		{'EXIT',_}=Exit ->
		    print(minor,
			  "WARNING: There might be slavenodes left in the"
			  " system. I tried to kill them, but I failed: ~p\n",
			  [Exit]);
		[] -> ok;
		List ->	    
		    print(minor,"WARNING: ~w slave nodes in system after test"++
			  "case. Tried to killed them.~n"++
			  "         Names:~p",
			  [length(List),List])
	    end;
	false ->
	    ok
    end,

    if number(Time) ->
	    put(test_server_total_time,get(test_server_total_time)+Time);
	true ->
	    ok
    end,
    check_new_crash_dumps(Where),
    stop_minor_log_file(),
    put(test_server_case_num,CaseNum+1),
    RetVal.

%% If remote target, this function sends the test suite (if not already sent)
%% and the content of datadir til target.
maybe_send_beam_and_datadir(Mod) ->
    case get(test_server_ctrl_job_sock) of
	undefined -> 
	    %% local target
	    ok;
	JobSock ->
	    %% remote target
	    case get(test_server_downloaded_suites) of
		undefined -> 
		    send_beam_and_datadir(Mod,JobSock),
		    put(test_server_downloaded_suites,[Mod]);
		Suites ->
		    case lists:member(Mod,Suites) of
			false ->
			    send_beam_and_datadir(Mod,JobSock),
			    put(test_server_downloaded_suites,[Mod|Suites]);
			true ->
			    ok
		    end
	    end
    end.

send_beam_and_datadir(Mod,JobSock) ->
    case code:which(Mod) of
	non_existing -> 
	    io:format("** WARNING: Suite ~w could not be found on host\n",
		      [Mod]);
	BeamFile -> 
	    send_beam(JobSock,Mod,BeamFile)
    end,
    DataDir = get_data_dir(Mod),
    case file:read_file_info(DataDir) of
	{ok,_I} ->
	    {ok,All} = file:list_dir(DataDir),
	    AddTarFiles =
		case controller_call(get_target_info) of
		    #target_info{os_family=ose} ->
			ObjExt = code:objfile_extension(),
			Wc = filename:join(DataDir, "*" ++ ObjExt),
			ModsInDatadir = filelib:wildcard(Wc),
			SendBeamFun = fun(X) -> send_beam(JobSock,X) end,
			lists:foreach(SendBeamFun, ModsInDatadir),
			%% No need to send C code or makefiles since 
			%% no compilation can be done on target anyway.
			%% Compiled C code must exist on target.
			%% Beam files are already sent as binaries.
			%% Erlang source are sent in case the test case
			%% is to compile it.
			Filter = fun("Makefile") -> false;
				    ("Makefile.src") -> false;
				    (Y) -> 
					 case filename:extension(Y) of
					     ".c"   -> false;
					     ObjExt -> false;
					     _      -> true
					 end
				 end,
			lists:filter(Filter, All);
		    _ ->
			All
		end,
	    Tarfile =  "data_dir.tar.gz",
	    {ok,Tar} = erl_tar:open(Tarfile,[write,compressed]),
	    ShortDataDir = filename:basename(DataDir),
	    AddTarFun = 
		fun(File) ->
			Long = filename:join(DataDir,File),
			Short = filename:join(ShortDataDir,File),
			ok = erl_tar:add(Tar,Long,Short,[])
		end,
	    lists:foreach(AddTarFun,AddTarFiles),
	    ok = erl_tar:close(Tar),
	    {ok,TarBin} = file:read_file(Tarfile),
	    file:delete(Tarfile),
	    request(JobSock,{{datadir,Tarfile},TarBin});
	{error,_R} ->
	    ok
    end.

send_beam(JobSock,BeamFile) ->
    Mod=filename:rootname(filename:basename(BeamFile),code:objfile_extension()),
    send_beam(JobSock,list_to_atom(Mod),BeamFile).    
send_beam(JobSock,Mod,BeamFile) ->
    {ok,BeamBin} = file:read_file(BeamFile),
    request(JobSock,{{beam,Mod,BeamFile},BeamBin}).
    

check_new_crash_dumps(Where) ->
    case Where of
	target ->
	    case get(test_server_ctrl_job_sock) of
		undefined ->
		    ok;
		Socket ->
		    read_job_sock_loop(Socket)
	    end;
	_ ->
	    ok
    end,
    test_server_sup:check_new_crash_dumps().



progress(skip, CaseNum, Mod, Func, Loc, Reason, Time, _Comment) ->
    print(major, "=result    skipped", []),
    print(1,"*** SKIPPED *** test case ~w of ~w",
	  [CaseNum,get(test_server_cases)]),
    test_server_sup:framework_call(report,[tc_done,{Mod,Func,{skipped,Reason}}]),
    print(html,"<td>~.3f s</td><td>SKIPPED</td><td>~s</td></tr>\n",
	  [Time,lists:flatten(Reason)]),
    FormattedLoc = test_server_sup:format_loc(Loc),
    print(minor,"location ~s",[FormattedLoc]),
    print(minor,"reason=~p",[lists:flatten(Reason)]),
    put(test_server_skipped,get(test_server_skipped)+1);
    
progress(failed,CaseNum,Mod,Func,Loc,timetrap_timeout,T,Comment0) ->
    print(major, "=result    failed:timeout:~p", [Loc]),
    print(1, "*** FAILED *** test case ~w of ~w",
	  [CaseNum,get(test_server_cases)]),
    test_server_sup:framework_call(report,
				   [tc_done,{Mod,Func,
					     {failed,timetrap_timeout}}]),
    FormattedLoc = test_server_sup:format_loc(Loc),
    ErrorReason = io_lib:format("{timetrap_timeout,~s}",[FormattedLoc]),
    Comment = 
	case Comment0 of
	    "" -> ErrorReason;
	    _ -> ErrorReason ++ "<br>" ++ Comment0
	end,
    print(html, 
	  "<td>~.3f s</td><td><font color=\"red\">FAILED</font></td>"
	  "<td><font color=\"red\">~s</font></td></tr>\n", 
	  [T/1000,Comment]),
    print(minor, "location ~s", [FormattedLoc]),
    print(minor, "reason=timetrap timeout", []),
    put(test_server_failed, get(test_server_failed)+1);

progress(failed, CaseNum, Mod, Func, Loc, Reason, Time, Comment0) ->
    print(major, "=result    failed:~p", [Loc]),
    print(1,"*** FAILED *** test case ~w of ~w",
	  [CaseNum,get(test_server_cases)]),
    test_server_sup:framework_call(report,[tc_done,{Mod,Func,{failed,Reason}}]),
    TimeStr = io_lib:format(if float(Time) -> "~.3f s";
			       true -> "~w"	     
			    end, [Time]),
    Comment = 
	case Comment0 of
	    "" -> "";
	    _ -> "<br>" ++ Comment0
	end,
    FormattedLoc = test_server_sup:format_loc(Loc),
    print(html, 
	  "<td>~s</td><td><font color=\"red\">FAILED</font></td>"
	  "<td><font color=\"red\">~s~s</font></td></tr>\n", 
	  [TimeStr,FormattedLoc,Comment]),
    print(minor, "location ~s", [FormattedLoc]),
    print(minor, "reason=~p", [Reason]),
    put(test_server_failed,get(test_server_failed)+1);

progress(ok, _CaseNum, Mod, Func, _Loc, RetVal, Time, Comment0) ->
    print(minor, "successfully completed test case",[]),
    test_server_sup:framework_call(report,[tc_done,{Mod,Func,ok}]),
    Comment =
	case RetVal of
	    {comment,String} ->
		print(major, "=result    ok:~s", [String]),
		"<td>" ++ String ++ "</td>";
	    _ ->
		print(major, "=result    ok", []),
		case Comment0 of
		    "" -> "";
		    _ -> "<td>" ++ Comment0 ++ "</td>"
		end
	end,
    print(major, "=elapsed   ~p", [Time]),
    print(html,"<td>~.3f s</td><td>Ok</td>~s</tr>\n",[Time,Comment]),
    print(minor,"returned value=~p",[RetVal]),
    put(test_server_ok,get(test_server_ok)+1).
    

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% run_test_case_apply(CaseNum, Mod, Func, Args, Run_init, 
%%                     Where, MultiplyTimetrap) -> 
%%  {{Time,RetVal,Loc,Comment},DetectedFail,ProcessesBefore,ProcessesAfter} |
%%  {{died,Reason,unknown,Comment},DetectedFail,ProcessesBefore,ProcessesAfter}
%% Where = target | host
%% Time = float()   (seconds)
%% RetVal = term()
%% Loc = term()
%% Comment = string()
%% Reason = term()
%% DetectedFail = [{File,Line}]
%% ProcessesBefore = ProcessesAfter = integer()
%%
%% Where indicates if the test should be run on target or always on the host.
%% 
%% If test is to be run on target, and target is remote the request is 
%% sent over socket to target, and test_server runs the case and sends the
%% result back over the socket. 
%% Else test_server runs the case directly on host.

run_test_case_apply(CaseNum,Mod,Func,Args,Run_init,host,MultiplyTimetrap) ->
    test_server:run_test_case_apply({CaseNum,Mod,Func,Args,Run_init,
				     MultiplyTimetrap});
run_test_case_apply(CaseNum,Mod,Func,Args,Run_init,target,MultiplyTimetrap) ->
    case get(test_server_ctrl_job_sock) of
	undefined ->
	    %% local target
	    test_server:run_test_case_apply({CaseNum,Mod,Func,Args,Run_init,
					     MultiplyTimetrap});
	JobSock ->
	    %% remote target
	    request(JobSock,{test_case,{CaseNum,Mod,Func,Args,Run_init,
					MultiplyTimetrap}}),
	    read_job_sock_loop(JobSock)
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% print(Detail,Format,Args) -> ok
%% Detail = integer()
%% Format = string()
%% Args = [term()]
%%
%% Just like io:format, except that depending on the Detail value, the output
%% is directed to console, major and/or minor log files. 

print(Detail, Format) ->
    print(Detail, Format, []).

print(Detail,Format,Args) ->
    Msg = io_lib:format(Format,Args),
    output({Detail,Msg},internal).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% print_timestamp(Detail,Leader) -> ok
%%
%% Prints Leader followed by a time stamp (date and time). Depending on
%% the Detail value, the output is directed to console, major and/or minor
%% log files. 

print_timestamp(Detail,Leader) ->
    print(Detail, timestamp_get(Leader), []).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% print_who(Host,User) -> ok
%%
%% Logs who run the suite.
print_who(Host,User) ->
    UserStr = case User of
		  "" -> "";
		  _ -> " by " ++ User
	      end,
    print(html, "Run~s on ~s", [UserStr,Host]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% output({Level,Message},Sender) -> ok
%% Level = integer() | minor | major | html
%% Message = string() | [integer()]
%% Sender = string() | internal
%%
%% Outputs the message on the channels indicated by Level. If Level is an
%% atom, only the corresponding channel receives the output. When Level is
%% an integer console, major and/or minor log file will receive output
%% depending on the user set thresholds (see get_levels/0, set_levels/3)
%%
%% When printing on the console, the message is prefixed with the test
%% suite's name. In case a name is not set (yet), Sender is used.
%%
%% When not outputting to the console, and the Sender is 'internal',
%% the message is prefixed with "=== ", so that it will be apparent that
%% the message comes from the test server,and not the test suite itself.

output({Level,Msg}, Sender) when integer(Level) ->
    SumLev = get(test_server_summary_level),
    if  Level =< SumLev ->
	    output_to_fd(stdout,Msg,Sender);
	true ->
	    ok
    end,
    MajLev = get(test_server_major_level),
    if  Level =< MajLev ->
	    output_to_fd(get(test_server_major_fd), Msg, Sender);
	true ->
	    ok
    end,
    MinLev = get(test_server_minor_level),
    if  Level >= MinLev ->
	    output_to_fd(get(test_server_minor_fd), Msg, Sender);
	true ->
	    ok
    end;
output({minor,Bytes},Sender) when list(Bytes) ->
    output_to_fd(get(test_server_minor_fd),Bytes,Sender);
output({major,Bytes},Sender) when list(Bytes) ->
    output_to_fd(get(test_server_major_fd),Bytes,Sender);
output({minor,Bytes},Sender) when binary(Bytes) ->
    output_to_fd(get(test_server_minor_fd),binary_to_list(Bytes),Sender);
output({major,Bytes},Sender) when binary(Bytes) ->
    output_to_fd(get(test_server_major_fd),binary_to_list(Bytes),Sender);
output({html,Msg},_Sender) ->
    case get(test_server_html_fd) of
	undefined ->
	    ok;
	Fd ->
	    io:put_chars(Fd,Msg),
	    case file:position(Fd, {cur, 0}) of
		{ok, Pos} ->
		    %% We are writing to a seekable file.  Finalise so
		    %% we get complete valid (and viewable) HTML code.
		    %% Then rewind to overwrite the finalising code.
		    io:put_chars(Fd, "\n</table>\n</body>\n</html>\n"),
		    file:position(Fd, Pos);
		{error, epipe} ->
		    %% The file is not seekable.  We cannot erase what
		    %% we've already written --- so the reader will
		    %% have to wait until we're done.
		    ok
	    end
    end;
output({minor,Data},Sender) ->
    output_to_fd(get(test_server_minor_fd),
		 lists:flatten(io_lib:format(
				 "Unexpected output: ~p~n", [Data])),Sender);
output({major,Data},Sender) ->
    output_to_fd(get(test_server_major_fd),
		 lists:flatten(io_lib:format(
				 "Unexpected output: ~p~n", [Data])),Sender).

output_to_fd(stdout,Msg,Sender) ->
    Name =
	case get(test_server_name) of
	    undefined -> Sender;
	    Other -> Other
	end,
    io:format("Testing ~s: ~s\n",[Name, lists:flatten(Msg)]);
output_to_fd(undefined,_Msg,_Sender) ->
    ok;
output_to_fd(Fd,[$=|Msg],internal) ->
    io:put_chars(Fd,[$=]),
    io:put_chars(Fd,Msg),
    io:put_chars(Fd,"\n");
output_to_fd(Fd,Msg,internal) ->
    io:put_chars(Fd,[$=,$=,$=,$ ]),
    io:put_chars(Fd,Msg),
    io:put_chars(Fd,"\n");
output_to_fd(Fd, Msg, _Sender) ->
    io:put_chars(Fd, Msg),
    io:put_chars(Fd, "\n").

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% make_config(Config) -> NewConfig
%% Config = [{Key,Value},...]
%% NewConfig = [{Key,Value},...]
%%
%% Creates a configuration list (currently returns it's input)

make_config(Initial) ->
    Initial.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% update_config(Config,Update) -> NewConfig
%% Config = [{Key,Value},...]
%% Update = [{Key,Value},...] | {Key,Value}
%% NewConfig = [{Key,Value},...]
%%
%% Adds or replaces the key-value pairs in config with those in update.
%% Returns the updated list.

update_config(Config,{Key,Val}) ->
    case lists:keymember(Key,1,Config) of
	true ->
	    lists:keyreplace(Key,1,Config,{Key,Val});
	false ->
	    [{Key,Val}|Config]
    end;
update_config(Config,[Assoc|Assocs]) ->
    NewConfig = update_config(Config,Assoc),
    update_config(NewConfig,Assocs);
update_config(Config,[]) ->
    Config.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% collect_cases(CurMod,TopCase,SkipList) -> BasicCaseList | {error,Reason}
%% CurMod = atom()
%% TopCase = term()
%% SkipList = [term(),...]
%% BasicCaseList = [term(),...]
%%
%% Parses the given test goal(s) in TopCase, and transforms them to a
%% simple list of test cases to call, when executing the test suite.
%%
%% CurMod is the "current" module, that is, the module the last instruction
%% was read from. May be be set to 'none' initially.
%%
%% SkipList is the list of test cases to skip and requirements to deny.
%%
%% The BasicCaseList is built out of TopCase, which may be any of the
%% following terms:
%%
%% []                        Nothing is added
%% List list()               The list is decomposed, and each element is
%%                           treated according to this table
%% Case atom()               CurMod:Case(suite) is called
%% {module,Case}             CurMod:Case(suite) is called
%% {Module,Case}             Module:Case(suite) is called
%% {module,Module,Case}      Module:Case(suite) is called
%% {module,Module,Case,Args} Module:Case is called with Args as arguments
%% {dir,Dir}                 All modules *_SUITE in the named directory
%%                           are listed, and each Module:all(suite) is called
%% {dir,Dir,Pattern}         All modules <Pattern>_SUITE in the named dir
%%                           are listed, and each Module:all(suite) is called
%% {conf,InitMF,Cases,FinMF} InitMF is placed in the BasicCaseList, then
%%                           Cases is treated according to this table, then
%%                           FinMF is placed in the BasicCaseList. InitMF
%%                           and FinMF are configuration manipulation
%%                           functions. See below.
%% {make,InitMFA,Cases,FinMFA} 
%%                           InitMFA is placed in the BasicCaseList, then
%%                           Cases is treated according to this table, then
%%                           FinMFA is placed in the BasicCaseList. InitMFA
%%                           and FinMFA are make/unmake functions. If InitMFA 
%%                           fails, Cases are not run. InitMFA and FinMFA are
%%                           always run on the host - not on target.
%%
%% When a function is called, above, it means that the function is invoked
%% and the return is expected to be:
%%
%% []                        Leaf case
%% {req,ReqList}             Kept for backwards compatibility - same as []
%% {req,ReqList,Cases}       Kept for backwards compatibility - 
%%                           Cases parsed recursively with collect_cases/3
%% Cases (list)              Recursively parsed with collect_cases/3
%%
%% Leaf cases are added to the BasicCaseList as Module:Case(Config). Each
%% case is checked against the SkipList. If present, a skip instruction
%% is inserted instead, which only prints the case name and the reason
%% why the case was skipped in the log files.
%%
%% Configuration manipulation functions are called with the current
%% configuration list as only argument, and are expected to return a new
%% configuration list. Such a pair of function may, for example, start a
%% server and stop it after a serie of test cases. 
%%
%% SkipCases is expected to be in the format:
%%
%% Other                     Recursively parsed with collect_cases/3
%% {Mod,Comment}             Skip Mod, with Comment
%% {Mod,Funcs,Comment}       Skip listed functions in Mod with Comment
%% {Mod,Func,Comment}        Skip named function in Mod with Comment
%%
-record(cc, {mod,				%Current module
	     skip}).				%Skip list

collect_all_cases(Top, Skip) when list(Skip) ->
    case collect_cases(Top, #cc{mod=[],skip=Skip}) of
	{ok,Cases,_St} -> Cases;
	Other -> Other
    end.

collect_cases([], St) -> {ok,[],St};
collect_cases([Case|Cs0], St0) ->
    case collect_cases(Case, St0) of
	{ok,FlatCases1,St1} ->
	    case collect_cases(Cs0, St1) of
		{ok,FlatCases2,St} ->
		    {ok,FlatCases1 ++ FlatCases2,St};
		{error,_Reason}=Error -> Error
	    end;
	{error,_Reason}=Error -> Error
    end;

   
collect_cases({module,Case}, St) when atom(Case), atom(St#cc.mod) ->
    collect_case({St#cc.mod,Case}, St);

collect_cases({module,Mod,Case}, St) ->
    collect_case({Mod,Case}, St);

collect_cases({module,Mod,Case,Args}, St) ->
    collect_case({Mod,Case,Args}, St);
collect_cases({dir,SubDir}, St) ->
    collect_files(SubDir, "*_SUITE", St);
collect_cases({dir,SubDir,Pattern}, St) ->
    collect_files(SubDir, Pattern++"*", St);
collect_cases({conf,InitF,CaseList,FinMF}, St) when atom(InitF) ->
    collect_cases({conf,{St#cc.mod,InitF},CaseList,FinMF}, St);
collect_cases({conf,InitMF,CaseList,FinF}, St) when atom(FinF) ->
    collect_cases({conf,InitMF,CaseList,{St#cc.mod,FinF}}, St);
collect_cases({conf,InitMF,CaseList,FinMF}, St0) ->
    case collect_cases(CaseList, St0) of
	{ok,[],_St}=Empty -> Empty;
	{ok,FlatCases,St} ->
	    Ref = make_ref(),
	    {ok,[{conf,Ref,InitMF}|FlatCases ++ [{conf,Ref,FinMF}]],St};
	{error,_Reason}=Error -> Error
    end;
collect_cases({make,InitMFA,CaseList,FinMFA}, St0) ->
    case collect_cases(CaseList, St0) of
	{ok,[],_St}=Empty -> Empty;
	{ok,FlatCases,St} ->
	    Ref = make_ref(),
	    {ok,[{make,Ref,InitMFA}|FlatCases ++ 
		 [{make,Ref,FinMFA}]],St};
	{error,_Reason}=Error -> Error
    end;

collect_cases({Module, Cases}, St) when list(Cases)  -> 
    case (catch collect_case(Cases, St#cc{mod=Module}, [])) of
	{ok, NewCases, NewSt} ->
 	    {ok, NewCases, NewSt};
 	Other ->
	    {error, Other}
     end;

collect_cases({_Mod,_Case}=Spec, St) ->
    collect_case(Spec, St);

collect_cases({_Mod,_Case,_Args}=Spec, St) ->
    collect_case(Spec, St);
collect_cases(Case, St) when atom(Case), atom(St#cc.mod) ->
    collect_case({St#cc.mod,Case}, St);
collect_cases(Other, _St) ->
    {error,{bad_subtest_spec,Other}}.

collect_case(MFA, St) ->
    case in_skip_list(MFA, St#cc.skip) of
	{true,Comment} ->
	    {ok,[{skip_case,{MFA,Comment}}],St};
	false ->
	    case MFA of
		{Mod,Case} -> collect_case_invoke(Mod, Case, MFA, St);
		{_Mod,_Case,_Args} -> {ok,[MFA],St}
	    end
    end.

collect_case([], St, Acc) ->
    {ok, Acc, St};

collect_case([Case | Cases], St, Acc) ->
    {ok, FlatCases, NewSt}  = collect_case({St#cc.mod, Case}, St),
    collect_case(Cases, NewSt, Acc ++ FlatCases).

collect_case_invoke(Mod, Case, MFA, St) ->
    case os:getenv("TEST_SERVER_FRAMEWORK") of
	false ->
	    case catch apply(Mod, Case, [suite]) of
		{'EXIT',_} -> 
		    {ok,[MFA],St};
		Suite -> 
		    collect_subcases(Mod,Case,MFA,St,Suite)
	    end;
	_ ->
	    Suite = test_server_sup:framework_call(get_suite,[Mod,Case],[]),
	    collect_subcases(Mod,Case,MFA,St,Suite)
    end.

collect_subcases(Mod, Case, MFA, St, Suite) ->	    
    case Suite of
	[] -> {ok,[MFA],St};
%%%! --- START Kept for backwards compatibilty ---
%%%! Requirements are not used
	{req,ReqList} ->
	    collect_case_deny(Mod, Case, MFA, ReqList, [], St);
	{req,ReqList,SubCases} ->
	    collect_case_deny(Mod, Case, MFA, ReqList, SubCases, St);
%%%! --- END Kept for backwards compatibilty ---
	{Skip,Reason} when Skip==skip; Skip==skipped ->
	    {ok,[{skip_case,{MFA,Reason}}],St};
	SubCases ->
	    collect_case_subcases(Mod, Case, SubCases, St)
    end.


collect_case_subcases(Mod, Case, SubCases, St0) ->
    OldMod = St0#cc.mod,
    case collect_cases(SubCases, St0#cc{mod=Mod}) of
	{ok,FlatCases,St} ->
	    {ok,FlatCases,St#cc{mod=OldMod}};
	{error,Reason} ->
	    {error,{{Mod,Case},Reason}}
    end.

collect_files(Dir, Pattern, St) ->
    {ok,Cwd} = file:get_cwd(),
    Dir1 = filename:join(Cwd, Dir),
    Wc = filename:join([Dir1,Pattern++code:objfile_extension()]),
    case catch filelib:wildcard(Wc) of
	{'EXIT', Reason} ->
	    io:format("Could not collect files: ~p~n", [Reason]),
	    {error,{collect_fail,Dir,Pattern}};
	Mods0 ->
	    Mods = [{path_to_module(Mod),all} || Mod <- lists:sort(Mods0)],
	    collect_cases(Mods, St)
    end.

path_to_module(Path) ->
    list_to_atom(filename:rootname(filename:basename(Path))).

collect_case_deny(Mod, Case, MFA, ReqList, SubCases, St) ->
    case {check_deny(ReqList, St#cc.skip),SubCases} of
	{{denied,Comment},_SubCases} ->
	    {ok,[{skip_case,{MFA,Comment}}],St};
	{granted,[]} ->
	    {ok,[MFA],St};
	{granted,SubCases} ->
	    collect_case_subcases(Mod, Case, SubCases, St)
    end.
    
check_deny([Req|Reqs], DenyList) ->
    case check_deny_req(Req, DenyList) of
	{denied,_Comment}=Denied -> Denied;
	granted -> check_deny(Reqs, DenyList)
    end;
check_deny([],_DenyList) -> granted;
check_deny(Req,DenyList) -> check_deny([Req], DenyList).

check_deny_req({Req,Val}, DenyList) ->
    %%io:format("ValCheck ~p=~p in ~p\n",[Req,Val,DenyList]),
    case lists:keysearch(Req, 1, DenyList) of
	{value,{_Req,DenyVal}} when Val >= DenyVal ->
	    {denied,io_lib:format("Requirement ~p=~p",[Req,Val])};
	_ ->
	    check_deny_req(Req,DenyList)
    end;
check_deny_req(Req,DenyList) ->
    case lists:member(Req, DenyList) of
	true -> {denied,io_lib:format("Requirement ~p",[Req])};
	false -> granted
    end.

in_skip_list({Mod,Func,_Args},SkipList) ->
    in_skip_list({Mod,Func},SkipList);    
in_skip_list({Mod,Func},[{Mod,Funcs,Comment}|SkipList]) when list(Funcs) ->
    case lists:member(Func,Funcs) of
	true ->
	    {true,Comment};
	_ ->
	    in_skip_list({Mod,Func},SkipList)
    end;
in_skip_list({Mod,Func},[{Mod,Func,Comment}|_SkipList]) ->
    {true,Comment};
in_skip_list({Mod,_Func},[{Mod,Comment}|_SkipList]) ->
    {true,Comment};
in_skip_list({Mod,Func},[_|SkipList]) ->
    in_skip_list({Mod,Func},SkipList);
in_skip_list(_,[]) ->
    false.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% spawn_tester(Mod,Func,Args,Dir,Name,Levels,ExtraTools)->Pid
%% Mod = atom()
%% Func = atom()
%% Args = [term(),...]
%% Dir = string()
%% Name = string()
%% Levels = {integer(),integer(),integer()}
%% ExtraTools = [ExtraTool,...]
%% ExtraTool = CoverInfo | TraceInfo
%%
%% Spawns a test suite execute-process, just an ordinary spawn, except
%% that it will set a lot of dictionary information before starting the
%% named function.Also, the execution is timed and protected by a catch.
%% When the named function is done executing (an entire test suite), a
%% summary of the results is inserted into the log files.
spawn_tester(Mod,Func,Args,Dir,Name,Levels,ExtraTools) ->
    spawn_link(
      fun() -> init_tester(Mod,Func,Args,Dir,Name,Levels,ExtraTools) 
      end).

init_tester(Mod, Func, Args, Dir, Name, {SumLev, MajLev, MinLev}, ExtraTools) ->
    process_flag(trap_exit,true),
    put(test_server_name,Name),
    put(test_server_dir,Dir),
    put(test_server_total_time,0),
    put(test_server_ok,0),
    put(test_server_failed,0),
    put(test_server_skipped,0),
    put(test_server_summary_level,SumLev),
    put(test_server_major_level,MajLev),
    put(test_server_minor_level,MinLev),
    StartedExtraTools = start_extra_tools(ExtraTools),
    {TimeMy,Result} = ts_tc(Mod,Func,Args),
    stop_extra_tools(StartedExtraTools),
    case Result of
	{'EXIT',test_suite_done} ->
	    print(25,"DONE, normal exit",[]);
	{'EXIT',_Pid,Reason} ->
	    print(1,"EXIT, reason ~p",[Reason]);
	{'EXIT',Reason} ->
	    print(1,"EXIT, reason ~p",[Reason]);
	_Other ->
	    print(25,"DONE",[])
    end,
    Time = TimeMy/1000000,
    SuccessStr =
	case get(test_server_failed) of
	    0 -> "Ok";
	    _ -> "FAILED"
	end,
    SkipStr =
	case get(test_server_skipped) of
	    0 -> "";
	    N -> io_lib:format(", ~p Skipped",[N])
	end,
    print(html,"<tr><td></td><td><b>TOTAL</b></td><td></td><td>~.3fs</td>"
	  "<td><b>~s</b></td><td>~p Ok, ~p Failed~s of ~p</td></tr>\n",
	  [Time,SuccessStr,get(test_server_ok),get(test_server_failed),
	   SkipStr,get(test_server_cases)]).

%% timer:tc/3
ts_tc(M, F, A) ->
    Before = erlang:now(),
    Val = (catch apply(M, F, A)),
    After = erlang:now(),
    Elapsed =
	(element(1,After)*1000000000000
	 +element(2,After)*1000000+element(3,After)) -
	(element(1,Before)*1000000000000
	 +element(2,Before)*1000000+element(3,Before)),
    {Elapsed, Val}.


start_extra_tools(ExtraTools) ->
    start_extra_tools(ExtraTools,[]).
start_extra_tools([{cover,App,Analyse} | ExtraTools], Started) ->
    case cover_compile(App) of
	{ok,AnalyseMods} ->
	    start_extra_tools(ExtraTools,
			      [{cover,App,Analyse,AnalyseMods}|Started]);
	{error,_} ->
	    start_extra_tools(ExtraTools,Started)
    end;
start_extra_tools([],Started) ->
    Started.


stop_extra_tools(ExtraTools) ->
    TestDir = get(test_server_log_dir_base),
    case lists:keymember(cover,1,ExtraTools) of
	false ->
	    write_default_coverlog(TestDir);
	true ->
	    ok
    end,
    stop_extra_tools(ExtraTools,TestDir).

stop_extra_tools([{cover,App,Analyse,AnalyseMods}|ExtraTools],TestDir) ->
    cover_analyse(App,Analyse,AnalyseMods,TestDir),
    stop_extra_tools(ExtraTools,TestDir);
stop_extra_tools([],_) ->
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% timestamp_filename_get(Leader) -> string()
%% Leader = string()
%%
%% Returns a string consisting of Leader concatenated with the current
%% date and time. The resulting string is suitable as a filename.
timestamp_filename_get(Leader) ->
    timestamp_get_internal(Leader,
			   "~s~w-~2.2.0w-~2.2.0w_~2.2.0w.~2.2.0w.~2.2.0w").

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% timestamp_get(Leader) -> string()
%% Leader = string()
%%
%% Returns a string consisting of Leader concatenated with the current
%% date and time. The resulting string is suitable for display.
timestamp_get(Leader) ->
    timestamp_get_internal(Leader,
			   "~s~w-~2.2.0w-~2.2.0w ~2.2.0w:~2.2.0w:~2.2.0w").

timestamp_get_internal(Leader,Format) ->
    {YY,MM,DD,H,M,S} = time_get(),
    io_lib:format(Format,[Leader,YY,MM,DD,H,M,S]).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% get_target_info() -> #target_info
%%
%% Returns a record containing system information for target
get_target_info() ->
    controller_call(get_target_info).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% time_get() -> {YY,MM,DD,H,M,S}
%% YY = integer()
%% MM = integer()
%% DD = integer()
%% H = integer()
%% M = integer()
%% S = integer()
%%
%% Returns the current Year,Month,Day,Hours,Minutes,Seconds.
%% The function checks that the date doesn't wrap while calling
%% getting the time.
time_get() ->
    {YY,MM,DD} = date(),
    {H,M,S} = time(),
    case date() of
	{YY,MM,DD} ->
	    {YY,MM,DD,H,M,S};
	_NewDay ->
	    %% date changed between call to date() and time(), try again
	    time_get()
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% format(Format) -> IoLibReturn
%% format(Detail,Format) -> IoLibReturn
%% format(Format,Args) -> IoLibReturn
%% format(Detail,Format,Args) -> IoLibReturn
%% Detail = integer()
%% Format = string()
%% Args = [term(),...]
%% IoLibReturn = term()
%%
%% Logs the Format string and Args, similar to io:format/1/2 etc. If
%% Detail is not specified, the default detail level (which is 50) is used.
%% Which log files the string will be logged in depends on the thresholds
%% set with set_levels/3. Typically with default detail level, only the
%% minor log file is used.
format(Format) ->
    format(minor, Format, []).

format(major, Format) ->
    format(major, Format, []);
format(minor, Format) ->
    format(minor, Format, []);
format(Detail, Format) when integer(Detail) ->
    format(Detail, Format, []);
format(Format, Args) ->
    format(minor, Format, Args).

format(Detail, Format, Args) ->
    Str =
	case catch io_lib:format(Format,Args) of
	    {'EXIT',_} ->
		io_lib:format("illegal format; ~p with args ~p.\n",
			      [Format,Args]);
	    Valid -> Valid
	end,
    log({Detail, Str}).

log(Msg) ->
    output(Msg,self()).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% start_node(SlaveName, Type, Options) ->
%%                   {ok, Slave} | {error, Reason}
%%
%% Called by test_server. See test_server:start_node/3 for details

start_node(Name, Type, Options) ->
    T = 10 * ?ACCEPT_TIMEOUT, % give some extra time
    format(minor, "=== Attempt to start ~w node ~p with options ~p",
	   [Type, Name, Options]),
    case controller_call({start_node,Name,Type,Options},T) of
	{{ok,Nodename}, Host, Cmd, Info, Warning} ->
	    format(minor,
		   "=== Successfully started node ~p on ~p with command: ~p",
		   [Nodename, Host, Cmd]),
	    format(major, "=node_start   ~p", [Nodename]),
	    case Info of
		[] -> ok;
		_ -> format(minor,Info)
	    end,
	    case Warning of
		[] -> ok;
		_ -> 
		    format(1, Warning),
		    format(minor, Warning)
	    end,
	    {ok, Nodename};
	{fail,{Ret, Host, Cmd}}  ->
	    format(minor, 
		   "=== Failed to start node ~p on ~p with command: ~p~n"
		   "=== Reason: ~p",
		   [Name, Host, Cmd, Ret]),
	    {fail,Ret};
	{Ret, undefined, undefined} ->
	    format(minor, "=== Failed to start node ~p: ~p",[Name,Ret]),
	    Ret;
	{Ret, Host, Cmd} ->
	    format(minor, 
		   "=== Failed to start node ~p on ~p with command: ~p~n"
		   "=== Reason: ~p",
		   [Name, Host, Cmd, Ret]),
	    Ret
    end.



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% wait_for_node(Node) -> ok | {error,timeout}
%%
%% Wait for a slave/peer node which has been started with
%% the option {wait,false}. This function returns when
%% when the new node has contacted test_server_ctrl again
wait_for_node(Slave) ->
    case catch controller_call({wait_for_node,Slave},10000) of
	{'EXIT',{timeout,_}} -> {error,timeout};
	ok -> ok
    end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% stop_node(Name) -> ok | {error,Reason}
%%
%% Clean up - test_server will stop this node
stop_node(Slave) ->
    controller_call({stop_node,Slave}).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                     DEBUGGER INTERFACE                    %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
i() ->
    hformat("Pid", "Initial Call", "Current Function", "Reducts", "Msgs"),
    Line=lists:duplicate(27, "-"),
    hformat(Line, Line, Line, Line, Line),
    display_info(processes(), 0, 0).

p(A,B,C) ->
    pinfo(ts_pid(A,B,C)).
p(X) when atom(X) ->
    pinfo(whereis(X));
p({A,B,C}) ->
    pinfo(ts_pid(A,B,C));
p(X) ->
    pinfo(X).

t() -> 
    t(wall_clock).
t(X) ->
    element(1, statistics(X)).

pi(Item,X) ->
    lists:keysearch(Item,1,p(X)).
pi(Item,A,B,C) ->
    lists:keysearch(Item,1,p(A,B,C)).

%% c:pid/3
ts_pid(X,Y,Z) when integer(X), integer(Y), integer(Z) ->
    list_to_pid("<" ++ integer_to_list(X) ++ "." ++
		integer_to_list(Y) ++ "." ++
		integer_to_list(Z) ++ ">").


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% display_info(Pids,Reductions,Messages) -> void()
%% Pids = [pid(),...]
%% Reductions = integer()
%% Messaged = integer()
%%
%% Displays info, similar to c:i() about the processes in the list Pids.
%% Also counts the total number of reductions and msgs for the listed
%% processes, if called with Reductions = Messages = 0.

display_info([Pid|T], R, M) ->
    case pinfo(Pid) of
	undefined ->
	    display_info(T, R, M);
	Info ->
	    Call = fetch(initial_call, Info),
	    Curr = case fetch(current_function, Info) of
		       {Mod,F,Args} when list(Args) ->
			   {Mod,F,length(Args)};
		       Other ->
			   Other
		   end,
	    Reds  = fetch(reductions, Info), 
	    LM = length(fetch(messages, Info)),
	    pformat(io_lib:format("~w", [Pid]),
		    io_lib:format("~w", [Call]),
		    io_lib:format("~w", [Curr]), Reds, LM),
	    display_info(T, R+Reds, M + LM)
    end;
display_info([], R, M) ->
    Line=lists:duplicate(27, "-"),
    hformat(Line, Line, Line, Line, Line),
    pformat("Total", "", "", R, M).

hformat(A1, A2, A3, A4, A5) ->
    io:format("~-10s ~-27s ~-27s ~8s ~4s~n", [A1,A2,A3,A4,A5]).

pformat(A1, A2, A3, A4, A5) ->
    io:format("~-10s ~-27s ~-27s ~8w ~4w~n", [A1,A2,A3,A4,A5]).

fetch(Key, Info) ->
    case lists:keysearch(Key, 1, Info) of
	{value, {_, Val}} ->
	    Val;
	_ ->
	    0
    end.

pinfo(P) ->
    Node = node(),
    case node(P) of
	Node ->
	    process_info(P);
	_ ->
	    rpc:call(node(P),erlang,process_info,[P])
    end.




%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Internal functions handling target communication over socket

%%
%% Generic send function for communication with target
%%
request(Sock,Request) ->
    gen_tcp:send(Sock,<<1,(term_to_binary(Request))/binary>>).

%%
%% Receive and decode request on job specific socket
%% Used when test is running on a remote target
%%
read_job_sock_loop(Sock) ->
    case gen_tcp:recv(Sock,0) of
	{error,Reason} ->
	    gen_tcp:close(Sock),
	    exit({controller,connection_lost,Reason});
	{ok,<<1,Request/binary>>} ->
	    case decode(binary_to_term(Request)) of
		ok -> 
		    read_job_sock_loop(Sock);
		{stop,Result} ->
		    Result
	    end
    end.

decode({apply,{M,F,A}}) ->
    apply(M,F,A),
    ok;
decode({sync_apply,{M,F,A}}) -> 
    R = apply(M,F,A),
    request(get(test_server_ctrl_job_sock),{sync_result,R}),
    ok;
decode({sync_result,Result}) ->
    {stop,Result};
decode({test_case_result,Result}) ->
    {stop,Result}; 
decode({privdir,empty_priv_dir}) ->
    {stop,ok};
decode({{privdir,PrivDirTar},TarBin}) ->
    Root = get(test_server_log_dir_base),
    unpack_tar(Root,PrivDirTar,TarBin),
    {stop,ok};
decode({crash_dumps,no_crash_dumps}) ->
    {stop,ok};
decode({{crash_dumps,CrashDumpTar},TarBin}) ->
    Dir = test_server_sup:crash_dump_dir(),
    unpack_tar(Dir,CrashDumpTar,TarBin),
    {stop,ok}.

unpack_tar(Dir,TarFileName0,TarBin) ->
    TarFileName = filename:join(Dir,TarFileName0),
    ok = file:write_file(TarFileName,TarBin),
    ok = erl_tar:extract(TarFileName,[compressed,{cwd,Dir}]),
    ok = file:delete(TarFileName).
    

%%%-----------------------------------------------------------------
%%% Support function for COVER
%%%
%%% A module is included in the cover analysis if
%%% - it belongs to the tested application and is not listed in the 
%%%   {exclude,List} part of the App.cover file
%%% - it does not belong to the application, but is listed in the
%%%   {include,List} part of the App.cover file
%%% - it does not belong to the application, but is listed in the 
%%%   cross.cover file (in the test_server application) under 'all' 
%%%   or under the tested application.
%%%
%%% The modules listed in the cross.cover file are modules that are
%%% hevily used by other applications than the one they belong
%%% to. After all tests are completed, these modules can be analysed
%%% with coverage data from all tests - see cross_cover_analyse/1. The
%%% result is stored in a file called cross_cover.html in the
%%% run.<timestamp> directory of the application the modules belong
%%% to.
%%%
%%% For example, the lists module is listed in cross.cover to be
%%% included in all tests. lists belongs to the stdlib
%%% application. cross_cover_analyse/1 will create a file named
%%% cross_cover.html under the newest stdlib.logs/run.xxx directory,
%%% where the coverage result for the lists module from all tests is
%%% presented.
%%%
%%% The lists module is also presented in the normal coverage log
%%% for stdlib, but that only includes the coverage achieved by
%%% the stdlib tests themselves.
%%%
%%% The Cross cover file cross.cover contains elements like this:
%%% {App,Modules}.
%%% where App can be an application name or the atom all. The
%%% application (or all applications) shall cover compile the listed
%%% Modules.


%% Cover compilation
%% The compilation is executed on the target node
cover_compile({App,CoverFile}) ->
    Cross = get_cross_modules(App),
    {Exclude,Include} = read_cover_file(CoverFile),
    What = {App,Exclude,Include,Cross},
    case get(test_server_ctrl_job_sock) of
	undefined ->
	    %% local target
	    test_server:cover_compile(What);
	JobSock ->
	    %% remote target
	    request(JobSock,{sync_apply,{test_server,cover_compile,[What]}}),
	    read_job_sock_loop(JobSock)
    end.

%% Read the coverfile for an application and return a list of modules
%% that are members of the application but shall not be compiled
%% (Exclude), and a list of modules that are not members of the
%% application but shall be compiled (Include).
read_cover_file(none) ->
    {[],[]};
read_cover_file(CoverFile) ->
    case file:consult(CoverFile) of
	{ok,List} ->
	    case check_cover_file(List,[],[]) of
		{ok,Exclude,Include} -> {Exclude,Include};
		error ->
		    io:fwrite("Faulty format of CoverFile ~p\n",[CoverFile]),
		    {[],[]}
	    end;
	{error,Reason} -> 
	    io:fwrite("Can't read CoverFile ~p\nReason: ~p\n",
		      [CoverFile,Reason]),
	    {[],[]}
    end.

check_cover_file([{exclude,all}|Rest],_,Include) ->
    check_cover_file(Rest,all,Include);
check_cover_file([{exclude,Exclude}|Rest],_,Include) ->
    case lists:all(fun(M) -> is_atom(M) end, Exclude) of
	true ->
	    check_cover_file(Rest,Exclude,Include);
	false ->
	    error
    end;
check_cover_file([{include,Include}|Rest],Exclude,_) ->
    case lists:all(fun(M) -> is_atom(M) end, Include) of
	true ->
	    check_cover_file(Rest,Exclude,Include);
	false ->
	    error
    end;
check_cover_file([],Exclude,Include) ->
    {ok,Exclude,Include}.



%% Cover analysis, per application
%% This analysis is executed on the target node once the test is
%% completed for an application. This is not the same as the cross
%% cover analysis, which can be executed on any node after the tests
%% are finshed.
%%
%% This per application analysis writes the file cover.html in the
%% application's run.<timestamp> directory.
cover_analyse({App,CoverFile},Analyse,AnalyseMods,TestDir) ->
    write_default_cross_coverlog(TestDir),

    {ok,CoverLog} = file:open(filename:join(TestDir,?coverlog_name),write),
    write_coverlog_header(CoverLog),
    io:fwrite(CoverLog,"<h1>Coverage for application '~w'</h1>\n",[App]),
    io:fwrite(CoverLog,
	      "<p><a href=\"~s\">Coverdata collected over all tests</a></p>",
	      [?cross_coverlog_name]),

    io:fwrite(CoverLog,"<p>CoverFile: ~p\n",[CoverFile]),
    {_,Excluded} = read_cover_file(CoverFile),
    io:fwrite(CoverLog,"<p>Excluded modules: <code>~p</code>\n",[Excluded]),
    Coverage = cover_analyse(Analyse,AnalyseMods),
    TotPercent = write_cover_result_table(CoverLog,Coverage),
    file:write_file(filename:join(TestDir,?cover_total),
		    term_to_binary(TotPercent)).

cover_analyse(Analyse,AnalyseMods) ->
    TestDir = get(test_server_log_dir_base),
    case get(test_server_ctrl_job_sock) of
	undefined ->
	    %% local target
	    test_server:cover_analyse({Analyse,TestDir},AnalyseMods);
	JobSock ->
	    %% remote target
	    request(JobSock,{sync_apply,{test_server,
					 cover_analyse,
					 [Analyse,AnalyseMods]}}),
	    read_job_sock_loop(JobSock)
    end.


%% Cover analysis, cross application
%% This can be executed on any node after all tests are finished.
%% The node's current directory must be the same as when the tests
%% were run.
cross_cover_analyse(Analyse) ->
    CoverdataFiles = get_coverdata_files(),
    lists:foreach(fun(CDF) -> cover:import(CDF) end, CoverdataFiles),
    io:fwrite("Cover analysing... ",[]),
    DetailsFun = 
	case Analyse of
	    details ->
		fun(Dir,M) -> 
			OutFile = filename:join(Dir,
						atom_to_list(M) ++
						".CROSS_COVER.html"),
			cover:analyse_to_file(M,OutFile,[html]),
			{file,OutFile}
		end;
	    _ ->
		fun(_,_) -> undefined end
	end,
    CrossModules = [Mod || Mod <- get_all_cross_modules(), 
			   lists:member(Mod,cover:imported_modules())],
    SortedModules = sort_modules(CrossModules,[]),
    Coverage = analyse_apps(SortedModules,DetailsFun,[]),
    cover:stop(),
    write_cross_cover_logs(Coverage).

%% For each application from which there are modules listed in the
%% cross.cover, write a cross cover log (cross_cover.html).
write_cross_cover_logs([{App,Coverage}|T]) ->
    case last_test_for_app(App) of
	false -> 
	    ok;
	Dir ->
	    CoverLogName = filename:join(Dir,?cross_coverlog_name),
	    {ok,CoverLog} = file:open(CoverLogName,write),
	    write_coverlog_header(CoverLog),
	    io:fwrite(CoverLog,
		      "<h1>Coverage results for \'~w\' from all tests</h1>\n",
		      [App]),
	    write_cover_result_table(CoverLog,Coverage),
	    io:fwrite("Written file ~p\n",[CoverLogName])
    end,
    write_cross_cover_logs(T);
write_cross_cover_logs([]) ->
    io:fwrite("done\n",[]).    

%% Find all exported coverdata files. First find all the latest
%% run.<timestamp> directories, and the check if there is a file named
%% all.coverdata.
get_coverdata_files() ->
    PossibleFiles = [last_coverdata_file(Dir) || 
			Dir <- filelib:wildcard([$*|?logdir_ext]),
			filelib:is_dir(Dir)],
    [File || File <- PossibleFiles, filelib:is_file(File)].

last_coverdata_file(Dir) ->
    LastDir = last_test(filelib:wildcard(filename:join(Dir,"run.[1-2]*")),false),
    filename:join(LastDir,"all.coverdata").


%% Find the latest run.<timestamp> directory for the given application.
last_test_for_app(App) ->
    AppLogDir = atom_to_list(App)++?logdir_ext,
    last_test(filelib:wildcard(filename:join(AppLogDir,"run.[1-2]*")),false).

last_test([Run|Rest], false) ->
    last_test(Rest, Run);
last_test([Run|Rest], Latest) when Run > Latest ->
    last_test(Rest, Run);
last_test([_|Rest], Latest) ->
    last_test(Rest, Latest);
last_test([], Latest) ->
    Latest.
    
%% Sort modules according to the application they belong to.
%% Return [{App,LastTestDir,ModuleList}]
sort_modules([M|Modules],Acc) ->
    App = get_app(M),
    Acc1 = 
	case lists:keysearch(App,1,Acc) of
	    {value,{App,LastTest,List}} ->
		lists:keyreplace(App,1,Acc,{App,LastTest,[M|List]});
	    false ->
		[{App,last_test_for_app(App),[M]}|Acc]
	end,
    sort_modules(Modules,Acc1);
sort_modules([],Acc) ->
    Acc.

get_app(Module) ->
    Beam = code:which(Module),
    AppDir = filename:basename(filename:dirname(filename:dirname(Beam))),
    [AppStr|_] = string:tokens(AppDir,"-"),
    list_to_atom(AppStr).


%% For each application, analyse all modules
%% Used for cross cover analysis.
analyse_apps([{App,LastTest,Modules}|T],DetailsFun,Acc) ->
    Cov = analyse_modules(LastTest,Modules,DetailsFun,[]),
    analyse_apps(T,DetailsFun,[{App,Cov}|Acc]);
analyse_apps([],_DetailsFun,Acc) ->
    Acc.

%% Analyse each module
%% Used for cross cover analysis.
analyse_modules(Dir,[M|Modules],DetailsFun,Acc) ->
    {ok,{M,{Cov,NotCov}}} = cover:analyse(M,module),
    Acc1 = [{M,{Cov,NotCov,DetailsFun(Dir,M)}}|Acc],
    analyse_modules(Dir,Modules,DetailsFun,Acc1);
analyse_modules(_Dir,[],_DetailsFun,Acc) ->
    Acc.


%% Read the cross cover file (cross.cover)
get_all_cross_modules() ->
    get_cross_modules(all).
get_cross_modules(App) ->
    case file:consult(?cross_cover_file) of
	{ok,List} -> 
	    get_cross_modules(App,List,[]);
	_X -> 
	    []
    end.

get_cross_modules(App,[{_To,Modules}|T],Acc) when App==all->
    get_cross_modules(App,T,Acc ++ Modules);
get_cross_modules(App,[{To,Modules}|T],Acc) when To==App; To==all->
    get_cross_modules(App,T,Acc ++ Modules);
get_cross_modules(App,[_H|T],Acc) ->
    get_cross_modules(App,T,Acc);
get_cross_modules(_App,[],Acc) ->
    Acc.
    


%% Support functions for writing the cover logs (both cross and normal)
write_coverlog_header(CoverLog) ->
    case catch 
	io:fwrite(CoverLog,
		  "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 3.2 Final//EN\">\n"
		  "<!-- autogenerated by '~w'. -->\n"
		  "<html>\n"
		  "<head><title>Coverage results</title></head>\n"
		  "<body bgcolor=\"white\" text=\"black\" "
		  "link=\"blue\" vlink=\"purple\" alink=\"red\">",
		  [?MODULE]) of
	{'EXIT',Reason} ->
	    io:format("\n\nERROR: Could not write normal heading in coverlog.\n"
		      "CoverLog: ~w\n"
		      "Reason: ~p\n",
		      [CoverLog,Reason]),
	    io:format(CoverLog,"<html><body>\n",[]);
	_ ->
	    ok
    end.


format_analyse(M,Cov,NotCov,undefined) ->
    io_lib:fwrite("<tr><td>~w</td>"
		  "<td align=right>~w %</td>"
		  "<td align=right>~w</td>"
		  "<td align=right>~w</td></tr>\n", 
		  [M,pc(Cov,NotCov),Cov,NotCov]);
format_analyse(M,Cov,NotCov,{file,File}) ->
    io_lib:fwrite("<tr><td><a href=\"~s\">~w</a></td>"
		  "<td align=right>~w %</td>"
		  "<td align=right>~w</td>"
		  "<td align=right>~w</td></tr>\n", 
		  [filename:basename(File),M,pc(Cov,NotCov),Cov,NotCov]);
format_analyse(M,Cov,NotCov,{lines,Lines}) ->
    CoverOutName = atom_to_list(M)++".COVER.html",
    {ok,CoverOut} = file:open(CoverOutName,write),
    write_not_covered(CoverOut,M,Lines),
    io_lib:fwrite("<tr><td><a href=\"~s\">~w</a></td>"
		  "<td align=right>~w %</td>"
		  "<td align=right>~w</td>"
		  "<td align=right>~w</td></tr>\n", 
		  [CoverOutName,M,pc(Cov,NotCov),Cov,NotCov]).

pc(0,0) ->
    0;
pc(Cov,NotCov) ->
    round(Cov/(Cov+NotCov)*100).


write_not_covered(CoverOut,M,Lines) ->
    io:fwrite(CoverOut,
	      "<html>\n"
	      "The following lines in module ~w are not covered:\n"
	      "<table border=3 cellpadding=5>\n"
	      "<th>Line Number</th>\n",
	      [M]),
    lists:foreach(fun({{_M,Line},{0,1}}) -> 
			  io:fwrite(CoverOut,"<tr><td>~w</td></tr>\n",[Line]);
		     (_) -> 
			  ok
		  end,
		  Lines),
    io:fwrite(CoverOut,"</table>\n</html>\n",[]).


write_default_coverlog(TestDir) ->
    {ok,CoverLog} = file:open(filename:join(TestDir,?coverlog_name),write),
    write_coverlog_header(CoverLog),
    io:fwrite(CoverLog,"Cover tool is not used\n</body></html>\n",[]),
    file:close(CoverLog).

write_default_cross_coverlog(TestDir) ->
    {ok,CrossCoverLog} = 
	file:open(filename:join(TestDir,?cross_coverlog_name),write),
    write_coverlog_header(CrossCoverLog),
    io:fwrite(CrossCoverLog,
	      "No cross cover modules exist for this application,<br>"
	      "or cross cover analysis is not completed.\n"
	      "</body></html>\n",[]),
    file:close(CrossCoverLog).

write_cover_result_table(CoverLog,Coverage) ->
    io:fwrite(CoverLog,
	      "<p><table border=3 cellpadding=5>\n"
	      "<tr><th>Module</th><th>Covered (%)</th><th>Covered (Lines)</th>"
	      "<th>Not covered (Lines)</th>\n",
	      []),
    {TotCov,TotNotCov} =
	lists:foldl(fun({M,{Cov,NotCov,Details}},{AccCov,AccNotCov}) -> 
			    Str = format_analyse(M,Cov,NotCov,Details),
			    io:fwrite(CoverLog,"~s",[Str]),
			    {AccCov+Cov,AccNotCov+NotCov}
		    end,
		    {0,0},
		    Coverage),
    TotPercent = pc(TotCov,TotNotCov),
    io:fwrite(CoverLog,
	      "<tr><th align=left>Total</th><th align=right>~w %</th>"
	      "<th align=right>~w</th><th align=right>~w</th></tr>\n"
	      "</table>\n"
	      "</body>\n"
	      "</html>\n",
	      [TotPercent,TotCov,TotNotCov]),
    file:close(CoverLog),
    TotPercent.
