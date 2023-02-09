-module(ra_log_cache).

-include("ra.hrl").

-export([
         init/0,
         reset/1,
         add/2,
         fetch/2,
         fetch/3,
         get_items/2,
         get_items/3,
         fold/5,
         trim/2,
         set_last/2,
         flush/1,
         needs_flush/1,
         size/1,
         range/1
         ]).

%% holds static or rarely changing fields
% -record(cfg, {}).

-record(?MODULE, {tbl :: ets:tid(),
                  range :: undefined | {ra:index(), ra:index()},
                  cache = #{} :: #{ra:index() => log_entry()}}).

-opaque state() :: #?MODULE{}.

-export_type([
              state/0
              ]).

-spec init() -> state().
init() ->
    Tid = ets:new(?MODULE, [set, private]),
    #?MODULE{tbl = Tid}.

-spec reset(state()) -> state().
reset(#?MODULE{range = undefined} = State) ->
    State;
reset(#?MODULE{tbl = Tid} = State) ->
    true = ets:delete_all_objects(Tid),
    State#?MODULE{cache = #{},
                  range = undefined}.

-spec add(log_entry(), state()) -> state().
add({Idx, _, _} = Entry, #?MODULE{range = {From, To},
                         cache = Cache} = State)
  when Idx == To+1 ->
    State#?MODULE{cache = maps:put(Idx, Entry, Cache),
                  range = {From, Idx}};
add({Idx, _, _} = Entry, #?MODULE{range = undefined,
                                  cache = Cache} = State) ->
    State#?MODULE{cache = maps:put(Idx, Entry, Cache),
                  range = {Idx, Idx}};
add({Idx, _, _} = Entry, #?MODULE{range = {_From, To}} = State)
  when Idx =< To ->
    add(Entry, set_last(Idx - 1, State)).

-spec fetch(ra:index(), state()) -> log_entry().
fetch(Idx, State) ->
    case fetch(Idx, State, undefined) of
        undefined ->
            exit({ra_log_cache_key_not_found, Idx});
        Item ->
            Item
    end.

-spec fetch(ra:index(), state(), term()) -> term() | log_entry().
fetch(Idx, #?MODULE{tbl = Tid, cache = Cache}, Default) ->
    case maps:get(Idx, Cache, undefined) of
        undefined ->
            case ets:lookup(Tid, Idx) of
                [] ->
                    Default;
            [Item] ->
                    Item
            end;
        Item ->
            Item
    end.

-spec fold(From :: ra:index(),
           To :: ra:index(),
           fun((log_entry(), Acc) -> Acc),
               Acc,
               state()) ->
    Acc when Acc :: term().
fold(To, To, Fun, Acc, State) ->
    E = fetch(To, State),
    Fun(E, Acc);
fold(From, To, Fun, Acc, State) ->
    E = fetch(From, State),
    fold(From + 1, To, Fun, Fun(E, Acc), State).

-spec get_items(From :: ra:index(), To :: ra:index(), state()) ->
    [log_entry()].
get_items(From, To, #?MODULE{tbl = Tid, cache = Cache}) ->
    get_cache_items(From, To, Cache, Tid, []).

-spec get_items([ra:index()], state()) ->
    {[log_entry()],
     NumRead :: non_neg_integer(),
     Remaining :: [ra:index()]}.
get_items(Indexes, #?MODULE{tbl = Tid, cache = Cache}) ->
    cache_read_sparse(Indexes, Cache, Tid, []).

-spec trim(ra:index(), state()) -> state().
trim(_To, #?MODULE{range = undefined} = State) ->
    State;
trim(To, #?MODULE{tbl = Tid,
                  range = {From, RangeTo},
                  cache = Cache} = State)
  when To >= From andalso
       To < RangeTo ->
    NewRange = {To + 1, RangeTo},
    State#?MODULE{range = NewRange,
                  cache = cache_without(From, To, Cache, Tid)};
trim(_To, State) ->
    reset(State).

-spec set_last(ra:index(), state()) -> state().
set_last(Idx, #?MODULE{tbl = Tid,
                       range = {From, To},
                       cache = Cache} = State)
  when Idx >= From andalso
       Idx =< To ->
    NewRange = {From, Idx},
    State#?MODULE{range = NewRange,
                  cache = cache_without(Idx + 1, To, Cache, Tid)};
set_last(_Idx, State) ->
    reset(State).

-spec flush(state()) -> state().
flush(#?MODULE{tbl = Tid,
               cache = Cache} = State)
  when map_size(Cache) > 0 ->
    _ = ets:insert(Tid, maps:values(Cache)),
    State#?MODULE{cache = #{}};
flush(State) ->
    State.

-spec needs_flush(state()) -> boolean().
needs_flush(#?MODULE{cache = Cache}) ->
    map_size(Cache) > 0.

-spec size(state()) -> non_neg_integer().
size(#?MODULE{tbl = Tid, cache = Cache}) ->
    map_size(Cache) + ets:info(Tid, size).

-spec range(state()) ->
    undefined | {ra:index(), ra:index()}.
range(#?MODULE{range = Range}) ->
    Range.

%% INTERNAL
%%

cache_without(FromIdx, Idx, Cache, _Tid)
  when FromIdx > Idx ->
    Cache;
cache_without(Idx, Idx, Cache, Tid) ->
    _ = ets:delete(Tid, Idx),
    maps:remove(Idx, Cache);
cache_without(FromIdx, ToIdx, Cache, Tid)
  when is_map_key(FromIdx, Cache) ->
    cache_without(FromIdx + 1, ToIdx, maps:remove(FromIdx, Cache), Tid);
cache_without(FromIdx, ToIdx, Cache, Tid) ->
    _ = ets:delete(Tid, FromIdx),
    cache_without(FromIdx + 1, ToIdx, Cache, Tid).

get_cache_items(From, To, _Cache, _Tid, Acc)
  when From > To ->
    Acc;
get_cache_items(From, To, Cache, Tid, Acc) ->
    case Cache of
        #{To := Entry} ->
            get_cache_items(From, To - 1, Cache, Tid, [Entry | Acc]);
        _ ->
            case ets:lookup(Tid, To) of
                [] ->
                    Acc;
                [Entry] ->
                    get_cache_items(From, To - 1, Cache, Tid, [Entry | Acc])
            end
    end.

cache_read_sparse(Indexes, Cache, Tid, Acc) ->
    cache_read_sparse(Indexes, Cache, Tid, 0, Acc).

cache_read_sparse([], _Cache, _Tid, Num, Acc) ->
    {Acc, Num, []}; %% no reminder
cache_read_sparse([Next | Rem] = Indexes, Cache, Tid, Num, Acc) ->
    case Cache of
        #{Next := Entry} ->
            cache_read_sparse(Rem, Cache, Tid, Num + 1, [Entry | Acc]);
        _ ->
            case ets:lookup(Tid, Next) of
                [] ->
                    {Acc, Num, Indexes};
                [Entry] ->
                    cache_read_sparse(Rem, Cache, Tid, Num + 1, [Entry | Acc])
            end
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
