namespace LauncherApi.Persistence;

/// <summary>
/// A strongly-typed view over <see cref="IDocumentStore"/> for a single type.
/// Inject <c>IRepository&lt;MyThing&gt;</c> anywhere you need to persist or load
/// <c>MyThing</c> objects — no registration per type is required.
/// </summary>
public interface IRepository<T> where T : class
{
    Task<T?> GetAsync(string id, CancellationToken cancellationToken = default);

    Task<IReadOnlyList<T>> GetAllAsync(CancellationToken cancellationToken = default);

    Task<IReadOnlyList<T>> FindAsync(Func<T, bool> predicate, CancellationToken cancellationToken = default);

    Task<T?> FindFirstAsync(Func<T, bool> predicate, CancellationToken cancellationToken = default);

    Task UpsertAsync(string id, T entity, CancellationToken cancellationToken = default);

    Task<bool> DeleteAsync(string id, CancellationToken cancellationToken = default);

    Task<bool> ExistsAsync(string id, CancellationToken cancellationToken = default);

    Task<int> CountAsync(CancellationToken cancellationToken = default);
}
