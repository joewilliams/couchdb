% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_replicator_doc_copiers).

-export([spawn_doc_copiers/5]).

-include("couch_db.hrl").
-include("couch_api_wrap.hrl").

-define(DOC_BATCH_SIZE, 50).



spawn_doc_copiers(Cp, Source, Target, MissingRevsQueue, CopiersCount) ->
    lists:map(
        fun(_) ->
            spawn_link(fun() ->
                doc_copy_loop(Cp, Source, Target, MissingRevsQueue)
            end)
        end,
        lists:seq(1, CopiersCount)).


-record(doc_acc, {
    docs = [],
    seqs = [],
    read = 0,
    written = 0,
    wfail = 0
}).

doc_copy_loop(Cp, Source, Target, MissingRevsQueue) ->
    Result = case couch_work_queue:dequeue(MissingRevsQueue, ?DOC_BATCH_SIZE) of
    closed ->
        ?LOG_DEBUG("Doc copier ~p got missing revs queue closed", [self()]),
        stop;

    {ok, [{doc_id, _} | _] = DocIds} ->
        Acc = lists:foldl(
            fun({doc_id, Id}, Acc) ->
                ?LOG_DEBUG("Doc copier ~p got {doc_id, ~p}", [self(), Id]),
                {ok, Acc2} = couch_api_wrap:open_doc_revs(
                    Source, Id, all, [],
                    fun(R, A) -> doc_handler(R, nil, Target, A) end, Acc),
                Acc2
            end,
            #doc_acc{}, DocIds),
        {Source, Acc};

    {ok, IdRevList} ->
        lists:foldl(
            fun({Id, Revs, PossibleAncestors, Seq} = IdRev, {SrcDb, BulkAcc}) ->
                ?LOG_DEBUG("Doc copier ~p got ~p", [self(), IdRev]),
                SrcDb2 = couch_api_wrap:maybe_reopen_db(SrcDb, Seq),
                {ok, BulkAcc2} = couch_api_wrap:open_doc_revs(
                    SrcDb2, Id, Revs, [{atts_since, PossibleAncestors}],
                    fun(R, A) -> doc_handler(R, Seq, Target, A) end,
                    BulkAcc),
                {SrcDb2, BulkAcc2}
            end,
            {Source, #doc_acc{}}, IdRevList)
    end,
    case Result of
    {Source2, DocAcc} ->
        #doc_acc{seqs = SeqsDone} = DocAcc2 = bulk_write_docs(DocAcc, Target),
        seqs_done(SeqsDone, Cp),
        send_stats(DocAcc2, Cp),
        doc_copy_loop(Cp, Source2, Target, MissingRevsQueue);
    stop ->
        ok
    end.


doc_handler({ok, #doc{atts = []} = Doc}, Seq, _Target, Acc) ->
    update_bulk_doc_acc(Acc, Seq, Doc);

doc_handler({ok, Doc}, Seq, Target, Acc) ->
    write_doc(Doc, Seq, Target, Acc);

doc_handler(_, _, _, Acc) ->
    Acc.


update_bulk_doc_acc(#doc_acc{docs = Docs, read = Read} = Acc, nil, Doc) ->
    Acc#doc_acc{
        docs = [Doc | Docs],
        read = Read + 1
    };

update_bulk_doc_acc(#doc_acc{seqs = [{Seq, Count} | Rest]} = Acc, Seq, Doc) ->
    Acc#doc_acc{
        docs = [Doc | Acc#doc_acc.docs],
        seqs = [{Seq, Count + 1} | Rest],
        read = Acc#doc_acc.read + 1
    };

update_bulk_doc_acc(#doc_acc{seqs = Seqs, read = Read} = Acc, Seq, Doc) ->
    Acc#doc_acc{
        docs = [Doc | Acc#doc_acc.docs],
        seqs = [{Seq, 1} | Seqs],
        read = Read + 1
    }.


write_doc(Doc, Seq, Db, #doc_acc{written = W, wfail = F, read = R} = Acc) ->
    SeqsDone = case Acc#doc_acc.seqs of
    [{Seq, Count} | RestSeqs] ->
        [{Seq, Count + 1} | RestSeqs];
    RestSeqs ->
        [{Seq, 1} | RestSeqs]
    end,
    case couch_api_wrap:update_doc(Db, Doc, [], replicated_changes) of
    {ok, _} ->
        Acc#doc_acc{written = W + 1, read = R + 1, seqs = SeqsDone};
    {error, <<"unauthorized">>} ->
        ?LOG_ERROR("Replicator: unauthorized to write document ~s to ~s",
            [Doc#doc.id, couch_api_wrap:db_uri(Db)]),
        Acc#doc_acc{wfail = F + 1, read = R + 1, seqs = SeqsDone};
    _ ->
        Acc#doc_acc{wfail = F + 1, read = R + 1, seqs = SeqsDone}
    end.


bulk_write_docs(#doc_acc{docs = []} = Acc, _) ->
    Acc;
bulk_write_docs(#doc_acc{docs = Docs, written = W, wfail = Wf} = Acc, Db) ->
    {ok, Errors} = couch_api_wrap:update_docs(
        Db, Docs, [delay_commit], replicated_changes),
    DbUri = couch_api_wrap:db_uri(Db),
    lists:foreach(
        fun({[ {<<"id">>, Id}, {<<"error">>, <<"unauthorized">>} ]}) ->
                ?LOG_ERROR("Replicator: unauthorized to write document"
                    " ~s to ~s", [Id, DbUri]);
            (_) ->
                ok
        end, Errors),
    Acc#doc_acc{
        wfail = Wf + length(Errors),
        written = W + length(Docs) - length(Errors)
    }.


seqs_done([], _) ->
    ok;
seqs_done([{nil, _} | _], _) ->
    ok;
seqs_done(SeqCounts, Cp) ->
    ok = gen_server:cast(Cp, {seq_changes_done, SeqCounts}).


send_stats(#doc_acc{read = R, written = W, wfail = Wf}, Cp) ->
    Stats = #rep_stats{
        docs_read = R,
        docs_written = W,
        doc_write_failures = Wf
    },
    ok = gen_server:cast(Cp, {add_stats, Stats}).