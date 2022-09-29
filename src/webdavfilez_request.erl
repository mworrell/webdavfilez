%% @doc WebDAV http request handler and streamer using httpc.
%% @author Marc Worrell
%% @copyright 2022 Marc Worrell
%% @end

%% Copyright 2022 Marc Worrell
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%

-module(webdavfilez_request).

-export([
    request/5,
    request_with_body/5,
    stream_to_fun/3,

    stream_loop/4,
    http_status/1,
    ct/1,

    basic_auth/1
]).

-define(CONNECT_TIMEOUT, 60000).    % 60s
-define(TIMEOUT, 1800000).          % 30m

-include_lib("kernel/include/logger.hrl").

request(Config, Method, Url, Headers, Options) ->
    Host = hostname(Url),
    Date = httpd_util:rfc1123_date(),
    AllHeaders = [
        {"Authorization", basic_auth(Config)},
        {"Date", Date}
        | Headers
    ],
    httpc:request(Method, {to_list(Url), AllHeaders},
                  opts(Host), [{body_format, binary}|Options],
                  httpc_webdavfilez_profile).

request_with_body(Config, Method, Url, Headers, Body) ->
    Host = hostname(Url),
    {"Content-Type", ContentType} = proplists:lookup("Content-Type", Headers),
    Date = httpd_util:rfc1123_date(),
    Hs1 = [
        {"Authorization", basic_auth(Config)},
        {"Date", Date}
        | Headers
    ],
    jobs:run(webdavfilez_jobs,
             fun() ->
                httpc:request(Method, {to_list(Url), Hs1, ContentType, Body},
                              opts(Host), [],
                              httpc_webdavfilez_profile)
            end).

stream_to_fun(Config, Url, Fun) ->
    {ok, RequestId} = webdavfilez_request:request(Config, get, Url, [], [{stream,{self,once}}, {sync,false}]),
    receive
        {http, {RequestId, stream_start, Headers, Pid}} ->
            start_fun(Fun),
            call_fun(Fun, {content_type, ct(Headers)}),
            httpc:stream_next(Pid),
            ?MODULE:stream_loop(RequestId, Pid, Url, Fun);
        {http, {RequestId, {_,_,_} = HttpRet}}->
            case http_status(HttpRet) of
                ok ->
                    eof_fun(Fun),
                    ok;
                {error, Reason} = Error ->
                    error_fun(Fun, Reason),
                    Error
            end;
        {http, {RequestId, Other}} ->
            ?LOG_ERROR(#{
                text => <<"Unexpected HTTP message">>,
                in => webdavfilez,
                result => error,
                reason => Other,
                url => Url
            }),
            error_fun(Fun, Other),
            {error, Other}
    after ?CONNECT_TIMEOUT ->
        error_fun(Fun, timeout),
        {error, timeout}
    end.

%% @private
stream_loop(RequestId, Pid, Url, Fun) ->
    receive
        {http, {RequestId, stream_end, Headers}} ->
            call_fun(Fun, {headers, Headers}),
            eof_fun(Fun),
            ok;
        {http, {RequestId, stream, Data}} ->
            call_fun(Fun, Data),
            httpc:stream_next(Pid),
            ?MODULE:stream_loop(RequestId, Pid, Url, Fun);
        {http, {RequestId, Other}} ->
            ?LOG_ERROR(#{
                text => <<"Unexpected HTTP message">>,
                in => webdavfilez,
                result => error,
                reason => Other,
                url => Url
            }),
            error_fun(Fun, Other),
            {error, Other}
    after ?TIMEOUT ->
        error_fun(Fun, timeout),
        {error, timeout}
    end.


start_fun({Ref, Pid}) when is_pid(Pid) ->
    Pid ! {webdav, {Ref, stream_start, []}};
start_fun(Fun) ->
    call_fun(Fun, stream_start).

call_fun({M,F,A}, Arg) ->
    erlang:apply(M,F,A++[Arg]);
call_fun(Fun, Arg) when is_function(Fun) ->
    Fun(Arg);
call_fun(Pid, Arg) when is_pid(Pid) ->
    Pid ! {webdav, Arg};
call_fun({Ref, Pid}, Arg) when is_pid(Pid) ->
    Pid ! {webdav, {Ref, stream, Arg}}.

eof_fun({M,F,A}) ->
    erlang:apply(M,F,A++[eof]);
eof_fun(Fun) when is_function(Fun) ->
    Fun(eof);
eof_fun(Pid) when is_pid(Pid) ->
    Pid ! {webdav, eof};
eof_fun({Ref, Pid}) when is_pid(Pid) ->
    Pid ! {webdav, {Ref, stream_end, []}}.

error_fun({M,F,A}, Error) ->
    erlang:apply(M,F,A++[Error]);
error_fun(Fun, Error) when is_function(Fun) ->
    Fun(Error);
error_fun(Pid, Error) when is_pid(Pid) ->
    Pid ! {webdav, Error};
error_fun({Ref, Pid}, Error) when is_pid(Pid) ->
    Pid ! {webdav, {Ref, Error}}.

http_status({{_,Code,_}, _Headers, _Body})
    when Code =:= 200;
         Code =:= 201;
         Code =:= 204;
         Code =:= 206 ->
    ok;
http_status({{_,404,_}, _Headers, _Body}) ->
    {error, enoent};
http_status({{_,403,_}, _Headers, _Body}) ->
    {error, forbidden};
http_status({{_,Code,_}, _Headers, _Body}) ->
    {error, Code}.


opts(Host) ->
    [
        {connect_timeout, ?CONNECT_TIMEOUT},
        {ssl, ssl_options(Host)},
        {timeout, ?TIMEOUT}
    ].

ssl_options(Host) ->
    case z_ip_address:is_local_name(Host) of
        true ->
            [ {verify, verify_none} ];
        false ->
            tls_certificate_check:options(Host)
    end.

basic_auth({Username, Password}) ->
    Username1 = unicode:characters_to_binary(Username),
    Password1 = unicode:characters_to_binary(Password),
    "Basic " ++ base64:encode_to_string(<<Username1/binary, $:, Password1/binary>>).

hostname(Url) ->
    #{ host := Host } = uri_string:parse(Url),
    to_list(Host).

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L.

ct(Headers) ->
    Mime = list_to_binary(proplists:get_value("content-type", Headers, "binary/octet-stream")),
    [ Mime1 | _ ] = binary:split(Mime, <<";">>),
    z_string:trim(Mime1).

