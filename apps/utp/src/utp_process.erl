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
         putback_receiver/4,
         dequeue_receiver/1,

         fill_via_send_queue/2,
	 bytes_in_recv_buffer/1,
         recv_buffer_empty/1,

         apply_all/2,
         apply_senders/2,
         apply_receivers/2,

         clear_senders/1
	]).

-export([error_all/2]).
-record(proc_info, {
	  receiver_q :: queue(),
	  sender_q   :: queue()
}).
-opaque({t,{type,{29,16},record,[{atom,{29,17},proc_info}]},[]}).
-export_type([t/0]).

mk() ->
    #proc_info { receiver_q = queue:new(),
                 sender_q   = queue:new() }.

apply_all(PI, F) ->
    apply_senders(PI, F),
    apply_receivers(PI, F).

apply_senders(PI, F) ->
    [F(From) || From <- all_senders(PI)].

apply_receivers(PI, F) ->
    [F(From) || From <- all_receivers(PI)].

clear_senders(PI) ->
    PI#proc_info { sender_q = queue:new() }.

all_senders(#proc_info { sender_q = SQ }) ->
    [From || {sender, From, _Data} <- queue:to_list(SQ)].

all_receivers(#proc_info { receiver_q = RQ }) ->
    [From || {receiver, From, _, _} <- queue:to_list(RQ)].

-spec enqueue_receiver(term(), integer(), t()) -> t().
enqueue_receiver(From, Length, #proc_info { receiver_q = RQ } = PI) ->
    NQ = queue:in({receiver, From, Length, <<>>}, RQ),
    PI#proc_info { receiver_q = NQ }.

-spec dequeue_receiver(t()) -> {ok, term(), t()} | empty.
dequeue_receiver(#proc_info { receiver_q = RQ } = PI) ->
    case queue:out(RQ) of
        {{value, Item}, NQ} ->
            {ok, Item, PI#proc_info { receiver_q = NQ }};
        {empty, _Q} ->
            empty
    end.

putback_receiver(From, Length, Data, #proc_info { receiver_q = RQ} = PI) ->
    NQ = queue:in_r({receiver, From, Length, Data}, RQ),
    PI#proc_info { receiver_q = NQ }.

-spec enqueue_sender({pid(), reference()}, binary(), t()) -> t().
enqueue_sender(From, Data, #proc_info { sender_q = SQ } = PI) when is_binary(Data) ->
    NQ = queue:in({sender, From, Data}, SQ),
    PI#proc_info { sender_q = NQ }.

fill_via_send_queue(N, #proc_info { sender_q = SQ } = PI) when is_integer(N) ->
    case dequeue(N, SQ, <<>>) of
        {done, Bin, SQ1} ->
            {filled, Bin, PI#proc_info { sender_q = SQ1}};
        {partial, Bin, SQ1} ->
            {partial, Bin, PI#proc_info { sender_q = SQ1}};
        zero ->
            zero
    end.

dequeue(0, _Q, <<>>) ->
    zero;
dequeue(0, Q, Bin) ->
    {done, Bin, Q};
dequeue(N, Q, Acc) ->
    {R, NQ} = queue:out(Q),
    case R of
        empty when Acc == <<>> ->
            zero;
        empty when Acc =/= <<>> ->
            {partial, Acc, Q}; % Should really use NQ here, but the dialyzer dislikes it
                               % probably due to an internal dialyzer mistake
        {value, {sender, From, Data}} when byte_size(Data) =< N ->
            gen_utp_worker:reply(From, ok),
            dequeue(N - byte_size(Data), NQ, <<Acc/binary, Data/binary>>);
        {value, {sender, From, Data}} when byte_size(Data) > N ->
            <<Take:N/binary, Rest/binary>> = Data,
            dequeue(0, queue:in_r({sender, From, Rest}, NQ), <<Acc/binary, Take/binary>>)
    end.

%% @doc Predicate: is the receive buffer empty
%% This function is a faster variant of `bytes_in_recv_buffer/1` for the 0 question case
%% @end
-spec recv_buffer_empty(t()) -> boolean().
recv_buffer_empty(#proc_info { receiver_q = RQ }) ->
    queue:is_empty(RQ).

%% @doc Return how many bytes there are left in the receive buffer
%% @end
-spec bytes_in_recv_buffer(t()) -> integer().
bytes_in_recv_buffer(#proc_info { receiver_q = RQ }) ->
    L = queue:to_list(RQ),
    lists:sum([byte_size(Payload) || {receiver, _From, _Sz, Payload} <- L]).




error_all(ProcessInfo, ErrorReason) ->
    F = fun(From) ->
                gen_fsm:reply(From, {error, ErrorReason})
        end,
    apply_all(ProcessInfo, F),
    mk().
