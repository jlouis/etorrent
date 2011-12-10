%% @author Jesper Louis andersen <jesper.louis.andersen@gmail.com>
%% @doc Handle Callback events in Etorrent
%% @end
-module(etorrent_callback_handler).

-include("log.hrl").
-behaviour(gen_event).
%% API
-export([add_handler/0, delete_handler/0]).

-export([install_callback/3, install_callback/4]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, { table :: gb_tree(),
                 monitors :: gb_tree() }).

%%====================================================================

%% @doc Add the handler to etorrent_event.
%% @end
add_handler() ->
    ok = etorrent_event:add_handler(?MODULE, []).

%% @doc Remove the handler from etorrent_event.
%% @end
-spec delete_handler() -> ok.
delete_handler() ->
    ok = etorrent_event:delete_handler(?MODULE, []).

%% @doc Install a callback on a torrent event.
%% By default a completion callback function is installed. Upon the completion
%% event the completion callback will be run in a spawned new process.
%%
%% @todo The more general variant is at the moment non-functional
%% @end
-spec install_callback(pid(), binary(),
                       fun(() -> any()) | [{atom(), fun()}]) ->
                              ok.
install_callback(TorrentPid, IH, Fun) when is_function(Fun, 0) ->
    install_callback(TorrentPid, IH, [{completion, Fun}]);
install_callback(TorrentPid, IH, EventCallbacks) when is_list(EventCallbacks) ->
    gen_event:call(etorrent_event, ?MODULE,
                   {install_callbacks, TorrentPid, IH, EventCallbacks}).

%% @doc Install a callback for a specific type of event
%% @todo This function is not yet working as intended
%% @end
-spec install_callback(pid(), binary(), atom(), fun()) -> ok.
install_callback(TorrentPid, IH, Ty, Fun) ->
    install_callback(TorrentPid, IH, [{Ty, Fun}]).


%%====================================================================

%% @private
init([]) ->
    {ok, #state{ table = gb_trees:empty(),
                 monitors = gb_trees:empty() }}.

%% @private
handle_event({completed_torrent, Id}, #state { table = T } = State) ->
    case etorrent_table:get_torrent(Id) of
        not_found ->
            ok; % Dead, ignore
        {value, PL} ->
            IH = proplists:get_value(info_hash, PL),
            perform_callback(gb_trees:lookup(IH, T))
    end,
    {ok, State};
handle_event(_Event, State) ->
    %% Silently ignore all state we don't care about.
    {ok, State}.

%% @private
handle_call({install_callbacks, TorrentPid, IH, CBPropList},
            #state { table = T,
                     monitors = M} = S) ->
    NewT = gb_trees:insert(IH, CBPropList, T),
    MRef = erlang:monitor(process, TorrentPid),
    NewM = gb_trees:insert(MRef, IH, M),
    {ok, ok, S#state { table = NewT,
                       monitors = NewM }};
handle_call(Request, State) ->
    ?WARN([unknown_request, Request]),
    Reply = ok,
    {ok, Reply, State}.

%% @private
handle_info({'DOWN', Ref, process, _Pid, _Reason},
            #state { monitors = M, table = T} = S) ->
    {value, IH} = gb_trees:lookup(Ref, M),
    {ok,
     S#state { monitors = gb_trees:delete(Ref, M),
               table    = gb_trees:delete(IH, T) }};
handle_info(_Info, State) ->
    {ok, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ----------------------------------------------------------------------

perform_callback(none) ->
    ok;
perform_callback({value, CBs}) ->
    CompFun = proplists:get_value(completion, CBs),
    spawn(fun() ->
                  try CompFun ()
                  catch
                      ErrType:Error ->
                          ?ERR([callback_error, ErrType, Error])
                  end
          end),
    ok.
