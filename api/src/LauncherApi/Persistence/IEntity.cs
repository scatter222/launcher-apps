namespace LauncherApi.Persistence;

/// <summary>
/// Optional marker for types that carry their own identity. Implementing this
/// unlocks the id-less convenience overloads on <see cref="IDocumentStore"/> and
/// <see cref="IRepository{T}"/> (e.g. <c>store.UpsertAsync(entity)</c>), so you
/// don't have to pass the key separately.
/// </summary>
public interface IEntity
{
    /// <summary>Stable, unique identifier used as the storage key.</summary>
    string Id { get; }
}
