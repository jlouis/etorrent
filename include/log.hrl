%%% Created : 14 Mar 2008 by Mats Cronqvist <masse@kreditor.se>

%% @doc
%% @end

-author('Mats Cronqvist').

%% Simplified into oblivion.
-define(log(T), error_logger:info_report(
                  [process_info(self(),current_function),{line,?LINE}|T])).

