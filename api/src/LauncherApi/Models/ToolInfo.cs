namespace LauncherApi.Models;

public class ToolInfo
{
    public string Id { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string Category { get; set; } = string.Empty;
    public bool Available { get; set; }
}
