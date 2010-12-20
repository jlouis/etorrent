%%%-------------------------------------------------------------------
%%% File    : etorrent_event.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Event tracking inside the etorrent application.
%%%
%%% Created : 25 Aug 2007 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_event).

%% Installation/deinstallation of the event mgr
-export([start_link/0,
	 add_handler/2,
	 delete_handler/2]).

%% Notifications
-export([notify/1,
         started_torrent/1,
         checking_torrent/1,
	 completed_torrent/1,
         seeding_torrent/1]).

-define(SERVER, ?MODULE).
-ignore_xref([{start_link, 0}, {event, 1}]).
%% =======================================================================
-spec notify(term()) -> ok.
notify(What) ->
    gen_event:notify(?SERVER, What).

-spec add_handler(atom() | pid(), [term()]) -> ok.
add_handler(Handler, Args) ->
    gen_event:add_handler(?SERVER, Handler, Args).

-spec delete_handler(atom() | pid(), [term()]) -> ok.
delete_handler(Handler, Args) ->
    gen_event:delete_handler(?SERVER, Handler, Args).

-spec started_torrent(integer()) -> ok.
started_torrent(Id) -> notify({started_torrent, Id}).

-spec checking_torrent(integer()) -> ok.
checking_torrent(Id) -> notify({checking_torrent, Id}).

-spec seeding_torrent(integer()) -> ok.
seeding_torrent(Id) -> notify({seeding_torrent, Id}).

-spec completed_torrent(integer()) -> ok.
completed_torrent(Id) -> notify({completed_torrent, Id}).

%% ====================================================================
start_link() ->
    gen_event:start_link({local, ?SERVER}).
