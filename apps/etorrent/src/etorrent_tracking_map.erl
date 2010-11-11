%%%-------------------------------------------------------------------
%%% File    : etorrent_tracking_map.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Tracking Map manipulations
%%%
%%% Created : 15 Jun 2008 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_tracking_map).

-behaviour(gen_server).

-include_lib("stdlib/include/qlc.hrl").
-include("etorrent_mnesia_table.hrl").



%% API
-export([start_link/0, all/0, new/3, select/1, statechange/2,
         is_ready_for_checking/1]).

-export([init/1, code_change/3, handle_info/2, handle_cast/2, handle_call/3,
         terminate/2]).

-record(state, { monitoring }).

-define(SERVER, ?MODULE).

-ignore_xref([{'start_link', 0}]).
%% ====================================================================
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

% @doc Add a new torrent
% <p>The torrent is given by File with the Supervisor pid as given to the
% database structure.</p>
% @end
-spec new(string(), pid(), integer()) -> ok.
new(File, Supervisor, Id) when is_integer(Id), is_pid(Supervisor), is_list(File) ->
    gen_server:call(?SERVER, {new, File, Supervisor, Id}).

% @doc Return everything we are currently tracking
% @end
-spec all() -> {atomic, [#tracking_map{}]}.
all() ->
    mnesia:transaction(
      fun () ->
              qlc:e(qlc:q([T || T <- mnesia:table(tracking_map)]))
      end).

% @doc Find tracking map matching the Query.
% <p>This function takes one out of 3 different query types. Either you query
% for an integer Id of the torrent, or you query for {filename, FN} .. or you
% query for {infohash, IH}. It returns the mnesia transaction with the result
% of the query.</p>
% @end
-spec select(integer() | {filename, string()} | {infohash, binary()}) ->
      {atomic, [#tracking_map{}]} | {aborted, term()}.
select(Id) when is_integer(Id) ->
    mnesia:transaction(
      fun () ->
              mnesia:read(tracking_map, Id, read)
      end);
select({filename,Filename}) ->
    mnesia:transaction(
      fun () ->
              Query = qlc:q([T || T <- mnesia:table(tracking_map),
                                  T#tracking_map.filename == Filename]),
              qlc:e(Query)
      end);
select({infohash, InfoHash}) ->
    mnesia:transaction(
      fun () ->
              Q = qlc:q([T || T <- mnesia:table(tracking_map),
                              T#tracking_map.info_hash =:= InfoHash]),
              qlc:e(Q)
      end).


% @doc Alter the state of the Tracking map identified by Id
%   <p>by What (see alter_map/2).</p>
% @end
-type alteration() :: {infohash, binary()} | started | stopped.
-spec statechange(integer(), alteration()) -> ok.
statechange(Id, What) ->
    F = fun () ->
                [TM] = mnesia:read(tracking_map, Id, write),
                mnesia:write(alter_map(TM, What))
        end,
    {atomic, _} = mnesia:transaction(F),
    ok.

% @doc Attempt to mark the torrent for checking.
%  <p>If this succeeds, returns true, else false</p>
% @end
-spec is_ready_for_checking(integer()) -> boolean().
is_ready_for_checking(Id) ->
    F = fun () ->
                Q = qlc:q([TM || TM <- mnesia:table(tracking_map),
                                 TM#tracking_map.state =:= checking]),
                case qlc:e(Q) of
                    [] ->
                        [TM] = mnesia:read(tracking_map, Id, write),
                        mnesia:write(TM#tracking_map { state = checking }),
                        true;
                    _ ->
                        false
                end
        end,
    {atomic, T} = mnesia:transaction(F),
    T.

%% =======================================================================

init([]) ->
    {ok, #state{ monitoring = dict:new() }}.


handle_call({new, File, Supervisor, Id}, {Pid, _Tag}, S) ->
    R = erlang:monitor(process, Pid),
    mnesia:dirty_write(#tracking_map { id = Id,
                                       filename = File,
                                       supervisor_pid = Supervisor,
                                       info_hash = unknown,
                                       state = awaiting}),
    {reply, ok, S #state{ monitoring = dict:store(R, Id, S#state.monitoring )}};
handle_call(_Msg, _From, S) ->
    {noreply, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({'DOWN', Ref, _, _, _}, S) ->
    {ok, Id} = dict:find(Ref, S#state.monitoring),
    mnesia:dirty_delete(tracking_map, Id),
    {noreply, S#state { monitoring = dict:erase(Ref, S#state.monitoring) }};
handle_info(_Msg, S) ->
    {noreply, S}.

code_change(_OldVsn, S, _Extra) ->
    {ok, S}.

terminate(_Reason, _S) ->
    ok.

%%====================================================================
alter_map(TM, What) ->
    case What of
        {infohash, IH} ->
            TM#tracking_map { info_hash = IH };
        started ->
            TM#tracking_map { state = started };
        stopped ->
            TM#tracking_map { state = stopped }
    end.
