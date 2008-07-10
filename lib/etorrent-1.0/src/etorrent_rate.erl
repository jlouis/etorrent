%%%-------------------------------------------------------------------
%%% File    : etorrent_rate.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Library of rate calculation code.
%%%
%%% Created : 10 Jul 2008 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_rate).

%% API
-export([get_rate/1, init/1, update/2]).

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
    T = now(),
    {0.0, 0, T + Fudge, T - Fudge, T - Fudge}.

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
%% TODO: Fix timer units (microseconds/seconds/millisecs/etc).
%%--------------------------------------------------------------------
update(Amount, {Rate, Total, NextExpected, Last, RateSince}) ->
    T = now(),
    case T < NextExpected andalso Amount =:= 0 of
	true ->
	    %% We got 0 bytes, but we did not expect them yet, so just
	    %% return the current tuple (simplification candidate)
	    {Rate, Total, NextExpected, Last, RateSince};
	false ->
	    %% New rate: Timeslot between Last and RateSince contributes
	    %%   with the old rate. Then we add the new Amount and calc.
	    %%   the rate for the interval [T, RateSince].
	    R = (Rate * timer:now_diff(Last, RateSince) + Amount) /
		 timer:now_diff(T, RateSince),
	    {R, %% New Rate
	     Total + Amount, %% Update Total
	     %% We expect the next data-block at the minimum of 5 secs or
	     %%   when Amount bytes has been fetched at the current rate.
	     T + lists:min([5, Amount / lists:max([R, 0.0001])]),
	     T, %% Bump last
	     %% RateSince is manipulated so it does not go beyond
	     %% ?MAX_RATE_PERIOD
	     lists:max([RateSince, T - ?MAX_RATE_PERIOD])}
    end.


%%--------------------------------------------------------------------
%% Function: get_rate/1
%% Args: RT     ::= rate_tuple()
%% Description: Get the rate, and update it if too old.
%%--------------------------------------------------------------------
get_rate(RT) ->
    update(0, RT).


%%====================================================================
%% Internal functions
%%====================================================================
