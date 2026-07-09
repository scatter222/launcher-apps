using System.Text.Json;
using LauncherApi.Models;

namespace LauncherApi.Services;

/// <summary>
/// Loads and serves the tool catalog (config/tools.json). The catalog is
/// informational: it describes which tools exist on which analysis VM so users
/// can explore what is available by category. Tools are not launched from here.
/// </summary>
public class ToolsService
{
    private readonly ToolCatalog _catalog;
    private readonly ILogger<ToolsService> _logger;

    public ToolsService(IConfiguration configuration, ILogger<ToolsService> logger)
    {
        _logger = logger;

        var configured = configuration["ToolsSettings:CatalogFile"];
        var catalogPath = !string.IsNullOrWhiteSpace(configured)
            ? configured
            : Path.Combine(AppContext.BaseDirectory, "config", "tools.json");

        _catalog = LoadCatalog(catalogPath);
        _logger.LogInformation(
            "Loaded tool catalog: {ToolCount} tools across {SystemCount} systems from {Path}",
            _catalog.Tools.Count, _catalog.Systems.Count, catalogPath);
    }

    private ToolCatalog LoadCatalog(string path)
    {
        if (!File.Exists(path))
        {
            _logger.LogWarning("Tool catalog not found at {Path}; serving an empty catalog.", path);
            return new ToolCatalog();
        }

        try
        {
            var json = File.ReadAllText(path);
            var catalog = JsonSerializer.Deserialize<ToolCatalog>(json, new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true
            });
            return catalog ?? new ToolCatalog();
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to parse tool catalog at {Path}; serving an empty catalog.", path);
            return new ToolCatalog();
        }
    }

    public IReadOnlyList<ToolSystem> GetSystems() => _catalog.Systems;

    /// <summary>
    /// Returns catalog tools, optionally filtered by system id and/or category
    /// (both case-insensitive).
    /// </summary>
    public IReadOnlyList<ToolInfo> GetTools(string? system = null, string? category = null)
    {
        IEnumerable<ToolInfo> tools = _catalog.Tools;

        if (!string.IsNullOrWhiteSpace(system))
            tools = tools.Where(t => string.Equals(t.System, system, StringComparison.OrdinalIgnoreCase));

        if (!string.IsNullOrWhiteSpace(category))
            tools = tools.Where(t => string.Equals(t.Category, category, StringComparison.OrdinalIgnoreCase));

        return tools.ToList();
    }
}
