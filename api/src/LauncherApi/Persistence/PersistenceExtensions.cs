namespace LauncherApi.Persistence;

/// <summary>
/// Id-less convenience overloads for types that implement <see cref="IEntity"/>,
/// so you can write <c>store.UpsertAsync(entity)</c> instead of repeating the key.
/// </summary>
public static class PersistenceExtensions
{
    public static Task UpsertAsync<T>(this IDocumentStore store, T entity, CancellationToken cancellationToken = default)
        where T : class, IEntity
        => store.UpsertAsync(entity.Id, entity, cancellationToken);

    public static Task<bool> DeleteAsync<T>(this IDocumentStore store, T entity, CancellationToken cancellationToken = default)
        where T : class, IEntity
        => store.DeleteAsync<T>(entity.Id, cancellationToken);

    public static Task UpsertAsync<T>(this IRepository<T> repository, T entity, CancellationToken cancellationToken = default)
        where T : class, IEntity
        => repository.UpsertAsync(entity.Id, entity, cancellationToken);

    public static Task<bool> DeleteAsync<T>(this IRepository<T> repository, T entity, CancellationToken cancellationToken = default)
        where T : class, IEntity
        => repository.DeleteAsync(entity.Id, cancellationToken);
}
