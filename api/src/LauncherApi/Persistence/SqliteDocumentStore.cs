using System.Collections.Concurrent;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace LauncherApi.Persistence;

/// <summary>
/// SQLite-backed implementation of <see cref="IDocumentStore"/>. Stores each type
/// in a dedicated table of the form <c>(Id TEXT PRIMARY KEY, Data TEXT,
/// CreatedAt TEXT, UpdatedAt TEXT)</c>, with the object serialized to JSON in
/// <c>Data</c>. Tables are created lazily on first use per type.
/// </summary>
public class SqliteDocumentStore : IDocumentStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
    };

    private readonly IDbConnectionFactory _connectionFactory;
    private readonly ILogger<SqliteDocumentStore> _logger;

    // Tracks which type tables have been ensured this process, so we only issue
    // CREATE TABLE IF NOT EXISTS once per type.
    private readonly ConcurrentDictionary<Type, string> _ensuredTables = new();

    public SqliteDocumentStore(IDbConnectionFactory connectionFactory, ILogger<SqliteDocumentStore> logger)
    {
        _connectionFactory = connectionFactory;
        _logger = logger;
    }

    public async Task<T?> GetAsync<T>(string id, CancellationToken cancellationToken = default) where T : class
    {
        var table = await EnsureTableAsync<T>(cancellationToken);
        await using var connection = await _connectionFactory.CreateOpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText = $"SELECT Data FROM {table} WHERE Id = $id LIMIT 1;";
        command.Parameters.AddWithValue("$id", id);

        var data = await command.ExecuteScalarAsync(cancellationToken) as string;
        return data is null ? null : Deserialize<T>(data);
    }

    public async Task<IReadOnlyList<T>> GetAllAsync<T>(CancellationToken cancellationToken = default) where T : class
    {
        var table = await EnsureTableAsync<T>(cancellationToken);
        await using var connection = await _connectionFactory.CreateOpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText = $"SELECT Data FROM {table} ORDER BY CreatedAt;";

        var results = new List<T>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            var entity = Deserialize<T>(reader.GetString(0));
            if (entity is not null)
            {
                results.Add(entity);
            }
        }

        return results;
    }

    public async Task<IReadOnlyList<T>> FindAsync<T>(Func<T, bool> predicate, CancellationToken cancellationToken = default) where T : class
    {
        var all = await GetAllAsync<T>(cancellationToken);
        return all.Where(predicate).ToList();
    }

    public async Task<T?> FindFirstAsync<T>(Func<T, bool> predicate, CancellationToken cancellationToken = default) where T : class
    {
        var all = await GetAllAsync<T>(cancellationToken);
        return all.FirstOrDefault(predicate);
    }

    public async Task UpsertAsync<T>(string id, T entity, CancellationToken cancellationToken = default) where T : class
    {
        var table = await EnsureTableAsync<T>(cancellationToken);
        var json = JsonSerializer.Serialize(entity, JsonOptions);
        var now = DateTime.UtcNow.ToString("o");

        await using var connection = await _connectionFactory.CreateOpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            $"INSERT INTO {table} (Id, Data, CreatedAt, UpdatedAt) " +
            "VALUES ($id, $data, $now, $now) " +
            "ON CONFLICT(Id) DO UPDATE SET Data = excluded.Data, UpdatedAt = excluded.UpdatedAt;";
        command.Parameters.AddWithValue("$id", id);
        command.Parameters.AddWithValue("$data", json);
        command.Parameters.AddWithValue("$now", now);

        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task<bool> DeleteAsync<T>(string id, CancellationToken cancellationToken = default) where T : class
    {
        var table = await EnsureTableAsync<T>(cancellationToken);
        await using var connection = await _connectionFactory.CreateOpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText = $"DELETE FROM {table} WHERE Id = $id;";
        command.Parameters.AddWithValue("$id", id);

        var affected = await command.ExecuteNonQueryAsync(cancellationToken);
        return affected > 0;
    }

    public async Task<bool> ExistsAsync<T>(string id, CancellationToken cancellationToken = default) where T : class
    {
        var table = await EnsureTableAsync<T>(cancellationToken);
        await using var connection = await _connectionFactory.CreateOpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText = $"SELECT 1 FROM {table} WHERE Id = $id LIMIT 1;";
        command.Parameters.AddWithValue("$id", id);

        var result = await command.ExecuteScalarAsync(cancellationToken);
        return result is not null;
    }

    public async Task<int> CountAsync<T>(CancellationToken cancellationToken = default) where T : class
    {
        var table = await EnsureTableAsync<T>(cancellationToken);
        await using var connection = await _connectionFactory.CreateOpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText = $"SELECT COUNT(*) FROM {table};";

        var result = await command.ExecuteScalarAsync(cancellationToken);
        return Convert.ToInt32(result);
    }

    private static T? Deserialize<T>(string json) where T : class
        => JsonSerializer.Deserialize<T>(json, JsonOptions);

    /// <summary>
    /// Lazily creates the backing table for <typeparamref name="T"/> and returns
    /// its (validated, safe-to-interpolate) name.
    /// </summary>
    private async Task<string> EnsureTableAsync<T>(CancellationToken cancellationToken)
    {
        if (_ensuredTables.TryGetValue(typeof(T), out var existing))
        {
            return existing;
        }

        var table = ResolveTableName(typeof(T));

        await using var connection = await _connectionFactory.CreateOpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            $"CREATE TABLE IF NOT EXISTS {table} (" +
            "Id TEXT PRIMARY KEY, " +
            "Data TEXT NOT NULL, " +
            "CreatedAt TEXT NOT NULL, " +
            "UpdatedAt TEXT NOT NULL);";
        await command.ExecuteNonQueryAsync(cancellationToken);

        if (_ensuredTables.TryAdd(typeof(T), table))
        {
            _logger.LogDebug("Ensured persistence table {Table} for type {Type}", table, typeof(T).FullName);
        }

        return table;
    }

    /// <summary>
    /// Derives a deterministic table name from a type. The result is restricted to
    /// alphanumerics and underscores, so it is safe to interpolate into SQL (SQLite
    /// does not support parameterized identifiers).
    /// </summary>
    private static string ResolveTableName(Type type)
    {
        var raw = type.Name;
        Span<char> buffer = stackalloc char[raw.Length];
        var length = 0;
        foreach (var c in raw)
        {
            buffer[length++] = char.IsLetterOrDigit(c) || c == '_' ? c : '_';
        }

        var name = new string(buffer[..length]);

        // Table names cannot begin with a digit.
        if (name.Length == 0 || char.IsDigit(name[0]))
        {
            name = "T_" + name;
        }

        return name;
    }
}
