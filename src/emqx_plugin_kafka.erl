%%--------------------------------------------------------------------
%% Copyright (c) 2015-2017 Feng Lee <feng@emqtt.io>.
%%
%% Modified by Ramez Hanna <rhanna@iotblue.net>
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_plugin_kafka).

-include("emqx_plugin_kafka.hrl").

-include_lib("brod/include/brod_int.hrl").

-include_lib("emqx/include/emqx.hrl").

-export([load/1, unload/0]).

% Hooks functions
-export([on_client_connected/4, on_client_disconnected/3]).
-export([on_message_publish/2, on_message_delivered/3, on_message_acked/3]).
% -export([on_client_subscribe/3, on_client_unsubscribe/3]).
% -export([on_session_created/3, on_session_resumed/3, on_session_terminated/3]).
% -export([on_session_subscribed/4, on_session_unsubscribed/4]).
% -export([on_message_publish/2, on_message_delivered/3, on_message_acked/3, on_message_dropped/3]).


-define(LOG(Level, Format, Args), emqx_logger:Level("KafkaBridge: " ++ Format, Args)).



%% Called when the plugin application start
load(Env) ->
  brod_init([Env]),
  emqx:hook('client.connected', fun ?MODULE:on_client_connected/4, [Env]),
  emqx:hook('client.disconnected', fun ?MODULE:on_client_disconnected/3, [Env]),
  emqx:hook('message.publish', fun ?MODULE:on_message_publish/2, [Env]),
  emqx:hook('message.delivered', fun ?MODULE:on_message_delivered/3, [Env]),
  emqx:hook('message.acked', fun ?MODULE:on_message_acked/3, [Env]).
% emqx:hook('message.dropped', fun ?MODULE:on_message_dropped/3, [Env]).
% emqx:hook('client.subscribe', fun ?MODULE:on_client_subscribe/3, [Env]),
% emqx:hook('client.unsubscribe', fun ?MODULE:on_client_unsubscribe/3, [Env]),
% emqx:hook('session.created', fun ?MODULE:on_session_created/3, [Env]),
% emqx:hook('session.resumed', fun ?MODULE:on_session_resumed/3, [Env]),
% emqx:hook('session.subscribed', fun ?MODULE:on_session_subscribed/4, [Env]),
% emqx:hook('session.unsubscribed', fun ?MODULE:on_session_unsubscribed/4, [Env]),
% emqx:hook('session.terminated', fun ?MODULE:on_session_terminated/3, [Env]),

brod_init(_Env) ->
  {ok, _} = application:ensure_all_started(gproc),
  {ok, _} = application:ensure_all_started(brod),
  {ok, Kafka} = application:get_env(?MODULE, broker),
  KafkaBootstrapHost = proplists:get_value(bootstrap_broker_host, Kafka),
  KafkaBootstrapPort = proplists:get_value(bootstrap_broker_port, Kafka),
  KafkaBootstrapEndpoints = [{KafkaBootstrapHost, KafkaBootstrapPort}],
  ClientConfig = [{auto_start_producers, true}, {default_producer_config, []}, {reconnect_cool_down_seconds, 10}, {reconnect_cool_down_seconds, 10}],
  ok = brod:start_client(KafkaBootstrapEndpoints, brod_client_1, ClientConfig),
  ok = brod:start_producer(brod_client_1, <<"message_publish">>, _ProducerConfig = []),
  io:format("Init brod with ~p~n", [KafkaBootstrapEndpoints]).

% on_client_subscribe(#{client_id := ClientId}, RawTopicFilters, _Env) ->
%     io:format("Client(~s) will subscribe: ~p~n", [ClientId, RawTopicFilters]),
%     {ok, RawTopicFilters}.

% on_client_unsubscribe(#{client_id := ClientId}, RawTopicFilters, _Env) ->
%     io:format("Client(~s) unsubscribe ~p~n", [ClientId, RawTopicFilters]),
%     {ok, RawTopicFilters}.

% on_session_created(#{client_id := ClientId}, SessAttrs, _Env) ->
%     io:format("Session(~s) created: ~p~n", [ClientId, SessAttrs]).

% on_session_resumed(#{client_id := ClientId}, SessAttrs, _Env) ->
%     io:format("Session(~s) resumed: ~p~n", [ClientId, SessAttrs]).

% on_session_subscribed(#{client_id := ClientId}, Topic, SubOpts, _Env) ->
%     io:format("Session(~s) subscribe ~s with subopts: ~p~n", [ClientId, Topic, SubOpts]).

% on_session_unsubscribed(#{client_id := ClientId}, Topic, Opts, _Env) ->
%     io:format("Session(~s) unsubscribe ~s with opts: ~p~n", [ClientId, Topic, Opts]).

% on_session_terminated(#{client_id := ClientId}, ReasonCode, _Env) ->
%     io:format("Session(~s) terminated: ~p.", [ClientId, ReasonCode]).

on_client_connected(#{client_id := ClientId, username := Username}, 0, _ConnInfo, _Env) ->
  Params = [{action, client_connected},
    {clientid, ClientId},
    {username, Username},
    {result, 0}],
  produce_kafka_message(<<"client_connected">>, Params, ClientId, _Env),
  ok;
on_client_connected(#{}, _ConnAck, _ConnInfo, _Env) ->
  ok.

on_client_disconnected(#{}, auth_failure, _Env) ->
  ok;
on_client_disconnected(Client, {shutdown, Reason}, Env) when is_atom(Reason) ->
  on_client_disconnected(Reason, Client, Env);
on_client_disconnected(#{client_id := ClientId, username := Username}, Reason, _Env)
  when is_atom(Reason) ->
  Params = [{action, client_disconnected},
    {clientid, ClientId},
    {username, Username},
    {reason, Reason}],
  produce_kafka_message(<<"client_disconnected">>, Params, ClientId, _Env),
  ok;
on_client_disconnected(_, Reason, _Env) ->
  ?LOG(error, "Client disconnected, cannot encode reason: ~p", [Reason]),
  ok.

on_message_publish(Message = #message{topic = <<"$SYS/", _/binary>>}, _Env) ->
  {ok, Message};
on_message_publish(Message = #message{topic = Topic, from = From, headers = #{username := Username}}, _Env) ->
  ?LOG(debug, "Client message: ~s~n", [emqx_message:format(Message)]),
  Params = [{action, message_publish},
    {clientid, From},
    {username, Username},
    {topic, Topic},
    {payload, Message#message.payload}],
  produce_kafka_message_async(<<"message_publish">>, Params, From, _Env),
  {ok, Message}.

on_message_delivered(#{client_id := ClientId}, Message, _Env) ->
  ?LOG(debug, "Delivered message to client(~s): ~s~n", [ClientId, emqx_message:format(Message)]),
  Params = jsx:encode([
    {action, message_published},
    {clientid, ClientId},
    {message, emqx_message:format(Message)}
  ]),
  produce_kafka_message_async(<<"message_published">>, jsx:encode(Params), ClientId, _Env),
  {ok, Message}.

on_message_acked(#{client_id := ClientId}, Message, _Env) ->
  ?LOG(debug, "Session(~s) acked message: ~s~n", [ClientId, emqx_message:format(Message)]),
  Params = jsx:encode([
    {action, message_acked},
    {clientid, ClientId},
    {message, emqx_message:format(Message)}
  ]),
  produce_kafka_message_async(<<"message_acked">>, jsx:encode(Params), ClientId, _Env),
  {ok, Message}.

% on_message_dropped(_By, #message{topic = <<"$SYS/", _/binary>>}, _Env) ->
%     ok;
% on_message_dropped(#{node := Node}, Message, _Env) ->
%     io:format("Message dropped by node ~s: ~s~n", [Node, emqx_message:format(Message)]);
% on_message_dropped(#{client_id := ClientId}, Message, _Env) ->
%     io:format("Message dropped by client ~s: ~s~n", [ClientId, emqx_message:format(Message)]).

% produce_kafka_message_publish(Message, _Env) ->
%     {ok, Topic} = application:get_env(emqx_kafka_bridge, kafka_publish_topic),
%     Payload = jsx:encode(Message),
%     ok = ekaf:produce_async(list_to_binary(Topic), Payload),
%     ok.

% produce_kafka_message_delivered(Message, _Env) ->
%     {ok, Topic} = application:get_env(emqx_kafka_bridge, kafka_delivered_topic),
%     Payload = jsx:encode(Message),
%     ok = ekaf:produce_async(list_to_binary(Topic), Payload),
%     ok.

% produce_kafka_message_acked(Message, _Env) ->
%     {ok, Topic} = application:get_env(emqx_kafka_bridge, kafka_acked_topic),
%     Payload = jsx:encode(Message),
%     ok = ekaf:produce_async(list_to_binary(Topic), Payload),
%     ok.

% produce_kafka_client_connected(Message, _Env) ->
%     {ok, Topic} = application:get_env(emqx_kafka_bridge, kafka_client_connect_topic),
%     Payload = jsx:encode(Message),
%     ok = ekaf:produce_async(list_to_binary(Topic), Payload),
%     ok.

% produce_kafka_client_disconnected(Message, _Env) ->
%     {ok, Topic} = application:get_env(emqx_kafka_bridge, kafka_client_disconnect_topic),
%     Payload = jsx:encode(Message),
%     ok = ekaf:produce_async(list_to_binary(Topic), Payload),
%     ok.

produce_kafka_message(Topic, Message, ClientId, _Env) ->
  Key = iolist_to_binary(ClientId),
  Partition = getPartition(Key),
  Message1 = jsx:encode(Message),
  ?LOG(debug, "Topic:~p, params:~s", [Topic, Message1]),
  ok = brod:produce_sync(brod_client_1, Topic, Partition, ClientId, Message1),
  ok.

produce_kafka_message_async(Topic, Message, ClientId, _Env) ->
  Key = iolist_to_binary(ClientId),
  Partition = getPartition(Key),
  Message1 = jsx:encode(Message),
  ?LOG(debug, "Topic:~p, params:~s", [Topic, Message1]),
  {ok, CallRef} = brod:produce(brod_client_1, Topic, Partition, ClientId, Message1),
  receive
    #brod_produce_reply{ call_ref = CallRef, result   = brod_produce_req_acked} -> ok
  after 5000 ->
    ct:fail({?MODULE, ?LINE, timeout})
  end,
  {ok, Message}.

a2b(A) when is_atom(A) -> erlang:atom_to_binary(A, utf8);
a2b(A) -> A.

getPartition(Key) ->
  {ok, Kafka} = application:get_env(?MODULE, broker),
  PartitionNum = proplists:get_value(producer_partition, Kafka),
  <<Fix:120, Match:8>> = crypto:hash(md5, Key),
  abs(Match) rem PartitionNum.

%% Called when the plugin application stop
unload() ->
  emqx:unhook('client.connected', fun ?MODULE:on_client_connected/4),
  emqx:unhook('client.disconnected', fun ?MODULE:on_client_disconnected/3),
  emqx:unhook('message.publish', fun ?MODULE:on_message_publish/2),
  emqx:unhook('message.delivered', fun ?MODULE:on_message_delivered/3),
  emqx:unhook('message.acked', fun ?MODULE:on_message_acked/3).
% emqx:unhook('client.subscribe', fun ?MODULE:on_client_subscribe/3),
% emqx:unhook('client.unsubscribe', fun ?MODULE:on_client_unsubscribe/3),
% emqx:unhook('session.created', fun ?MODULE:on_session_created/3),
% emqx:unhook('session.resumed', fun ?MODULE:on_session_resumed/3),
% emqx:unhook('session.subscribed', fun ?MODULE:on_session_subscribed/4),
% emqx:unhook('session.unsubscribed', fun ?MODULE:on_session_unsubscribed/4),
% emqx:unhook('session.terminated', fun ?MODULE:on_session_terminated/3),
% emqx:unhook('message.dropped', fun ?MODULE:on_message_dropped/3).