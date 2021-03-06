%% @doc Config parsing and processing for the TOML format
-module(mongoose_config_parser_toml).

-behaviour(mongoose_config_parser).

-export([parse_file/1]).

-ifdef(TEST).
-export([parse/1,
         extract_errors/1]).
-endif.

-include("mongoose.hrl").
-include("ejabberd_config.hrl").

%% Used to create per-host config when the list of hosts is not known yet
-define(HOST_F(Expr), [fun(Host) -> Expr end]).

%% Input: TOML parsed by tomerl
-type toml_key() :: binary().
-type toml_value() :: tomerl:value().
-type toml_section() :: tomerl:section().

%% Output: list of config records, containing key-value pairs
-type option() :: term(). % a part of a config value OR a list of them, may contain config errors
-type top_level_option() :: #config{} | #local_config{} | acl:acl().
-type config_error() :: #{class := error, what := atom(), text := string(), any() => any()}.
-type override() :: {override, atom()}.
-type config() :: top_level_option() | config_error() | override().
-type config_list() :: [config() | fun((ejabberd:server()) -> [config()])]. % see HOST_F

%% Path from the currently processed config node to the root
%%   - toml_key(): key in a toml_section()
%%   - item: item in a list
%%   - tuple(): item in a list, tagged with data from the item, e.g. host name
-type path() :: [toml_key() | item | tuple()].

-spec parse_file(FileName :: string()) -> mongoose_config_parser:state().
parse_file(FileName) ->
    case tomerl:read_file(FileName) of
        {ok, Content} ->
            process(Content);
        {error, Error} ->
            Text = tomerl:format_error(Error),
            ?LOG_ERROR(#{what => toml_parsing_failed,
                         text => Text}),
            mongoose_config_utils:exit_or_halt("Could not load the TOML configuration file")
    end.

-spec process(toml_section()) -> mongoose_config_parser:state().
process(Content) ->
    Config = parse(Content),
    Hosts = get_hosts(Config),
    {FOpts, Config1} = lists:partition(fun(Opt) -> is_function(Opt, 1) end, Config),
    {Overrides, Opts} = lists:partition(fun({override, _}) -> true;
                                           (_) -> false
                                        end, Config1),
    HOpts = lists:flatmap(fun(F) -> lists:flatmap(F, Hosts) end, FOpts),
    AllOpts = Opts ++ HOpts,
    case extract_errors(AllOpts) of
        [] ->
            build_state(Hosts, AllOpts, Overrides);
        [#{text := Text}|_] = Errors ->
            [?LOG_ERROR(Error) || Error <- Errors],
            mongoose_config_utils:exit_or_halt(Text)
    end.

%% Config processing functions are annotated with TOML paths
%% Path syntax: dotted, like TOML keys with the following additions:
%%   - '[]' denotes an element in a list
%%   - '( ... )' encloses an optional prefix
%%   - '*' is a wildcard for names - usually that name is passed as an argument
%% If the path is the same as for the previous function, it is not repeated.
%%
%% Example: (host_config[].)access.*
%% Meaning: either a key in the 'access' section, e.g.
%%            [access]
%%              local = ...
%%          or the same, but prefixed for a specific host, e.g.
%%            [[host_config]]
%%              host = "myhost"
%%              host_config.access
%%                local = ...

%% root path
-spec parse(toml_section()) -> config_list().
parse(Content) ->
    handle([], Content).

-spec parse_root(path(), toml_section()) -> config_list().
parse_root(Path, Content) ->
    ensure_keys([<<"general">>], Content),
    parse_section(Path, Content).

%% path: *
-spec process_section(path(), toml_section() | [toml_section()]) -> config_list().
process_section([<<"general">>] = Path, Content) ->
    ensure_keys([<<"hosts">>], Content),
    parse_section(Path, Content);
process_section([<<"listen">>] = Path, Content) ->
    Listeners = parse_section(Path, Content),
    [#local_config{key = listen, value = Listeners}];
process_section([<<"auth">>|_] = Path, Content) ->
    parse_section(Path, Content, fun(AuthOpts) ->
                                         ?HOST_F(partition_auth_opts(AuthOpts, Host))
                                 end);
process_section([<<"outgoing_pools">>] = Path, Content) ->
    Pools = parse_section(Path, Content),
    [#local_config{key = outgoing_pools, value = Pools}];
process_section([<<"services">>] = Path, Content) ->
    Services = parse_section(Path, Content),
    [#local_config{key = services, value = Services}];
process_section([<<"modules">>|_] = Path, Content) ->
    Mods = parse_section(Path, Content),
    ?HOST_F([#local_config{key = {modules, Host}, value = Mods}]);
process_section([<<"host_config">>] = Path, Content) ->
    parse_list(Path, Content);
process_section(Path, Content) ->
    parse_section(Path, Content).

%% path: (host_config[].)general.*
-spec process_general(path(), toml_value()) -> [config()].
process_general([<<"loglevel">>|_], V) ->
    [#local_config{key = loglevel, value = b2a(V)}];
process_general([<<"hosts">>|_] = Path, Hosts) ->
    [#config{key = hosts, value = parse_list(Path, Hosts)}];
process_general([<<"registration_timeout">>|_], V) ->
    [#local_config{key = registration_timeout, value = int_or_infinity(V)}];
process_general([<<"language">>|_], V) ->
    [#config{key = language, value = V}];
process_general([<<"all_metrics_are_global">>|_], V) ->
    [#local_config{key = all_metrics_are_global, value = V}];
process_general([<<"sm_backend">>|_], V) ->
    [#config{key = sm_backend, value = {b2a(V), []}}];
process_general([<<"max_fsm_queue">>|_], V) ->
    [#local_config{key = max_fsm_queue, value = V}];
process_general([<<"http_server_name">>|_], V) ->
    [#local_config{key = cowboy_server_name, value = b2l(V)}];
process_general([<<"rdbms_server_type">>|_], V) ->
    [#local_config{key = rdbms_server_type, value = b2a(V)}];
process_general([<<"override">>|_] = Path, Value) ->
    parse_list(Path, Value);
process_general([<<"pgsql_users_number_estimate">>|_], V) ->
    ?HOST_F([#local_config{key = {pgsql_users_number_estimate, Host}, value = V}]);
process_general([<<"route_subdomains">>|_], V) ->
    ?HOST_F([#local_config{key = {route_subdomains, Host}, value = b2a(V)}]);
process_general([<<"mongooseimctl_access_commands">>|_] = Path, Rules) ->
    [#local_config{key = mongooseimctl_access_commands, value = parse_section(Path, Rules)}];
process_general([<<"routing_modules">>|_] = Path, Mods) ->
    [#local_config{key = routing_modules, value = parse_list(Path, Mods)}];
process_general([<<"replaced_wait_timeout">>|_], V) ->
    ?HOST_F([#local_config{key = {replaced_wait_timeout, Host}, value = V}]);
process_general([<<"hide_service_name">>|_], V) ->
    ?HOST_F([#local_config{key = {hide_service_name, Host}, value = V}]).

-spec process_host(path(), toml_value()) -> [option()].
process_host(_Path, Val) ->
    [jid:nodeprep(Val)].

-spec process_override(path(), toml_value()) -> [option()].
process_override(_Path, Override) ->
    [{override, b2a(Override)}].

-spec ctl_access_rule(path(), toml_section()) -> [option()].
ctl_access_rule([Rule|_] = Path, Section) ->
    limit_keys([<<"commands">>, <<"argument_restrictions">>], Section),
    [{b2a(Rule),
      parse_kv(Path, <<"commands">>, Section),
      parse_kv(Path, <<"argument_restrictions">>, Section, #{})}].

-spec ctl_access_commands(path(), toml_value()) -> option().
ctl_access_commands(_Path, <<"all">>) -> all;
ctl_access_commands(Path, Commands) -> parse_list(Path, Commands).

-spec ctl_access_arg_restriction(path(), toml_value()) -> [option()].
ctl_access_arg_restriction([Key|_], Value) ->
    [{b2a(Key), b2l(Value)}].

%% path: listen.*[]
-spec process_listener(path(), toml_section()) -> [option()].
process_listener([_, Type|_] = Path, Content) ->
    Options = maps:without([<<"port">>, <<"ip_address">>], Content),
    PortIP = listener_portip(Content),
    parse_section(Path, Options,
                  fun(Opts) ->
                          {Port, IPT, _, _, Proto, OptsClean} =
                              ejabberd_listener:parse_listener_portip(PortIP, Opts),
                          [{{Port, IPT, Proto}, listener_module(Type), OptsClean}]
                  end).

-spec listener_portip(toml_section()) -> option().
listener_portip(#{<<"port">> := Port, <<"ip_address">> := Addr}) -> {Port, b2l(Addr)};
listener_portip(#{<<"port">> := Port}) -> Port.

-spec listener_module(toml_key()) -> option().
listener_module(<<"http">>) -> ejabberd_cowboy;
listener_module(<<"c2s">>) -> ejabberd_c2s;
listener_module(<<"s2s">>) -> ejabberd_s2s_in;
listener_module(<<"service">>) -> ejabberd_service.

%% path: listen.http[].*
-spec http_listener_opt(path(), toml_value()) -> [option()].
http_listener_opt([<<"tls">>|_] = Path, Opts) ->
    [{ssl, parse_section(Path, Opts)}];
http_listener_opt([<<"transport">>|_] = Path, Opts) ->
    [{transport_options, parse_section(Path, Opts)}];
http_listener_opt([<<"protocol">>|_] = Path, Opts) ->
    [{protocol_options, parse_section(Path, Opts)}];
http_listener_opt([<<"handlers">>|_] = Path, Handlers) ->
    [{modules, parse_section(Path, Handlers)}];
http_listener_opt(P, V) -> listener_opt(P, V).

%% path: listen.c2s[].*
-spec c2s_listener_opt(path(), toml_value()) -> [option()].
c2s_listener_opt([<<"access">>|_], V) -> [{access, b2a(V)}];
c2s_listener_opt([<<"shaper">>|_], V) -> [{shaper, b2a(V)}];
c2s_listener_opt([<<"xml_socket">>|_], V) -> [{xml_socket, V}];
c2s_listener_opt([<<"zlib">>|_], V) -> [{zlib, V}];
c2s_listener_opt([<<"max_fsm_queue">>|_], V) -> [{max_fsm_queue, V}];
c2s_listener_opt([{tls, _}|_] = P, V) -> listener_tls_opts(P, V);
c2s_listener_opt(P, V) -> xmpp_listener_opt(P, V).

%% path: listen.s2s[].*
-spec s2s_listener_opt(path(), toml_value()) -> [option()].
s2s_listener_opt([<<"shaper">>|_], V) -> [{shaper, b2a(V)}];
s2s_listener_opt([<<"tls">>|_] = P, V) -> parse_section(P, V);
s2s_listener_opt(P, V) -> xmpp_listener_opt(P, V).

%% path: listen.service[].*,
%%       listen.http[].handlers.mod_websockets[].service.*
-spec service_listener_opt(path(), toml_value()) -> [option()].
service_listener_opt([<<"access">>|_], V) -> [{access, b2a(V)}];
service_listener_opt([<<"shaper_rule">>|_], V) -> [{shaper_rule, b2a(V)}];
service_listener_opt([<<"check_from">>|_], V) -> [{service_check_from, V}];
service_listener_opt([<<"hidden_components">>|_], V) -> [{hidden_components, V}];
service_listener_opt([<<"conflict_behaviour">>|_], V) -> [{conflict_behaviour, b2a(V)}];
service_listener_opt([<<"password">>|_], V) -> [{password, b2l(V)}];
service_listener_opt([<<"max_fsm_queue">>|_], V) -> [{max_fsm_queue, V}];
service_listener_opt(P, V) -> xmpp_listener_opt(P, V).

%% path: listen.c2s[].*, listen.s2s[].*, listen.service[].*
-spec xmpp_listener_opt(path(), toml_value()) -> [option()].
xmpp_listener_opt([<<"hibernate_after">>|_], V) -> [{hibernate_after, V}];
xmpp_listener_opt([<<"max_stanza_size">>|_], V) -> [{max_stanza_size, V}];
xmpp_listener_opt([<<"backlog">>|_], N) -> [{backlog, N}];
xmpp_listener_opt([<<"proxy_protocol">>|_], V) -> [{proxy_protocol, V}];
xmpp_listener_opt([<<"num_acceptors">>|_], V) -> [{acceptors_num, V}];
xmpp_listener_opt(Path, V) -> listener_opt(Path, V).

%% path: listen.*[].*
-spec listener_opt(path(), toml_value()) -> [option()].
listener_opt([<<"proto">>|_], Proto) -> [{proto, b2a(Proto)}];
listener_opt([<<"ip_version">>|_], 6) -> [inet6];
listener_opt([<<"ip_version">>|_], 4) -> [inet].

%% path: listen.http[].tls.*
-spec https_option(path(), toml_value()) -> [option()].
https_option([<<"verify_mode">>|_], Value) -> [{verify_mode, b2a(Value)}];
https_option(Path, Value) -> tls_option(Path, Value).

%% path: listen.c2s[].tls.*
-spec c2s_tls_option(path(), toml_value()) -> option().
c2s_tls_option([<<"mode">>|_], V) -> [b2a(V)];
c2s_tls_option([<<"verify_peer">>|_], V) -> [verify_peer(V)];
c2s_tls_option([<<"protocol_options">>, {tls, fast_tls}|_] = Path, V) ->
    [{protocol_options, parse_list(Path, V)}];
c2s_tls_option([_, {tls, fast_tls}|_] = Path, V) -> fast_tls_option(Path, V);
c2s_tls_option([<<"verify_mode">>, {tls, just_tls}|_], V) -> b2a(V);
c2s_tls_option([<<"disconnect_on_failure">>, {tls, just_tls}|_], V) -> V;
c2s_tls_option([<<"crl_files">>, {tls, just_tls}|_] = Path, V) -> [{crlfiles, parse_list(Path, V)}];
c2s_tls_option([_, {tls, just_tls}|_] = Path, V) -> tls_option(Path, V).

%% path: listen.s2s[].tls.*
-spec s2s_tls_option(path(), toml_value()) -> [option()].
s2s_tls_option([<<"protocol_options">>|_] = Path, V) ->
    [{protocol_options, parse_list(Path, V)}];
s2s_tls_option([Opt|_] = Path, Val) when Opt =:= <<"cacertfile">>;
                                         Opt =:= <<"dhfile">>;
                                         Opt =:= <<"ciphers">> ->
    fast_tls_option(Path, Val).

%% path: listen.http[].transport.*
-spec cowboy_transport_opt(path(), toml_value()) -> [option()].
cowboy_transport_opt([<<"num_acceptors">>|_], N) -> [{num_acceptors, N}];
cowboy_transport_opt([<<"max_connections">>|_], N) -> [{max_connections, int_or_infinity(N)}].

%% path: listen.http[].protocol.*
-spec cowboy_protocol_opt(path(), toml_value()) -> [option()].
cowboy_protocol_opt([<<"compress">>|_], V) -> [{compress, V}].

%% path: listen.http[].handlers.*[]
-spec cowboy_module(path(), toml_section()) -> [option()].
cowboy_module([_, Type|_] = Path, #{<<"host">> := Host, <<"path">> := ModPath} = Options) ->
    Opts = maps:without([<<"host">>, <<"path">>], Options),
    ModuleOpts = cowboy_module_options(Path, Opts),
    [{b2l(Host), b2l(ModPath), b2a(Type), ModuleOpts}].

-spec cowboy_module_options(path(), toml_section()) -> [option()].
cowboy_module_options([_, <<"mod_websockets">>|_] = Path, Opts) ->
    parse_section(Path, Opts);
cowboy_module_options([_, <<"lasse_handler">>|_], Opts) ->
    limit_keys([<<"module">>], Opts),
    #{<<"module">> := Module} = Opts,
    [b2a(Module)];
cowboy_module_options([_, <<"cowboy_static">>|_], Opts) ->
    limit_keys([<<"type">>, <<"app">>, <<"content_path">>], Opts),
    #{<<"type">> := Type,
      <<"app">> := App,
      <<"content_path">> := Path} = Opts,
    {b2a(Type), b2a(App), b2l(Path), [{mimetypes, cow_mimetypes, all}]};
cowboy_module_options([_, <<"cowboy_swagger_redirect_handler">>|_], Opts) ->
    Opts = #{};
cowboy_module_options([_, <<"cowboy_swagger_json_handler">>|_], Opts) ->
    Opts = #{};
cowboy_module_options([_, <<"mongoose_api">>|_] = Path, Opts) ->
    #{<<"handlers">> := _} = Opts,
    parse_section(Path, Opts);
cowboy_module_options([_, <<"mongoose_api_admin">>|_],
    #{<<"username">> := User, <<"password">> := Pass}) ->
    [{auth, {User, Pass}}];
cowboy_module_options([_, <<"mongoose_api_admin">>|_], #{}) ->
    [];
cowboy_module_options([_, <<"mongoose_api_client">>|_], #{}) ->
    [];
cowboy_module_options(_, Opts) ->
    limit_keys([], Opts),
    [].

%% path: listen.http[].handlers.mod_websockets[].*
-spec websockets_option(path(), toml_value()) -> [option()].
websockets_option([<<"timeout">>|_], V) ->
    [{timeout, int_or_infinity(V)}];
websockets_option([<<"ping_rate">>|_], <<"none">>) ->
    [{ping_rate, none}];
websockets_option([<<"ping_rate">>|_], V) ->
    [{ping_rate, V}];
websockets_option([<<"max_stanza_size">>|_], V) ->
    [{max_stanza_size, int_or_infinity(V)}];
websockets_option([<<"service">>|_] = Path, Value) ->
    [{ejabberd_service, parse_section(Path, Value)}].

%% path: listen.http[].handlers.mongoose_api[].*
-spec mongoose_api_option(path(), toml_value()) -> [option()].
mongoose_api_option([<<"handlers">>|_] = Path, Value) ->
    [{handlers, parse_list(Path, Value)}].

%% path: listen.c2s[].tls
-spec listener_tls_opts(path(), toml_section()) -> [option()].
listener_tls_opts([{tls, just_tls}|_] = Path, M) ->
    VM = just_tls_verify_fun(Path, M),
    Common = maps:with([<<"mode">>, <<"verify_peer">>, <<"crl_files">>], M),
    OptsM = maps:without([<<"module">>,
                          <<"mode">>, <<"verify_peer">>, <<"crl_files">>,
                          <<"verify_mode">>, <<"disconnect_on_failure">>], M),
    SSLOpts = case VM ++ parse_section(Path, OptsM) of
                  [] -> [];
                  Opts -> [{ssl_options, Opts}]
              end,
    [{tls_module, just_tls}] ++ SSLOpts ++ parse_section(Path, Common);
listener_tls_opts([{tls, fast_tls}|_] = Path, M) ->
    parse_section(Path, maps:without([<<"module">>], M)).

-spec just_tls_verify_fun(path(), toml_section()) -> [option()].
just_tls_verify_fun(Path, #{<<"verify_mode">> := _} = M) ->
    VMode = parse_kv(Path, <<"verify_mode">>, M),
    Disconnect = parse_kv(Path, <<"disconnect_on_failure">>, M, true),
    [{verify_fun, {VMode, Disconnect}}];
just_tls_verify_fun(_, _) -> [].

%% path: (host_config[].)auth.*
-spec auth_option(path(), toml_value()) -> [option()].
auth_option([<<"methods">>|_] = Path, Methods) ->
    [{auth_method, parse_list(Path, Methods)}];
auth_option([<<"password">>|_] = Path, #{<<"hash">> := Hashes}) ->
    [{password_format, {scram, parse_list([<<"hash">> | Path], Hashes)}}];
auth_option([<<"password">>|_], #{<<"format">> := V}) ->
    [{password_format, b2a(V)}];
auth_option([<<"scram_iterations">>|_], V) ->
    [{scram_iterations, V}];
auth_option([<<"sasl_external">>|_] = Path, V) ->
    [{cyrsasl_external, parse_list(Path, V)}];
auth_option([<<"sasl_mechanisms">>|_] = Path, V) ->
    [{sasl_mechanisms, parse_list(Path, V)}];
auth_option([<<"jwt">>|_] = Path, V) ->
    ensure_keys([<<"secret">>, <<"algorithm">>, <<"username_key">>], V),
    parse_section(Path, V);
auth_option(Path, V) ->
    parse_section(Path, V).

%% path: (host_config[].)auth.anonymous.*
auth_anonymous_option([<<"allow_multiple_connections">>|_], V) ->
    [{allow_multiple_connections, V}];
auth_anonymous_option([<<"protocol">>|_], V) ->
    [{anonymous_protocol, b2a(V)}].

%% path: (host_config[].)auth.ldap.*
-spec auth_ldap_option(path(), toml_section()) -> [option()].
auth_ldap_option([<<"pool_tag">>|_], V) ->
    [{ldap_pool_tag, b2a(V)}];
auth_ldap_option([<<"bind_pool_tag">>|_], V) ->
    [{ldap_bind_pool_tag, b2a(V)}];
auth_ldap_option([<<"base">>|_], V) ->
    [{ldap_base, b2l(V)}];
auth_ldap_option([<<"uids">>|_] = Path, V) ->
    [{ldap_uids, parse_list(Path, V)}];
auth_ldap_option([<<"filter">>|_], V) ->
    [{ldap_filter, b2l(V)}];
auth_ldap_option([<<"dn_filter">>|_] = Path, V) ->
    parse_section(Path, V, fun process_dn_filter/1);
auth_ldap_option([<<"local_filter">>|_] = Path, V) ->
    parse_section(Path, V, fun process_local_filter/1);
auth_ldap_option([<<"deref">>|_], V) ->
    [{ldap_deref, b2a(V)}].

process_dn_filter(Opts) ->
    {_, Filter} = proplists:lookup(filter, Opts),
    {_, Attrs} = proplists:lookup(attributes, Opts),
    [{ldap_dn_filter, {Filter, Attrs}}].

process_local_filter(Opts) ->
    {_, Op} = proplists:lookup(operation, Opts),
    {_, Attribute} = proplists:lookup(attribute, Opts),
    {_, Values} = proplists:lookup(values, Opts),
    [{ldap_local_filter, {Op, {Attribute, Values}}}].

-spec auth_ldap_uids(path(), toml_section()) -> [option()].
auth_ldap_uids(_, #{<<"attr">> := Attr, <<"format">> := Format}) ->
    [{b2l(Attr), b2l(Format)}];
auth_ldap_uids(_, #{<<"attr">> := Attr}) ->
    [b2l(Attr)].

-spec auth_ldap_dn_filter(path(), toml_value()) -> [option()].
auth_ldap_dn_filter([<<"filter">>|_], V) ->
    [{filter, b2l(V)}];
auth_ldap_dn_filter([<<"attributes">>|_] = Path, V) ->
    Attrs = parse_list(Path, V),
    [{attributes, Attrs}].

-spec auth_ldap_local_filter(path(), toml_value()) -> [option()].
auth_ldap_local_filter([<<"operation">>|_], V) ->
    [{operation, b2a(V)}];
auth_ldap_local_filter([<<"attribute">>|_], V) ->
    [{attribute, b2l(V)}];
auth_ldap_local_filter([<<"values">>|_] = Path, V) ->
    Attrs = parse_list(Path, V),
    [{values, Attrs}].

%% path: (host_config[].)auth.external.*
-spec auth_external_option(path(), toml_value()) -> [option()].
auth_external_option([<<"instances">>|_], V) ->
    [{extauth_instances, V}];
auth_external_option([<<"program">>|_], V) ->
    [{extauth_program, b2l(V)}].

%% path: (host_config[].)auth.http.*
-spec auth_http_option(path(), toml_value()) -> [option()].
auth_http_option([<<"basic_auth">>|_], V) ->
    [{basic_auth, b2l(V)}].

%% path: (host_config[].)auth.jwt.*
-spec auth_jwt_option(path(), toml_value()) -> [option()].
auth_jwt_option([<<"secret">>|_] = Path, V) ->
    [Item] = parse_section(Path, V), % expect exactly one option
    [Item];
auth_jwt_option([<<"algorithm">>|_], V) ->
    [{jwt_algorithm, b2l(V)}];
auth_jwt_option([<<"username_key">>|_], V) ->
    [{jwt_username_key, b2a(V)}].

%% path: (host_config[].)auth.jwt.secret.*
-spec auth_jwt_secret(path(), toml_value()) -> [option()].
auth_jwt_secret([<<"file">>|_], V) ->
    [{jwt_secret_source, b2l(V)}];
auth_jwt_secret([<<"env">>|_], V) ->
    [{jwt_secret_source, {env, b2l(V)}}];
auth_jwt_secret([<<"value">>|_], V) ->
    [{jwt_secret, b2l(V)}].

%% path: (host_config[].)auth.riak.*
-spec auth_riak_option(path(), toml_value()) -> [option()].
auth_riak_option([<<"bucket_type">>|_], V) ->
    [{bucket_type, V}].

%% path: (host_config[].)auth.sasl_external[]
-spec sasl_external(path(), toml_value()) -> [option()].
sasl_external(_, <<"standard">>) -> [standard];
sasl_external(_, <<"common_name">>) -> [common_name];
sasl_external(_, <<"auth_id">>) -> [auth_id];
sasl_external(_, M) -> [{mod, b2a(M)}].

%% path: (host_config[].)auth.sasl_mechanism[]
%%       auth.sasl_mechanisms.*
-spec sasl_mechanism(path(), toml_value()) -> [option()].
sasl_mechanism(_, V) ->
    [b2a(<<"cyrsasl_", V/binary>>)].

-spec partition_auth_opts([{atom(), any()}], ejabberd:server()) -> [config()].
partition_auth_opts(AuthOpts, Host) ->
    {InnerOpts, OuterOpts} = lists:partition(fun({K, _}) -> is_inner_auth_opt(K) end, AuthOpts),
    [#local_config{key = {auth_opts, Host}, value = InnerOpts} |
     [#local_config{key = {K, Host}, value = V} || {K, V} <- OuterOpts]].

-spec is_inner_auth_opt(atom()) -> boolean().
is_inner_auth_opt(auth_method) -> false;
is_inner_auth_opt(allow_multiple_connections) -> false;
is_inner_auth_opt(anonymous_protocol) -> false;
is_inner_auth_opt(sasl_mechanisms) -> false;
is_inner_auth_opt(extauth_instances) -> false;
is_inner_auth_opt(_) -> true.

%% path: outgoing_pools.*.*
-spec process_pool(path(), toml_section()) -> [option()].
process_pool([Tag, Type|_] = Path, M) ->
    Scope = pool_scope(M),
    Options = parse_section(Path, maps:without([<<"scope">>, <<"host">>, <<"connection">>], M)),
    ConnectionOptions = parse_kv(Path, <<"connection">>, M, #{}),
    [{b2a(Type), Scope, b2a(Tag), Options, ConnectionOptions}].

-spec pool_scope(toml_section()) -> option().
pool_scope(#{<<"scope">> := <<"single_host">>, <<"host">> := Host}) -> Host;
pool_scope(#{<<"scope">> := Scope}) -> b2a(Scope);
pool_scope(#{}) -> global.

%% path: outgoing_pools.*.*.*,
%%       (host_config[].)modules.mod_event_pusher.backend.push.wpool.*
-spec pool_option(path(), toml_value()) -> [option()].
pool_option([<<"workers">>|_], V) -> [{workers, V}];
pool_option([<<"strategy">>|_], V) -> [{strategy, b2a(V)}];
pool_option([<<"call_timeout">>|_], V) -> [{call_timeout, V}].

%% path: outgoing_pools.*.connection
-spec connection_options(path(), toml_section()) -> [option()].
connection_options([{connection, Driver}, _, <<"rdbms">>|_] = Path, M) ->
    Options = parse_section(Path, maps:with([<<"keepalive_interval">>], M)),
    ServerOptions = parse_section(Path, maps:without([<<"keepalive_interval">>], M)),
    Server = rdbms_server(Driver, ServerOptions),
    [{server, Server} | Options];
connection_options([_, _, <<"riak">>|_] = Path, Options = #{<<"username">> := UserName,
                                                            <<"password">> := Password}) ->
    M = maps:without([<<"username">>, <<"password">>], Options),
    [{credentials, b2l(UserName), b2l(Password)} | parse_section(Path, M)];
connection_options(Path, Options) ->
    parse_section(Path, Options).

-spec rdbms_server(atom(), [option()]) -> option().
rdbms_server(odbc, Opts) ->
    [{settings, Settings}] = Opts,
    Settings;
rdbms_server(Driver, Opts) ->
    {_, Host} = proplists:lookup(host, Opts),
    {_, Database} = proplists:lookup(database, Opts),
    {_, UserName} = proplists:lookup(username, Opts),
    {_, Password} = proplists:lookup(password, Opts),
    case {proplists:get_value(port, Opts, no_port),
          proplists:get_value(tls, Opts, no_tls)} of
        {no_port, no_tls} -> {Driver, Host, Database, UserName, Password};
        {Port, no_tls} -> {Driver, Host, Port, Database, UserName, Password};
        {no_port, TLS} -> {Driver, Host, Database, UserName, Password, TLS};
        {Port, TLS} -> {Driver, Host, Port, Database, UserName, Password, TLS}
    end.

%% path: outgoing_pools.rdbms.*.connection.*
-spec odbc_option(path(), toml_value()) -> [option()].
odbc_option([<<"settings">>|_], V) -> [{settings, b2l(V)}];
odbc_option(Path, V) -> rdbms_option(Path, V).

-spec sql_server_option(path(), toml_value()) -> [option()].
sql_server_option([<<"host">>|_], V) -> [{host, b2l(V)}];
sql_server_option([<<"database">>|_], V) -> [{database, b2l(V)}];
sql_server_option([<<"username">>|_], V) -> [{username, b2l(V)}];
sql_server_option([<<"password">>|_], V) -> [{password, b2l(V)}];
sql_server_option([<<"port">>|_], V) -> [{port, V}];
sql_server_option([<<"tls">>, {connection, mysql} | _] = Path, Opts) ->
    [{tls, parse_section(Path, Opts)}];
sql_server_option([<<"tls">>, {connection, pgsql} | _] = Path, Opts) ->
    % true means try to establish encryption and proceed plain if failed
    % required means fail if encryption is not possible
    % false would mean do not even try, but we do not let the user do it
    {SSLMode, Opts1} = case maps:take(<<"required">>, Opts) of
                           {true, M} -> {required, M};
                           {false, M} -> {true, M};
                           error -> {true, Opts}
                       end,
    SSLOpts = case parse_section(Path, Opts1) of
                  [] -> [];
                  SSLOptList -> [{ssl_opts, SSLOptList}]
              end,
    [{tls, [{ssl, SSLMode} | SSLOpts]}];
sql_server_option(Path, V) -> rdbms_option(Path, V).

-spec rdbms_option(path(), toml_value()) -> [option()].
rdbms_option([<<"keepalive_interval">>|_], V) -> [{keepalive_interval, V}];
rdbms_option([<<"driver">>|_], _V) -> [].

%% path: outgoing_pools.http.*.connection.*
-spec http_option(path(), toml_value()) -> [option()].
http_option([<<"host">>|_], V) -> [{server, b2l(V)}];
http_option([<<"path_prefix">>|_], V) -> [{path_prefix, b2l(V)}];
http_option([<<"request_timeout">>|_], V) -> [{request_timeout, V}];
http_option([<<"tls">>|_] = Path, Options) -> [{http_opts, parse_section(Path, Options)}].

%% path: outgoing_pools.redis.*.connection.*
-spec redis_option(path(), toml_value()) -> [option()].
redis_option([<<"host">>|_], Host) -> [{host, b2l(Host)}];
redis_option([<<"port">>|_], Port) -> [{port, Port}];
redis_option([<<"database">>|_], Database) -> [{database, Database}];
redis_option([<<"password">>|_], Password) -> [{password, b2l(Password)}].

%% path: outgoing_pools.ldap.*.connection.*
-spec ldap_option(path(), toml_value()) -> [option()].
ldap_option([<<"host">>|_], Host) -> [{host, b2l(Host)}];
ldap_option([<<"port">>|_], Port) -> [{port, Port}];
ldap_option([<<"rootdn">>|_], RootDN) -> [{rootdn, b2l(RootDN)}];
ldap_option([<<"password">>|_], Password) -> [{password, b2l(Password)}];
ldap_option([<<"encrypt">>|_], <<"tls">>) -> [{encrypt, tls}];
ldap_option([<<"encrypt">>|_], <<"none">>) -> [{encrypt, none}];
ldap_option([<<"servers">>|_] = Path, V) -> [{servers, parse_list(Path, V)}];
ldap_option([<<"connect_interval">>|_], V) -> [{connect_interval, V}];
ldap_option([<<"tls">>|_] = Path, Options) -> [{tls_options, parse_section(Path, Options)}].

%% path: outgoing_pools.riak.*.connection.*
-spec riak_option(path(), toml_value()) -> [option()].
riak_option([<<"address">>|_], Addr) -> [{address, b2l(Addr)}];
riak_option([<<"port">>|_], Port) -> [{port, Port}];
riak_option([<<"credentials">>|_] = Path, V) ->
    parse_section(Path, V, fun process_riak_credentials/1);
riak_option([<<"cacertfile">>|_], Path) -> [{cacertfile, b2l(Path)}];
riak_option([<<"certfile">>|_], Path) -> [{certfile, b2l(Path)}];
riak_option([<<"keyfile">>|_], Path) -> [{keyfile, b2l(Path)}];
riak_option([<<"tls">>|_] = Path, Options) ->
    Ssl = parse_section(Path, Options),
    {RootOpts, SslOpts} = proplists:split(Ssl, [cacertfile, certfile, keyfile]),
    case SslOpts of
        [] ->lists:flatten(RootOpts);
        _ -> [{ssl_opts, SslOpts} | lists:flatten(RootOpts)]
    end.

process_riak_credentials(Creds) ->
    {_, User} = proplists:lookup(user, Creds),
    {_, Pass} = proplists:lookup(password, Creds),
    [{credentials, User, Pass}].

%% path: outgoing_pools.riak.*.connection.credentials.*
-spec riak_credentials(path(), toml_value()) -> [option()].
riak_credentials([<<"user">>|_], V) -> [{user, b2l(V)}];
riak_credentials([<<"password">>|_], V) -> [{password, b2l(V)}].

%% path: outgoing_pools.cassandra.*.connnection.*
-spec cassandra_option(path(), toml_value()) -> [option()].
cassandra_option([<<"servers">>|_] = Path, V) -> [{servers, parse_list(Path, V)}];
cassandra_option([<<"keyspace">>|_], KeySpace) -> [{keyspace, b2l(KeySpace)}];
cassandra_option([<<"tls">>|_] = Path, Options) -> [{ssl, parse_section(Path, Options)}];
cassandra_option([<<"auth">>|_] = Path, Options) ->
    [AuthConfig] = parse_section(Path, Options),
    [{auth, AuthConfig}];
cassandra_option([<<"plain">>|_], #{<<"username">> := User, <<"password">> := Pass}) ->
    [{cqerl_auth_plain_handler, [{User, Pass}]}].

%% path: outgoing_pools.cassandra.*.connection.servers[]
-spec cassandra_server(path(), toml_section()) -> [option()].
cassandra_server(_, #{<<"ip_address">> := IPAddr, <<"port">> := Port}) -> [{b2l(IPAddr), Port}];
cassandra_server(_, #{<<"ip_address">> := IPAddr}) -> [b2l(IPAddr)].

%% path: outgoing_pools.elastic.*.connection.*
-spec elastic_option(path(), toml_value()) -> [option()].
elastic_option([<<"host">>|_], Host) -> [{host, b2l(Host)}];
elastic_option([<<"port">>|_], Port) -> [{port, Port}].

%% path: outgoing_pools.rabbit.*.connection.*
-spec rabbit_option(path(), toml_value()) -> [option()].
rabbit_option([<<"amqp_host">>|_], V) -> [{amqp_host, b2l(V)}];
rabbit_option([<<"amqp_port">>|_], V) -> [{amqp_port, V}];
rabbit_option([<<"amqp_username">>|_], V) -> [{amqp_username, b2l(V)}];
rabbit_option([<<"amqp_password">>|_], V) -> [{amqp_password, b2l(V)}];
rabbit_option([<<"confirms_enabled">>|_], V) -> [{confirms_enabled, V}];
rabbit_option([<<"max_worker_queue_len">>|_], V) -> [{max_worker_queue_len, int_or_infinity(V)}].

%% path: services.*
-spec process_service(path(), toml_section()) -> [option()].
process_service([S|_] = Path, Opts) ->
    [{b2a(S), parse_section(Path, Opts)}].

%% path: services.*.*
-spec service_opt(path(), toml_value()) -> [option()].
service_opt([<<"submods">>, <<"service_admin_extra">>|_] = Path, V) ->
    List = parse_list(Path, V),
    [{submods, List}];
service_opt([<<"initial_report">>, <<"service_mongoose_system_metrics">>|_], V) ->
    [{initial_report, V}];
service_opt([<<"periodic_report">>, <<"service_mongoose_system_metrics">>|_], V) ->
    [{periodic_report, V}];
service_opt([<<"report">>, <<"service_mongoose_system_metrics">>|_], true) ->
    [report];
service_opt([<<"report">>, <<"service_mongoose_system_metrics">>|_], false) ->
    [no_report];
service_opt([<<"tracking_id">>, <<"service_mongoose_system_metrics">>|_],  V) ->
    [{tracking_id, b2l(V)}].

%% path: (host_config[].)modules.*
-spec process_module(path(), toml_section()) -> [option()].
process_module([Mod|_] = Path, Opts) ->
    %% Sort option keys to ensure options could be matched in tests
    post_process_module(b2a(Mod), parse_section(Path, Opts)).

post_process_module(mod_mam_meta, Opts) ->
    %% Disable the archiving by default
    [{mod_mam_meta, lists:sort(defined_or_false(muc, defined_or_false(pm, Opts)))}];
post_process_module(Mod, Opts) ->
    [{Mod, lists:sort(Opts)}].

%% path: (host_config[].)modules.*.*
-spec module_opt(path(), toml_value()) -> [option()].
module_opt([<<"report_commands_node">>, <<"mod_adhoc">>|_], V) ->
    [{report_commands_node, V}];
module_opt([<<"validity_period">>, <<"mod_auth_token">>|_] = Path, V) ->
    parse_list(Path, V);
module_opt([<<"inactivity">>, <<"mod_bosh">>|_], V) ->
    [{inactivity, int_or_infinity(V)}];
module_opt([<<"max_wait">>, <<"mod_bosh">>|_], V) ->
    [{max_wait, int_or_infinity(V)}];
module_opt([<<"server_acks">>, <<"mod_bosh">>|_], V) ->
    [{server_acks, V}];
module_opt([<<"backend">>, <<"mod_bosh">>|_], V) ->
    [{backend, b2a(V)}];
module_opt([<<"maxpause">>, <<"mod_bosh">>|_], V) ->
    [{maxpause, V}];
module_opt([<<"cache_size">>, <<"mod_caps">>|_], V) ->
    [{cache_size, V}];
module_opt([<<"cache_life_time">>, <<"mod_caps">>|_], V) ->
    [{cache_life_time, V}];
module_opt([<<"buffer_max">>, <<"mod_csi">>|_], V) ->
    [{buffer_max, int_or_infinity(V)}];
module_opt([<<"extra_domains">>, <<"mod_disco">>|_] = Path, V) ->
    Domains = parse_list(Path, V),
    [{extra_domains, Domains}];
module_opt([<<"server_info">>, <<"mod_disco">>|_] = Path, V) ->
    Info = parse_list(Path, V),
    [{server_info, Info}];
module_opt([<<"users_can_see_hidden_services">>, <<"mod_disco">>|_], V) ->
    [{users_can_see_hidden_services, V}];
module_opt([<<"backend">>, <<"mod_event_pusher">>|_] = Path, V) ->
    Backends = parse_section(Path, V),
    [{backends, Backends}];
module_opt([<<"service">>, <<"mod_extdisco">>|_] = Path, V) ->
    parse_list(Path, V);
module_opt([<<"host">>, <<"mod_http_upload">>|_], V) ->
    [{host, b2l(V)}];
module_opt([<<"backend">>, <<"mod_http_upload">>|_], V) ->
    [{backend, b2a(V)}];
module_opt([<<"expiration_time">>, <<"mod_http_upload">>|_], V) ->
    [{expiration_time, V}];
module_opt([<<"token_bytes">>, <<"mod_http_upload">>|_], V) ->
    [{token_bytes, V}];
module_opt([<<"max_file_size">>, <<"mod_http_upload">>|_], V) ->
    [{max_file_size, V}];
module_opt([<<"s3">>, <<"mod_http_upload">>|_] = Path, V) ->
    S3Opts = parse_section(Path, V),
    [{s3, S3Opts}];
module_opt([<<"backend">>, <<"mod_inbox">>|_], V) ->
    [{backend, b2a(V)}];
module_opt([<<"reset_markers">>, <<"mod_inbox">>|_] = Path, V) ->
    Markers = parse_list(Path, V),
    [{reset_markers, Markers}];
module_opt([<<"groupchat">>, <<"mod_inbox">>|_] = Path, V) ->
    GChats = parse_list(Path, V),
    [{groupchat, GChats}];
module_opt([<<"aff_changes">>, <<"mod_inbox">>|_], V) ->
    [{aff_changes, V}];
module_opt([<<"remove_on_kicked">>, <<"mod_inbox">>|_], V) ->
    [{remove_on_kicked, V}];
module_opt([<<"global_host">>, <<"mod_global_distrib">>|_], V) ->
    [{global_host, b2l(V)}];
module_opt([<<"local_host">>, <<"mod_global_distrib">>|_], V) ->
    [{local_host, b2l(V)}];
module_opt([<<"message_ttl">>, <<"mod_global_distrib">>|_], V) ->
    [{message_ttl, V}];
module_opt([<<"connections">>, <<"mod_global_distrib">>|_] = Path, V) ->
    Conns = parse_section(Path, V),
    [{connections, Conns}];
module_opt([<<"cache">>, <<"mod_global_distrib">>|_] = Path, V) ->
    Cache = parse_section(Path, V),
    [{cache, Cache}];
module_opt([<<"bounce">>, <<"mod_global_distrib">>|_], false) ->
    [{bounce, false}];
module_opt([<<"bounce">>, <<"mod_global_distrib">>|_] = Path, V) ->
    Bounce = parse_section(Path, V),
    [{bounce, Bounce}];
module_opt([<<"redis">>, <<"mod_global_distrib">>|_] = Path, V) ->
    Redis = parse_section(Path, V),
    [{redis, Redis}];
module_opt([<<"hosts_refresh_interval">>, <<"mod_global_distrib">>|_], V) ->
    [{hosts_refresh_interval, V}];
module_opt([<<"proxy_host">>, <<"mod_jingle_sip">>|_], V) ->
    [{proxy_host, b2l(V)}];
module_opt([<<"proxy_port">>, <<"mod_jingle_sip">>|_], V) ->
    [{proxy_port, V}];
module_opt([<<"listen_port">>, <<"mod_jingle_sip">>|_], V) ->
    [{listen_port, V}];
module_opt([<<"local_host">>, <<"mod_jingle_sip">>|_], V) ->
    [{local_host, b2l(V)}];
module_opt([<<"sdp_origin">>, <<"mod_jingle_sip">>|_], V) ->
    [{sdp_origin, b2l(V)}];
module_opt([<<"ram_key_size">>, <<"mod_keystore">>|_], V) ->
    [{ram_key_size, V}];
module_opt([<<"keys">>, <<"mod_keystore">>|_] = Path, V) ->
    Keys = parse_list(Path, V),
    [{keys, Keys}];
module_opt([<<"pm">>, <<"mod_mam_meta">>|_] = Path, V) ->
    PM = parse_section(Path, V),
    [{pm, PM}];
module_opt([<<"muc">>, <<"mod_mam_meta">>|_] = Path, V) ->
    Muc = parse_section(Path, V),
    [{muc, Muc}];
module_opt([_, <<"mod_mam_meta">>|_] = Path, V) ->
    mod_mam_opts(Path, V);
module_opt([<<"host">>, <<"mod_muc">>|_], V) ->
    [{host, b2l(V)}];
module_opt([<<"access">>, <<"mod_muc">>|_], V) ->
    [{access, b2a(V)}];
module_opt([<<"access_create">>, <<"mod_muc">>|_], V) ->
    [{access_create, b2a(V)}];
module_opt([<<"access_admin">>, <<"mod_muc">>|_], V) ->
    [{access_admin, b2a(V)}];
module_opt([<<"access_persistent">>, <<"mod_muc">>|_], V) ->
    [{access_persistent, b2a(V)}];
module_opt([<<"history_size">>, <<"mod_muc">>|_], V) ->
    [{history_size, V}];
module_opt([<<"room_shaper">>, <<"mod_muc">>|_], V) ->
    [{room_shaper, b2a(V)}];
module_opt([<<"max_room_id">>, <<"mod_muc">>|_], V) ->
    [{max_room_id, int_or_infinity(V)}];
module_opt([<<"max_room_name">>, <<"mod_muc">>|_], V) ->
    [{max_room_name, int_or_infinity(V)}];
module_opt([<<"max_room_desc">>, <<"mod_muc">>|_], V) ->
    [{max_room_desc, int_or_infinity(V)}];
module_opt([<<"min_message_interval">>, <<"mod_muc">>|_], V) ->
    [{min_message_interval, V}];
module_opt([<<"min_presence_interval">>, <<"mod_muc">>|_], V) ->
    [{min_presence_interval, V}];
module_opt([<<"max_users">>, <<"mod_muc">>|_], V) ->
    [{max_users, V}];
module_opt([<<"max_users_admin_threshold">>, <<"mod_muc">>|_], V) ->
    [{max_users_admin_threshold, V}];
module_opt([<<"user_message_shaper">>, <<"mod_muc">>|_], V) ->
    [{user_message_shaper, b2a(V)}];
module_opt([<<"user_presence_shaper">>, <<"mod_muc">>|_], V) ->
    [{user_presence_shaper, b2a(V)}];
module_opt([<<"max_user_conferences">>, <<"mod_muc">>|_], V) ->
    [{max_user_conferences, V}];
module_opt([<<"http_auth_pool">>, <<"mod_muc">>|_], V) ->
    [{http_auth_pool, b2a(V)}];
module_opt([<<"load_permanent_rooms_at_startup">>, <<"mod_muc">>|_], V) ->
    [{load_permanent_rooms_at_startup, V}];
module_opt([<<"hibernate_timeout">>, <<"mod_muc">>|_], V) ->
    [{hibernate_timeout, V}];
module_opt([<<"hibernated_room_check_interval">>, <<"mod_muc">>|_], V) ->
    [{hibernated_room_check_interval, int_or_infinity(V)}];
module_opt([<<"hibernated_room_timeout">>, <<"mod_muc">>|_], V) ->
    [{hibernated_room_timeout, int_or_infinity(V)}];
module_opt([<<"default_room">>, <<"mod_muc">>|_] = Path, V) ->
    Defaults = parse_section(Path, V),
    [{default_room_options, Defaults}];
module_opt([<<"outdir">>, <<"mod_muc_log">>|_], V) ->
    [{outdir, b2l(V)}];
module_opt([<<"access_log">>, <<"mod_muc_log">>|_], V) ->
    [{access_log, b2a(V)}];
module_opt([<<"dirtype">>, <<"mod_muc_log">>|_], V) ->
    [{dirtype, b2a(V)}];
module_opt([<<"dirname">>, <<"mod_muc_log">>|_], V) ->
    [{dirname, b2a(V)}];
module_opt([<<"file_format">>, <<"mod_muc_log">>|_], V) ->
    [{file_format, b2a(V)}];
module_opt([<<"css_file">>, <<"mod_muc_log">>|_], <<"false">>) ->
    [{cssfile, false}];
module_opt([<<"css_file">>, <<"mod_muc_log">>|_], V) ->
    [{cssfile, V}];
module_opt([<<"timezone">>, <<"mod_muc_log">>|_], V) ->
    [{timezone, b2a(V)}];
module_opt([<<"top_link">>, <<"mod_muc_log">>|_] = Path, V) ->
    Link = list_to_tuple(parse_section(Path, V)),
    [{top_link, Link}];
module_opt([<<"spam_prevention">>, <<"mod_muc_log">>|_], V) ->
    [{spam_prevention, V}];
module_opt([<<"host">>, <<"mod_muc_light">>|_], V) ->
    [{host, b2l(V)}];
module_opt([<<"equal_occupants">>, <<"mod_muc_light">>|_], V) ->
    [{equal_occupants, V}];
module_opt([<<"legacy_mode">>, <<"mod_muc_light">>|_], V) ->
    [{legacy_mode, V}];
module_opt([<<"rooms_per_user">>, <<"mod_muc_light">>|_], V) ->
    [{rooms_per_user, int_or_infinity(V)}];
module_opt([<<"blocking">>, <<"mod_muc_light">>|_], V) ->
    [{blocking, V}];
module_opt([<<"all_can_configure">>, <<"mod_muc_light">>|_], V) ->
    [{all_can_configure, V}];
module_opt([<<"all_can_invite">>, <<"mod_muc_light">>|_], V) ->
    [{all_can_invite, V}];
module_opt([<<"max_occupants">>, <<"mod_muc_light">>|_], V) ->
    [{max_occupants, int_or_infinity(V)}];
module_opt([<<"rooms_per_page">>, <<"mod_muc_light">>|_], V) ->
    [{rooms_per_page, int_or_infinity(V)}];
module_opt([<<"rooms_in_rosters">>, <<"mod_muc_light">>|_], V) ->
    [{rooms_in_rosters, V}];
module_opt([<<"config_schema">>, <<"mod_muc_light">>|_] = Path, V) ->
    Configs = parse_list(Path, V),
    [{config_schema, Configs}];
module_opt([<<"access_max_user_messages">>, <<"mod_offline">>|_], V) ->
    [{access_max_user_messages, b2a(V)}];
module_opt([<<"send_pings">>, <<"mod_ping">>|_], V) ->
    [{send_pings, V}];
module_opt([<<"ping_interval">>, <<"mod_ping">>|_], V) ->
    [{ping_interval, V}];
module_opt([<<"timeout_action">>, <<"mod_ping">>|_], V) ->
    [{timeout_action, b2a(V)}];
module_opt([<<"ping_req_timeout">>, <<"mod_ping">>|_], V) ->
    [{ping_req_timeout, V}];
module_opt([<<"host">>, <<"mod_pubsub">>|_], V) ->
    [{host, b2l(V)}];
module_opt([<<"access_createnode">>, <<"mod_pubsub">>|_], V) ->
    [{access_createnode, b2a(V)}];
module_opt([<<"max_items_node">>, <<"mod_pubsub">>|_], V) ->
    [{max_items_node, V}];
module_opt([<<"max_subscriptions_node">>, <<"mod_pubsub">>|_], <<"infinity">>) ->
    [];
module_opt([<<"max_subscriptions_node">>, <<"mod_pubsub">>|_], V) ->
    [{max_subscriptions_node, V}];
module_opt([<<"nodetree">>, <<"mod_pubsub">>|_], V) ->
    [{nodetree, V}];
module_opt([<<"ignore_pep_from_offline">>, <<"mod_pubsub">>|_], V) ->
    [{ignore_pep_from_offline, V}];
module_opt([<<"last_item_cache">>, <<"mod_pubsub">>|_], false) ->
    [{last_item_cache, false}];
module_opt([<<"last_item_cache">>, <<"mod_pubsub">>|_], V) ->
    [{last_item_cache, b2a(V)}];
module_opt([<<"plugins">>, <<"mod_pubsub">>|_] = Path, V) ->
    Plugs = parse_list(Path, V),
    [{plugins, Plugs}];
module_opt([<<"pep_mapping">>, <<"mod_pubsub">>|_] = Path, V) ->
    Mappings = parse_list(Path, V),
    [{pep_mapping, Mappings}];
module_opt([<<"default_node_config">>, <<"mod_pubsub">>|_] = Path, V) ->
    Config = parse_section(Path, V),
    [{default_node_config, Config}];
module_opt([<<"item_publisher">>, <<"mod_pubsub">>|_], V) ->
    [{item_publisher, V}];
module_opt([<<"sync_broadcast">>, <<"mod_pubsub">>|_], V) ->
    [{sync_broadcast, V}];
module_opt([<<"pool_name">>, <<"mod_push_service_mongoosepush">>|_], V) ->
    [{pool_name, b2a(V)}];
module_opt([<<"api_version">>, <<"mod_push_service_mongoosepush">>|_], V) ->
    [{api_version, b2l(V)}];
module_opt([<<"max_http_connections">>, <<"mod_push_service_mongoosepush">>|_], V) ->
    [{max_http_connections, V}];
module_opt([<<"access">>, <<"mod_register">>|_], V) ->
    [{access, b2a(V)}];
module_opt([<<"registration_watchers">>, <<"mod_register">>|_] = Path, V) ->
    [{registration_watchers, parse_list(Path, V)}];
module_opt([<<"password_strength">>, <<"mod_register">>|_], V) ->
    [{password_strength, V}];
module_opt([<<"ip_access">>, <<"mod_register">>|_] = Path, V) ->
    Rules = parse_list(Path, V),
    [{ip_access, Rules}];
module_opt([<<"welcome_message">>, <<"mod_register">>|_] = Path, V) ->
    parse_section(Path, V, fun process_welcome_message/1);
module_opt([<<"routes">>, <<"mod_revproxy">>|_] = Path, V) ->
    Routes = parse_list(Path, V),
    [{routes, Routes}];
module_opt([<<"versioning">>, <<"mod_roster">>|_], V) ->
    [{versioning, V}];
module_opt([<<"store_current_id">>, <<"mod_roster">>|_], V) ->
    [{store_current_id, V}];
module_opt([<<"ldap_useruid">>, <<"mod_shared_roster_ldap">>|_], V) ->
    [{ldap_useruid, b2l(V)}];
module_opt([<<"ldap_groupattr">>, <<"mod_shared_roster_ldap">>|_], V) ->
    [{ldap_groupattr, b2l(V)}];
module_opt([<<"ldap_groupdesc">>, <<"mod_shared_roster_ldap">>|_], V) ->
    [{ldap_groupdesc, b2l(V)}];
module_opt([<<"ldap_userdesc">>, <<"mod_shared_roster_ldap">>|_], V) ->
    [{ldap_userdesc, b2l(V)}];
module_opt([<<"ldap_userid">>, <<"mod_shared_roster_ldap">>|_], V) ->
    [{ldap_userid, b2l(V)}];
module_opt([<<"ldap_memberattr">>, <<"mod_shared_roster_ldap">>|_], V) ->
    [{ldap_memberattr, b2l(V)}];
module_opt([<<"ldap_memberattr_format">>, <<"mod_shared_roster_ldap">>|_], V) ->
    [{ldap_memberattr_format, b2l(V)}];
module_opt([<<"ldap_memberattr_format_re">>, <<"mod_shared_roster_ldap">>|_], V) ->
    [{ldap_memberattr_format_re, b2l(V)}];
module_opt([<<"ldap_auth_check">>, <<"mod_shared_roster_ldap">>|_], V) ->
    [{ldap_auth_check, V}];
module_opt([<<"ldap_user_cache_validity">>, <<"mod_shared_roster_ldap">>|_], V) ->
    [{ldap_user_cache_validity, V}];
module_opt([<<"ldap_group_cache_validity">>, <<"mod_shared_roster_ldap">>|_], V) ->
    [{ldap_group_cache_validity, V}];
module_opt([<<"ldap_user_cache_size">>, <<"mod_shared_roster_ldap">>|_], V) ->
    [{ldap_user_cache_size, V}];
module_opt([<<"ldap_group_cache_size">>, <<"mod_shared_roster_ldap">>|_], V) ->
    [{ldap_group_cache_size, V}];
module_opt([<<"ldap_rfilter">>, <<"mod_shared_roster_ldap">>|_], V) ->
    [{ldap_rfilter, b2l(V)}];
module_opt([<<"ldap_gfilter">>, <<"mod_shared_roster_ldap">>|_], V) ->
    [{ldap_gfilter, b2l(V)}];
module_opt([<<"ldap_ufilter">>, <<"mod_shared_roster_ldap">>|_], V) ->
    [{ldap_ufilter, b2l(V)}];
module_opt([<<"buffer_max">>, <<"mod_stream_management">>|_], <<"no_buffer">>) ->
    [{buffer_max, no_buffer}];
module_opt([<<"buffer_max">>, <<"mod_stream_management">>|_], V) ->
    [{buffer_max, int_or_infinity(V)}];
module_opt([<<"ack_freq">>, <<"mod_stream_management">>|_], <<"never">>) ->
    [{ack_freq, never}];
module_opt([<<"ack_freq">>, <<"mod_stream_management">>|_], V) ->
    [{ack_freq, V}];
module_opt([<<"resume_timeout">>, <<"mod_stream_management">>|_], V) ->
    [{resume_timeout, V}];
module_opt([<<"stale_h">>, <<"mod_stream_management">>|_] = Path, V) ->
    Stale = parse_section(Path, V),
    [{stale_h, Stale}];
module_opt([<<"host">>, <<"mod_vcard">>|_], V) ->
    [{host, b2l(V)}];
module_opt([<<"search">>, <<"mod_vcard">>|_], V) ->
    [{search, V}];
module_opt([<<"matches">>, <<"mod_vcard">>|_], V) ->
    [{matches, int_or_infinity(V)}];
module_opt([<<"ldap_vcard_map">>, <<"mod_vcard">>|_] = Path, V) ->
    Maps = parse_list(Path, V),
    [{ldap_vcard_map, Maps}];
module_opt([<<"ldap_uids">>, <<"mod_vcard">>|_] = Path, V) ->
    List = parse_list(Path, V),
    [{ldap_uids, List}];
module_opt([<<"ldap_search_fields">>, <<"mod_vcard">>|_] = Path, V) ->
    Fields = parse_list(Path, V),
    [{ldap_search_fields, Fields}];
module_opt([<<"ldap_search_reported">>, <<"mod_vcard">>|_] = Path, V) ->
    Reported = parse_list(Path, V),
    [{ldap_search_reported, Reported}];
module_opt([<<"ldap_search_operator">>, <<"mod_vcard">>|_], V) ->
    [{ldap_search_operator, b2a(V)}];
module_opt([<<"ldap_binary_search_fields">>, <<"mod_vcard">>|_] = Path, V) ->
    List = parse_list(Path, V),
    [{ldap_binary_search_fields, List}];
module_opt([<<"os_info">>, <<"mod_version">>|_], V) ->
    [{os_info, V}];
% General options
module_opt([<<"iqdisc">>|_], V) ->
    {Type, Opts} = maps:take(<<"type">>, V),
    [{iqdisc, iqdisc_value(b2a(Type), Opts)}];
module_opt([<<"backend">>|_], V) ->
    [{backend, b2a(V)}];
%% LDAP-specific options
module_opt([<<"ldap_pool_tag">>|_], V) ->
    [{ldap_pool_tag, b2a(V)}];
module_opt([<<"ldap_base">>|_], V) ->
    [{ldap_base, b2l(V)}];
module_opt([<<"ldap_filter">>|_], V) ->
    [{ldap_filter, b2l(V)}];
module_opt([<<"ldap_deref">>|_], V) ->
    [{ldap_deref, b2a(V)}];
%% Backend-specific options
module_opt([<<"riak">>|_] = Path, V) ->
    parse_section(Path, V).

process_welcome_message(Props) ->
    Subject = proplists:get_value(subject, Props, ""),
    Body = proplists:get_value(body, Props, ""),
    [{welcome_message, {Subject, Body}}].

%% path: (host_config[].)modules.*.riak.*
-spec riak_opts(path(), toml_section()) -> [option()].
riak_opts([<<"defaults_bucket_type">>|_], V) ->
    [{defaults_bucket_type, V}];
riak_opts([<<"names_bucket_type">>|_], V) ->
    [{names_bucket_type, V}];
riak_opts([<<"version_bucket_type">>|_], V) ->
    [{version_bucket_type, V}];
riak_opts([<<"bucket_type">>|_], V) ->
    [{bucket_type, V}];
riak_opts([<<"search_index">>|_], V) ->
    [{search_index, V}].

-spec mod_register_ip_access_rule(path(), toml_section()) -> [option()].
mod_register_ip_access_rule(_, #{<<"address">> := Addr, <<"policy">> := Policy}) ->
    [{b2a(Policy), b2l(Addr)}].

-spec mod_auth_token_validity_periods(path(), toml_section()) -> [option()].
mod_auth_token_validity_periods(_,
    #{<<"token">> := Token, <<"value">> := Value, <<"unit">> := Unit}) ->
        [{{validity_period, b2a(Token)}, {Value, b2a(Unit)}}].

-spec mod_disco_server_info(path(), toml_section()) -> [option()].
mod_disco_server_info(Path, #{<<"module">> := <<"all">>, <<"name">> := Name, <<"urls">> := Urls}) ->
    URLList = parse_list([<<"urls">> | Path], Urls),
    [{all, b2l(Name), URLList}];
mod_disco_server_info(Path, #{<<"module">> := Modules, <<"name">> := Name, <<"urls">> := Urls}) ->
    Mods = parse_list([<<"module">> | Path], Modules),
    URLList = parse_list([<<"urls">> | Path], Urls),
    [{Mods, b2l(Name), URLList}].

-spec mod_event_pusher_backend_sns(path(), toml_section()) -> [option()].
mod_event_pusher_backend_sns(Path, Opts) ->
    SnsOpts = parse_section(Path, Opts),
    [{sns, SnsOpts}].

-spec mod_event_pusher_backend_push(path(), toml_section()) -> [option()].
mod_event_pusher_backend_push(Path, Opts) ->
    PushOpts = parse_section(Path, Opts),
    [{push, PushOpts}].

-spec mod_event_pusher_backend_http(path(), toml_section()) -> [option()].
mod_event_pusher_backend_http(Path, Opts) ->
    HttpOpts = parse_section(Path, Opts),
    [{http, HttpOpts}].

-spec mod_event_pusher_backend_rabbit(path(), toml_section()) -> [option()].
mod_event_pusher_backend_rabbit(Path, Opts) ->
    ROpts = parse_section(Path, Opts),
    [{rabbit, ROpts}].

-spec mod_event_pusher_backend_sns_opts(path(), toml_value()) -> [option()].
mod_event_pusher_backend_sns_opts([<<"presence_updates_topic">>|_], V) ->
    [{presence_updates_topic, b2l(V)}];
mod_event_pusher_backend_sns_opts([<<"pm_messages_topic">>|_], V) ->
    [{pm_messages_topic, b2l(V)}];
mod_event_pusher_backend_sns_opts([<<"muc_messages_topic">>|_], V) ->
    [{muc_messages_topic, b2l(V)}];
mod_event_pusher_backend_sns_opts([<<"plugin_module">>|_], V) ->
    [{plugin_module, b2a(V)}];
mod_event_pusher_backend_sns_opts([<<"muc_host">>|_], V) ->
    [{muc_host, b2l(V)}];
mod_event_pusher_backend_sns_opts([<<"sns_host">>|_], V) ->
    [{sns_host, b2l(V)}];
mod_event_pusher_backend_sns_opts([<<"region">>|_], V) ->
    [{region, b2l(V)}];
mod_event_pusher_backend_sns_opts([<<"access_key_id">>|_], V) ->
    [{access_key_id, b2l(V)}];
mod_event_pusher_backend_sns_opts([<<"secret_access_key">>|_], V) ->
    [{secret_access_key, b2l(V)}];
mod_event_pusher_backend_sns_opts([<<"account_id">>|_], V) ->
    [{account_id, b2l(V)}];
mod_event_pusher_backend_sns_opts([<<"pool_size">>|_], V) ->
    [{pool_size, V}];
mod_event_pusher_backend_sns_opts([<<"publish_retry_count">>|_], V) ->
    [{publish_retry_count, V}];
mod_event_pusher_backend_sns_opts([<<"publish_retry_time_ms">>|_], V) ->
    [{publish_retry_time_ms, V}].

-spec mod_event_pusher_backend_push_opts(path(), toml_value()) -> [option()].
mod_event_pusher_backend_push_opts([<<"backend">>|_], V) ->
    [{backend, b2a(V)}];
mod_event_pusher_backend_push_opts([<<"wpool">>|_] = Path, V) ->
    WpoolOpts = parse_section(Path, V),
    [{wpool, WpoolOpts}];
mod_event_pusher_backend_push_opts([<<"plugin_module">>|_], V) ->
    [{plugin_module, b2a(V)}];
mod_event_pusher_backend_push_opts([<<"virtual_pubsub_hosts">> |_] = Path, V) ->
    VPH = parse_list(Path, V),
    [{virtual_pubsub_hosts, VPH}].

-spec mod_event_pusher_backend_http_opts(path(), toml_value()) -> [option()].
mod_event_pusher_backend_http_opts([<<"pool_name">>|_], V) ->
    [{pool_name, b2a(V)}];
mod_event_pusher_backend_http_opts([<<"path">>|_], V) ->
    [{path, b2l(V)}];
mod_event_pusher_backend_http_opts([<<"callback_module">>|_], V) ->
    [{callback_module, b2a(V)}].

-spec mod_event_pusher_backend_rabbit_opts(path(), toml_value()) -> [option()].
mod_event_pusher_backend_rabbit_opts([<<"presence_exchange">>|_] = Path, V) ->
    [{presence_exchange, parse_section(Path, V)}];
mod_event_pusher_backend_rabbit_opts([<<"chat_msg_exchange">>|_] = Path, V) ->
    [{chat_msg_exchange, parse_section(Path, V)}];
mod_event_pusher_backend_rabbit_opts([<<"groupchat_msg_exchange">>|_] = Path, V) ->
    [{groupchat_msg_exchange, parse_section(Path, V)}].

-spec mod_event_pusher_rabbit_presence_ex(path(), toml_value()) -> [option()].
mod_event_pusher_rabbit_presence_ex([<<"name">>|_], V) ->
    [{name, V}];
mod_event_pusher_rabbit_presence_ex([<<"type">>|_], V) ->
    [{type, V}].

-spec mod_event_pusher_rabbit_msg_ex(path(), toml_value()) -> [option()].
mod_event_pusher_rabbit_msg_ex([<<"name">>|_], V) ->
    [{name, V}];
mod_event_pusher_rabbit_msg_ex([<<"type">>|_], V) ->
    [{type, V}];
mod_event_pusher_rabbit_msg_ex([<<"sent_topic">>|_], V) ->
    [{sent_topic, V}];
mod_event_pusher_rabbit_msg_ex([<<"recv_topic">>|_], V) ->
    [{recv_topic, V}].

-spec mod_extdisco_service(path(), toml_value()) -> [option()].
mod_extdisco_service([_, <<"service">>|_] = Path, V) ->
    [parse_section(Path, V)];
mod_extdisco_service([<<"type">>|_], V) ->
    [{type, b2a(V)}];
mod_extdisco_service([<<"host">>|_], V) ->
    [{host, b2l(V)}];
mod_extdisco_service([<<"port">>|_], V) ->
    [{port, V}];
mod_extdisco_service([<<"transport">>|_], V) ->
    [{transport, b2l(V)}];
mod_extdisco_service([<<"username">>|_], V) ->
    [{username, b2l(V)}];
mod_extdisco_service([<<"password">>|_], V) ->
    [{password, b2l(V)}].

-spec mod_http_upload_s3(path(), toml_value()) -> [option()].
mod_http_upload_s3([<<"bucket_url">>|_], V) ->
    [{bucket_url, b2l(V)}];
mod_http_upload_s3([<<"add_acl">>|_], V) ->
    [{add_acl, V}];
mod_http_upload_s3([<<"region">>|_], V) ->
    [{region, b2l(V)}];
mod_http_upload_s3([<<"access_key_id">>|_], V) ->
    [{access_key_id, b2l(V)}];
mod_http_upload_s3([<<"secret_access_key">>|_], V) ->
    [{secret_access_key, b2l(V)}].

-spec mod_global_distrib_connections(path(), toml_value()) -> [option()].
mod_global_distrib_connections([<<"endpoints">>|_] = Path, V) ->
    Endpoints = parse_list(Path, V),
    [{endpoints, Endpoints}];
mod_global_distrib_connections([<<"advertised_endpoints">>|_], false) ->
    [{advertised_endpoints, false}];
mod_global_distrib_connections([<<"advertised_endpoints">>|_] = Path, V) ->
    Endpoints = parse_list(Path, V),
    [{advertised_endpoints, Endpoints}];
mod_global_distrib_connections([<<"connections_per_endpoint">>|_], V) ->
    [{connections_per_endpoint, V}];
mod_global_distrib_connections([<<"endpoint_refresh_interval">>|_], V) ->
    [{endpoint_refresh_interval, V}];
mod_global_distrib_connections([<<"endpoint_refresh_interval_when_empty">>|_], V) ->
    [{endpoint_refresh_interval_when_empty, V}];
mod_global_distrib_connections([<<"disabled_gc_interval">>|_], V) ->
    [{disabled_gc_interval, V}];
mod_global_distrib_connections([<<"tls">>|_] = _Path, false) ->
    [{tls_opts, false}];
mod_global_distrib_connections([<<"tls">>|_] = Path, V) ->
    TLSOpts = parse_section(Path, V),
    [{tls_opts, TLSOpts}].

-spec mod_global_distrib_cache(path(), toml_value()) -> [option()].
mod_global_distrib_cache([<<"cache_missed">>|_], V) ->
    [{cache_missed, V}];
mod_global_distrib_cache([<<"domain_lifetime_seconds">>|_], V) ->
    [{domain_lifetime_seconds, V}];
mod_global_distrib_cache([<<"jid_lifetime_seconds">>|_], V) ->
    [{jid_lifetime_seconds, V}];
mod_global_distrib_cache([<<"max_jids">>|_], V) ->
    [{max_jids, V}].

-spec mod_global_distrib_redis(path(), toml_value()) -> [option()].
mod_global_distrib_redis([<<"pool">>|_], V) ->
    [{pool, b2a(V)}];
mod_global_distrib_redis([<<"expire_after">>|_], V) ->
    [{expire_after, V}];
mod_global_distrib_redis([<<"refresh_after">>|_], V) ->
    [{refresh_after, V}].

-spec mod_global_distrib_bounce(path(), toml_value()) -> [option()].
mod_global_distrib_bounce([<<"resend_after_ms">>|_], V) ->
    [{resend_after_ms, V}];
mod_global_distrib_bounce([<<"max_retries">>|_], V) ->
    [{max_retries, V}].

-spec mod_global_distrib_connections_endpoints(path(), toml_section()) -> [option()].
mod_global_distrib_connections_endpoints(_, #{<<"host">> := Host, <<"port">> := Port}) ->
    [{b2l(Host), Port}].

-spec mod_global_distrib_connections_advertised_endpoints(path(), toml_section()) -> [option()].
mod_global_distrib_connections_advertised_endpoints(_, #{<<"host">> := Host, <<"port">> := Port}) ->
    [{b2l(Host), Port}].

-spec mod_keystore_keys(path(), toml_section()) -> [option()].
mod_keystore_keys(_, #{<<"name">> := Name, <<"type">> := <<"ram">>}) ->
    [{b2a(Name), ram}];
mod_keystore_keys(_, #{<<"name">> := Name, <<"type">> := <<"file">>, <<"path">> := Path}) ->
    [{b2a(Name), {file, b2l(Path)}}].

-spec mod_mam_opts(path(), toml_value()) -> [option()].
mod_mam_opts([<<"backend">>|_], V) ->
    [{backend, b2a(V)}];
mod_mam_opts([<<"no_stanzaid_element">>|_], V) ->
    [{no_stanzaid_element, V}];
mod_mam_opts([<<"is_archivable_message">>|_], V) ->
    [{is_archivable_message, b2a(V)}];
mod_mam_opts([<<"message_retraction">>|_], V) ->
    [{message_retraction, V}];
mod_mam_opts([<<"user_prefs_store">>|_], false) ->
    [{user_prefs_store, false}];
mod_mam_opts([<<"user_prefs_store">>|_], V) ->
    [{user_prefs_store, b2a(V)}];
mod_mam_opts([<<"full_text_search">>|_], V) ->
    [{full_text_search, V}];
mod_mam_opts([<<"cache_users">>|_], V) ->
    [{cache_users, V}];
mod_mam_opts([<<"rdbms_message_format">>|_], V) ->
    [{rdbms_message_format, b2a(V)}];
mod_mam_opts([<<"async_writer">>|_], V) ->
    [{async_writer, V}];
mod_mam_opts([<<"flush_interval">>|_], V) ->
    [{flush_interval, V}];
mod_mam_opts([<<"max_batch_size">>|_], V) ->
    [{max_batch_size, V}];
mod_mam_opts([<<"default_result_limit">>|_], V) ->
    [{default_result_limit, V}];
mod_mam_opts([<<"max_result_limit">>|_], V) ->
    [{max_result_limit, V}];
mod_mam_opts([<<"archive_chat_markers">>|_], V) ->
    [{archive_chat_markers, V}];
mod_mam_opts([<<"archive_groupchats">>|_], V) ->
    [{archive_groupchats, V}];
mod_mam_opts([<<"async_writer_rdbms_pool">>|_], V) ->
    [{async_writer_rdbms_pool, b2a(V)}];
mod_mam_opts([<<"db_jid_format">>|_], V) ->
    [{db_jid_format, b2a(V)}];
mod_mam_opts([<<"db_message_format">>|_], V) ->
    [{db_message_format, b2a(V)}];
mod_mam_opts([<<"simple">>|_], V) ->
    [{simple, V}];
mod_mam_opts([<<"host">>|_], V) ->
    [{host, b2l(V)}];
mod_mam_opts([<<"extra_lookup_params">>|_], V) ->
    [{extra_lookup_params, b2a(V)}];
mod_mam_opts([<<"riak">>|_] = Path, V) ->
    parse_section(Path, V).

-spec mod_muc_default_room(path(), toml_value()) -> [option()].
mod_muc_default_room([<<"title">>|_], V) ->
    [{title, V}];
mod_muc_default_room([<<"description">>|_], V) ->
    [{description, V}];
mod_muc_default_room([<<"allow_change_subj">>|_], V) ->
    [{allow_change_subj, V}];
mod_muc_default_room([<<"allow_query_users">>|_], V) ->
    [{allow_query_users, V}];
mod_muc_default_room([<<"allow_private_messages">>|_], V) ->
    [{allow_private_messages, V}];
mod_muc_default_room([<<"allow_visitor_status">>|_], V) ->
    [{allow_visitor_status, V}];
mod_muc_default_room([<<"allow_visitor_nickchange">>|_], V) ->
    [{allow_visitor_nickchange, V}];
mod_muc_default_room([<<"public">>|_], V) ->
    [{public, V}];
mod_muc_default_room([<<"public_list">>|_], V) ->
    [{public_list, V}];
mod_muc_default_room([<<"persistent">>|_], V) ->
    [{persistent, V}];
mod_muc_default_room([<<"moderated">>|_], V) ->
    [{moderated, V}];
mod_muc_default_room([<<"members_by_default">>|_], V) ->
    [{members_by_default, V}];
mod_muc_default_room([<<"members_only">>|_], V) ->
    [{members_only, V}];
mod_muc_default_room([<<"allow_user_invites">>|_], V) ->
    [{allow_user_invites, V}];
mod_muc_default_room([<<"allow_multiple_sessions">>|_], V) ->
    [{allow_multiple_sessions, V}];
mod_muc_default_room([<<"password_protected">>|_], V) ->
    [{password_protected, V}];
mod_muc_default_room([<<"password">>|_], V) ->
    [{password, V}];
mod_muc_default_room([<<"anonymous">>|_], V) ->
    [{anonymous, V}];
mod_muc_default_room([<<"max_users">>|_], V) ->
    [{max_users, V}];
mod_muc_default_room([<<"logging">>|_], V) ->
    [{logging, V}];
mod_muc_default_room([<<"maygetmemberlist">>|_] = Path, V) ->
    List = parse_list(Path, V),
    [{maygetmemberlist, List}];
mod_muc_default_room([<<"affiliations">>|_] = Path, V) ->
    Affs = parse_list(Path, V),
    [{affiliations, Affs}];
mod_muc_default_room([<<"subject">>|_], V) ->
    [{subject, V}];
mod_muc_default_room([<<"subject_author">>|_], V) ->
    [{subject_author, V}].

-spec mod_muc_default_room_affiliations(path(), toml_section()) -> [option()].
mod_muc_default_room_affiliations(_, #{<<"user">> := User, <<"server">> := Server,
    <<"resource">> := Resource, <<"affiliation">> := Aff}) ->
    [{{User, Server, Resource}, b2a(Aff)}].

-spec mod_muc_log_top_link(path(), toml_value()) -> [option()].
mod_muc_log_top_link([<<"target">>|_], V) ->
    [b2l(V)];
mod_muc_log_top_link([<<"text">>|_], V) ->
    [b2l(V)].

-spec mod_muc_light_config_schema(path(), toml_section()) -> [option()].
mod_muc_light_config_schema(_, #{<<"field">> := Field, <<"value">> := Val,
                                 <<"internal_key">> := Key, <<"type">> := Type}) ->
    [{b2l(Field), Val, b2a(Key), b2a(Type)}];
mod_muc_light_config_schema(_, #{<<"field">> := Field, <<"value">> := Val}) ->
    [{b2l(Field), b2l(Val)}].

-spec mod_pubsub_pep_mapping(path(), toml_section()) -> [option()].
mod_pubsub_pep_mapping(_, #{<<"namespace">> := Name, <<"node">> := Node}) ->
    [{b2l(Name), b2l(Node)}].

-spec mod_pubsub_default_node_config(path(), toml_section()) -> [option()].
mod_pubsub_default_node_config([<<"access_model">>|_], Value) ->
    [{access_model, b2a(Value)}];
mod_pubsub_default_node_config([<<"deliver_notifications">>|_], Value) ->
    [{deliver_notifications, Value}];
mod_pubsub_default_node_config([<<"deliver_payloads">>|_], Value) ->
    [{deliver_payloads, Value}];
mod_pubsub_default_node_config([<<"max_items">>|_], Value) ->
    [{max_items, Value}];
mod_pubsub_default_node_config([<<"max_payload_size">>|_], Value) ->
    [{max_payload_size, Value}];
mod_pubsub_default_node_config([<<"node_type">>|_], Value) ->
    [{node_type, b2a(Value)}];
mod_pubsub_default_node_config([<<"notification_type">>|_], Value) ->
    [{notification_type, b2a(Value)}];
mod_pubsub_default_node_config([<<"notify_config">>|_], Value) ->
    [{notify_config, Value}];
mod_pubsub_default_node_config([<<"notify_delete">>|_], Value) ->
    [{notify_delete, Value}];
mod_pubsub_default_node_config([<<"notify_retract">>|_], Value) ->
    [{notify_retract, Value}];
mod_pubsub_default_node_config([<<"persist_items">>|_], Value) ->
    [{persist_items, Value}];
mod_pubsub_default_node_config([<<"presence_based_delivery">>|_], Value) ->
    [{presence_based_delivery, Value}];
mod_pubsub_default_node_config([<<"publish_model">>|_], Value) ->
    [{publish_model, b2a(Value)}];
mod_pubsub_default_node_config([<<"purge_offline">>|_], Value) ->
    [{purge_offline, Value}];
mod_pubsub_default_node_config([<<"roster_groups_allowed">>|_] = Path, Value) ->
    Groups = parse_list(Path, Value),
    [{roster_groups_allowed, Groups}];
mod_pubsub_default_node_config([<<"send_last_published_item">>|_], Value) ->
    [{send_last_published_item, b2a(Value)}];
mod_pubsub_default_node_config([<<"subscribe">>|_], Value) ->
    [{subscribe, Value}].

mod_pubsub_roster_groups_allowed(_, Value) ->
    [Value].

-spec mod_revproxy_routes(path(), toml_section()) -> [option()].
mod_revproxy_routes(_, #{<<"host">> := Host, <<"path">> := Path, <<"method">> := Method,
    <<"upstream">> := Upstream}) ->
        [{b2l(Host), b2l(Path), b2l(Method), b2l(Upstream)}];
mod_revproxy_routes(_, #{<<"host">> := Host, <<"path">> := Path, <<"upstream">> := Upstream}) ->
        [{b2l(Host), b2l(Path), b2l(Upstream)}].

-spec mod_stream_management_stale_h(path(), toml_value()) -> [option()].
mod_stream_management_stale_h([<<"enabled">>|_], V) ->
    [{enabled, V}];
mod_stream_management_stale_h([<<"repeat_after">>|_], V) ->
    [{stale_h_repeat_after, V}];
mod_stream_management_stale_h([<<"geriatric">>|_], V) ->
    [{stale_h_geriatric, V}].

-spec mod_vcard_ldap_uids(path(), toml_section()) -> [option()].
mod_vcard_ldap_uids(_, #{<<"attr">> := Attr, <<"format">> := Format}) ->
    [{b2l(Attr), b2l(Format)}];
mod_vcard_ldap_uids(_, #{<<"attr">> := Attr}) ->
    [b2l(Attr)].


-spec mod_vcard_ldap_vcard_map(path(), toml_section()) -> [option()].
mod_vcard_ldap_vcard_map(_, #{<<"vcard_field">> := VF, <<"ldap_pattern">> := LP,
    <<"ldap_field">> := LF}) ->
    [{VF, LP, [LF]}].

-spec mod_vcard_ldap_search_fields(path(), toml_section()) -> [option()].
mod_vcard_ldap_search_fields(_, #{<<"search_field">> := SF, <<"ldap_field">> := LF}) ->
    [{SF, LF}].

-spec mod_vcard_ldap_search_reported(path(), toml_section()) -> [option()].
mod_vcard_ldap_search_reported(_, #{<<"search_field">> := SF, <<"vcard_field">> := VF}) ->
    [{SF, VF}].

-spec mod_vcard_ldap_binary_search_fields(path(), toml_section()) -> [option()].
mod_vcard_ldap_binary_search_fields(_, V) ->
    [V].

-spec iqdisc_value(atom(), toml_section()) -> option().
iqdisc_value(queues, #{<<"workers">> := Workers} = V) ->
    limit_keys([<<"workers">>], V),
    {queues, Workers};
iqdisc_value(Type, V) ->
    limit_keys([], V),
    Type.

-spec service_admin_extra_submods(path(), toml_value()) -> [option()].
service_admin_extra_submods(_, V) ->
    [b2a(V)].

welcome_message([<<"subject">>|_], Value) ->
    [{subject, b2l(Value)}];
welcome_message([<<"body">>|_], Value) ->
    [{body, b2l(Value)}].

%% path: (host_config[].)shaper.*
-spec process_shaper(path(), toml_section()) -> [config()].
process_shaper([Name, _|Path], #{<<"max_rate">> := MaxRate}) ->
    [#config{key = {shaper, b2a(Name), host(Path)}, value = {maxrate, MaxRate}}].

%% path: (host_config[].)acl.*
-spec process_acl(path(), toml_value()) -> [config()].
process_acl([item, ACLName, _|Path], Content) ->
    [acl:to_record(host(Path), b2a(ACLName), acl_data(Content))].

-spec acl_data(toml_value()) -> option().
acl_data(#{<<"match">> := <<"all">>}) -> all;
acl_data(#{<<"match">> := <<"none">>}) -> none;
acl_data(M) ->
    {AclName, AclKeys} = find_acl(M, lists:sort(maps:keys(M)), acl_keys()),
    list_to_tuple([AclName | lists:map(fun(K) -> maps:get(K, M) end, AclKeys)]).

find_acl(M, SortedMapKeys, [{AclName, AclKeys}|Rest]) ->
    case lists:sort(AclKeys) of
        SortedMapKeys -> {AclName, AclKeys};
        _ -> find_acl(M, SortedMapKeys, Rest)
    end.

acl_keys() ->
    [{user, [<<"user">>, <<"server">>]},
     {user, [<<"user">>]},
     {server, [<<"server">>]},
     {resource, [<<"resource">>]},
     {user_regexp, [<<"user_regexp">>, <<"server">>]},
     {node_regexp, [<<"user_regexp">>, <<"server_regexp">>]},
     {user_regexp, [<<"user_regexp">>]},
     {server_regexp, [<<"server_regexp">>]},
     {resource_regexp, [<<"resource_regexp">>]},
     {user_glob, [<<"user_glob">>, <<"server">>]},
     {node_glob, [<<"user_glob">>, <<"server_glob">>]},
     {user_glob, [<<"user_glob">>]},
     {server_glob, [<<"server_glob">>]},
     {resource_glob, [<<"resource_glob">>]}
    ].

%% path: (host_config[].)access.*
-spec process_access_rule(path(), toml_value()) -> [config()].
process_access_rule([Name, _|HostPath] = Path, Contents) ->
    Rules = parse_list(Path, Contents),
    [#config{key = {access, b2a(Name), host(HostPath)}, value = Rules}].

%% path: (host_config[].)access.*[]
-spec process_access_rule_item(path(), toml_section()) -> [option()].
process_access_rule_item(_, #{<<"acl">> := ACL, <<"value">> := Value}) ->
    [{access_rule_value(Value), b2a(ACL)}].

host([]) -> global;
host([{host, Host}, _]) -> Host.

-spec access_rule_value(toml_value()) -> option().
access_rule_value(B) when is_binary(B) -> b2a(B);
access_rule_value(V) -> V.

%% path: (host_config[].)s2s.*
-spec process_s2s_option(path(), toml_value()) -> config_list().
process_s2s_option([<<"dns">>|_] = Path, V) ->
    [#local_config{key = s2s_dns_options, value = parse_section(Path, V)}];
process_s2s_option([<<"outgoing">>|_] = Path, V) ->
    parse_section(Path, V);
process_s2s_option([<<"use_starttls">>|_], V) ->
    [#local_config{key = s2s_use_starttls, value = b2a(V)}];
process_s2s_option([<<"certfile">>|_], V) ->
    [#local_config{key = s2s_certfile, value = b2l(V)}];
process_s2s_option([<<"default_policy">>|_], V) ->
    ?HOST_F([#local_config{key = {s2s_default_policy, Host}, value = b2a(V)}]);
process_s2s_option([<<"host_policy">>|_] = Path, V) ->
    parse_list(Path, V);
process_s2s_option([<<"address">>|_] = Path, V) ->
    parse_list(Path, V);
process_s2s_option([<<"ciphers">>|_], V) ->
    [#local_config{key = s2s_ciphers, value = b2l(V)}];
process_s2s_option([<<"domain_certfile">>|_] = Path, V) ->
    parse_list(Path, V);
process_s2s_option([<<"shared">>|_], V) ->
    ?HOST_F([#local_config{key = {s2s_shared, Host}, value = V}]);
process_s2s_option([<<"max_retry_delay">>|_], V) ->
    ?HOST_F([#local_config{key = {s2s_max_retry_delay, Host}, value = V}]).

%% path: s2s.dns.*
-spec s2s_dns_opt(path(), toml_value()) -> [option()].
s2s_dns_opt([<<"timeout">>|_], Value) -> [{timeout, Value}];
s2s_dns_opt([<<"retries">>|_], Value) -> [{retries, Value}].

%% path: s2s.outgoing.*
-spec outgoing_s2s_opt(path(), toml_value()) -> [config()].
outgoing_s2s_opt([<<"port">>|_], Value) ->
    [#local_config{key = outgoing_s2s_port, value = Value}];
outgoing_s2s_opt([<<"ip_versions">>|_] = Path, Value) ->
    [#local_config{key = outgoing_s2s_families, value = parse_list(Path, Value)}];
outgoing_s2s_opt([<<"connection_timeout">>|_], Value) ->
    [#local_config{key = outgoing_s2s_timeout, value = int_or_infinity(Value)}].

%% path: s2s.outgoing.ip_versions[]
-spec s2s_address_family(path(), toml_value()) -> [option()].
s2s_address_family(_, 4) -> [ipv4];
s2s_address_family(_, 6) -> [ipv6].

%% path: s2s.host_policy[]
-spec s2s_host_policy(path(), toml_section()) -> config_list().
s2s_host_policy(Path, M) ->
    parse_section(Path, M, fun process_host_policy/1).

process_host_policy(Opts) ->
    {_, S2SHost} = proplists:lookup(host, Opts),
    {_, Policy} = proplists:lookup(policy, Opts),
    ?HOST_F([#local_config{key = {{s2s_host, S2SHost}, Host}, value = Policy}]).

%% path: s2s.host_policy[].*
-spec s2s_host_policy_opt(path(), toml_value()) -> [option()].
s2s_host_policy_opt([<<"host">>|_], V) -> [{host, V}];
s2s_host_policy_opt([<<"policy">>|_], V) -> [{policy, b2a(V)}].

%% path: s2s.address[]
-spec s2s_address(path(), toml_section()) -> [config()].
s2s_address(Path, M) ->
    parse_section(Path, M, fun process_s2s_address/1).

process_s2s_address(Opts) ->
    {_, Host} = proplists:lookup(host, Opts),
    {_, IPAddress} = proplists:lookup(ip_address, Opts),
    Addr = case proplists:lookup(port, Opts) of
               {_, Port} -> {IPAddress, Port};
               none -> IPAddress
           end,
    [#local_config{key = {s2s_addr, Host}, value = Addr}].

%% path: s2s.address[].*
-spec s2s_addr_opt(path(), toml_value()) -> [option()].
s2s_addr_opt([<<"host">>|_], V) -> [{host, V}];
s2s_addr_opt([<<"ip_address">>|_], V) -> [{ip_address, b2l(V)}];
s2s_addr_opt([<<"port">>|_], V) -> [{port, V}].

%% path: s2s.domain_certfile[]
-spec s2s_domain_cert(path(), toml_section()) -> [config()].
s2s_domain_cert(_, #{<<"domain">> := Dom, <<"certfile">> := Cert}) ->
    [#local_config{key = {domain_certfile, b2l(Dom)}, value = b2l(Cert)}].

%% path: host_config[]
-spec process_host_item(path(), toml_section()) -> config_list().
process_host_item(Path, M) ->
    {_Host, Sections} = maps:take(<<"host">>, M),
    parse_section(Path, Sections).

%% path: listen.http[].tls.*,
%%       listen.c2s[].tls.*,
%%       outgoing_pools.rdbms.connection.tls.*,
%%       outgoing_pools.ldap.connection.tls.*,
%%       outgoing_pools.riak.connection.tls.*,
%%       outgoing_pools.cassandra.connection.tls.*
-spec tls_option(path(), toml_value()) -> [option()].
tls_option([<<"verify_peer">>|_], V) -> [{verify, verify_peer(V)}];
tls_option([<<"certfile">>|_], V) -> [{certfile, b2l(V)}];
tls_option([<<"cacertfile">>|_], V) -> [{cacertfile, b2l(V)}];
tls_option([<<"dhfile">>|_], V) -> [{dhfile, b2l(V)}];
tls_option([<<"keyfile">>|_], V) -> [{keyfile, b2l(V)}];
tls_option([<<"password">>|_], V) -> [{password, b2l(V)}];
tls_option([<<"server_name_indication">>|_], false) -> [{server_name_indication, disable}];
tls_option([<<"ciphers">>|_] = Path, L) -> [{ciphers, parse_list(Path, L)}];
tls_option([<<"versions">>|_] = Path, L) -> [{versions, parse_list(Path, L)}].

%% path: listen.http[].tls.*,
%%       listen.c2s[].tls.*,,
%%       (host_config[].)modules.mod_global_distrib.connections.tls.*
-spec fast_tls_option(path(), toml_value()) -> [option()].
fast_tls_option([<<"certfile">>|_], V) -> [{certfile, b2l(V)}];
fast_tls_option([<<"cacertfile">>|_], V) -> [{cafile, b2l(V)}];
fast_tls_option([<<"dhfile">>|_], V) -> [{dhfile, b2l(V)}];
fast_tls_option([<<"ciphers">>|_], V) -> [{ciphers, b2l(V)}].

-spec verify_peer(boolean()) -> option().
verify_peer(false) -> verify_none;
verify_peer(true) -> verify_peer.

-spec tls_cipher(path(), toml_value()) -> [option()].
tls_cipher(_, #{<<"key_exchange">> := KEx,
                <<"cipher">> := Cipher,
                <<"mac">> := MAC,
                <<"prf">> := PRF}) ->
    [#{key_exchange => b2a(KEx), cipher => b2a(Cipher), mac => b2a(MAC), prf => b2a(PRF)}];
tls_cipher(_, Cipher) -> [b2l(Cipher)].

set_overrides(Overrides, State) ->
    lists:foldl(fun({override, Scope}, CurrentState) ->
                        mongoose_config_parser:override(Scope, CurrentState)
                end, State, Overrides).

%% TODO replace with binary_to_existing_atom where possible, prevent atom leak
b2a(B) -> binary_to_atom(B, utf8).

b2l(B) -> binary_to_list(B).

int_or_infinity(I) when is_integer(I) -> I;
int_or_infinity(<<"infinity">>) -> infinity.

-spec limit_keys([toml_key()], toml_section()) -> any().
limit_keys(Keys, Section) ->
    case maps:keys(maps:without(Keys, Section)) of
        [] -> ok;
        ExtraKeys -> error(#{what => unexpected_keys, unexpected_keys => ExtraKeys})
    end.

-spec ensure_keys([toml_key()], toml_section()) -> any().
ensure_keys(Keys, Section) ->
    case lists:filter(fun(Key) -> not maps:is_key(Key, Section) end, Keys) of
        [] -> ok;
        MissingKeys -> error(#{what => missing_mandatory_keys, missing_keys => MissingKeys})
    end.

-spec parse_kv(path(), toml_key(), toml_section(), option()) -> option().
parse_kv(Path, K, Section, Default) ->
    Value = maps:get(K, Section, Default),
    Key = key(K, Path, Value),
    handle([Key|Path], Value).

-spec parse_kv(path(), toml_key(), toml_section()) -> option().
parse_kv(Path, K, Section) ->
    #{K := Value} = Section,
    Key = key(K, Path, Value),
    handle([Key|Path], Value).

%% Parse with post-processing, this needs to be eliminated by fixing the internal config structure
-spec parse_section(path(), toml_section(), fun(([option()]) -> option())) -> option().
parse_section(Path, V, PostProcessF) ->
    L = parse_section(Path, V),
    case extract_errors(L) of
        [] -> PostProcessF(L);
        Errors -> Errors
    end.

-spec parse_section(path(), toml_section()) -> [option()].
parse_section(Path, M) ->
    lists:flatmap(fun({K, V}) ->
                          Key = key(K, Path, V),
                          handle([Key|Path], V)
                  end, lists:sort(maps:to_list(M))).

-spec parse_list(path(), [toml_value()]) -> [option()].
parse_list(Path, L) ->
    lists:flatmap(fun(Elem) ->
                          Key = item_key(Path, Elem),
                          handle([Key|Path], Elem)
                  end, L).

-spec handle(path(), toml_value()) -> option().
handle(Path, Value) ->
    lists:foldl(fun(_, [#{what := _, class := error}] = Error) ->
                        Error;
                   (StepName, AccIn) ->
                        try_call(handle_step(StepName, AccIn), StepName, Path, Value)
                end, Path, [handle, parse, validate]).

handle_step(handle, _) ->
    fun(Path, _Value) -> handler(Path) end;
handle_step(parse, Handler) ->
    Handler;
handle_step(validate, ParsedValue) ->
    fun(Path, _Value) ->
            mongoose_config_validator_toml:validate(Path, ParsedValue),
            ParsedValue
    end.

-spec try_call(fun((path(), any()) -> option()), atom(), path(), toml_value()) -> option().
try_call(F, StepName, Path, Value) ->
    try
        F(Path, Value)
    catch error:Reason:Stacktrace ->
            BasicFields = #{what => toml_processing_failed,
                            class => error,
                            stacktrace => Stacktrace,
                            text => error_text(StepName),
                            toml_path => path_to_string(Path),
                            toml_value => Value},
            ErrorFields = error_fields(Reason),
            [maps:merge(BasicFields, ErrorFields)]
    end.

-spec error_text(atom()) -> string().
error_text(handle) -> "Unexpected option in the TOML configuration file";
error_text(parse) -> "Malformed option in the TOML configuration file";
error_text(validate) -> "Incorrect option value in the TOML configuration file".

-spec error_fields(any()) -> map().
error_fields(#{what := Reason} = M) -> maps:remove(what, M#{reason => Reason});
error_fields(Reason) -> #{reason => Reason}.

-spec path_to_string(path()) -> string().
path_to_string(Path) ->
    Items = lists:flatmap(fun node_to_string/1, lists:reverse(Path)),
    string:join(Items, ".").

node_to_string(item) -> [];
node_to_string({host, _}) -> [];
node_to_string({tls, TLSAtom}) -> [atom_to_list(TLSAtom)];
node_to_string(Node) -> [binary_to_list(Node)].

-spec handler(path()) -> fun((path(), toml_value()) -> option()).
handler([]) -> fun parse_root/2;
handler([_]) -> fun process_section/2;

%% general
handler([_, <<"general">>]) -> fun process_general/2;
handler([_, <<"hosts">>, <<"general">>]) -> fun process_host/2;
handler([_, <<"override">>, <<"general">>]) -> fun process_override/2;
handler([_, <<"mongooseimctl_access_commands">>, <<"general">>]) -> fun ctl_access_rule/2;
handler([<<"commands">>, _, <<"mongooseimctl_access_commands">>, <<"general">>]) ->
    fun ctl_access_commands/2;
handler([_, <<"commands">>, _, <<"mongooseimctl_access_commands">>, <<"general">>]) ->
    fun(_, Val) -> [b2l(Val)] end;
handler([<<"argument_restrictions">>, _, <<"mongooseimctl_access_commands">>, <<"general">>]) ->
    fun parse_section/2;
handler([_, <<"argument_restrictions">>, _, <<"mongooseimctl_access_commands">>, <<"general">>]) ->
    fun ctl_access_arg_restriction/2;
handler([_, <<"routing_modules">>, <<"general">>]) ->
    fun(_, Val) -> [b2a(Val)] end;

%% listen
handler([_, <<"listen">>]) -> fun parse_list/2;
handler([_, _, <<"listen">>]) -> fun process_listener/2;
handler([_, _, <<"http">>, <<"listen">>]) -> fun http_listener_opt/2;
handler([_, _, <<"c2s">>, <<"listen">>]) -> fun c2s_listener_opt/2;
handler([_, _, <<"s2s">>, <<"listen">>]) -> fun s2s_listener_opt/2;
handler([_, <<"tls">>, _, <<"s2s">>, <<"listen">>]) -> fun s2s_tls_option/2;
handler([_, _, <<"service">>, <<"listen">>]) -> fun service_listener_opt/2;
handler([_, {tls, _}, _, <<"c2s">>, <<"listen">>]) -> fun c2s_tls_option/2;
handler([_, <<"versions">>, {tls, just_tls}, _, <<"c2s">>, <<"listen">>]) ->
    fun(_, Val) -> [b2a(Val)] end;
handler([_, <<"ciphers">>, {tls, just_tls}, _, <<"c2s">>, <<"listen">>]) ->
    fun tls_cipher/2;
handler([_, <<"crl_files">>, {tls, just_tls}, _, <<"c2s">>, <<"listen">>]) ->
    fun(_, Val) -> [b2l(Val)] end;
handler([_, <<"protocol_options">>, _TLS, _, _, <<"listen">>]) ->
    fun(_, Val) -> [b2l(Val)] end;
handler([_, <<"tls">>, _, <<"http">>, <<"listen">>]) -> fun https_option/2;
handler([_, <<"transport">>, _, <<"http">>, <<"listen">>]) -> fun cowboy_transport_opt/2;
handler([_, <<"protocol">>, _, <<"http">>, <<"listen">>]) -> fun cowboy_protocol_opt/2;
handler([_, <<"handlers">>, _, <<"http">>, <<"listen">>]) -> fun parse_list/2;
handler([_, _, <<"handlers">>, _, <<"http">>, <<"listen">>]) -> fun cowboy_module/2;
handler([_, _, <<"mongoose_api">>, <<"handlers">>, _, <<"http">>, <<"listen">>]) ->
    fun mongoose_api_option/2;
handler([_, <<"handlers">>, _, <<"mongoose_api">>, <<"handlers">>, _, <<"http">>, <<"listen">>]) ->
    fun(_, Val) -> [b2a(Val)] end;
handler([_, _, <<"mod_websockets">>, <<"handlers">>, _, <<"http">>, <<"listen">>]) ->
    fun websockets_option/2;
handler([_, <<"service">>, _, <<"mod_websockets">>, <<"handlers">>, _, <<"http">>, <<"listen">>]) ->
    fun service_listener_opt/2;

%% auth
handler([_, <<"auth">>]) -> fun auth_option/2;
handler([_, <<"anonymous">>, <<"auth">>]) -> fun auth_anonymous_option/2;
handler([_, <<"ldap">>, <<"auth">>]) -> fun auth_ldap_option/2;
handler([_, <<"external">>, <<"auth">>]) -> fun auth_external_option/2;
handler([_, <<"http">>, <<"auth">>]) -> fun auth_http_option/2;
handler([_, <<"jwt">>, <<"auth">>]) -> fun auth_jwt_option/2;
handler([_, <<"secret">>, <<"jwt">>, <<"auth">>]) -> fun auth_jwt_secret/2;
handler([_, <<"riak">>, <<"auth">>]) -> fun auth_riak_option/2;
handler([_, <<"uids">>, <<"ldap">>, <<"auth">>]) -> fun auth_ldap_uids/2;
handler([_, <<"dn_filter">>, <<"ldap">>, <<"auth">>]) -> fun auth_ldap_dn_filter/2;
handler([_, <<"local_filter">>, <<"ldap">>, <<"auth">>]) -> fun auth_ldap_local_filter/2;
handler([_, <<"attributes">>, _, <<"ldap">>, <<"auth">>]) -> fun(_, V) -> [b2l(V)] end;
handler([_, <<"values">>, _, <<"ldap">>, <<"auth">>]) -> fun(_, V) -> [b2l(V)] end;
handler([_, <<"methods">>, <<"auth">>]) -> fun(_, Val) -> [b2a(Val)] end;
handler([_, <<"hash">>, <<"password">>, <<"auth">>]) -> fun(_, Val) -> [b2a(Val)] end;
handler([_, <<"sasl_external">>, <<"auth">>]) -> fun sasl_external/2;
handler([_, <<"sasl_mechanisms">>, <<"auth">>]) -> fun sasl_mechanism/2;

%% outgoing_pools
handler([_, <<"outgoing_pools">>]) -> fun parse_section/2;
handler([_, _, <<"outgoing_pools">>]) -> fun process_pool/2;
handler([<<"connection">>, _, _, <<"outgoing_pools">>]) -> fun connection_options/2;
handler([{connection, _}, _,
         <<"rdbms">>, <<"outgoing_pools">>]) -> fun connection_options/2;
handler([_, _, _, <<"outgoing_pools">>]) -> fun pool_option/2;
handler([_, {connection, odbc}, _,
         <<"rdbms">>, <<"outgoing_pools">>]) -> fun odbc_option/2;
handler([_, {connection, _}, _,
         <<"rdbms">>, <<"outgoing_pools">>]) -> fun sql_server_option/2;
handler([_, <<"connection">>, _,
         <<"http">>, <<"outgoing_pools">>]) -> fun http_option/2;
handler([_, <<"connection">>, _,
         <<"redis">>, <<"outgoing_pools">>]) -> fun redis_option/2;
handler([_, <<"connection">>, _,
         <<"ldap">>, <<"outgoing_pools">>]) -> fun ldap_option/2;
handler([_, <<"servers">>, <<"connection">>, _,
         <<"ldap">>, <<"outgoing_pools">>]) -> fun(_, V) -> [b2l(V)] end;
handler([_, <<"connection">>, _,
         <<"riak">>, <<"outgoing_pools">>]) -> fun riak_option/2;
handler([_, <<"credentials">>, <<"connection">>, _,
         <<"riak">>, <<"outgoing_pools">>]) -> fun riak_credentials/2;
handler([_, <<"connection">>, _,
         <<"cassandra">>, <<"outgoing_pools">>]) -> fun cassandra_option/2;
handler([_, <<"auth">>, <<"connection">>, _,
         <<"cassandra">>, <<"outgoing_pools">>]) -> fun cassandra_option/2;
handler([_, <<"servers">>, <<"connection">>, _,
         <<"cassandra">>, <<"outgoing_pools">>]) -> fun cassandra_server/2;
handler([_, <<"connection">>, _,
         <<"elastic">>, <<"outgoing_pools">>]) -> fun elastic_option/2;
handler([_, <<"connection">>, _,
         <<"rabbit">>, <<"outgoing_pools">>]) -> fun rabbit_option/2;
handler([_, <<"tls">>, _, _, _, <<"outgoing_pools">>]) -> fun tls_option/2;
handler([_, <<"versions">>, <<"tls">>, _, _, _, <<"outgoing_pools">>]) ->
    fun(_, Val) -> [b2a(Val)] end;
handler([_, <<"ciphers">>, <<"tls">>, _, _, _, <<"outgoing_pools">>]) ->
    fun tls_cipher/2;

%% services
handler([_, <<"services">>]) -> fun process_service/2;
handler([_, _, <<"services">>]) -> fun service_opt/2;

%% modules
handler([_, <<"modules">>]) -> fun process_module/2;
handler([_, _, <<"modules">>]) -> fun module_opt/2;
handler([_, <<"riak">>, _, <<"modules">>]) ->
    fun riak_opts/2;
handler([_, <<"ip_access">>, <<"mod_register">>, <<"modules">>]) ->
    fun mod_register_ip_access_rule/2;
handler([_, <<"registration_watchers">>, <<"mod_register">>, <<"modules">>]) ->
    fun(_, V) -> [V] end;
handler([_, <<"welcome_message">>, <<"mod_register">>, <<"modules">>]) ->
    fun welcome_message/2;
handler([_, <<"validity_period">>, <<"mod_auth_token">>, <<"modules">>]) ->
    fun mod_auth_token_validity_periods/2;
handler([_, <<"extra_domains">>, <<"mod_disco">>, <<"modules">>]) ->
    fun(_, V) -> [V] end;
handler([_, <<"server_info">>, <<"mod_disco">>, <<"modules">>]) ->
    fun mod_disco_server_info/2;
handler([_, <<"urls">>, _, <<"server_info">>, <<"mod_disco">>, <<"modules">>]) ->
    fun(_, V) -> [b2l(V)] end;
handler([_, <<"module">>, _, <<"server_info">>, <<"mod_disco">>, <<"modules">>]) ->
    fun(_, V) -> [b2a(V)] end;
handler([<<"sns">>, <<"backend">>, <<"mod_event_pusher">>, <<"modules">>]) ->
    fun mod_event_pusher_backend_sns/2;
handler([<<"push">>, <<"backend">>, <<"mod_event_pusher">>, <<"modules">>]) ->
    fun mod_event_pusher_backend_push/2;
handler([<<"http">>, <<"backend">>, <<"mod_event_pusher">>, <<"modules">>]) ->
    fun mod_event_pusher_backend_http/2;
handler([<<"rabbit">>, <<"backend">>, <<"mod_event_pusher">>, <<"modules">>]) ->
    fun mod_event_pusher_backend_rabbit/2;
handler([_, <<"sns">>, <<"backend">>, <<"mod_event_pusher">>, <<"modules">>]) ->
    fun mod_event_pusher_backend_sns_opts/2;
handler([_, <<"push">>, <<"backend">>, <<"mod_event_pusher">>, <<"modules">>]) ->
    fun mod_event_pusher_backend_push_opts/2;
handler([_, <<"http">>, <<"backend">>, <<"mod_event_pusher">>, <<"modules">>]) ->
    fun mod_event_pusher_backend_http_opts/2;
handler([_, <<"rabbit">>, <<"backend">>, <<"mod_event_pusher">>, <<"modules">>]) ->
    fun mod_event_pusher_backend_rabbit_opts/2;
handler([_,<<"wpool">>, <<"push">>, <<"backend">>, <<"mod_event_pusher">>, <<"modules">>]) ->
    fun pool_option/2;
handler([_,<<"virtual_pubsub_hosts">>, <<"push">>, <<"backend">>, <<"mod_event_pusher">>, <<"modules">>]) ->
    fun (_, V) -> [b2l(V)] end;
handler([_,<<"presence_exchange">>, <<"rabbit">>, <<"backend">>, <<"mod_event_pusher">>, <<"modules">>]) ->
    fun mod_event_pusher_rabbit_presence_ex/2;
handler([_,<<"chat_msg_exchange">>, <<"rabbit">>, <<"backend">>, <<"mod_event_pusher">>, <<"modules">>]) ->
    fun mod_event_pusher_rabbit_msg_ex/2;
handler([_,<<"groupchat_msg_exchange">>, <<"rabbit">>, <<"backend">>, <<"mod_event_pusher">>, <<"modules">>]) ->
    fun mod_event_pusher_rabbit_msg_ex/2;
handler([_, <<"service">>, <<"mod_extdisco">>, <<"modules">>]) ->
    fun mod_extdisco_service/2;
handler([_, _, <<"service">>, <<"mod_extdisco">>, <<"modules">>]) ->
    fun mod_extdisco_service/2;
handler([_, <<"s3">>, <<"mod_http_upload">>, <<"modules">>]) ->
    fun mod_http_upload_s3/2;
handler([_, <<"reset_markers">>, <<"mod_inbox">>, <<"modules">>]) ->
    fun(_, V) -> [b2a(V)] end;
handler([_, <<"groupchat">>, <<"mod_inbox">>, <<"modules">>]) ->
    fun(_, V) -> [b2a(V)] end;
handler([_, <<"connections">>, <<"mod_global_distrib">>, <<"modules">>]) ->
    fun mod_global_distrib_connections/2;
handler([_, <<"cache">>, <<"mod_global_distrib">>, <<"modules">>]) ->
    fun mod_global_distrib_cache/2;
handler([_, <<"bounce">>, <<"mod_global_distrib">>, <<"modules">>]) ->
    fun mod_global_distrib_bounce/2;
handler([_, <<"redis">>, <<"mod_global_distrib">>, <<"modules">>]) ->
    fun mod_global_distrib_redis/2;
handler([_,<<"endpoints">>, <<"connections">>, <<"mod_global_distrib">>, <<"modules">>]) ->
    fun mod_global_distrib_connections_endpoints/2;
handler([_,<<"advertised_endpoints">>, <<"connections">>, <<"mod_global_distrib">>, <<"modules">>]) ->
    fun mod_global_distrib_connections_advertised_endpoints/2;
handler([_,<<"tls">>, <<"connections">>, <<"mod_global_distrib">>, <<"modules">>]) ->
    fun fast_tls_option/2;
handler([_, <<"keys">>, <<"mod_keystore">>, <<"modules">>]) ->
    fun mod_keystore_keys/2;
handler([_, _, <<"mod_mam_meta">>, <<"modules">>]) ->
    fun mod_mam_opts/2;
handler([_, <<"default_room">>, <<"mod_muc">>, <<"modules">>]) ->
    fun mod_muc_default_room/2;
handler([_, <<"maygetmemberlist">>, <<"default_room">>, <<"mod_muc">>, <<"modules">>]) ->
    fun (_, V) -> [b2a(V)] end;
handler([_, <<"affiliations">>, <<"default_room">>, <<"mod_muc">>, <<"modules">>]) ->
    fun mod_muc_default_room_affiliations/2;
handler([_, <<"top_link">>, <<"mod_muc_log">>, <<"modules">>]) ->
    fun mod_muc_log_top_link/2;
handler([_, <<"config_schema">>, <<"mod_muc_light">>, <<"modules">>]) ->
    fun mod_muc_light_config_schema/2;
handler([_, <<"plugins">>, <<"mod_pubsub">>, <<"modules">>]) ->
    fun(_, V) -> [V] end;
handler([_, <<"pep_mapping">>, <<"mod_pubsub">>, <<"modules">>]) ->
    fun mod_pubsub_pep_mapping/2;
handler([_, <<"default_node_config">>, <<"mod_pubsub">>, <<"modules">>]) ->
    fun mod_pubsub_default_node_config/2;
handler([_, <<"roster_groups_allowed">>, <<"default_node_config">>, <<"mod_pubsub">>, <<"modules">>]) ->
    fun mod_pubsub_roster_groups_allowed/2;
handler([_, <<"routes">>, <<"mod_revproxy">>, <<"modules">>]) ->
    fun mod_revproxy_routes/2;
handler([_, <<"stale_h">>, <<"mod_stream_management">>, <<"modules">>]) ->
    fun mod_stream_management_stale_h/2;
handler([_, <<"ldap_uids">>, <<"mod_vcard">>, <<"modules">>]) ->
    fun mod_vcard_ldap_uids/2;
handler([_, <<"ldap_vcard_map">>, <<"mod_vcard">>, <<"modules">>]) ->
    fun mod_vcard_ldap_vcard_map/2;
handler([_, <<"ldap_search_fields">>, <<"mod_vcard">>, <<"modules">>]) ->
    fun mod_vcard_ldap_search_fields/2;
handler([_, <<"ldap_search_reported">>, <<"mod_vcard">>, <<"modules">>]) ->
    fun mod_vcard_ldap_search_reported/2;
handler([_, <<"ldap_binary_search_fields">>, <<"mod_vcard">>, <<"modules">>]) ->
    fun mod_vcard_ldap_binary_search_fields/2;
handler([_, <<"submods">>, <<"service_admin_extra">>, <<"services">>]) ->
    fun service_admin_extra_submods/2;


%% shaper, acl, access
handler([_, <<"shaper">>]) -> fun process_shaper/2;
handler([_, <<"acl">>]) -> fun parse_list/2;
handler([_, _, <<"acl">>]) -> fun process_acl/2;
handler([_, <<"access">>]) -> fun process_access_rule/2;
handler([_, _, <<"access">>]) -> fun process_access_rule_item/2;

%% s2s
handler([_, <<"s2s">>]) -> fun process_s2s_option/2;
handler([_, <<"dns">>, <<"s2s">>]) -> fun s2s_dns_opt/2;
handler([_, <<"outgoing">>, <<"s2s">>]) -> fun outgoing_s2s_opt/2;
handler([_, <<"ip_versions">>, <<"outgoing">>, <<"s2s">>]) -> fun s2s_address_family/2;
handler([_, <<"host_policy">>, <<"s2s">>]) -> fun s2s_host_policy/2;
handler([_, _, <<"host_policy">>, <<"s2s">>]) -> fun s2s_host_policy_opt/2;
handler([_, <<"address">>, <<"s2s">>]) -> fun s2s_address/2;
handler([_, _, <<"address">>, <<"s2s">>]) -> fun s2s_addr_opt/2;
handler([_, <<"domain_certfile">>, <<"s2s">>]) -> fun s2s_domain_cert/2;

%% host_config
handler([_, <<"host_config">>]) -> fun process_host_item/2;
handler([<<"auth">>, _, <<"host_config">>] = P) -> handler_for_host(P);
handler([<<"modules">>, _, <<"host_config">>] = P) -> handler_for_host(P);
handler([_, _, <<"host_config">>]) -> fun process_section/2;
handler([_, <<"general">>, _, <<"host_config">>] = P) -> handler_for_host(P);
handler([_, <<"s2s">>, _, <<"host_config">>] = P) -> handler_for_host(P);
handler(Path) ->
    [<<"host_config">>, {host, _} | Rest] = lists:reverse(Path),
    handler(lists:reverse(Rest)).

%% 1. Strip host_config, choose the handler for the remaining path
%% 2. Wrap the handler in a fun that calls the resulting function F for the current host
-spec handler_for_host(path()) -> fun((path(), toml_value()) -> option()).
handler_for_host(Path) ->
    [<<"host_config">>, {host, Host} | Rest] = lists:reverse(Path),
    Handler = handler(lists:reverse(Rest)),
    fun(PathArg, ValueArg) ->
            ConfigFunctions = Handler(PathArg, ValueArg),
            lists:flatmap(fun(F) -> F(Host) end, ConfigFunctions)
    end.

-spec key(toml_key(), path(), toml_value()) -> tuple() | toml_key().
key(<<"tls">>, [item, <<"c2s">>, <<"listen">>], M) ->
    %% store the tls module in path as both of them need different options
    case maps:get(<<"module">>, M, <<"fast_tls">>) of
        <<"just_tls">> -> {tls, just_tls};
        <<"fast_tls">> -> {tls, fast_tls}
    end;
key(<<"connection">>, [_, <<"rdbms">>, <<"outgoing_pools">>], M) ->
    %% store the db driver in path as 'odbc' and 'mysql'/'pgsql' need different options
    Driver = maps:get(<<"driver">>, M),
    {connection, b2a(Driver)};
key(Key, _Path, _) -> Key.

-spec item_key(path(), toml_value()) -> tuple() | item.
item_key([<<"host_config">>], #{<<"host">> := Host}) -> {host, Host};
item_key(_, _) -> item.

defined_or_false(Key, Opts) ->
    case proplists:is_defined(Key, Opts) of
        true ->
            [];
        false ->
            [{Key, false}]
    end ++ Opts.

%% Processing of the parsed options

-spec get_hosts(config_list()) -> [ejabberd:server()].
get_hosts(Config) ->
    case lists:filter(fun(#config{key = hosts}) -> true;
                         (_) -> false
                      end, Config) of
        [] -> [];
        [#config{value = Hosts}] -> Hosts
    end.

-spec build_state([ejabberd:server()], [top_level_option()], [override()]) ->
          mongoose_config_parser:state().
build_state(Hosts, Opts, Overrides) ->
    lists:foldl(fun(F, StateIn) -> F(StateIn) end,
                mongoose_config_parser:new_state(),
                [fun(S) -> mongoose_config_parser:set_hosts(Hosts, S) end,
                 fun(S) -> mongoose_config_parser:set_opts(Opts, S) end,
                 fun mongoose_config_parser:dedup_state_opts/1,
                 fun mongoose_config_parser:add_dep_modules/1,
                 fun(S) -> set_overrides(Overrides, S) end]).

%% Any nested option() may be a config_error() - this function extracts them all recursively
-spec extract_errors([config()]) -> [config_error()].
extract_errors(Config) ->
    extract(fun(#{what := _, class := error}) -> true;
               (_) -> false
            end, Config).

-spec extract(fun((option()) -> boolean()), option()) -> [option()].
extract(Pred, Data) ->
    case Pred(Data) of
        true -> [Data];
        false -> extract_items(Pred, Data)
    end.

-spec extract_items(fun((option()) -> boolean()), option()) -> [option()].
extract_items(Pred, L) when is_list(L) -> lists:flatmap(fun(El) -> extract(Pred, El) end, L);
extract_items(Pred, T) when is_tuple(T) -> extract_items(Pred, tuple_to_list(T));
extract_items(Pred, M) when is_map(M) -> extract_items(Pred, maps:to_list(M));
extract_items(_, _) -> [].
