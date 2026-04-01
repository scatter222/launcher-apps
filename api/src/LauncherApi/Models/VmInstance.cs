namespace LauncherApi.Models;

public class VmInstance
{
    public string Id { get; set; } = string.Empty;
    public string TemplateId { get; set; } = string.Empty;
    public string TemplateName { get; set; } = string.Empty;
    public string Owner { get; set; } = string.Empty;
    public string DomainName { get; set; } = string.Empty;
    public string DiskPath { get; set; } = string.Empty;
    public string State { get; set; } = "stopped";
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public string ConsoleType { get; set; } = "vnc";
    public int ConsolePort { get; set; }
    public VmSpecs Specs { get; set; } = new();
}

public class CreateInstanceRequest
{
    public string TemplateId { get; set; } = string.Empty;
}

public class ConsoleInfo
{
    public string Type { get; set; } = string.Empty;
    public string Host { get; set; } = string.Empty;
    public int Port { get; set; }
    public string Url { get; set; } = string.Empty;
}
