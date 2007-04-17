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
%%% Purpose : Autoconf for OSE

-module(ts_autoconf_ose).
-export([configure/1]).

%%% Supported platforms:
-define(PLATFORMS, ["ose"]).
-define(CENTRAL_LOG_DIR, "/usr/local/otp").

%% takes an argument {Target_arch, Target_host} (e.g. {ose, maeglin}).
configure({Target_arch, Target_host}) ->
    case variables({Target_arch, Target_host}) of
	{ok, Vars} ->
	    ts_lib:subst_file("conf_vars.in", "conf_vars", Vars);
	Error ->
	    Error
    end.

variables({Target_arch, Target_host}) ->
    case lists:member(Target_arch,?PLATFORMS) of
	true ->
	    Vars = [{host_os, "OSE"},
		    {host,  Target_arch},
		    {target_host, Target_host},
		    {host_cpu, "ppc750"},
		    {'CC', ""},
		    {'CFLAGS', ""},
		    {'DEFS', ""},
		    {'LIBS', ""},
		    {'SHLIB_CFLAGS', ""},
		    {'LD', ""},
		    {'CROSSLDFLAGS', ""},
		    {'SHLIB_EXTRACT_ALL', ""},
		    {'SHLIB_LD', ""},
		    {obj, ""},
		    {'SHLIB_SUFFIX', ""},
		    {exe, ""}],
	    {ok,Vars};
	false ->
	    {error,"unsupported_platform"}
    end.
