%% @author Magnus Klaar <magnus.klaar@gmail.com>
%% @doc File I/O Request supervisor
%% <p>
%% All file I/O requests are performed by a supervised process running under
%% this supervisor process. Failed I/O requests are retried until success.
%% </p>
%% @end
-module(etorrent_io_req_sup).
-behaviour(supervisor).

%% exported functions
-export([start_link/1, start_child/4]).

%% supervisor callbacks
-export([init/1]).


%% @doc Start the file I/O request supervisor.
%% @end
start_link(TorrentID) ->
    supervisor:start_link(?MODULE, [TorrentID]).


%% @doc Add a file I/O request process.
%% @end
start_child(TorrentID, Piece, Offset, Length) ->
    SupPid = etorrent_utils:await({etorrent_io_req_sup, TorrentID}, infinity),
    supervisor:start_child(SupPid, [Piece, Offset, Length, self()]).


%% @private
init([TorrentID]) ->
    etorrent_utils:register({etorrent_io_req_sup, TorrentID}),
    {ok, {{simple_one_for_one, 1, 60}, [request_spec(TorrentID)]}}. 


%% @private
request_spec(TorrentID) ->
    {undefined,                                                    
        {etorrent_io_req, start_link, [TorrentID]},                        
        transient, 2000, worker, [etorrent_io_req]}.
