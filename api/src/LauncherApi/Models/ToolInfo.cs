namespace LauncherApi.Models;

/// <summary>
/// A single tool available on one of the lab's analysis systems. This is a
/// catalog entry for exploration only — tools are not launched from here; each
/// runs on its own VM. The <see cref="System"/> field indicates which VM the
/// tool lives on.
/// </summary>
public class ToolInfo
{
    public string Id { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public List<string> Aliases { get; set; } = new();

    /// <summary>Id of the system/VM this tool is installed on (see <see cref="ToolSystem"/>).</summary>
    public string System { get; set; } = string.Empty;

    public string Category { get; set; } = string.Empty;
    public string? Subcategory { get; set; }
    public string Description { get; set; } = string.Empty;

    /// <summary>True if the tool is part of the system's default install set.</summary>
    public bool Default { get; set; }

    /// <summary>A representative example invocation, for reference.</summary>
    public string? Example { get; set; }
}

/// <summary>A system/VM that hosts a set of tools.</summary>
public class ToolSystem
{
    public string Id { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string Os { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    public string? PackageManager { get; set; }
    public string? Source { get; set; }
}

/// <summary>The full tool catalog loaded from config/tools.json.</summary>
public class ToolCatalog
{
    public int Version { get; set; }
    public string Description { get; set; } = string.Empty;
    public List<ToolSystem> Systems { get; set; } = new();
    public List<ToolInfo> Tools { get; set; } = new();
}
