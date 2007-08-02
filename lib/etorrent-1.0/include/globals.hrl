%%%-------------------------------------------------------------------
%%% File    : globals.hrl
%%% Author  : Jesper Louis Andersen <>
%%% License : See LICENSE
%%% Description : Various global records
%%%
%%% Created :  2 Aug 2007 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------

-record(process_locations,
	{ state_pid,        % Pid of the state process
	  master_pid,       % Pid of the Torrent_peer_master
	  control_pid       % Pid of the torrent controller
        }).



