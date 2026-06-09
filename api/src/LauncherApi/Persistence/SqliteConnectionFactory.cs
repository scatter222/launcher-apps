using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Options;

namespace LauncherApi.Persistence;

/// <summary>
/// Builds SQLite connections from <see cref="SqlitePersistenceOptions"/>, ensuring
/// the database directory exists and applying connection-level pragmas.
/// </summary>
public class SqliteConnectionFactory : IDbConnectionFactory
{
    private readonly SqlitePersistenceOptions _options;
    private readonly string _connectionString;

    public SqliteConnectionFactory(IOptions<SqlitePersistenceOptions> options, IHostEnvironment environment)
    {
        _options = options.Value;

        if (!string.IsNullOrWhiteSpace(_options.ConnectionString))
        {
            _connectionString = _options.ConnectionString!;
            return;
        }

        // Resolve a relative DatabasePath against the application's content root so
        // the location is stable regardless of the working directory.
        var dbPath = _options.DatabasePath;
        if (!Path.IsPathRooted(dbPath))
        {
            dbPath = Path.Combine(environment.ContentRootPath, dbPath);
        }

        var directory = Path.GetDirectoryName(dbPath);
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        _connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = dbPath,
            Mode = SqliteOpenMode.ReadWriteCreate,
        }.ToString();
    }

    public SqliteConnection Create() => new(_connectionString);

    public async Task<SqliteConnection> CreateOpenAsync(CancellationToken cancellationToken = default)
    {
        var connection = Create();
        await connection.OpenAsync(cancellationToken);

        // Apply per-connection pragmas. WAL is a database-level setting but is safe
        // (and cheap) to re-assert on each connection.
        await using var pragma = connection.CreateCommand();
        pragma.CommandText =
            $"PRAGMA busy_timeout = {_options.BusyTimeoutMs};" +
            (_options.EnableWalMode ? "PRAGMA journal_mode = WAL;" : string.Empty) +
            "PRAGMA foreign_keys = ON;";
        await pragma.ExecuteNonQueryAsync(cancellationToken);

        return connection;
    }
}
