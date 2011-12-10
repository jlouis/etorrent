%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Log Etorrent Events to a file.
%% <p>This gen_event logger lets you log etorrent information to a file</p>
%% @end
-module(etorrent_file_logger).


-behaviour(gen_event).

%% Install/Deinstall
-export([add_handler/0, add_handler/1, delete_handler/0]).

%% Callbacks
-export([init/1, handle_event/2, handle_info/2, terminate/2]).
-export([handle_call/2, code_change/3]).

-type filepath() :: string().
-record(state, {dir :: filepath(),
		fname :: filepath(),
		cur_fd :: file:io_device(),
		pred :: fun((term()) -> boolean())}).

%% =======================================================================

%% @doc Add a default handler accepting everything
%% @end
-spec add_handler() -> ok.
add_handler() ->
    add_handler(fun (_) ->
			true
		end).

%% @doc Add a handler with a predicate function.
%% <p>This variant only outputs things the predicate function accepts</p>
%% @end
-spec add_handler(fun ( (term()) -> boolean() )) -> ok.
add_handler(Predicate) ->
    ok = etorrent_event:add_handler(?MODULE, [Predicate]).

%% @doc Delete an installed handler
%% @end
delete_handler() ->
    etorrent_event:delete_handler(?MODULE, []).

%% -----------------------------------------------------------------------
file_open(Dir, Fname) ->
    {ok, FD} = file:open(filename:join(Dir, Fname), [append]),
    {ok, FD}.

date_str({{Y, Mo, D}, {H, Mi, S}}) ->
    lists:flatten(io_lib:format("~w-~2.2.0w-~2.2.0w ~2.2.0w:"
                                "~2.2.0w:~2.2.0w",
                                [Y,Mo,D,H,Mi,S])).
%% =======================================================================

%% @private
init([Pred]) ->
    Dir = etorrent_config:logger_dir(),
    Fname = etorrent_config:logger_file(),
    case catch file_open(Dir, Fname) of
        {ok, Fd} -> {ok, #state { dir = Dir, fname = Fname,
                                  cur_fd = Fd, pred = Pred }};
        Error -> Error
    end.

%% @private
handle_event(Event, S) ->
    Date = date_str(erlang:localtime()),
        #state{dir = _Dir, fname = _Fname, cur_fd = _CurFd, pred = Pred} = S,
        case catch Pred(Event) of
        true ->
        io:format(S#state.cur_fd, "~s : ~p~n", [Date, Event]),
                {ok, S};
        _ ->
        {ok, S}
        end.

%% @private
handle_info(_, State) ->
    {ok, State}.

%% @private
terminate(_, State) ->
    case file:close(State#state.cur_fd) of
        ok -> State;
        {error, R} ->
            lager:warning("Can't close file: ~p", [R]),
            State
    end.

%% @private
handle_call(null, State) ->
    {ok, null, State}.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

