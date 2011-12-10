%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Log to a memory table
%% <p>The gen_event event handler here is used to handle events and
%% their insertion into into an ETS table. It is used mainly by the
%% webui for listing the last 12 hours of events that occurred in the system.</p>
%% @end
%% @todo This module is missing some API-calls. They are in other modules.
-module(etorrent_memory_logger).

-include_lib("stdlib/include/ms_transform.hrl").

-behaviour(gen_event).

%% Introduction/removal
-export([add_handler/0, delete_handler/0]).

%% Query
-export([all_entries/0]).

%% Callback
-export([init/1, handle_event/2, handle_info/2, terminate/2]).
-export([handle_call/2, code_change/3]).

-record(state, {}).

-define(TAB, ?MODULE).
-define(OLD_PRUNE_TIME, 12 * 60 * 60).

%% =======================================================================

%% @doc Add the handler to etorrent_event.
%% @end
-spec add_handler() -> ok.
add_handler() ->
    ok = etorrent_event:add_handler(?MODULE, []).

%% @doc Remove the handler from etorrent_event.
%% @end
-spec delete_handler() -> ok.
delete_handler() ->
    ok = etorrent_event:delete_handler(?MODULE, []).

%% @doc Return all entries in the memory logger table
%% @end
%% @todo Improve spec
-spec all_entries() -> [{term(), term(), term()}].
all_entries() ->
    ets:match_object(?TAB, '_').

%% =======================================================================

%% @private
init(_Args) ->
    _ = ets:new(?TAB, [named_table, protected]),
    {ok, #state{}}.

%% @private
handle_event(Evt, S) ->
    Now = now(),
    ets:insert_new(?TAB, {Now, erlang:localtime(), Evt}),
    prune_old_events(),
    {ok, S}.

%% @private
handle_info(_, State) ->
    {ok, State}.

%% @private
terminate(_, _State) ->
    ok.

%% @private
handle_call(null, State) ->
    {ok, null, State}.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =======================================================================

%% @doc Prune events which are older than a given amount of time
%% @end
prune_old_events() ->
    NowSecs = calendar:datetime_to_gregorian_seconds(
                        calendar:universal_time()),
    TS = NowSecs - ?OLD_PRUNE_TIME,
    PruneTime = calendar:gregorian_seconds_to_datetime(TS),
    MS = ets:fun2ms(fun({N, LT, Evt}) -> LT < PruneTime end),
    ets:select_delete(?TAB, MS),
    ok.









