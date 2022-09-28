[![Test](https://github.com/mworrell/webdavfilez/workflows/Test/badge.svg)](https://github.com/mworrell/webdavfilez/actions)
[![Hex.pm Version](https://img.shields.io/hexpm/v/webdavfilez.svg)](https://hex.pm/packages/webdavfilez)
[![Hex.pm Downloads](https://img.shields.io/hexpm/dt/webdavfilez.svg)](https://hex.pm/packages/webdavfilez)

webdavfilez
===========

Really tiny WebDAV client - only put, get and delete.

This client is used in combination with filezcache and zotonic.

Distinction with other WebDAV clients is:

 * Only get, put and delete are supported
 * put of files and/or binaries
 * get with optional streaming function, to be able to stream to the filezcache
 * simple jobs queue, using the 'jobs' scheduler

Example
-------

```erlang
rebar3 shell
===> Verifying dependencies...
===> Analyzing applications...
===> Compiling webdavfilez
Erlang/OTP 23 [erts-11.1] [source] [64-bit] [smp:12:12] [ds:12:12:10] [async-threads:1] [hipe]

Eshell V11.1  (abort with ^G)
1> application:ensure_all_started(webdavfilez).
{ok,[jobs,webdavfilez]}
2> Cfg = {<<"username">>, <<"password">>}.
{<<"username">>, <<"password">>}
3> webdavfilez:put(Cfg, <<"https://my.storage-server.com/foo/LICENSE">>, {filename, "LICENSE"}).
ok
4> webdavfilez:stream(Cfg, <<"https://my.storage-server.com/foo/LICENSE">>, fun(X) -> io:format("!! ~p~n", [X]) end).
!! stream_start
!! {content_type,<<"binary/octet-stream">>}
!! <<"\n    Apache License\n", ...>>
!! eof
5> webdavfilez:delete(Cfg, <<"https://my.storage-server.com/foo/LICENSE">>).
ok
```

Request Queue
-------------

Requests can be queued. They will be placed in a supervisor and scheduled using https://github.com/uwiger/jobs
The current scheduler restricts the number of parallel WebDAV requests. The default maximum is 10.

The `get`, `put` and `delete` requests can be queued. A function or pid can be given as a callback for the job result.
The `stream` command can’t be queued: it is already running asynchronously.

Example:

```erlang
6> {ok, ReqId, JobPid} = webdavfilez:queue_put(Cfg, <<"https://my.storage-server.com/foo/LICENSE">>, {filename, 10175, "LICENSE"}, fun(ReqId, Result) -> nop end).
{ok,#Ref<0.0.0.3684>,<0.854.0>}
```

The returned `JobPid` is the pid of the process in the s3filez queue supervisor.
The callback can be a function (arity 2), `{M,F,A}` or a pid.

If the callback is a pid then it will receive the message `{webdavfilez_done, ReqId, Result}`.

