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
%%% Purpose : Supervises running of test cases.

-module(ts_run).

-export([run/4]).

-include("ts.hrl").

-import(lists, [map/2,member/2,filter/2,reverse/1]).

-record(state,
	{file,					% File given.
	 mod,					% Module to run.
	 test_server_args,			% Arguments to test server.
	 command,				% Command to run.
	 test_dir,				% Directory for test suite.
	 makefiles,				% List of all makefiles.
	 makefile,				% Current makefile.
	 batch,					% Are we running in batch mode?
	 data_wc,				% Wildcard for data dirs.
	 topcase,				% Top case specification.
	 all					% Set if we have all_SUITE_data
	}).

-define(tracefile,"traceinfo").

%% Options is a slightly modified version of the options given to
%% ts:run. Vars0 are from the variables file.
run(File, Args0, Options, Vars0) ->
    Vars=
	case lists:keysearch(vars, 1, Options) of
	    {value, {vars, Vars1}} ->
		Vars1++Vars0;
	    _ ->
		Vars0
	end,
    {Batch,Runner}  = 
	case {member(interactive, Options), member(batch, Options)} of
	    {false, true} ->
		{true, fun run_batch/3};
	    _ ->
		{false, fun run_interactive/3}
	end,
    HandleTopcase = case member(keep_topcase, Options) of
			true -> [fun copy_topcase/3];
			false -> [fun remove_original_topcase/3,
				  fun init_topcase/3]
		    end,
    MakefileHooks = [fun make_make/3,
		     fun add_make_testcase/3],
    MakeLoop = fun(V, Sp, St) -> make_loop(MakefileHooks, V, Sp, St) end,
    Hooks = [fun init_state/3,
	     fun read_spec_file/3] ++
	     HandleTopcase ++
             [fun run_preinits/3,
	     fun find_makefiles/3,
	     MakeLoop,
	     fun make_test_suite/3,
	     fun add_topcase_to_spec/3,
	     fun write_spec_file/3,
	     fun make_command/3,
	     Runner],
    Args = make_test_server_args(Args0,Options,Vars),
    St = #state{file=File,test_server_args=Args,batch=Batch},
    R = execute(Hooks, Vars, [], St),
    case Batch of
	true -> ts_reports:make_index();
	false -> ok % ts_reports:make_index() is run on the test_server node
    end,
    case R of
	{ok,_,_,_} -> ok;
	Error -> Error
    end.

make_loop(Hooks, Vars0, Spec0, St0) ->
    case St0#state.makefiles of
	[Makefile|Rest] ->
	    case execute(Hooks, Vars0, Spec0, St0#state{makefile=Makefile}) of
		{error, Reason} ->
		    {error, Reason};
		{ok, Vars, Spec, St} ->
		    make_loop(Hooks, Vars, Spec, St#state{makefiles=Rest})
	    end;
	[] ->
	    {ok, Vars0, Spec0, St0}
    end.

execute([Hook|Rest], Vars0, Spec0, St0) ->
    case Hook(Vars0, Spec0, St0) of
	ok ->
	    execute(Rest, Vars0, Spec0, St0);
	{ok, Vars, Spec, St} ->
	    execute(Rest, Vars, Spec, St);
	Error ->
	    Error
    end;
execute([], Vars, Spec, St) ->
    {ok, Vars, Spec, St}.

%% Initialize our internal state.

init_state(Vars, [], St0) ->
    {FileBase,Wc0,Mod} =
	case St0#state.file of
	    {Fil,Mod0} -> {Fil, atom_to_list(Mod0) ++ "*_data",Mod0};
	    Fil -> {Fil,"*_SUITE_data",[]}
	end,
    {ok,Cwd} = file:get_cwd(),
    TestDir = filename:join(filename:dirname(Cwd), FileBase++"_test"),
    case filelib:is_dir(TestDir) of
	true ->
	    Wc = filename:join(TestDir, Wc0),
	    {ok,Vars,[],St0#state{file=FileBase,mod=Mod,
				  test_dir=TestDir,data_wc=Wc}};
	false ->
	    {error,{no_test_directory,TestDir}}
    end.
    
%% Read the spec file for the test suite.

read_spec_file(Vars, _, St) ->
    TestDir = St#state.test_dir,
    File = St#state.file,
    SpecFile = get_spec_filename(Vars, TestDir, File),
    case file:consult(SpecFile) of
	{ok, Spec} -> {ok,Vars,Spec,St};
	{error, Atom} when atom(Atom) ->
	    {error,{no_spec,SpecFile}};
	{error,Reason} ->
	    {error,{bad_spec,file:format_error(Reason)}}
    end.

get_spec_filename(Vars, TestDir, File) ->
    case ts_lib:var(os, Vars) of
	"VxWorks" ->
	    check_spec_filename(TestDir, File, ".spec.vxworks");
	"OSE" ->
	    check_spec_filename(TestDir, File, ".spec.ose");
	"Windows"++_ ->
	    check_spec_filename(TestDir, File, ".spec.win");
	_Other ->
	    filename:join(TestDir, File ++ ".spec")
    end.

check_spec_filename(TestDir, File, Ext) ->
    Spec = filename:join(TestDir, File ++ Ext),
    case filelib:is_file(Spec) of
	true -> Spec;
	false -> filename:join(TestDir, File ++ ".spec")
    end.

%% Remove the top case from the spec file. We will add our own
%% top case later.

remove_original_topcase(Vars, Spec, St) ->
    {ok,Vars,filter(fun ({topcase,_}) -> false;
			(_Other) -> true end, Spec),St}.

%% Initialize our new top case. We'll keep in it the state to be
%%  able to add more to it.

init_topcase(Vars, Spec, St) ->
    TestDir = St#state.test_dir,
    TopCase = 
	case St#state.mod of
	    Mod when atom(Mod) ->
		ModStr = atom_to_list(Mod),
		case filelib:is_file(filename:join(TestDir,ModStr++".erl")) of
		    true -> [{Mod,all}];
		    false ->
			Wc = filename:join(TestDir, ModStr ++ "*_SUITE.erl"),
			[{list_to_atom(filename:basename(M, ".erl")),all} ||
			    M <- filelib:wildcard(Wc)]
		end;
	    _Other ->
		%% Here we used to return {dir,TestDir}. Now we instead
		%% list all suites in TestDir, so we can add make testcases
		%% around it later (see add_make_testcase) without getting
		%% duplicates of the suite. (test_server_ctrl does no longer
		%% check for duplicates of testcases)
		Wc = filename:join(TestDir, "*_SUITE.erl"),
		[{list_to_atom(filename:basename(M, ".erl")),all} ||
		    M <- filelib:wildcard(Wc)]
	end,
    {ok,Vars,Spec,St#state{topcase=TopCase}}.

%% Or if option keep_topcase was given, eh... keep the topcase
copy_topcase(Vars, Spec, St) ->
    {value,{topcase,Tc}} = lists:keysearch(topcase,1,Spec),
    {ok, Vars, lists:keydelete(topcase,1,Spec),St#state{topcase=Tc}}.


%% Run any "Makefile.first" files first.
%%  XXX We should fake a failing test case if the make fails.

run_preinits(Vars, Spec, St) ->
    Wc = filename:join(St#state.data_wc, "Makefile.first"),
    run_pre_makefiles(filelib:wildcard(Wc), Vars, Spec, St),
    {ok,Vars,Spec,St}.

run_pre_makefiles([Makefile|Ms], Vars0, Spec0, St0) ->
    Hooks = [fun run_pre_makefile/3],
    case execute(Hooks, Vars0, Spec0, St0#state{makefile=Makefile}) of
	{error,_Reason}=Error -> Error;
	{ok,Vars,Spec,St} -> run_pre_makefiles(Ms, Vars, Spec, St)
    end;
run_pre_makefiles([], Vars, Spec, St) -> {ok,Vars,Spec,St}.

run_pre_makefile(Vars, Spec, St) ->
    Makefile = St#state.makefile,
    Shortname = filename:basename(Makefile),
    DataDir = filename:dirname(Makefile),
    case ts_make:make(DataDir, Shortname) of
	ok -> {ok,Vars,Spec,St};
	{error,_Reason}=Error -> Error
    end.

%% Search for `Makefile.src' in each *_SUITE_data directory.

find_makefiles(Vars, Spec, St) ->
    Wc = filename:join(St#state.data_wc, "Makefile.src"),
    Makefiles = reverse(filelib:wildcard(Wc)),
    {ok,Vars,Spec,St#state{makefiles=Makefiles}}.
    
%% Create "Makefile" from "Makefile.src".

make_make(Vars, Spec, State) ->
    Src = State#state.makefile,
    Dest = filename:rootname(Src),
    ts_lib:progress(Vars, 1, "Making ~s...\n", [Dest]),
    case ts_lib:subst_file(Src, Dest, Vars) of
	ok ->
	    {ok, Vars, Spec, State#state{makefile=Dest}};
	{error, Reason} ->
	    {error, {Src, Reason}}
    end.

%% Add a testcase which will do the making of the stuff in the data directory.

add_make_testcase(Vars, Spec, St) ->
    Makefile = St#state.makefile,
    Dir = filename:dirname(Makefile),
    case ts_lib:var(os, Vars) of
	"OSE" ->
	    %% For OSE, C code in datadir must be linked in the image file,
	    %% and erlang code is sent as binaries from test_server_ctrl
	    %% Making erlang code here because the Makefile.src probably won't
	    %% work.
	    Erl_flags=[{i, "../../test_server"}|ts_lib:var(erl_flags,Vars)],
	    {ok, Cwd} = file:get_cwd(),
	    ok = file:set_cwd(Dir),
	    Result = (catch make:all(Erl_flags)),
	    ok = file:set_cwd(Cwd),
	    case Result of
		up_to_date -> {ok, Vars, Spec, St};
		_error -> {error, {erlang_make_failed,Dir}}
	    end;
	_ ->
	    Shortname = filename:basename(Makefile),
	    Suite = filename:basename(Dir, "_data"),
	    Config = [{data_dir,Dir},{makefile,Shortname}],
	    MakeModule = Suite ++ "_make",
	    MakeModuleSrc = filename:join(filename:dirname(Dir), 
					  MakeModule ++ ".erl"),
	    MakeMod = list_to_atom(MakeModule),
	    case filelib:is_file(MakeModuleSrc) of
		true -> ok;
		false -> generate_make_module(MakeModuleSrc, MakeModule)
	    end,
	    case Suite of
		"all_SUITE" ->
		    {ok,Vars,Spec,St#state{all={MakeMod,Config}}};
		_ ->
		    %% Avoid duplicates of testcases. There is no longer
		    %% a check for this in test_server_ctrl.
		    TestCase = {list_to_atom(Suite),all},
		    TopCase0 = case St#state.topcase of
				   List when is_list(List) ->
				       List -- [TestCase];
				   Top ->
				       [Top] -- [TestCase]
			       end,
		    TopCase = [{make,{MakeMod,make,[Config]},
				TestCase,
				{MakeMod,unmake,[Config]}}|TopCase0],
		    {ok,Vars,Spec,St#state{topcase=TopCase}}
	    end
    end.

generate_make_module(Name, ModuleString) ->
    {ok,Host} = inet:gethostname(),
    file:write_file(Name,
		    ["-module(",ModuleString,").\n",
		     "\n",
		     "-export([make/1,unmake/1]).\n",
		     "\n",
		     "make(Config) when list(Config) ->\n",
		     "    ts_make:make([{cross_node,\'ts@" ++ Host ++ "\'}|Config]).\n",
		     "\n",
		     "unmake(Config) when list(Config) ->\n",
		     "    ts_make:unmake(Config).\n"]).
			   

make_test_suite(Vars, _Spec, State) ->
    TestDir = State#state.test_dir,

    Erl_flags=[{i, "../test_server"}|ts_lib:var(erl_flags,Vars)],

    case code:is_loaded(test_server_line) of
        false -> code:load_file(test_server_line);
	_ -> ok
    end,

    {ok, Cwd} = file:get_cwd(),
    ok = file:set_cwd(TestDir),
    Result = (catch make:all(Erl_flags)),
    ok = file:set_cwd(Cwd),
    case Result of
	up_to_date ->
	    ok;
	{'EXIT', Reason} ->
	    %% If I return an error here, the test will be stopped
	    %% and it will not show up in the top index page. Instead
	    %% I return ok - the test will run for all existing suites.
	    %% It might be that there are old suites that are run, but
	    %% at least one suite is missing, and that is reported on the
	    %% top index page.
	    io:format("~s: {error,{make_crashed,~p}\n",
		      [State#state.file,Reason]),
	    ok;
	error ->
	    %% See comment above
	    io:format("~s: {error,make_of_test_suite_failed}\n",
		      [State#state.file]),
	    ok
    end.

%% Add topcase to spec.

add_topcase_to_spec(Vars, Spec, St) ->
    Tc = case St#state.all of
	     {MakeMod,Config} ->
		 [{make,{MakeMod,make,[Config]},
		   St#state.topcase,
		   {MakeMod,unmake,[Config]}}];
	     undefined -> St#state.topcase
	 end,
    {ok,Vars,Spec++[{topcase,Tc}],St}.

%% Writes the (possibly transformed) spec file.

write_spec_file(Vars, Spec, _State) ->
    F = fun(Term) -> io_lib:format("~p.~n", [Term]) end,
    SpecFile = map(F, Spec),
    Hosts = 
	case lists:keysearch(hosts, 1, Vars) of
	    false ->
		[];
	    {value, {hosts, HostList}} ->
		io_lib:format("{hosts,~p}.~n",[HostList])
	end,
    DiskLess =
	case lists:keysearch(diskless, 1, Vars) of
	    false ->
		[];
	    {value, {diskless, How}} ->
		io_lib:format("{diskless, ~p}.~n",[How])
	end,
    IPv6Hosts =
	case lists:keysearch(ipv6_hosts, 1, Vars) of
	    false ->
		[];
	    {value, {ipv6_hosts, IPv6HostList}} ->
		io_lib:format("{ipv6_hosts, ~p}.~n",[IPv6HostList])
	end,
    file:write_file("current.spec", [DiskLess,Hosts,IPv6Hosts,SpecFile]).

%% Makes the command to start up the Erlang node to run the tests.

backslashify([$\\, $" | T]) ->
    [$\\, $" | backslashify(T)];
backslashify([$" | T]) ->
    [$\\, $" | backslashify(T)];
backslashify([H | T]) ->
    [H | backslashify(T)];
backslashify([]) ->
    [].

make_command(Vars, Spec, State) ->
    TestDir = State#state.test_dir,
    TestPath = filename:nativename(TestDir),
    Erl = atom_to_list(lib:progname()),
    Naming =
	case ts_lib:var(longnames, Vars) of
	    true ->
		" -name ";
	    false ->
		" -sname "
	end,
    ExtraArgs = 
	case lists:keysearch(erl_start_args,1,Vars) of
	    {value,{erl_start_args,Args}} -> Args;
	    false -> ""
	end,
    CrashFile = State#state.file ++ "_erl_crash.dump",
    case filelib:is_file(CrashFile) of
	true -> 
	    io:format("ts_run: Deleting dump: ~s\n",[CrashFile]),
	    file:delete(CrashFile);
	false -> 
	    ok
    end,
    Cmd = [Erl, Naming, "test_server -pa ", $", TestPath, $",
	   " -rsh ", ts_lib:var(rsh_name, Vars),
	   " -env PATH \"",
	   backslashify(lists:flatten([TestPath, path_separator(),
			  remove_path_spaces()])), 
	   "\"",
	   " -env ERL_CRASH_DUMP ", CrashFile,
	   " -boot start_sasl -sasl errlog_type error",
	   " -s test_server_ctrl run_test ", State#state.test_server_args,
	   " ",
	   ExtraArgs],
    {ok, Vars, Spec, State#state{command=lists:flatten(Cmd)}}.

run_batch(Vars, _Spec, State) ->
    process_flag(trap_exit, true),
    Command = State#state.command ++ " -noinput -s erlang halt",
    ts_lib:progress(Vars, 1, "Command: ~s~n", [Command]),
    Port = open_port({spawn, Command}, [stream, in, eof]),
    ts_lib:print_data(Port).

run_interactive(Vars, _Spec, State) ->
    Command = State#state.command ++ " -s ts_reports make_index",
    ts_lib:progress(Vars, 1, "Command: ~s~n", [Command]),
    case ts_lib:var(os, Vars) of
	"Windows NT" ->
	    os:cmd("start w" ++ Command),
	    ok;
	"Windows 2000" ->
	    %io:format("~s~n",["start w" ++ Command]),
	    os:cmd("start w" ++ Command),
	    ok;
	"Windows 95" ->
	    %% Windows 95 strikes again!  We must redirect standard
	    %% input and output for the `start' command, to force
	    %% standard input and output to the Erlang shell to be
	    %% connected to the newly started console.
	    %% Without these redirections, the Erlang shell would be
	    %% connected to the pipes provided by the port program
	    %% and there would be an inactive console window.
	    os:cmd("start < nul > nul w" ++ Command),
	    ok;
	"Windows 98" ->
	    os:cmd("start < nul > nul w" ++ Command),
	    ok;
	_Other ->
	    %% Assuming ts and controller always run on solaris
	    start_xterm(Command)
    end.

start_xterm(Command) ->
    case os:find_executable("xterm") of
	false ->
	    io:format("The `xterm' program was not found.\n"),
	    {error, no_xterm};
	_Xterm ->
	    case os:getenv("DISPLAY") of
		false ->
		    io:format("DISPLAY is not set.\n"),
		    {error, display_not_set};
		Display ->
		    io:format("Starting xterm (DISPLAY=~s)...\n",
			      [Display]),
		    os:cmd("xterm -sl 10000 -e " ++ Command ++ "&"),
		    ok
	    end
    end.

path_separator() ->
    case os:type() of
	{win32, _} -> ";";
	{unix, _}  -> ":";
	vxworks ->    ":"
    end.


make_test_server_args(Args0,Options,Vars) ->
    Parameters = 
	case ts_lib:var(os, Vars) of
	    "VxWorks" ->
		F = write_parameterfile(vxworks,Vars),
		" PARAMETERS " ++ F;
	    "OSE" ->
		F = write_parameterfile(ose,Vars),
		" PARAMETERS " ++ F;
	    _ ->
		""
	end,
    Trace = 
	case lists:keysearch(trace,1,Options) of
	    {value,{trace,TI}} when tuple(TI); tuple(hd(TI)) ->
		ok = file:write_file(?tracefile,io_lib:format("~p.~n",[TI])),
		" TRACE " ++ ?tracefile;
	    {value,{trace,TIFile}} when atom(TIFile) ->
		" TRACE " ++ atom_to_list(TIFile);
	    {value,{trace,TIFile}} ->
		" TRACE " ++ TIFile;
	    false ->
		""
	end,
    Cover = 
	case lists:keysearch(cover,1,Options) of
	    {value,{cover,App,File,Analyse}} -> 
		" COVER " ++ to_list(App) ++ " " ++ to_list(File) ++ " " ++ 
		    to_list(Analyse);
	    false -> 
		""
	end,
    Args0 ++ Parameters ++ Trace ++ Cover.

to_list(X) when atom(X) ->
    atom_to_list(X);
to_list(X) when list(X) ->
    X.

write_parameterfile(Type,Vars) ->
    Cross_host = ts_lib:var(target_host, Vars),
    SlaveTargets = case lists:keysearch(slavetargets,1,Vars) of
		       {value, ST} ->
			   [ST];
		       _ ->
			   []
		   end,
    Master = case lists:keysearch(master,1,Vars) of
		 {value,M} -> [M];
		 false -> []
	     end,
    ToWrite = [{type,Type},
	       {target, list_to_atom(Cross_host)}] ++ SlaveTargets ++ Master,

    Crossfile = atom_to_list(Type) ++ "parameters" ++ os:getpid(),
    ok = file:write_file(Crossfile,io_lib:format("~p.~n", [ToWrite])),
    Crossfile.

%%
%% Paths and spaces handling for w2k and XP
%%
remove_path_spaces() ->
    Path = os:getenv("PATH"),
    case os:type() of
	{win32,nt} ->
	    remove_path_spaces(Path);
	_ ->
	    Path
    end.

remove_path_spaces(Path) ->
    SPath = split_path(Path),
    [NSHead|NSTail] = lists:map(fun(X) -> filename:nativename(
					    filename:join(
					      translate_path(split_one(X)))) 
				end,
				SPath),
    NSHead ++ lists:flatten([[$;|X] || X <- NSTail]).

translate_path(PList) ->
    %io:format("translate_path([~p|~p]~n",[Base,PList]),
    translate_path(PList,[]).


translate_path([],_) ->
    [];
translate_path([PC | T],BaseList) ->
    FullPath = filename:nativename(filename:join(BaseList ++ [PC])),
    NewPC = case catch file:altname(FullPath) of
		{ok,X} ->
		    X;
		_ ->
		    PC
	    end,
    %io:format("NewPC:~s, DirList:~p~n",[NewPC,DirList]),
    NewBase = BaseList ++ [NewPC],
    NextDir = filename:nativename(filename:join(NewBase)),
    [NewPC | translate_path(T,NewBase)].

split_one(Path) ->
    filename:split(Path).

split_path(Path) ->
    string:tokens(Path,";").


