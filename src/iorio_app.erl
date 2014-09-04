-module(iorio_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    Dispatch = cowboy_router:compile([
        {'_', [
               {"/listen", bullet_handler, [{handler, iorio_listen_handler}]},
               {"/stream/:bucket/:stream", iorio_data_handler, []},
               {"/list/:bucket", iorio_list_handler, []},
               {"/ping", iorio_ping_handler, []},
               {"/ui/[...]", cowboy_static, {priv_dir, iorio, "assets",
                                             [{mimetypes, cow_mimetypes, all}]}}
        ]}
    ]),
    ApiPort = application:get_env(iorio, port, 8080),
    ApiAcceptors = application:get_env(iorio, nb_acceptors, 100),
    {ok, _} = cowboy:start_http(http, ApiAcceptors, [{port, ApiPort}], [
        {env, [{dispatch, Dispatch}]}
    ]),

    case iorio_sup:start_link() of
        {ok, Pid} ->
            ok = riak_core:register([{vnode_module, iorio_vnode}]),

            ok = riak_core_ring_events:add_guarded_handler(iorio_ring_event_handler, []),
            ok = riak_core_node_watcher_events:add_guarded_handler(iorio_node_event_handler, []),
            ok = riak_core_node_watcher:service_up(iorio, self()),

            {ok, Pid};
        {error, Reason} ->
            {error, Reason}
    end.

stop(_State) ->
    ok.
