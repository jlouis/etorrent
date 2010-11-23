-define(INFO(T), error_logger:info_report(T)).
-define(WARN(T), error_logger:warning_report(
        [process_info(self(), current_function), {line, ?LINE} | T])).
-define(ERR(T), error_logger:error_report(
        [process_info(self(), current_function), {line, ?LINE} | T])).

-define(DEBUG(Format, Args), io:format("D(~p:~p:~p) : "++Format++"~n",
                                       [self(),?MODULE,?LINE]++Args)).
-define(DEBUGP(Args), io:format("D(~p:~p:~p) : ~p~n",
                                       [self(),?MODULE,?LINE, Args])).

