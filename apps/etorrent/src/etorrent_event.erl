%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Handle messaging events in etorrent.
%% <p>This module handles the processing of <em>event messages</em> in
%% etorrent. Whenever something important happens, a message is sent
%% to then `gen_event' process. It then hands the message on to any
%% handler which has been registered with it. Normally these are
%% handlers for file logging and memory logging.</p>
%% @end
-module(etorrent_event).

%% Installation/deinstallation of the event mgr
-export([start_link/0,
	 add_handler/2,
	 delete_handler/2]).

%% Notifications
-export([notify/1,
         started_torrent/1,
         stopped_torrent/1,
         checking_torrent/1,
	 completed_torrent/1,
         seeding_torrent/1]).

-define(SERVER, ?MODULE).
%% =======================================================================

%% @doc Notify the event system of an event
%% <p>The system accepts any term as the event.</p>
%% @end
-spec notify(term()) -> ok.
notify(What) ->
    gen_event:notify(?SERVER, What).

%% @doc Add an event handler
%% @end
-spec add_handler(atom() | pid(), [term()]) -> ok.
add_handler(Handler, Args) ->
    gen_event:add_handler(?SERVER, Handler, Args).

%% @doc Delete an event handler
%% @end
-spec delete_handler(atom() | pid(), [term()]) -> ok.
delete_handler(Handler, Args) ->
    gen_event:delete_handler(?SERVER, Handler, Args).

%% @equiv notify({stopped_torrent, Id})
-spec stopped_torrent(integer()) -> ok.
stopped_torrent(Id) -> notify({stopped_torrent, Id}).

%% @equiv notify({started_torrent, Id})
-spec started_torrent(integer()) -> ok.
started_torrent(Id) -> notify({started_torrent, Id}).

%% @equiv notify({checking_torrent, Id})
-spec checking_torrent(integer()) -> ok.
checking_torrent(Id) -> notify({checking_torrent, Id}).

%% @equiv notify({seeding_torrent, Id})
-spec seeding_torrent(integer()) -> ok.
seeding_torrent(Id) -> notify({seeding_torrent, Id}).

%% @equiv notify({completed_torrent, Id})
-spec completed_torrent(integer()) -> ok.
completed_torrent(Id) -> notify({completed_torrent, Id}).

%% ====================================================================

%% @doc Start the event handler
%% @end
start_link() ->
    gen_event:start_link({local, ?SERVER}).



