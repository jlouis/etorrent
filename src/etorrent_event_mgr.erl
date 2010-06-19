%%%-------------------------------------------------------------------
%%% File    : etorrent_event_mgr.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Event tracking inside the etorrent application.
%%%
%%% Created : 25 Aug 2007 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_event_mgr).

-export([start_link/0,

         event/1,
         started_torrent/1,
         checking_torrent/1,
         seeding_torrent/1]).

-define(SERVER, ?MODULE).

%% API
event(What) ->
    gen_event:notify(?SERVER, What).

started_torrent(Id) ->
    event({started_torrent, Id}).

checking_torrent(Id) ->
    event({checking_torrent, Id}).

seeding_torrent(Id) ->
    event({seeding_torrent, Id}).

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
    gen_event:add_handler(?SERVER, etorrent_memory_logger, []),
    {ok, Pid}.

