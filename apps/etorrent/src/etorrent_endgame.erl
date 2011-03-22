-module(etorrent_endgame).
-behaviour(gen_server).

%% gen_server callbacks
-export([init/1,
        handle_call/3,
        handle_cast/2,
        handle_info/2,
        terminate/2,
        code_change/3]).

init('_') -> ok.


handle_call({register_peer, Pid}, _, State) ->
    %% Initialize peer data structures
    {reply, ok, State};

handle_call({sent_request, Pid, Index, Offset, Length}, _, State) ->
    %% Add the chunk to the set of open requests
    %% Add the peer as the only one having sent the request
    {reply, ok, State};

handle_call({which_peers, Pid, Index, Offset, Length}, _, State) ->
    %% Find out which other peers have sent the request
    {reply, {ok, []}, State};

handle_call({request_chunks, Pid, Peerset, Numchunks}, _, State) ->
    %% Find out which chunks are a good fit
    %% Add Pid the set of peers having open requests for these chunks
    %% Return the chunks to the peer
    {reply, {ok, []}, State};

handle_call({mark_fetched, Pid, Index, Offset, Length}, _, State) ->
    %% Ensure that request_chunks does not return this chunk unless
    %% the peer crashes
    {reply, ok, State};

handle_call({mark_stored, Pid, Index, Offset, Length}, _, State) ->
    %% Find out which other peers have open requests for these chunks
    %% Ensure that request_chunks never returns this request again
    {reply, ok, State}.


handle_cast('_', '_') -> ok.
handle_info('_', '_') -> ok.
terminate('_', '_') -> ok.
code_change('_', '_', '_') -> ok.
