%%%-------------------------------------------------------------------
%%% File    : etorrent_rate.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Library of rate calculation code.
%%%
%%% Created : 10 Jul 2008 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_rate).

%% API
-export([init/1, update/2, now_secs/0]).

-include("etorrent_rate.hrl").

-define(MAX_RATE_PERIOD, 20).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: init/1
%% Args: Fudge ::= integer() - The fudge skew to start out with
%% Description: Return an initialized rate tuple.
%%--------------------------------------------------------------------
init(Fudge) ->
    T = now_secs(),
    #peer_rate { next_expected = T + Fudge,
		 last = T - Fudge,
		 rate_since = T - Fudge }.

%%--------------------------------------------------------------------
%% Function: update/2
%% Args: Amount ::= integer() - Number of bytes that arrived
%%       Rate   ::= double()  - Current rate
%%       Total  ::= integer() - Total amount of bytes downloaded
%%       NextExpected ::= time() - When is the next update expected
%%       Last   ::= time()    - When was the last update
%%       RateSince ::= time() - Point in time where the rate has its
%%                              basis
%% Description: Update the rate by Amount.
%%--------------------------------------------------------------------
update(#peer_rate {rate = Rate,
		   total = Total,
		   next_expected = NextExpected,
		   last = Last,
		   rate_since = RateSince} = RT, Amount) when is_integer(Amount) ->
    T = now_secs(),
    case T < NextExpected andalso Amount =:= 0 of
	true ->
	    %% We got 0 bytes, but we did not expect them yet, so just
	    %% return the current tuple (simplification candidate)
	    RT;
	false ->
	    %% New rate: Timeslot between Last and RateSince contributes
	    %%   with the old rate. Then we add the new Amount and calc.
	    %%   the rate for the interval [T, RateSince].
	    R = (Rate * (Last - RateSince) + Amount) / (T - RateSince),
	    #peer_rate { rate = R, %% New Rate
			 total = Total + Amount,
			 %% We expect the next data-block at the minimum of 5 secs or
			 %%   when Amount bytes has been fetched at the current rate.
			 next_expected =
			   T + lists:min([5, Amount / lists:max([R, 0.0001])]),
			 last = T,
			 %% RateSince is manipulated so it does not go beyond
			 %% ?MAX_RATE_PERIOD
			 rate_since = lists:max([RateSince, T - ?MAX_RATE_PERIOD])}
    end.

%%====================================================================
%% Internal functions
%%====================================================================
now_secs() ->
    calendar:datetime_to_gregorian_seconds(
     calendar:local_time()).
