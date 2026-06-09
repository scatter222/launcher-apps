namespace LauncherApi.Persistence;

/// <summary>
/// Configuration for the SQLite persistence layer. Bound from the
/// "Persistence" section of configuration (appsettings.json, env vars, etc.).
/// </summary>
public class SqlitePersistenceOptions
{
    public const string SectionName = "Persistence";

    /// <summary>
    /// Path to the SQLite database file. Relative paths are resolved against the
    /// application's content root. The containing directory is created if missing.
    /// </summary>
    public string DatabasePath { get; set; } = "data/launcher.db";

    /// <summary>
    /// Optional explicit connection string. When set, it takes precedence over
    /// <see cref="DatabasePath"/> and is used verbatim.
    /// </summary>
    public string? ConnectionString { get; set; }

    /// <summary>
    /// Enable Write-Ahead Logging for better read/write concurrency. Recommended.
    /// </summary>
    public bool EnableWalMode { get; set; } = true;

    /// <summary>
    /// Busy timeout (milliseconds) the SQLite driver waits when the database is
    /// locked before failing. Helps under concurrent access.
    /// </summary>
    public int BusyTimeoutMs { get; set; } = 5000;
}
