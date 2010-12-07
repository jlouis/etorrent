-module(etorrent_log).
-export([init_settings/0,
         enable/1,
         disable/1,
         is_enabled/1,
         info/3,
         error/3]).

%% ETS-table to use for settings.
log_tab() ->
    etorrent_logging_topics.

%% @doc
%% Load logging settings from the etorrent-config and create a
%% public table so that it can be updated from the shell and read
%% by any process in etorrent that performs logging.
%% @end
-spec init_settings() -> ok.
init_settings() ->
    _ = ets:new(log_tab(), [public, named_table, set]),
    _ = ets:insert(log_tab(), etorrent_config:log_settings()),
    ok.

%% @doc
%% Enable any log messages of this type, this function will not
%% crash if an invalid topic is specified. The topic name must
%% be an atom.
%% @end
-spec enable(atom()) -> ok.
enable(Topic) when is_atom(Topic) ->
    true = ets:insert(log_tab(), {Topic, true}),
    ok.

%% @doc
%% Disable any log messages of this type, this function will not
%% crash if an invalid topic is specified.
%% @end
-spec disable(atom()) -> ok.
disable(Topic) when is_atom(Topic) ->
    true = ets:insert(log_tab(), {Topic, false}),
    ok.
    


%% @doc
%% Lookup whether the user has requested messages of this type to appear
%% in the log. The message will appear in the log if has been enabled
%% with etorrent_log:enable(Topic) or if the default policy is to log
%% all messages.
%% @end
-spec is_enabled(atom()) -> boolean().
is_enabled(Topic) ->
    case ets:lookup(log_tab(), Topic) of
        [{_, Setting}] ->
            Setting;
        [] ->
            case ets:lookup(log_tab(), default) of
                [{default, Policy}] -> Policy
            end
    end.

%% @doc
%% This is equivalent to calling error_logger:info_msg(Format, Args).
%% If the topic has not been enabled in the configuration or using
%% etorrent_log:enable(Topic) the message will be supressed.
%% @end 
-spec info(atom(), string(), list(term())) -> ok.
info(Topic, Format, Args) ->
    case is_enabled(Topic) of
        false -> ok;
        true  -> error_logger:info_msg(Format, Args)
    end.

%% @doc
%% This is equivalent to calling error_logger:error_msg(Format, Args).
%% If the topic has not been enabled in the configuration or using
%% etorrent_log:enable(Topic) the message will be supressed.
%% @end 
-spec error(atom(), string(), list(term())) -> ok.
error(Topic, Format, Args) ->
    case is_enabled(Topic) of
        false -> ok;
        true  -> error_logger:error_msg(Format, Args)
    end.
