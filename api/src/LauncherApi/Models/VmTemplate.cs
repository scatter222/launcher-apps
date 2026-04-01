namespace LauncherApi.Models;

public class VmTemplate
{
    public string Id { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    public string BaseImage { get; set; } = string.Empty;
    public string Category { get; set; } = string.Empty;
    public VmSpecs Specs { get; set; } = new();
    public List<string> Tags { get; set; } = new();
}

public class VmSpecs
{
    public int Memory { get; set; } = 2048;
    public int Cpus { get; set; } = 2;
    public int DiskSize { get; set; } = 40;
}
