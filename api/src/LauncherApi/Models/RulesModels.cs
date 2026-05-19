namespace LauncherApi.Models;

// Server-side configuration for one rule set (e.g. Suricata, YARA, Zeek).
// Bound from the "RuleSets" array in appsettings.json.
public class RuleSetConfig
{
    public string Id { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    public string Directory { get; set; } = string.Empty;
    public List<string> AllowedExtensions { get; set; } = new();
    public long MaxFileSizeBytes { get; set; } = 1_048_576;
}

public class RuleSetSummary
{
    public string Id { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    public string Directory { get; set; } = string.Empty;
    public List<string> AllowedExtensions { get; set; } = new();
    public long MaxFileSizeBytes { get; set; }
}

public class RuleFileSummary
{
    public string Name { get; set; } = string.Empty;
    public long Size { get; set; }
    public DateTime LastModified { get; set; }
}

public class RuleFileContent
{
    public string Name { get; set; } = string.Empty;
    public string Content { get; set; } = string.Empty;
    public long Size { get; set; }
    public DateTime LastModified { get; set; }
}

public class RuleFileUpload
{
    public string Name { get; set; } = string.Empty;
    public string Content { get; set; } = string.Empty;
    public bool Overwrite { get; set; }
}
