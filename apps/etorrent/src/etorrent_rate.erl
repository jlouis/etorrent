%%%-------------------------------------------------------------------
%%% File    : etorrent_rate.erl
%%% Author  : Jesper Louis Andersen <>
%%% Description : Library of rate calculation code.
%%%
%%% Created : 10 Jul 2008 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(etorrent_rate).

%% API
-export([init/0, init/1, update/2, eta/2]).

-include("etorrent_rate.hrl").

-define(MAX_RATE_PERIOD, 20).

%% ====================================================================
% @doc Convenience initializer for init/1
% @end
init() -> init(?RATE_FUDGE).

% @doc Initialize the rate tuple.
%    Takes a single integer, fudge, which is the fudge factor used to start up.
%    It fakes the startup of the rate calculation.
% @end
-spec init(integer()) -> #peer_rate{}.
init(Fudge) ->
    T = now_secs(),
    #peer_rate { next_expected = T + Fudge,
                 last = T - Fudge,
                 rate_since = T - Fudge }.

% @doc Update the rate record with Amount new downloaded bytes
% @end
-spec update(#peer_rate{}, integer()) -> #peer_rate{}.
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

% @doc Calculate estimated time of arrival.
% @end
-type eta() :: {integer(), {integer(), integer(), integer()}}.
-spec eta(integer(), float()) -> eta().
eta(Left, DownloadRate) ->
        calendar:seconds_to_daystime(round(Left / DownloadRate)).

% @doc Returns the number of seconds elapsed as gregorian calendar seconds
% @end
-spec now_secs() -> integer().
now_secs() ->
    calendar:datetime_to_gregorian_seconds(
     calendar:local_time()).
