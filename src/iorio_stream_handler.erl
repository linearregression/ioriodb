-module(iorio_stream_handler).

-export([init/3, terminate/3]).

-export([rest_init/2,
         rest_terminate/2,
         allowed_methods/2,
         content_types_accepted/2,
         content_types_provided/2,
         is_authorized/2,
         from_json/2,
         to_json/2
        ]).

-record(state, {bucket, stream, from_sn, limit, secret, session=nil}).

-include_lib("sblob/include/sblob.hrl").
-include("include/iorio.hrl").

to_int_or(Bin, Default) ->
    Str = binary_to_list(Bin),
    case string:to_integer(Str) of
        {Int, ""} -> Int;
        _ -> Default
    end.

init({tcp, http}, _Req, _Opts) -> {upgrade, protocol, cowboy_rest}.

rest_init(Req, [{secret, Secret}]) ->
    {Bucket, Req1} = cowboy_req:binding(bucket, Req),
    {Stream, Req2} = cowboy_req:binding(stream, Req1),
    {FromSNStr, Req3} = cowboy_req:qs_val(<<"from">>, Req2, <<"">>),
    {LimitStr, Req4} = cowboy_req:qs_val(<<"limit">>, Req3, <<"1">>),

    FromSN = to_int_or(FromSNStr, nil),
    Limit = to_int_or(LimitStr, 1),

	{ok, Req4, #state{bucket=Bucket, stream=Stream, from_sn=FromSN,
                      limit=Limit, secret=Secret}}.

allowed_methods(Req, State) -> {[<<"GET">>, <<"POST">>], Req, State}.

get_session(#state{session=Session}) -> Session.
set_session(State, Session) -> State#state{session=Session}.

action_for_method(<<"POST">>) ->
    ?PERM_STREAM_PUT;
action_for_method(<<"GET">>) ->
    ?PERM_STREAM_GET.

action_for_request(Req) ->
    {Method, Req1} = cowboy_req:method(Req),
    Action = action_for_method(Method),
    {Req1, Action}.

is_authorized(Req, State=#state{secret=Secret, bucket=Bucket, stream=Stream}) ->
    GetSession = fun get_session/1,
    SetSession = fun set_session/2,
    {Req1, Action} = action_for_request(Req),
    iorio_session:handle_is_authorized_for_stream(Req1, Secret, State,
                                                  GetSession, SetSession,
                                                  Bucket, Stream, Action).

content_types_accepted(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, from_json}], Req, State}.

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, to_json}], Req, State}.

sblob_to_json(#sblob_entry{seqnum=SeqNum, timestamp=Timestamp, data=_Data}) ->
    [{meta, [{id, SeqNum}, {t, Timestamp}]}].

sblob_to_json_full(#sblob_entry{seqnum=SeqNum, timestamp=Timestamp, data=Data}) ->
    [{meta, [{id, SeqNum}, {t, Timestamp}]}, {data, jsx:decode(Data)}].

to_json(Req, State=#state{bucket=Bucket, stream=Stream, from_sn=From, limit=Limit}) ->
    Blobs = iorio:get(Bucket, Stream, From, Limit),
    Items = lists:map(fun sblob_to_json_full/1, Blobs),

    {jsx:encode(Items), Req, State}.

store_blob(Bucket, Stream, Body) ->
    {ok, SblobEntry} = iorio:put(Bucket, Stream, Body),
    ResultJson = sblob_to_json(SblobEntry),
    jsx:encode(ResultJson).

store_blob_and_reply(Req, State, Bucket, Stream, Body) ->
    Result = store_blob(Bucket, Stream, Body),
    Req1 = cowboy_req:set_resp_body(Result, Req),
    {true, Req1, State}.

from_json(Req, State=#state{bucket=Bucket, stream=Stream}) ->
    {ok, Body, Req1} = cowboy_req:body(Req),
    case jsx:is_json(Body) of
        true ->
            store_blob_and_reply(Req1, State, Bucket, Stream, Body);
        false ->
            {false, iorio_http:invalid_body(Req1), State}
    end.


rest_terminate(_Req, _State) ->
	ok.

terminate(_Reason, _Req, _State) ->
	ok.
