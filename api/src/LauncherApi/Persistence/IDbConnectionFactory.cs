using Microsoft.Data.Sqlite;

namespace LauncherApi.Persistence;

/// <summary>
/// Creates SQLite connections to the application database. Inject this when you
/// need to run hand-written SQL directly instead of using <see cref="IDocumentStore"/>
/// or <see cref="IRepository{T}"/>.
/// </summary>
public interface IDbConnectionFactory
{
    /// <summary>Creates a new, unopened connection.</summary>
    SqliteConnection Create();

    /// <summary>Creates and opens a new connection.</summary>
    Task<SqliteConnection> CreateOpenAsync(CancellationToken cancellationToken = default);
}
