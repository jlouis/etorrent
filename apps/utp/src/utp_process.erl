%% @doc Handle a queue of processes waiting on a socket
%%
%% This module abstracts a type of processes queues. When a process want to either send or
%% receive on a socket, it enqueues itself on these queues and waits in line. When we want
%% to feed data from the socket to rest of Erlang, we use processes from these queues to
%% do it.
%% @end
-module(utp_process).

-export([
	 mk/0,

	 enqueue_sender/3,
	 enqueue_receiver/3,

	 dequeue_packet/2
	]).
-record(process_info, {
	  receiver_q :: queue(),
	  sender_q   :: queue()
}).
-type t() :: #process_info{}.
-export_type([t/0]).

mk() ->
    #process_info { receiver_q = queue:new(),
		    sender_q   = queue:new() }.

enqueue_receiver(From, Length, #process_info { receiver_q = RQ } = PI) ->
    NQ = queue:in({receiver, From, Length, <<>>}, RQ),
    PI#process_info { receiver_q = NQ }.

enqueue_sender(From, Data, #process_info { sender_q = SQ } = PI) ->
    NQ = queue:in({sender, From, Data}, SQ),
    PI#process_info { sender_q = NQ }.


dequeue_packet(#process_info { sender_q = SQ } = PI, Size) when Size > 0 ->
    case dequeue_packet(<<>>, SQ, Size) of
	{ok, Payload, NewSQ} ->
	    {value, Payload, PI#process_info { sender_q = NewSQ }};
	{partial, <<>>, SQ} ->
	    none;
	{partial, Payload, NewSQ} ->
	    {value, Payload, PI#process_info { sender_q = NewSQ }}
    end.

dequeue_packet(Payload, Q, 0) ->
    {ok, Payload, Q};
dequeue_packet(Payload, Q, N) when is_integer(N) ->
    case queue:out(Q) of
	{empty, _} ->
	    {partial, Payload, Q};
	{value, {sender, From, Data}, NewQ} ->
	    case Data of
		<<PL:N/binary, Rest/binary>> ->
		    {ok, <<Payload/binary, PL/binary>>,
		     case Rest of
			 <<>> ->
			     gen_utp:reply(From, ok),
			     NewQ;
			 Remaining ->
			     queue:in_r({sender, From, Remaining}, NewQ)
		     end};
		<<PL/binary>> when byte_size(PL) < N ->
		    gen_utp:reply(From, ok),
		    dequeue_packet(<<Payload/binary, PL/binary>>,
				   NewQ,
				   N - byte_size(PL))
	    end
    end.

