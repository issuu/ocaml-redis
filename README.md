Redis client library for Ocaml
==============================

ocaml-redis implements the client spec of the [Redis key-value store](http://redis.io/). This version is aimed to be compatible with Redis 2.2, and is not compatible with earlier versions.

Example Usage
-------------

    >> let conn = Redis.create_connection ()
    in
    begin
        Redis.lpush "redis" "works" conn;
        Redis.lpush "redis" "fast" conn;
        Redis.lpush "redis" "simple" conn;
        List.map Redis.string_of_bulk_data
            (Redis.lrange "redis" 0 2 conn);
    end;;
    ["simple"; "fast"; "works"]

Building
--------

To build the library,

    make

should do the trick. From there, you will have to statically link _build/src/redis.cmx, _build/src/redis.cmo and _build/src/redis.cmi with your code.

Testing
-------

To run a simple smoke test on a redis server *you do not mind completely wiping* running on your localhost, execute:

    make test

To run the Redis instance use `redis-server redis.conf` from the root of the project.

Todo
----

See the [issue tracker](http://github.com/rgeoghegan/ocaml-redis/issues)
