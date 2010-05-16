%% The type of torrent records.

-type(torrent_state() :: 'leeching' | 'seeding' | 'endgame' | 'unknown').
%% A single torrent is represented as the 'torrent' record
-record(torrent,
    {id :: non_neg_integer(), % Unique identifier of torrent, monotonically increasing
     left :: non_neg_integer(), % How many bytes are there left before we have the
                                % full torrent
     total  :: non_neg_integer(), % How many bytes are there in total
     uploaded :: non_neg_integer(), % How many bytes have we uploaded
     downloaded :: non_neg_integer(), % How many bytes have we downloaded
     pieces = unknown :: non_neg_integer() | 'unknown', % Number of pieces in torrent
     seeders = 0 :: non_neg_integer(), % How many people have a completed file?
     leechers = 0 :: non_neg_integer(), % How many people are downloaded
     state :: torrent_state()}).
