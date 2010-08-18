%% A mapping containing the chunks tracking
-record(chunk, {idt :: {integer() | '_' | '$1',
			integer() | '_' | '$1',
			not_fetched | fetched | {assigned, pid() | '_'} | '_'},
                chunks :: [integer() | {integer(), integer(), [term()]}] | '_' | '$2'}).


