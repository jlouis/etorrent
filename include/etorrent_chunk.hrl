%% A mapping containing the chunks tracking
-record(chunk, {idt, % {id, piece_number, state} tuple
                     % state is fetched | {assigned, Pid} | not_fetched,
                chunks}). % {offset, size}


