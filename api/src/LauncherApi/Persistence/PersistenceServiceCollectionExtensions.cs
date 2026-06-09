namespace LauncherApi.Persistence;

/// <summary>
/// DI registration for the SQLite persistence layer.
/// </summary>
public static class PersistenceServiceCollectionExtensions
{
    /// <summary>
    /// Registers the SQLite persistence services: the connection factory, the
    /// shared <see cref="IDocumentStore"/>, and the open-generic
    /// <see cref="IRepository{T}"/>. After calling this you can inject
    /// <see cref="IDocumentStore"/>, <c>IRepository&lt;T&gt;</c>, or
    /// <see cref="IDbConnectionFactory"/> anywhere.
    /// </summary>
    public static IServiceCollection AddSqlitePersistence(this IServiceCollection services, IConfiguration configuration)
    {
        services.Configure<SqlitePersistenceOptions>(
            configuration.GetSection(SqlitePersistenceOptions.SectionName));

        services.AddSingleton<IDbConnectionFactory, SqliteConnectionFactory>();
        services.AddSingleton<IDocumentStore, SqliteDocumentStore>();
        services.AddSingleton(typeof(IRepository<>), typeof(Repository<>));

        return services;
    }
}
