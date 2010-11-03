%% Individual pieces are represented via the piece record
-record(piece, {idpn, % {Id, PieceNumber} pair identifying the piece
                hash, % Hash of piece
                id, % (IDX) Id of this piece owning this piece, again for an index
                piece_number, % Piece Number of piece, replicated for fast qlc access
                files, % File operations to manipulate piece
                left = unknown, % Number of chunks left...
                state}). % (IDX) state is: fetched | not_fetched | chunked
