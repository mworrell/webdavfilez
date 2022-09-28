%% @doc Make directories on a WebDAV server.
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
-module(webdavfilez_mkdir).

-export([
    mkdir/2,
    parent_dir/1
    ]).

% Dir not there: 409
% Make dir that exists: 405

-spec mkdir(Config, Url) -> Result when
    Config :: webdavfilez:config(),
    Url :: binary() | string(),
    Result :: ok | {error, term()}.
mkdir(Cfg, Url) ->
    case mkcol(Cfg, Url) of
        ok ->
            ok;
        {error, enoent} ->
            % Nothing there, try finding most top level dir
            % that exists, and then descend adding directories.
            recursive_mkdir(Cfg, Url);
        {error, _} = Error ->
            Error
    end.

mkcol(Cfg, Url) ->
    Hs = [
        {<<"Authorization">>, to_bin(webdavfilez_request:basic_auth(Cfg))}
    ],
    case hackney:request(mkcol, Url, Hs, <<>>, [ with_body ]) of
        {ok, Status, _RespHs, _RespBody} when Status >= 200, Status =< 299 ->
            ok;
        {ok, 401, _RespHs, _RespBody} ->
            {error, forbidden};
        {ok, 403, _RespHs, _RespBody} ->
            {error, forbidden};
        {ok, 409, _RespHs, _RespBody} ->
            case check_if_exists(Cfg, Url) of
                ok ->
                    {error, eexist};
                {error, _} = Error ->
                    Error
            end;
        {ok, Status, _RespHs, _RespBody} ->
            {error, Status};
        {error, _} = Error ->
            Error
    end.

check_if_exists(Cfg, Url) ->
    Hs = [
        {<<"Authorization">>, to_bin(webdavfilez_request:basic_auth(Cfg))},
        {<<"Depth">>, <<"1">>}
    ],
    ReqBody = <<"<?xml version=\"1.0\"?>
<a:propfind xmlns:a=\"DAV:\">
<a:prop><a:resourcetype/></a:prop>
</a:propfind>">>,
    case hackney:request(propfind, Url, Hs, ReqBody, [ with_body ]) of
        {ok, 207, _, _} ->
            ok;
        {ok, 404, _, _} ->
            {error, enoent};
        {ok, 401, _, _} ->
            {error, eacces};
        {ok, 403, _, _} ->
            {error, eaccess};
        {ok, Status, _, _} ->
            {error, Status}
    end.

recursive_mkdir(Cfg, Url) ->
    case parent_dir(Url) of
        {ok, ParentUrl} ->
            case check_if_exists(Cfg, ParentUrl) of
                ok ->
                    % Try make dir of Url
                    mkcol(Cfg, Url);
                {error, enoent} ->
                    case recursive_mkdir(Cfg, ParentUrl) of
                        ok ->
                            mkcol(Cfg, Url);
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

parent_dir(Url) when is_binary(Url); is_list(Url) ->
    Parsed = #{ path := Path } = uri_string:parse(Url),
    case binary:split(to_bin(Path), <<"/">>, [ global, trim_all ]) of
        [] ->
            {error, enoent};
        Ps ->
            Parts1 = lists:reverse(tl(lists:reverse(Ps))),
            Parsed1 = Parsed#{
                path => iolist_to_binary("/" ++ lists:join($/, Parts1))
            },
            {ok, uri_string:recompose(Parsed1)}
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L).
