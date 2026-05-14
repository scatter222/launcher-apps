namespace LauncherApi.Models;

public class YaraSettings
{
    public string RulesDirectory { get; set; } = "/var/lib/yara/rules";
    public string[] AllowedExtensions { get; set; } = new[] { ".yar", ".yara" };
    public long MaxFileSizeBytes { get; set; } = 1_048_576;
}

public class YaraRuleSummary
{
    public string Name { get; set; } = string.Empty;
    public long Size { get; set; }
    public DateTime LastModified { get; set; }
}

public class YaraRuleContent
{
    public string Name { get; set; } = string.Empty;
    public string Content { get; set; } = string.Empty;
    public long Size { get; set; }
    public DateTime LastModified { get; set; }
}

public class YaraRuleUpload
{
    public string Name { get; set; } = string.Empty;
    public string Content { get; set; } = string.Empty;
    public bool Overwrite { get; set; }
}
