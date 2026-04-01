using System.Diagnostics;
using System.Text.Json;
using LauncherApi.Models;

namespace LauncherApi.Services;

public class VmService
{
    private readonly string _baseImageDir;
    private readonly string _instanceDir;
    private readonly string _instancesFile;
    private readonly string _defaultNetwork;
    private readonly int _maxInstancesPerUser;
    private readonly List<VmTemplate> _templates;
    private readonly ILogger<VmService> _logger;

    public VmService(IConfiguration configuration, ILogger<VmService> logger)
    {
        _logger = logger;

        var vmConfig = configuration.GetSection("VmSettings");
        _baseImageDir = vmConfig["BaseImageDir"] ?? "/var/lib/libvirt/images/base";
        _instanceDir = vmConfig["InstanceDir"] ?? "/var/lib/libvirt/images/instances";
        _defaultNetwork = vmConfig["DefaultNetwork"] ?? "default";
        _maxInstancesPerUser = int.Parse(vmConfig["MaxInstancesPerUser"] ?? "5");
        _instancesFile = Path.Combine(_instanceDir, "instances.json");

        // Load templates from config
        _templates = configuration.GetSection("VmTemplates").Get<List<VmTemplate>>() ?? new List<VmTemplate>();

        // Ensure instance directory exists
        Directory.CreateDirectory(_instanceDir);
    }

    public List<VmTemplate> GetTemplates() => _templates;

    public async Task<List<VmInstance>> GetUserInstances(string owner)
    {
        var all = await LoadInstances();
        var userInstances = all.Where(i => i.Owner == owner).ToList();

        // Refresh state from virsh for each instance
        foreach (var instance in userInstances)
        {
            instance.State = await GetDomainState(instance.DomainName);
        }

        return userInstances;
    }

    public async Task<VmInstance> CreateInstance(string owner, string templateId)
    {
        var template = _templates.FirstOrDefault(t => t.Id == templateId);
        if (template == null)
            throw new ArgumentException($"Template not found: {templateId}");

        var userInstances = await GetUserInstances(owner);
        if (userInstances.Count >= _maxInstancesPerUser)
            throw new InvalidOperationException($"Maximum of {_maxInstancesPerUser} instances per user reached.");

        var shortId = Guid.NewGuid().ToString("N")[..8];
        var sanitizedOwner = owner.Split('@')[0]; // testuser@REALM -> testuser
        var domainName = $"{templateId}-{sanitizedOwner}-{shortId}";
        var diskPath = Path.Combine(_instanceDir, $"{domainName}.qcow2");
        var baseImagePath = Path.Combine(_baseImageDir, template.BaseImage);

        if (!File.Exists(baseImagePath))
            throw new FileNotFoundException($"Base image not found: {baseImagePath}");

        // Create copy-on-write overlay
        await RunCommand("qemu-img", $"create -f qcow2 -b {baseImagePath} -F qcow2 {diskPath}");

        // Find a free VNC port
        var consolePort = await FindFreeVncPort();

        var instance = new VmInstance
        {
            Id = shortId,
            TemplateId = templateId,
            TemplateName = template.Name,
            Owner = owner,
            DomainName = domainName,
            DiskPath = diskPath,
            State = "stopped",
            CreatedAt = DateTime.UtcNow,
            ConsoleType = "vnc",
            ConsolePort = consolePort,
            Specs = new VmSpecs
            {
                Memory = template.Specs.Memory,
                Cpus = template.Specs.Cpus,
                DiskSize = template.Specs.DiskSize
            }
        };

        // Generate and define libvirt domain XML
        var xml = GenerateDomainXml(instance);
        var xmlPath = Path.Combine(Path.GetTempPath(), $"{domainName}.xml");
        await File.WriteAllTextAsync(xmlPath, xml);
        await RunCommand("virsh", $"define {xmlPath}");
        File.Delete(xmlPath);

        // Start the VM
        await RunCommand("virsh", $"start {domainName}");
        instance.State = "running";

        // Persist instance record
        var instances = await LoadInstances();
        instances.Add(instance);
        await SaveInstances(instances);

        _logger.LogInformation("Created VM instance {DomainName} for {Owner} from template {TemplateId}",
            domainName, owner, templateId);

        return instance;
    }

    public async Task StartInstance(string owner, string instanceId)
    {
        var instance = await GetOwnedInstance(owner, instanceId);
        await RunCommand("virsh", $"start {instance.DomainName}");
    }

    public async Task StopInstance(string owner, string instanceId)
    {
        var instance = await GetOwnedInstance(owner, instanceId);
        await RunCommand("virsh", $"shutdown {instance.DomainName}");
    }

    public async Task RestartInstance(string owner, string instanceId)
    {
        var instance = await GetOwnedInstance(owner, instanceId);
        try
        {
            await RunCommand("virsh", $"reboot {instance.DomainName}");
        }
        catch
        {
            await RunCommand("virsh", $"destroy {instance.DomainName}");
            await Task.Delay(1000);
            await RunCommand("virsh", $"start {instance.DomainName}");
        }
    }

    public async Task DeleteInstance(string owner, string instanceId)
    {
        var instance = await GetOwnedInstance(owner, instanceId);

        // Stop if running
        var state = await GetDomainState(instance.DomainName);
        if (state == "running")
        {
            await RunCommand("virsh", $"destroy {instance.DomainName}");
        }

        // Undefine and remove storage
        await RunCommand("virsh", $"undefine {instance.DomainName} --remove-all-storage");

        // Remove from instance tracking
        var instances = await LoadInstances();
        instances.RemoveAll(i => i.Id == instanceId && i.Owner == owner);
        await SaveInstances(instances);

        _logger.LogInformation("Deleted VM instance {DomainName} for {Owner}", instance.DomainName, owner);
    }

    public async Task<ConsoleInfo> GetConsoleInfo(string owner, string instanceId)
    {
        var instance = await GetOwnedInstance(owner, instanceId);

        return new ConsoleInfo
        {
            Type = instance.ConsoleType,
            Host = "0.0.0.0",
            Port = instance.ConsolePort,
            Url = $"vnc://api.lab.forge.local:{instance.ConsolePort}"
        };
    }

    // --- Private helpers ---

    private async Task<VmInstance> GetOwnedInstance(string owner, string instanceId)
    {
        var instances = await LoadInstances();
        var instance = instances.FirstOrDefault(i => i.Id == instanceId && i.Owner == owner);
        if (instance == null)
            throw new KeyNotFoundException($"Instance {instanceId} not found for user {owner}");
        return instance;
    }

    private async Task<string> GetDomainState(string domainName)
    {
        try
        {
            var output = await RunCommand("virsh", $"domstate {domainName}");
            var state = output.Trim().ToLower();
            if (state.Contains("running")) return "running";
            if (state.Contains("paused")) return "paused";
            return "stopped";
        }
        catch
        {
            return "stopped";
        }
    }

    private async Task<int> FindFreeVncPort()
    {
        var instances = await LoadInstances();
        var usedPorts = instances.Select(i => i.ConsolePort).ToHashSet();
        for (int port = 5900; port < 6000; port++)
        {
            if (!usedPorts.Contains(port)) return port;
        }
        throw new InvalidOperationException("No free VNC ports available (5900-5999 exhausted)");
    }

    private string GenerateDomainXml(VmInstance instance)
    {
        return $@"<domain type='kvm'>
  <name>{instance.DomainName}</name>
  <metadata>
    <launcher:instance xmlns:launcher='http://launcher-apps/vm'>
      <launcher:owner>{instance.Owner}</launcher:owner>
      <launcher:instanceId>{instance.Id}</launcher:instanceId>
      <launcher:templateId>{instance.TemplateId}</launcher:templateId>
    </launcher:instance>
  </metadata>
  <memory unit='MiB'>{instance.Specs.Memory}</memory>
  <vcpu placement='static'>{instance.Specs.Cpus}</vcpu>
  <os>
    <type arch='x86_64' machine='pc-q35-6.2'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='{instance.DiskPath}'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='network'>
      <source network='{_defaultNetwork}'/>
      <model type='virtio'/>
    </interface>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <graphics type='vnc' port='{instance.ConsolePort}' autoport='no' listen='0.0.0.0'/>
    <video>
      <model type='qxl' ram='65536' vram='65536' vgamem='16384' heads='1' primary='yes'/>
    </video>
  </devices>
</domain>";
    }

    private async Task<List<VmInstance>> LoadInstances()
    {
        if (!File.Exists(_instancesFile))
            return new List<VmInstance>();

        var json = await File.ReadAllTextAsync(_instancesFile);
        return JsonSerializer.Deserialize<List<VmInstance>>(json) ?? new List<VmInstance>();
    }

    private async Task SaveInstances(List<VmInstance> instances)
    {
        var json = JsonSerializer.Serialize(instances, new JsonSerializerOptions { WriteIndented = true });
        await File.WriteAllTextAsync(_instancesFile, json);
    }

    private static async Task<string> RunCommand(string command, string arguments)
    {
        var psi = new ProcessStartInfo
        {
            FileName = command,
            Arguments = arguments,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        using var process = Process.Start(psi)
            ?? throw new InvalidOperationException($"Failed to start {command}");

        var stdout = await process.StandardOutput.ReadToEndAsync();
        var stderr = await process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();

        if (process.ExitCode != 0)
            throw new InvalidOperationException($"{command} failed (exit {process.ExitCode}): {stderr}");

        return stdout;
    }
}
