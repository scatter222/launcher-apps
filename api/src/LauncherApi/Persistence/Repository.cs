namespace LauncherApi.Persistence;

/// <summary>
/// Default <see cref="IRepository{T}"/> implementation that simply delegates to the
/// shared <see cref="IDocumentStore"/>. Registered as an open generic so any
/// <c>IRepository&lt;T&gt;</c> resolves without per-type wiring.
/// </summary>
public class Repository<T> : IRepository<T> where T : class
{
    private readonly IDocumentStore _store;

    public Repository(IDocumentStore store)
    {
        _store = store;
    }

    public Task<T?> GetAsync(string id, CancellationToken cancellationToken = default)
        => _store.GetAsync<T>(id, cancellationToken);

    public Task<IReadOnlyList<T>> GetAllAsync(CancellationToken cancellationToken = default)
        => _store.GetAllAsync<T>(cancellationToken);

    public Task<IReadOnlyList<T>> FindAsync(Func<T, bool> predicate, CancellationToken cancellationToken = default)
        => _store.FindAsync(predicate, cancellationToken);

    public Task<T?> FindFirstAsync(Func<T, bool> predicate, CancellationToken cancellationToken = default)
        => _store.FindFirstAsync(predicate, cancellationToken);

    public Task UpsertAsync(string id, T entity, CancellationToken cancellationToken = default)
        => _store.UpsertAsync(id, entity, cancellationToken);

    public Task<bool> DeleteAsync(string id, CancellationToken cancellationToken = default)
        => _store.DeleteAsync<T>(id, cancellationToken);

    public Task<bool> ExistsAsync(string id, CancellationToken cancellationToken = default)
        => _store.ExistsAsync<T>(id, cancellationToken);

    public Task<int> CountAsync(CancellationToken cancellationToken = default)
        => _store.CountAsync<T>(cancellationToken);
}
