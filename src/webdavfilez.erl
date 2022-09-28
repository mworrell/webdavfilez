%% @doc WebDAV file storage. Can put, get and stream files.
%% Uses a job queue which is regulated by "jobs".
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

-module(webdavfilez).

-export([
    queue_get/3,
    queue_get_id/4,
    queue_put/3,
    queue_put/4,
    queue_put/5,
    queue_put_id/5,
    queue_delete/2,
    queue_delete/3,
    queue_delete_id/4,

    queue_stream/3,
    queue_stream_id/4,

    get/2,
    delete/2,
    put/3,
    put/4,
    stream/3,

    create_bucket/2,
    create_bucket/3
    ]).

-export([
    put_body_file/1
    ]).

-define(BLOCK_SIZE, 65536).

-type config() :: {Username::binary() | string(), Password::binary() | string()}.
-type url() :: binary() | string().
-type ready_fun() :: undefined | {atom(),atom(),list()} | fun() | pid().
-type stream_fun() :: {atom(),atom(),list()} | fun() | pid().
-type put_data() :: {data, binary()}
                  | {filename, non_neg_integer(), file:filename_all()}
                  | {filename, file:filename_all()}.

-type queue_reply() :: {ok, any(), pid()} | {error, {already_started, pid()}}.

-type sync_reply() :: ok | {error, enoent | forbidden | http_code()}.
-type http_code() :: 100..600.

-type put_opts() :: [ put_opt() ].
-type put_opt() :: {acl, acl_type()} | {content_type, string()}.
-type acl_type() :: private | public_read | public_read_write | authenticated_read
                  | bucket_owner_read | bucket_owner_full_control.

-export_type([
    config/0,
    url/0,
    ready_fun/0,
    stream_fun/0,
    put_data/0,
    queue_reply/0,
    sync_reply/0,
    http_code/0,
    put_opts/0,
    put_opt/0,
    acl_type/0
]).

%% @doc Queue a file dowloader and call ready_fun when finished.
-spec queue_get(config(), url(), ready_fun()) -> queue_reply().
queue_get(Config, Url, ReadyFun) ->
    webdavfilez_jobs_sup:queue({get, Config, Url, ReadyFun}).


%% @doc Queue a named file dowloader and call ready_fun when finished.
%%      Names must be unique, duplicates are refused with <tt>{error, {already_started, _}}</tt>.
-spec queue_get_id(any(), config(), url(), ready_fun()) -> queue_reply().
queue_get_id(JobId, Config, Url, ReadyFun) ->
    webdavfilez_jobs_sup:queue(JobId, {get, Config, Url, ReadyFun}).


%% @doc Queue a file uploader. The data can be a binary or a filename.
-spec queue_put(config(), url(), put_data()) -> queue_reply().
queue_put(Config, Url, What) ->
    queue_put(Config, Url, What, undefined).


%% @doc Queue a file uploader and call ready_fun when finished.
-spec queue_put(config(), url(), put_data(), ready_fun()) -> queue_reply().
queue_put(Config, Url, What, ReadyFun) ->
    queue_put(Config, Url, What, ReadyFun, []).


%% @doc Queue a file uploader and call ready_fun when finished. Options include
%% the <tt>acl</tt> setting and <tt>content_type</tt> for the file.
-spec queue_put(config(), url(), put_data(), ready_fun(), put_opts()) -> queue_reply().
queue_put(Config, Url, What, ReadyFun, Opts) ->
    webdavfilez_jobs_sup:queue({put, Config, Url, What, ReadyFun, Opts}).

%% @doc Start a named file uploader. Names must be unique, duplicates are refused with
%% <tt>{error, {already_started, _}}</tt>.
-spec queue_put_id(any(), config(), url(), put_data(), ready_fun()) -> queue_reply().
queue_put_id(JobId, Config, Url, What, ReadyFun) ->
    webdavfilez_jobs_sup:queue(JobId, {put, Config, Url, What, ReadyFun}).


%% @doc Async delete a file on WebDAV
-spec queue_delete(config(), url()) -> queue_reply().
queue_delete(Config, Url) ->
    queue_delete(Config, Url, undefined).

%% @doc Async delete a file on WebDAV, call ready_fun when ready.
-spec queue_delete(config(), url(), ready_fun()) -> queue_reply().
queue_delete(Config, Url, ReadyFun) ->
    webdavfilez_jobs_sup:queue({delete, Config, Url, ReadyFun}).


%% @doc Queue a named file deletion process, call ready_fun when ready.
-spec queue_delete_id(any(), config(), url(), ready_fun()) -> queue_reply().
queue_delete_id(JobId, Config, Url, ReadyFun) ->
    webdavfilez_jobs_sup:queue(JobId, {delete, Config, Url, ReadyFun}).


%% @doc Queue a file downloader that will stream chunks to the given stream_fun. The
%% default block size for the chunks is 64KB.
-spec queue_stream(config(), url(), stream_fun()) -> queue_reply().
queue_stream(Config, Url, StreamFun) ->
    webdavfilez_jobs_sup:queue({stream, Config, Url, StreamFun}).


%% @doc Queue a named file downloader that will stream chunks to the given stream_fun. The
%% default block size for the chunks is 64KB.
-spec queue_stream_id(any(), config(), url(), stream_fun()) -> queue_reply().
queue_stream_id(JobId, Config, Url, StreamFun) ->
    webdavfilez_jobs_sup:queue(JobId, {stream, Config, Url, StreamFun}).


%%% Normal API - blocking on the process

%% @doc Fetch the data at the url.
-spec get( config(), url() ) ->
      {ok, ContentType::binary(), Data::binary()}
    | {error, enoent | forbidden | http_code()}.
get(Config, Url) ->
    Result = jobs:run(
        webdavfilez_jobs,
        fun() ->
            webdavfilez_request:request(Config, get, Url, [], [])
        end),
    case Result of
        {ok, {{_Http, 200, _Ok}, Headers, Body}} ->
            {ok, webdavfilez_request:ct(Headers), Body};
        Other ->
            ret_status(Other)
    end.

%% @doc Delete the file at the url.
-spec delete( config(), url() ) -> sync_reply().
delete(Config, Url) ->
    ret_status(jobs:run(
        webdavfilez_jobs,
        fun() ->
            webdavfilez_request:request(Config, delete, Url, [], [])
        end)).


%% @doc Put a binary or file to the given url.
-spec put( config(), url(), put_data() ) -> sync_reply().
put(Config, Url, Payload) ->
    put(Config, Url, Payload, []).


%% @doc Put a binary or file to the given url. Set options for acl and/or content_type.
-spec put( config(), url(), put_data(), put_opts() ) -> sync_reply().
put(Config, Url, {data, Data}, Opts) ->
    Hs = opts_to_headers(Opts),
    ret_status(webdavfilez_request:request_with_body(Config, put, Url, Hs, Data));
put(Config, Url, {filename, Filename}, Opts) ->
    Size = filelib:file_size(Filename),
    put(Config, Url, {filename, Size, Filename}, Opts);
put(Config, Url, {filename, Size, Filename}, Opts) ->
    Hs = [
          {"Content-Length", integer_to_list(Size)}
          | opts_to_headers(Opts)
    ],
    Ret = ret_status(webdavfilez_request:request_with_body(Config, put, Url, Hs, {fun ?MODULE:put_body_file/1, {file, Filename}})),
    case Ret of
        ok ->
            ok;
        {error, 409} ->
            % Directory might not exist
            case webdavfilez_mkdir:parent_dir(Url) of
                {ok, UrlParent} ->
                    case webdavfilez_mkdir:mkdir(Config, UrlParent) of
                        ok ->
                            % Retry
                            ret_status(webdavfilez_request:request_with_body(Config, put, Url, Hs, {fun ?MODULE:put_body_file/1, {file, Filename}}));
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} ->
                    {error, 409}
            end;
        {error, 405} ->
            {error, epath};
        {error, _} = Error ->
            Error
    end.

put_body_file({file, Filename}) ->
    {ok, FD} = file:open(Filename, [read,binary]),
    put_body_file({fd, FD});
put_body_file({fd, FD}) ->
    case file:read(FD, ?BLOCK_SIZE) of
        eof ->
            file:close(FD),
            eof;
        {ok, Data} ->
            {ok, Data, {fd, FD}}
    end.

%% @doc Create a directory (bucket) at the URL.
-spec create_bucket( config(), url() ) -> sync_reply().
create_bucket(Config, Url) ->
    create_bucket(Config, Url, []).

%% @doc Create a directory (bucket) at the URL, ignore acl options.
-spec create_bucket( config(), url(), put_opts() ) -> sync_reply().
create_bucket(Config, Url, _Opts) ->
    webdavfilez_mkdir:mkdir(Config, Url).

opts_to_headers(Opts) ->
    Hs = lists:foldl(
           fun({acl, _AclOption}, Hs) ->
                    % Ignore S3 ACL options
                    Hs;
              ({content_type, CT}, Hs) ->
                    [{"Content-Type", CT} | Hs];
              (Unknown, _) ->
                    throw({error, {unknown_option, Unknown}})
           end,
           [],
           Opts),
    case proplists:get_value("Content-Type", Hs) of
        undefined ->
            [{"Content-Type", "binary/octet-stream"} | Hs];
        _ ->
            Hs
    end.

%%% Stream the contents of the url to the function, callback or to the httpc-streaming option.

-spec stream( config(), url(), stream_fun() ) -> sync_reply().
stream(Config, Url, Fun) when is_function(Fun,1) ->
    webdavfilez_request:stream_to_fun(Config, Url, Fun);
stream(Config, Url, {_M,_F,_A} = MFA) ->
    webdavfilez_request:stream_to_fun(Config, Url, MFA);
stream(Config, Url, Pid) when is_pid(Pid) ->
    webdavfilez_request:stream_to_fun(Config, Url, Pid).

ret_status({ok, Rest}) ->
    webdavfilez_request:http_status(Rest);
ret_status({error, _} = Error) ->
    Error.
