%%%-------------------------------------------------------------------
%%% File    : etorrent_tracking_map.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Tracking Map manipulations
%%%
%%% Created : 15 Jun 2008 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_tracking_map).

-include_lib("stdlib/include/qlc.hrl").
-include("etorrent_mnesia_table.hrl").

%% API
-export([all/0, new/3, delete/1, select/1, statechange/2,
	 is_ready_for_checking/1]).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: new(Filename, Supervisor) -> ok
%% Description: Add a new torrent given by File with the Supervisor
%%   pid as given to the database structure.
%%--------------------------------------------------------------------
new(File, Supervisor, Id) ->
    mnesia:dirty_write(#tracking_map { id = Id,
				       filename = File,
				       supervisor_pid = Supervisor,
				       info_hash = unknown,
				       state = awaiting}).

%%--------------------------------------------------------------------
%% Function: all/0
%% Description: Return everything we are currently tracking
%%--------------------------------------------------------------------
all() ->
    mnesia:transaction(
      fun () ->
	      qlc:e(qlc:q([T || T <- mnesia:table(tracking_map)]))
      end).

%%--------------------------------------------------------------------
%% Function: select(Id) -> [#tracking_map]
%% Args:    Id ::= integer() | {filename, FN} | {infohash, IH}
%%
%%          FN ::= string()
%%          IH ::= binary()
%% Description: Find tracking map matching the filename in question.
%%--------------------------------------------------------------------
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

%%--------------------------------------------------------------------
%% Function: delete(Id) -> ok
%% Description: Clean out all references to torrents matching Pid
%%--------------------------------------------------------------------
delete(Id) when is_integer(Id) ->
    mnesia:dirty_delete(tracking_map, Id).

%%--------------------------------------------------------------------
%% Function: statechange(Id, What) -> ok
%% Description: Alter the state of the Tracking map identified by Id
%%   by What (see alter_map/2).
%%--------------------------------------------------------------------
statechange(Id, What) ->
    F = fun () ->
		[TM] = mnesia:read(tracking_map, Id, write),
		mnesia:write(alter_map(TM, What))
	end,
    {atomic, _} = mnesia:transaction(F),
    ok.

%%--------------------------------------------------------------------
%% Function: is_ready_for_checking(Id) -> bool()
%% Description: Attempt to mark the torrent for checking. If this
%%   succeeds, returns true, else false
%%--------------------------------------------------------------------
is_ready_for_checking(Id) ->
    F = fun () ->
		Q = qlc:q([TM || TM <- mnesia:table(tracking_map),
				 TM#tracking_map.state =:= checking]),
		case length(qlc:e(Q)) of
		    0 ->
			[TM] = mnesia:read(tracking_map, Id, write),
			mnesia:write(TM#tracking_map { state = checking }),
			true;
		    _ ->
			false
		end
	end,
    {atomic, T} = mnesia:transaction(F),
    T.

%%====================================================================
%% Internal functions
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
