%%%-------------------------------------------------------------------
%%% File    : etorrent_event_mgr.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Event tracking inside the etorrent application.
%%%
%%% Created : 25 Aug 2007 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_event_mgr).

%% API
-export([start_link/0,

	started_torrent/1,
	checking_torrent/1,
	seeding_torrent/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% gen_event callbacks
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | {error,Error}
%% Description: Creates an event manager.
%%--------------------------------------------------------------------
start_link() ->
    {ok, Pid} = gen_event:start_link({local, ?SERVER}),
    {ok, Dir} = application:get_env(etorrent, logger_dir),
    {ok, MaxBytes} = application:get_env(etorrent, logger_max_bytes),
    {ok, MaxFiles} = application:get_env(etorrent, logger_max_files),
    Args = log_mf_h:init(Dir, MaxBytes, MaxFiles),
    gen_event:add_handler(?SERVER, log_mf_h, Args),
    {ok, Pid}.

started_torrent(Id) ->
    gen_event:notify(?SERVER, {started_torrent, Id}).


checking_torrent(Id) ->
    gen_event:notify(?SERVER, {checking_torrent, Id}).

seeding_torrent(Id) ->
    gen_event:notify(?SERVER, {seeding_torrent, Id}).

