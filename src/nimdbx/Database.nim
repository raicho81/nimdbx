import private/libmdbx, private/utils
from os import nil


type
    DatabaseObj* = object
        m_env {.requiresInit.}: MDBX_env
        #openDBIMutex: mutex    # TODO: Implement this

    Database* = ref DatabaseObj
        ## An open database file. Data is stored in Collections within it.

    DatabaseFlag* = enum
        ## Database-wide options. Some of these are dangerous!
        ## The comments below are extremely sketchy. Check libmdbx's docs for ``MDBX_env_flags_t``.
        NoSubdir,       # Don't put DB file in a directory
        ReadOnly,       # Open read-only
        Exclusive,      # Exclusive access to db; no other connections allowed.
        Accede,         # Adapt if DB already open by other process with different flags
        NoTLS,          # Allow multiple Snapshots/Transactions on a single OS thread.
        Coalesce,       # Coalesce freed items; may reduce fragmentation
        LIFOReclaim,    # Can improve performance if filesystem has a write-back cache
        PagePerturb,    # Fill released pages with garbage to help catch invalid access
        NoMetaSync,     # Faster writes, but system crash can corrupt database!
        SafeNoSync,     # Faster writes, but system crash may wipe out latest transaction!
        UtterlyNoSync   # Extremely fast writes, but system crash can corrupt database!
    DatabaseFlags* = set[DatabaseFlag]

    CopyDBFlag* = enum
        CopyCompactCopy,        # "Omit free space from copy and renumber all pages sequentially"
        CopyForceDynamicSize    # "Force to make resizeable copy, i.e. dynamic size instead of fixed"
    CopyDBFlags* = set[CopyDBFlag]

    DeleteDBMode* = enum
        JustDelete = 0,
        EnsureUnused = 1,
        WaitForUnused = 2


proc `=destroy`(db: var DatabaseObj) =
    if db.m_env != nil:
        discard mdbx_env_close(db.m_env)


proc existsDatabase*(path: string): bool =
    ## Returns true if a Database exists at the given path.
    os.dirExists(path)

proc deleteDatabase*(path: string, mode = EnsureUnused) =
    ## Deletes the Database directory at the given path.
    ## The file must not be open!
    check mdbx_env_delete(path, MDBXEnvDeleteMode(mode))

proc eraseDatabase*(path: string) =
    ## Erases the contents of a Database at the given path, by emptying the directory.
    ## Afterwards the directory will exist but be empty.
    ## The file must not be open!
    if os.existsOrCreateDir(path):
        deleteDatabase(path)
        discard os.existsOrCreateDir(path)


const kEnvFlags = [MDBX_NOSUBDIR,  # These *MUST* exactly match the DatabaseFlag enum values
                   MDBX_RDONLY,
                   MDBX_EXCLUSIVE,
                   MDBX_ACCEDE,
                   MDBX_NOTLS,
                   MDBX_COALESCE,
                   MDBX_LIFORECLAIM,
                   MDBX_PAGEPERTURB,
                   MDBX_NOMETASYNC,
                   MDBX_SAFE_NOSYNC,
                   MDBX_UTTERLY_NOSYNC]
proc convertFlags(flags: DatabaseFlags): EnvFlags =
    result = EnvFlags(0)
    for bit in 0..<kEnvFlags.len:
        if (cast[uint](flags) and uint(1 shl bit)) != 0:
            result = result or kEnvFlags[bit]

# Default database configuration values used by ``openDatabase``:
const DefaultDatabaseFlags*  = {LIFOReclaim, NoTLS}
const DefaultFileMode*       = 0o600
const DefaultMinFileSize*    =   5 * 1024 * 1024
const DefaultMaxFileSize*    = 400 * 1024 * 1024
const DefaultMaxCollections* = 20


proc openDatabase*(path: string,
                   flags = DefaultDatabaseFlags,
                   fileMode = DefaultFileMode,
                   minFileSize = DefaultMinFileSize,
                   maxFileSize = DefaultMaxFileSize,
                   fileGrowsBy = -1,
                   fileShrinksBy = -1,
                   pageSize = -1,
                   maxCollections = DefaultMaxCollections): Database =
    ## Opens a Database. (All parameters but the ``path`` are optional and can usually be omitted.)
    ## * path: The filesystem path of the database directory
    ## * flags: libmdbx environment flags. Default is ``MDBX_LIFORECLAIM``. Other useful flags are
    ##          ``MDBX_RDONLY`` (read-only) and ``MDBX_EXCLUSIVE`` (don't allow any other Database
    ##          instances, or other processes, to open the file; improves speed.)
    ##          Other flags are complex and can be dangerous. See mdbx.h for details.
    ## * fileMode: The POSIX permissions for the directory and files (defaults to 0o600)
    ## * minFileSize: The initial file size, in bytes. Will not shrink below this.
    ## * maxFileSize: The maximum size the file can grow to.
    ## * fileGrowsBy: How much the file grows when it runs out of space
    ## * fileShrinksBy: How much free space will cause the file to shrink
    ## * pageSize: Size of a database page
    ## * maxCollections: The maximum number of Collections you will open in this session
    var env: MDBX_env
    check mdbx_env_create(env)
    result = Database(m_env: env)
    check mdbx_env_set_geometry(env,
                                minFileSize,        # lower bound
                                -1,                 # size_now (-1 = 'keep current size')
                                maxFileSize,        # upper bound
                                fileGrowsBy,        # growth step
                                fileShrinksBy,      # shrink threshold
                                pageSize)           # page size
    check mdbx_env_set_maxdbs(env, uint32(maxCollections))
    check mdbx_env_open(env, path, convertFlags(flags), fileMode)
    check mdbx_env_set_userctx(env, cast[pointer](result))  # In case something needs it later


proc getDB(env: MDBX_env): Database =
    cast[Database](mdbx_env_get_userctx(env))


proc isOpen*(db: Database): bool {.inline.} =
    return db != nil and db.m_env != nil

proc mustBeOpen*(db: Database) =
    if not db.isOpen: raise newException(CatchableError, "Using already-closed Database")

proc env*(db: Database): MDBX_env =
    if db.m_env == nil: raise newException(CatchableError, "Database has been closed")
    return db.m_env


proc stats*(db: Database): MDBX_stat =
    ## Returns low-level information about the database file.
    check mdbx_env_stat_ex(db.env, nil, result, csize_t(sizeof(result)))


proc path*(db: Database): string =
    ## The filesystem path the database was opened with.
    var cpath: cstring
    check mdbx_env_get_path(db.env, cpath)
    return $cpath


proc copyTo*(db: Database, path: string, flags: CopyDBFlags = {}) =
    ## Copies an open Database to a new file.
    check mdbx_env_copy(db.env, path, MDBXCopyFlags(cast[uint](flags)))


proc close*(db: Database) =
    ## Closes a Database. It is illegal to reference the Database and objects derived from it --
    ## Collections, Snapshots, Transactions, Cursors -- afterwards.
    ## (The Database is also closed when its object is destroyed.)
    let env = db.m_env
    if env != nil:
        db.m_env = nil
        check mdbx_env_close(env)


proc closeAndDelete*(db: Database, mode = EnsureUnused) =
    ## Closes the Database, then deletes its directory.
    let path = db.path
    db.close
    deleteDatabase(path, mode)