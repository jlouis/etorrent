-record(rate_mgr, {pid :: tuple(),   % Pid of receiver
                   last_got :: integer() | 'unknown' | '_',
                   rate :: float() | '_'}). % Rate

