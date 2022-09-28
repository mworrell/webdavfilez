%% @doc Main app code. Ensure the httpc profiles are present, start the
%% supervisor for the queued jobs.
%% @author Marc Worrell
%% @copyright 2022 Marc Worrell
%% @end

%% Copyright 2022 Marc Worrell
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

-module(webdavfilez_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    ensure_httpc_profile(),
    case webdavfilez_sup:start_link() of
        {ok, Pid} ->
            ensure_queue(),
            {ok, Pid};
        Other ->
            {error, Other}
    end.

stop(_State) ->
    ok.

ensure_httpc_profile() ->
    case inets:start(httpc, [{profile, httpc_webdavfilez_profile}]) of
        {ok, _} ->
            ok = httpc:set_options([
                {max_sessions, max_connections()}
            ], httpc_webdavfilez_profile),
            ok;
        {error, {already_started, _}} -> ok
    end.

ensure_queue() ->
    jobs:add_queue(webdavfilez_jobs, [
            {regulators, [{counter, [
                                {limit, max_connections()}
                             ]}]}
        ]).

max_connections() ->
    case application:get_env(webdavfilez, max_connections) of
        {ok, N} when is_integer(N) -> N;
        undefined -> 10
    end.
