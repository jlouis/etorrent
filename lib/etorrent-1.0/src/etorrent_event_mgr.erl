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

         persisted_state_to_disk/0,

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
    {ok, Fname} = application:get_env(etorrent, logger_fname),
    Args = etorrent_file_logger:init(Dir, Fname),
    gen_event:add_handler(?SERVER, etorrent_file_logger, Args),
    {ok, Pid}.

started_torrent(Id) ->
    gen_event:notify(?SERVER, {started_torrent, Id}).


checking_torrent(Id) ->
    gen_event:notify(?SERVER, {checking_torrent, Id}).

seeding_torrent(Id) ->
    gen_event:notify(?SERVER, {seeding_torrent, Id}).

persisted_state_to_disk() ->
    gen_event:notify(?SERVER, persisted_state_to_disk).
