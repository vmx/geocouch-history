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

-module(couch_spatial_group).
-behaviour(gen_server).

%% API
-export([start_link/1, request_group/2, open_db_group/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("couch_db.hrl").
-include("couch_spatial.hrl").

-record(group_state, {
%    type,
    db_name,
    init_args,
    group,
    updater_pid=nil,
%    compactor_pid=nil,
    waiting_commit=false,
    waiting_list=[],
    ref_counter=nil
}).


% from template
start_link(InitArgs) ->
    case gen_server:start_link(couch_spatial_group,
            {InitArgs, self(), Ref = make_ref()}, []) of
    {ok, Pid} ->
        {ok, Pid};
    ignore ->
        receive
        {Ref, Pid, Error} ->
            case process_info(self(), trap_exit) of
            {trap_exit, true} -> receive {'EXIT', Pid, _} -> ok end;
            {trap_exit, false} -> ok
            end,
            Error
        end;
    Error ->
        Error
    end.

% api methods
request_group(Pid, Seq) ->
    ?LOG_DEBUG("request_group {Pid, Seq} ~p", [{Pid, Seq}]),
    case gen_server:call(Pid, {request_group, Seq}, infinity) of
    {ok, Group, RefCounter} ->
        couch_ref_counter:add(RefCounter),
        {ok, Group};
    Error ->
        ?LOG_DEBUG("request_group Error ~p", [Error]),
        throw(Error)
    end.



init({InitArgs, ReturnPid, Ref}) ->
    process_flag(trap_exit, true),
    case prepare_group(InitArgs, false) of
    {ok, #spatial_group{db=Db, fd=Fd, current_seq=Seq}=Group} ->
        case Seq > couch_db:get_update_seq(Db) of
        true ->
            ReturnPid ! {Ref, self(), {error, invalid_view_seq}},
            ignore;
        _ ->
            couch_db:monitor(Db),
            Owner = self(),
            Pid = spawn_link(
                fun()-> couch_spatial_updater:update(Owner, Group) end
            ),
            {ok, RefCounter} = couch_ref_counter:start([Fd]),
            {ok, #group_state{
                    db_name=couch_db:name(Db),
                    init_args=InitArgs,
                    updater_pid = Pid,
                    group=Group,
                    ref_counter=RefCounter}}
        end;
    Error ->
        ReturnPid ! {Ref, self(), Error},
        ignore
    end.

% NOTE vmx: There's a lenghy comment about this call in couch_view_group.erl
handle_call({request_group, RequestSeq}, From,
        #group_state{
            db_name=DbName,
            group=#spatial_group{current_seq=GroupSeq}=Group,
            updater_pid=nil,
            waiting_list=WaitList
            }=State) when RequestSeq > GroupSeq ->
    {ok, Db} = couch_db:open_int(DbName, []),
    Group2 = Group#spatial_group{db=Db},
    Owner = self(),
    Pid = spawn_link(fun()-> couch_spatial_updater:update(Owner, Group2) end),

    {noreply, State#group_state{
        updater_pid=Pid,
        group=Group2,
        waiting_list=[{From,RequestSeq}|WaitList]
        }, infinity};

% If the request seqence is less than or equal to the seq_id of a known Group,
% we respond with that Group.
handle_call({request_group, RequestSeq}, _From, #group_state{
            group = #spatial_group{current_seq=GroupSeq} = Group,
            ref_counter = RefCounter
        } = State) when RequestSeq =< GroupSeq  ->
?LOG_DEBUG("(2) request_group handler: seqs: req: ~p, group: ~p", [RequestSeq, GroupSeq]),
    {reply, {ok, Group, RefCounter}, State};

% Otherwise: TargetSeq => RequestSeq > GroupSeq
% We've already initiated the appropriate action, so just hold the response until the group is up to the RequestSeq
handle_call({request_group, RequestSeq}, From,
        #group_state{waiting_list=WaitList}=State) ->
?LOG_DEBUG("(3) request_group handler: seqs: req: ~p", [RequestSeq]),
    {noreply, State#group_state{
        waiting_list=[{From, RequestSeq}|WaitList]
        }, infinity}.

handle_cast({partial_update, Pid, NewGroup}, #group_state{updater_pid=Pid}
        = State) ->
    #group_state{
        db_name = DbName,
        waiting_commit = WaitingCommit
    } = State,
    NewSeq = NewGroup#spatial_group.current_seq,
    ?LOG_INFO("checkpointing spatial update at seq ~p for ~s ~s", [NewSeq,
        DbName, NewGroup#spatial_group.name]),
    if not WaitingCommit ->
        erlang:send_after(1000, self(), delayed_commit);
    true -> ok
    end,
    {noreply, State#group_state{group=NewGroup, waiting_commit=true}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(delayed_commit, #group_state{db_name=DbName,group=Group}=State) ->
    {ok, Db} = couch_db:open_int(DbName, []),
    CommittedSeq = couch_db:get_committed_update_seq(Db),
    couch_db:close(Db),
    if CommittedSeq >= Group#spatial_group.current_seq ->
        % save the header
        Header = {Group#spatial_group.sig, get_index_header_data(Group)},
        ok = couch_file:write_header(Group#spatial_group.fd, Header),
        {noreply, State#group_state{waiting_commit=false}};
    true ->
        % We can't commit the header because the database seq that's fully
        % committed to disk is still behind us. If we committed now and the
        % database lost those changes our view could be forever out of sync
        % with the database. But a crash before we commit these changes, no big
        % deal, we only lose incremental changes since last committal.
        erlang:send_after(1000, self(), delayed_commit),
        {noreply, State#group_state{waiting_commit=true}}
    end;

handle_info({'EXIT', FromPid, {new_group, #spatial_group{db=Db}=Group}},
        #group_state{db_name=DbName,
            updater_pid=UpPid,
            ref_counter=RefCounter,
            waiting_list=WaitList,
            waiting_commit=WaitingCommit}=State) when UpPid == FromPid ->
    ok = couch_db:close(Db),
    if not WaitingCommit ->
        erlang:send_after(1000, self(), delayed_commit);
    true -> ok
    end,
    case reply_with_group(Group, WaitList, [], RefCounter) of
    [] ->
        {noreply, State#group_state{waiting_commit=true, waiting_list=[],
                group=Group#spatial_group{db=nil}, updater_pid=nil}};
    StillWaiting ->
        % we still have some waiters, reopen the database and reupdate the index
        {ok, Db2} = couch_db:open_int(DbName, []),
        Group2 = Group#spatial_group{db=Db2},
        Owner = self(),
        Pid = spawn_link(fun() -> couch_view_updater:update(Owner, Group2) end),
        {noreply, State#group_state{waiting_commit=true,
                waiting_list=StillWaiting, group=Group2, updater_pid=Pid}}
    end;

handle_info({'EXIT', _FromPid, normal}, State) ->
    {noreply, State};

handle_info({'EXIT', FromPid, {{nocatch, Reason}, _Trace}}, State) ->
    ?LOG_DEBUG("Uncaught throw() in linked pid: ~p", [{FromPid, Reason}]),
    {stop, Reason, State};

handle_info({'EXIT', FromPid, Reason}, State) ->
    ?LOG_DEBUG("Exit from linked pid: ~p", [{FromPid, Reason}]),
    {stop, Reason, State};

% Shutting down will trigger couch_spatial:handle_info(EXIT...)
handle_info({'DOWN',_,_,_,_}, State) ->
    ?LOG_INFO("Shutting down spatial group server, monitored db is closing.", []),
    {stop, normal, reply_all(State, shutdown)};

handle_info(_Msg, Server) ->
    {noreply, Server}.

terminate(_Reason, _Srv) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

% reply_with_group/3
% for each item in the WaitingList {Pid, Seq}
% if the Seq is =< GroupSeq, reply
reply_with_group(Group=#spatial_group{current_seq=GroupSeq}, [{Pid, Seq}|WaitList],
        StillWaiting, RefCounter) when Seq =< GroupSeq ->
    gen_server:reply(Pid, {ok, Group, RefCounter}),
    reply_with_group(Group, WaitList, StillWaiting, RefCounter);

% else
% put it in the continuing waiting list
reply_with_group(Group, [{Pid, Seq}|WaitList], StillWaiting, RefCounter) ->
    reply_with_group(Group, WaitList, [{Pid, Seq}|StillWaiting], RefCounter);

% return the still waiting list
reply_with_group(_Group, [], StillWaiting, _RefCounter) ->
    StillWaiting.

reply_all(#group_state{waiting_list=WaitList}=State, Reply) ->
    [catch gen_server:reply(Pid, Reply) || {Pid, _} <- WaitList],
    State#group_state{waiting_list=[]}.

open_db_group(DbName, DDocId) ->
    case couch_db:open_int(DbName, []) of
    {ok, Db} ->
        case couch_db:open_doc(Db, DDocId) of
        {ok, Doc} ->
            {ok, Db, design_doc_to_spatial_group(Doc)};
        Else ->
            couch_db:close(Db),
            Else
        end;
    Else ->
        Else
    end.


design_doc_to_spatial_group(#doc{id=Id,body={Fields}}) ->
    Language = proplists:get_value(<<"language">>, Fields, <<"javascript">>),
    {DesignOptions} = proplists:get_value(<<"options">>, Fields, {[]}),
    {RawIndexes} = proplists:get_value(<<"spatial">>, Fields, {[]}),
    % add the views to a dictionary object, with the map source as the key
    DictBySrc =
    lists:foldl(fun({Name, IndexSrc}, DictBySrcAcc) ->
        Index =
        case dict:find({IndexSrc}, DictBySrcAcc) of
            {ok, Index0} -> Index0;
            error -> #spatial{def=IndexSrc} % create new spatial index object
        end,
        Index2 = Index#spatial{index_names=[Name|Index#spatial.index_names]},
        dict:store({IndexSrc}, Index2, DictBySrcAcc)
    end, dict:new(), RawIndexes),
    % number the views
    {Indexes, _N} = lists:mapfoldl(
        fun({_Src, Index}, N) ->
            {Index#spatial{id_num=N},N+1}
        end, 0, lists:sort(dict:to_list(DictBySrc))),
    set_index_sig(#spatial_group{name=Id, indexes=Indexes, def_lang=Language,
                                 design_options=DesignOptions}).

set_index_sig(#spatial_group{
            indexes=Indexes,
            def_lang=Language,
            design_options=DesignOptions}=G) ->
    G#spatial_group{sig=erlang:md5(term_to_binary({Indexes, Language,
                                                   DesignOptions}))}.



prepare_group({RootDir, DbName, #spatial_group{sig=Sig}=Group}, ForceReset)->
    case couch_db:open_int(DbName, []) of
    {ok, Db} ->
        case open_index_file(RootDir, DbName, Sig) of
        {ok, Fd} ->
            if ForceReset ->
                % this can happen if we missed a purge
                {ok, reset_file(Db, Fd, DbName, Group)};
            true ->
                % 09 UPGRADE CODE
                ok = couch_file:upgrade_old_header(Fd, <<$r, $c, $k, 0>>),
                case (catch couch_file:read_header(Fd)) of
                {ok, {Sig, HeaderInfo}} ->
                    % sigs match!
                    {ok, init_group(Db, Fd, Group, HeaderInfo)};
                _ ->
                    % this happens on a new file
                    {ok, reset_file(Db, Fd, DbName, Group)}
                end
            end;
        Error ->
            catch delete_index_file(RootDir, DbName, Sig),
            Error
        end;
    Else ->
        Else
    end.

get_index_header_data(#spatial_group{current_seq=Seq, purge_seq=PurgeSeq,
            id_btree=IdBtree,indexes=Indexes}) ->
    IndexStates = [TreePos || #spatial{treepos=TreePos} <- Indexes],
    #spatial_index_header{seq=Seq,
            purge_seq=PurgeSeq,
            id_btree_state=couch_btree:get_state(IdBtree),
            index_states=IndexStates}.

delete_index_file(RootDir, DbName, GroupSig) ->
    file:delete(index_file_name(RootDir, DbName, GroupSig)).

index_file_name(RootDir, DbName, GroupSig) ->
    couch_view_group:design_root(RootDir, DbName) ++
        couch_util:to_hex(?b2l(GroupSig)) ++".spatial".

open_index_file(RootDir, DbName, GroupSig) ->
    FileName = index_file_name(RootDir, DbName, GroupSig),
    case couch_file:open(FileName) of
    {ok, Fd}        -> {ok, Fd};
    {error, enoent} -> couch_file:open(FileName, [create]);
    Error           -> Error
    end.

reset_group(#spatial_group{indexes=Indexes}=Group) ->
    Indexes2 = [Index#spatial{treepos=nil} || Index <- Indexes],
    Group#spatial_group{db=nil,fd=nil,query_server=nil,current_seq=0,
            indexes=Indexes2}.

reset_file(Db, Fd, DbName, #spatial_group{sig=Sig,name=Name} = Group) ->
    ?LOG_DEBUG("Resetting spatial group index \"~s\" in db ~s", [Name, DbName]),
    ok = couch_file:truncate(Fd, 0),
    ok = couch_file:write_header(Fd, {Sig, nil}),
    init_group(Db, Fd, reset_group(Group), nil).


init_group(Db, Fd, #spatial_group{indexes=Indexes}=Group, nil) ->
    init_group(Db, Fd, Group,
        #spatial_index_header{seq=0, purge_seq=couch_db:get_purge_seq(Db),
            id_btree_state=nil, index_states=[nil || _ <- Indexes]});
init_group(Db, Fd, #spatial_group{indexes=Indexes}=Group,
           IndexHeader) ->
    #spatial_index_header{seq=Seq, purge_seq=PurgeSeq,
            id_btree_state=IdBtreeState, index_states=IndexStates} = IndexHeader,
    {ok, IdBtree} = couch_btree:open(IdBtreeState, Fd),
    Indexes2 = lists:zipwith(
        fun(IndexTreePos, Index) ->
            %{ok, Btree} = couch_btree:open(BtreeState, Fd),
            Index#spatial{treepos=IndexTreePos}
        end,
        IndexStates, Indexes),
    Group#spatial_group{db=Db, fd=Fd, current_seq=Seq, purge_seq=PurgeSeq,
        id_btree=IdBtree, indexes=Indexes2}.
