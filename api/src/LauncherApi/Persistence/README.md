# Persistence

A general-purpose SQLite persistence layer. Store and retrieve any object by key
without writing schema, migrations, or SQL. Each type gets its own table and is
serialized to JSON automatically.

## Setup

Already wired up in `Program.cs`:

```csharp
builder.Services.AddSqlitePersistence(builder.Configuration);
```

Configure the database location in `appsettings.json`:

```json
"Persistence": {
  "DatabasePath": "data/launcher.db",
  "EnableWalMode": true,
  "BusyTimeoutMs": 5000
}
```

Set `ConnectionString` instead of `DatabasePath` to use a full connection string verbatim.

## Usage

### Option A — inject a typed repository (recommended)

Inject `IRepository<T>` for the type you care about. No per-type registration needed.

```csharp
public class SessionService
{
    private readonly IRepository<Session> _sessions;

    public SessionService(IRepository<Session> sessions) => _sessions = sessions;

    public Task SaveAsync(Session s)        => _sessions.UpsertAsync(s.Id, s);
    public Task<Session?> GetAsync(string id) => _sessions.GetAsync(id);
    public Task<IReadOnlyList<Session>> AllAsync() => _sessions.GetAllAsync();
}
```

### Option B — inject the shared document store

Inject `IDocumentStore` when one service deals with several types.

```csharp
await store.UpsertAsync("user-42", user);
var user = await store.GetAsync<User>("user-42");
var admins = await store.FindAsync<User>(u => u.IsAdmin);
await store.DeleteAsync<User>("user-42");
```

### Option C — raw SQL

Inject `IDbConnectionFactory` when you need hand-written SQL or indexed queries.

```csharp
await using var conn = await factory.CreateOpenAsync();
await using var cmd = conn.CreateCommand();
cmd.CommandText = "SELECT COUNT(*) FROM Session;";
var count = await cmd.ExecuteScalarAsync();
```

## `IEntity` convenience

If your type implements `IEntity` (exposes a `string Id`), you can skip passing the
key explicitly:

```csharp
public class Session : IEntity
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    // ...
}

await store.UpsertAsync(session);   // uses session.Id
await repo.DeleteAsync(session);    // uses session.Id
```

## Notes

- `FindAsync`/`FindFirstAsync` load the type's rows and filter in memory — fine for
  moderate collections. For large data sets, use `IDbConnectionFactory` with a real
  `WHERE` clause.
- Tables are created lazily the first time a type is used.
- Services are registered as singletons; a fresh SQLite connection is opened per
  operation, so the layer is safe for concurrent use.
