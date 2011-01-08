-record(rate_mgr, {pid :: '_' | {integer() | '_', pid() | '_'}, % {Id, Pid} of receiver
                   snub_state :: normal | snubbed | '_',  % Snubbing state
                   rate :: float() | '_'}).               % Rate

