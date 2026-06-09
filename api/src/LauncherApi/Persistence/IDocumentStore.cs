namespace LauncherApi.Persistence;

/// <summary>
/// A general-purpose, type-agnostic store for persisting and retrieving objects
/// in SQLite. Each type <typeparamref name="T"/> is kept in its own table and
/// serialized as JSON, so you can store and retrieve anything by key without
/// writing schema, migrations, or per-type SQL.
///
/// <para>
/// Inject this directly, or inject the strongly-typed <see cref="IRepository{T}"/>
/// for a single type.
/// </para>
/// </summary>
public interface IDocumentStore
{
    /// <summary>Gets a single object by its key, or <c>null</c> if not found.</summary>
    Task<T?> GetAsync<T>(string id, CancellationToken cancellationToken = default) where T : class;

    /// <summary>Gets every stored object of the given type.</summary>
    Task<IReadOnlyList<T>> GetAllAsync<T>(CancellationToken cancellationToken = default) where T : class;

    /// <summary>
    /// Returns all objects matching the predicate. Note: this loads and filters
    /// in memory — suitable for moderate collections. For large data sets or
    /// indexed queries, use <see cref="IDbConnectionFactory"/> directly.
    /// </summary>
    Task<IReadOnlyList<T>> FindAsync<T>(Func<T, bool> predicate, CancellationToken cancellationToken = default) where T : class;

    /// <summary>Returns the first object matching the predicate, or <c>null</c>.</summary>
    Task<T?> FindFirstAsync<T>(Func<T, bool> predicate, CancellationToken cancellationToken = default) where T : class;

    /// <summary>Inserts or replaces the object stored under <paramref name="id"/>.</summary>
    Task UpsertAsync<T>(string id, T entity, CancellationToken cancellationToken = default) where T : class;

    /// <summary>Deletes the object with the given key. Returns <c>true</c> if a row was removed.</summary>
    Task<bool> DeleteAsync<T>(string id, CancellationToken cancellationToken = default) where T : class;

    /// <summary>Returns <c>true</c> if an object with the given key exists.</summary>
    Task<bool> ExistsAsync<T>(string id, CancellationToken cancellationToken = default) where T : class;

    /// <summary>Counts the stored objects of the given type.</summary>
    Task<int> CountAsync<T>(CancellationToken cancellationToken = default) where T : class;
}
