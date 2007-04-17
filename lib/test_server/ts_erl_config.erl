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
%%% Purpose : Updates variable list with variables depending on
%%%	      running Erlang system.

-module(ts_erl_config).


-export([variables/2]).

%% Returns a list of key, value pairs.

variables(Base0,OsType) ->
    Base1 = erl_include(Base0),
    Base2 = erl_interface(Base1,OsType),
    Base3 = ic(Base2, OsType),
    Base4 = jinterface(Base3),
    Base5 = ig_vars(Base4),
    Base6 = dl_vars(Base5,OsType),
    Base7 = emu_vars(Base6),
    Base8 = ssl_vars(Base7),
    Base = separators(Base8, OsType),
    [{'EMULATOR', tl(code:objfile_extension())} | Base].

dl_vars(Vars, {win32, _}) ->
    ShlibRules0 = ".SUFFIXES: @dll@ @obj@ .c\n" ++
	".c@dll@:\n" 
	"\t@CC@ @DEFS@ @SHLIB_CFLAGS@ $(SHLIB_EXTRA_CFLAGS) "
	"$< -I@erl_include@ "
	" kernel32.lib $(SHLIB_EXTRA_LDFLAGS)",
    ShlibRules = ts_lib:subst(ShlibRules0, Vars),
    [{'SHLIB_RULES', ShlibRules}|Vars];
dl_vars(Vars, _) ->
    ShlibRules0 = ".SUFFIXES:\n" ++
	".SUFFIXES: @dll@ @obj@ .c\n\n" ++
	".c@dll@:\n" ++
	"\t@CC@ -c @SHLIB_CFLAGS@ @CFLAGS@ $(SHLIB_EXTRA_CFLAGS) -I@erl_include@ @DEFS@ $<\n" ++
	"\t@SHLIB_LD@ @CROSSLDFLAGS@ $(SHLIB_EXTRA_LDFLAGS) -o $@ $*@obj@",
    ShlibRules = ts_lib:subst(ShlibRules0, Vars),
    [{'SHLIB_RULES', ShlibRules}|Vars].
		
erl_include(Vars) ->
    Include = 
	case erl_root(Vars) of
	    {installed, Root} ->
		filename:join([Root, "usr", "include"]);
	    {clearcase, Root, _Target} ->
		filename:join([Root, "erts", "emulator", "beam"]) ++
		    system_include(Root, Vars)
	end,
    [{erl_include, filename:nativename(Include)}|Vars].


system_include(Root, Vars) ->
    SysDir =
	case ts_lib:var(os, Vars) of
	    "Windows" ++ _T -> "sys/win32";
	    "VxWorks" -> "sys.vxworks";
	    "OSE" -> "sys/ose";
	    _ -> "sys/unix"
	end,
    " -I" ++ filename:nativename(filename:join([Root, "erts", "emulator", SysDir])).

erl_interface(Vars,OsType) ->
    {LibPath, Incl} =
	case lib_dir(Vars, erl_interface) of
	    {error, bad_name} ->
		exit({error, cannot_find_erl_interface});
	    Dir ->
		{case erl_root(Vars) of
		     {installed, _Root} ->
			 filename:join(Dir, "lib");
		     {clearcase, _Root, Target} ->
			 filename:join([Dir, "obj", Target])
		 end,
		 filename:join(Dir, "include")}
	end,
    Lib = link_library("erl_interface",OsType),
    Lib1 = link_library("ei",OsType),
    ThreadLib = case OsType of
		    % FIXME: FreeBSD uses gcc flag '-pthread' or linking with
		    % "libc_p". So it has to be last of libs. This is an
		    % temporary solution, should be configured elsewhere.
		    {unix,freebsd} ->
			"-lc_r";
		    {unix,_} ->
			"-lpthread";
		    _ -> 
			"" % VxWorks or OSE
		end,
    [{erl_interface_libpath, filename:nativename(LibPath)},
     {erl_interface_sock_libs, sock_libraries(OsType)},
     {erl_interface_lib, Lib},
     {erl_interface_eilib, Lib1},
     {erl_interface_threadlib, ThreadLib},
     {erl_interface_include, filename:nativename(Incl)}|Vars].

ic(Vars, OsType) ->
    {ClassPath, LibPath, Incl} =
	case lib_dir(Vars, ic) of
	    {error, bad_name} ->
		exit({error, cannot_find_ic});
	    Dir ->
		{filename:join([Dir, "priv", "ic.jar"]),
		 case erl_root(Vars) of
		     {installed, _Root} ->
			 filename:join([Dir, "priv", "lib"]);
		     {clearcase, _Root, Target} ->
			 filename:join([Dir, "priv", "lib", Target])
		 end,
		 filename:join(Dir, "include")}
	end,
    [{ic_classpath, filename:nativename(ClassPath)},
     {ic_libpath, filename:nativename(LibPath)},
     {ic_lib, link_library("ic", OsType)},
     {ic_include_path, filename:nativename(Incl)}|Vars].

jinterface(Vars) ->
    ClassPath =
	case lib_dir(Vars, jinterface) of
	    {error, bad_name} ->
		"";
	    Dir ->
		filename:join([Dir, "priv", "OtpErlang.jar"])
	end,
    [{jinterface_classpath, filename:nativename(ClassPath)}|Vars].

ig_vars(Vars) ->
    {Lib0, Incl} = 
	case erl_root(Vars) of
	    {installed, Root} ->
		Base = filename:join([Root, "usr"]),
		{filename:join([Base, "lib"]), 
		 filename:join([Base, "include"])};
	    {clearcase, Root, Target} ->
		{filename:join([Root, "lib", "ig", "obj", Target]),
		 filename:join([Root, "lib", "ig", "include"])}
	end,
    [{ig_libdir, filename:nativename(Lib0)},
     {ig_include, filename:nativename(Incl)}|Vars].

lib_dir(Vars, Lib) ->
    LibLibDir = code:lib_dir(Lib),
    case {get_var(crossroot, Vars), LibLibDir} of
	{{error, _}, _} ->			%no crossroot
	    LibLibDir;
	{_, {error, _}} ->			%no lib
	    LibLibDir;
	{CrossRoot, _} ->
	    %% XXX: Ugly. So ugly I won't comment it
	    %% /Patrik
	    CLibDir = filename:join([CrossRoot, "lib", atom_to_list(Lib)]),
	    Cmd = "ls -d " ++ CLibDir ++ "*",
	    XLibDir = lists:last(string:tokens(os:cmd(Cmd),"\n")),
	    case file:list_dir(XLibDir) of
		{error, enoent} ->
		    [];
		_ ->
		    XLibDir
	    end
    end.

erl_root(Vars) ->
    Root = code:root_dir(),
    case ts_lib:erlang_type() of
	{clearcase, _Version} ->
	    Target = get_var(target, Vars),
	    {clearcase, Root, Target};
	{_, _} ->
	    case get_var(crossroot,Vars) of
		{error, notfound} ->
		    {installed, Root};
		CrossRoot ->
		    {installed, CrossRoot}
	    end
    end.


get_var(Key, Vars) ->
    case lists:keysearch(Key, 1, Vars) of
	{value, {Key, Value}} ->
	    Value;
	_ ->
	    {error, notfound}
    end.


sock_libraries({win32, _}) ->
    "ws2_32.lib";
sock_libraries({unix, _}) ->
    "";	% Included in general libraries if needed.
sock_libraries(vxworks) ->
    "";
sock_libraries(ose) ->
    "";
sock_libraries(_Other) ->
    exit({sock_libraries, not_supported}).


link_library(LibName,{win32, _}) ->
    LibName ++ ".lib";
link_library(LibName,{unix, _}) ->
    "lib" ++ LibName ++ ".a";
link_library(LibName,vxworks) ->
    "lib" ++ LibName ++ ".a";
link_library(_LibName,ose) ->
    "";
link_library(_LibName,_Other) ->
    exit({link_library, not_supported}).

%% Returns emulator specific variables.
emu_vars(Vars) ->
    [{is_source_build, is_source_build()},
     {erl_name, atom_to_list(lib:progname())}|Vars].

is_source_build() ->
    string:str(erlang:system_info(system_version), "[source]") > 0.

%%
%% ssl_libdir
%%
ssl_vars(Vars) ->
    case erl_root(Vars) of
	{installed, _Root} ->
	    case lib_dir(Vars, ssl) of
		{error, bad_name} ->
		%% Not installed. Is ok.
		    Vars;
		Dir ->
		    [{ssl_libdir, filename:nativename(Dir)}| Vars]
	    end;
	{clearcase, _Root, _Target} ->
	    case lib_dir(Vars, ssl) of
		{error, bad_name} ->
		    exit({error, cannot_find_ssl});
		Dir ->
		    [{ssl_libdir, filename:nativename(Dir)}| Vars]
	    end
    end.

separators(Vars, {win32,_}) ->
    [{'DS',"\\"},{'PS',";"}|Vars];
separators(Vars, _) ->
    [{'DS',"/"},{'PS',":"}|Vars].
