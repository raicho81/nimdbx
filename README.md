# nimdbx

An extremely fast persistent key-value store for the [Nim](https://nim-lang.org) language, based on the amazing [MDBX](https://github.com/erthink/libmdbx) library.

NimDBX just maps arbitrary keys to values, in multiple namespaces, storing them in a local file. The file is memory-mapped, which makes reads _ridiculously_ fast, with zero copying and zero system calls: the library literally just locates the data in the mapped address space and hands you a pointer to it.

Even though it's low-level, it provides full ACID semantics: Atomic commits, Consistent views of data, Isolation from other commits, and Durable changes. Multiple threads and processes can open the same database file without trouble. The database is not corrupted by program crashes, kernel panics, nor power failures.

For more details I highly recommend reading the libmdbx [README](https://github.com/erthink/libmdbx/blob/master/README.md) and at least skimming the [API documentation](https://erthink.github.io/libmdbx/).

## Credits and Origins

NimDBX is by Jens Alfke. libmdbx is by Леонид Юрьев (Leonid Yuriev) and is a heavily modified extension of Howard Chu's [LMDB](http://lmdb.tech). Many of the concepts and even C APIs date back through [Berkeley DB](https://en.wikipedia.org/wiki/Berkeley_DB) to the original [1979 dbm library](https://en.wikipedia.org/wiki/DBM_%28computing%29).

I don't call NimDBX a libmdbx "wrapper" because it doesn't present exactly the same API. For instance, I've renamed some entities, like "database" instead of "environment", "collection" instead of "DBI", "snapshot" instead of "read-only transaction". NimDBX also tries to be safer, as befits a Nim API, preventing most dangling pointers and NULL-derefs.

But yes, this is really just a thin Nim shell around the libmdbx C library.

### License

NimDBX is released under the Apache 2 license.

However, libmdbx itself is under the OpenLDAP Public License -- see `vendor/libmdbx/LICENSE`.

## The Data Model

- A **database** is contained in a regular file (normally wrapped in a directory.)
- Each database can contain multiple named **collections**.
- Each collection can contain any number of **keys** and their associated **values**.
  A collection may optionally support multiple values per key (or duplicate keys; same thing.)
- A **cursor** lets you iterate a collection's keys and values in order.
- A **snapshot** is a self-consistent read-only view of the database.
  It stays the same even if some other thread or process makes changes.
  _The only way to access keys and values is within a snapshot._
- A **transaction** is like a snapshot but writeable.
  Changes you make in a transaction are private until you commit it.
  _The only way to modify the database is within a transaction._

That's it. No columns, no indexes, no query language. Those kinds of things can be built on top of this foundation.

### Keys and Values

Values are just arbitrary blobs, up to 4GB long.

Keys are arbitrary blobs, up to about 1KB long. The NimDBX API lets you treat a key as Nim `string`, `seq[byte]`, `int32`, or `int64`.

A collection may support **duplicate keys**: multiple records with the same key and distinct values. The values are kept in sorted order too. This is useful when using collections to implement indexes.

When you read data, the API calls return pointers to keys and values. These point directly into the mapped address space of the database file. That's super fast! But it's important to keep in mind that _the data only remains valid for the duration of the snapshot or transaction that you used to read it._ Afterwards, that part of the database might get reused for something else.

That means that, if you plan on keeping keys or values around, you need to copy them. Fortunately NimDBX includes converters to transparently convert keys/values to strings or `seq`s or integers.

### "Snapshots"?

A snapshot is a read-only transaction. (In fact, in the libmdbx API it _is_ a transaction, just with the `MDBX_TXN_RDONLY` flag.) Like a regular transaction, it gives you a Consistent, Isolated view of the data.

One thing that may seem weird if you're used to other databases is that you can't directly read values from a `Collection` object. There's no API for that. Instead you have to create a `CollectionSnapshot`, which is basically a tuple of the `Collection` and a database-wide `Snapshot` -- that's where the accessors are.

This is for two important reasons: first, the snapshot ensures that all the data you read comes from the same moment in time and isn't affected by some other thread or process making changes. Second, the snapshot marks the database pages you read as being in use, so that the keys and values in mapped memory don't get overwritten by other transactions.

Because of this, it's important not to leave snapshots around too long. As long as a snapshot exists, it's preventing many pages of the file from being reused, even if the data in those pages becomes obsolete. That means transactions have to grow the file instead of overwriting pages.

## Building

Building should be automatic, thanks to Nimble and [Nimterop](https://github.com/nimterop/nimterop).

`nimble test` will compile and run the unit tests.

## Status

This is pretty new code (as of November 2020). It has tests, but hasn't been exercised much yet.
And libMDBX is still under development, though I've found it quite solid.

I plan to expose some more libmdbx features, and add some more idiomatic Nim APIs.
