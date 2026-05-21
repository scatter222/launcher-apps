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

    // Optional. When present, the launcher can ask the API to restart the
    // associated service inside a libvirt guest VM via the QEMU guest agent.
    public RestartConfig? Restart { get; set; }
}

// How to restart a rule-consuming service inside a libvirt guest. The API
// shells out to `virsh qemu-agent-command <VmName> ...` and runs Path + Args
// inside the guest via guest-exec.
public class RestartConfig
{
    public string VmName { get; set; } = string.Empty;
    public string Path { get; set; } = string.Empty;
    public List<string> Args { get; set; } = new();
    public int TimeoutSeconds { get; set; } = 60;
    public string Description { get; set; } = string.Empty;
}

public class RuleSetSummary
{
    public string Id { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    public string Directory { get; set; } = string.Empty;
    public List<string> AllowedExtensions { get; set; } = new();
    public long MaxFileSizeBytes { get; set; }

    public bool RestartAvailable { get; set; }
    public string? RestartDescription { get; set; }
    public string? RestartVmName { get; set; }
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

public class RestartResult
{
    public bool Success { get; set; }
    public string VmName { get; set; } = string.Empty;
    public string Command { get; set; } = string.Empty;
    public int? ExitCode { get; set; }
    public string? Stdout { get; set; }
    public string? Stderr { get; set; }
    public string? Error { get; set; }
    public double DurationSeconds { get; set; }
}
