using LauncherApi.Models;
using Microsoft.Extensions.Options;

namespace LauncherApi.Services;

public class YaraService
{
    public enum WriteResult
    {
        Created,
        Updated,
        ConflictExists,
        InvalidName,
        TooLarge
    }

    private readonly YaraSettings _settings;
    private readonly ILogger<YaraService> _logger;

    public YaraService(IOptions<YaraSettings> settings, ILogger<YaraService> logger)
    {
        _settings = settings.Value;
        _logger = logger;
        EnsureDirectoryExists();
    }

    public string RulesDirectory => _settings.RulesDirectory;

    private void EnsureDirectoryExists()
    {
        if (Directory.Exists(_settings.RulesDirectory)) return;
        try
        {
            Directory.CreateDirectory(_settings.RulesDirectory);
            _logger.LogInformation("Created YARA rules directory at {Path}", _settings.RulesDirectory);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Could not create YARA rules directory at {Path}", _settings.RulesDirectory);
        }
    }

    private bool IsAllowedExtension(string filename)
    {
        var ext = Path.GetExtension(filename);
        if (string.IsNullOrEmpty(ext)) return false;
        return _settings.AllowedExtensions
            .Any(allowed => allowed.Equals(ext, StringComparison.OrdinalIgnoreCase));
    }

    // Resolves the on-disk path for a filename, refusing anything that would
    // escape the configured rules directory or use a disallowed extension.
    private string? ResolveSafePath(string filename)
    {
        if (string.IsNullOrWhiteSpace(filename)) return null;
        if (filename.Contains('/') || filename.Contains('\\') || filename.Contains("..")) return null;
        if (!IsAllowedExtension(filename)) return null;

        var rootFull = Path.GetFullPath(_settings.RulesDirectory);
        var candidate = Path.GetFullPath(Path.Combine(rootFull, filename));
        var rootWithSep = rootFull.EndsWith(Path.DirectorySeparatorChar)
            ? rootFull
            : rootFull + Path.DirectorySeparatorChar;
        if (!candidate.StartsWith(rootWithSep, StringComparison.Ordinal) && candidate != rootFull)
        {
            return null;
        }
        return candidate;
    }

    public IReadOnlyList<YaraRuleSummary> ListRules()
    {
        if (!Directory.Exists(_settings.RulesDirectory))
            return Array.Empty<YaraRuleSummary>();

        return new DirectoryInfo(_settings.RulesDirectory)
            .EnumerateFiles()
            .Where(f => IsAllowedExtension(f.Name))
            .Select(f => new YaraRuleSummary
            {
                Name = f.Name,
                Size = f.Length,
                LastModified = f.LastWriteTimeUtc
            })
            .OrderBy(r => r.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    public bool TryReadRule(string filename, out YaraRuleContent? content, out string? error)
    {
        content = null;
        error = null;
        var path = ResolveSafePath(filename);
        if (path is null)
        {
            error = "Invalid filename or extension.";
            return false;
        }
        if (!File.Exists(path))
        {
            error = "File not found.";
            return false;
        }
        var info = new FileInfo(path);
        var text = File.ReadAllText(path);
        content = new YaraRuleContent
        {
            Name = info.Name,
            Content = text,
            Size = info.Length,
            LastModified = info.LastWriteTimeUtc
        };
        return true;
    }

    public WriteResult WriteRule(YaraRuleUpload upload, out string? error)
    {
        error = null;
        var path = ResolveSafePath(upload.Name);
        if (path is null)
        {
            error = "Invalid filename. Use a simple name with an allowed extension (e.g. rules.yar).";
            return WriteResult.InvalidName;
        }
        var byteCount = System.Text.Encoding.UTF8.GetByteCount(upload.Content ?? string.Empty);
        if (byteCount > _settings.MaxFileSizeBytes)
        {
            error = $"File exceeds maximum size of {_settings.MaxFileSizeBytes} bytes.";
            return WriteResult.TooLarge;
        }

        EnsureDirectoryExists();

        var exists = File.Exists(path);
        if (exists && !upload.Overwrite)
        {
            return WriteResult.ConflictExists;
        }
        File.WriteAllText(path, upload.Content ?? string.Empty);
        return exists ? WriteResult.Updated : WriteResult.Created;
    }

    public bool DeleteRule(string filename, out string? error)
    {
        error = null;
        var path = ResolveSafePath(filename);
        if (path is null)
        {
            error = "Invalid filename.";
            return false;
        }
        if (!File.Exists(path))
        {
            error = "File not found.";
            return false;
        }
        File.Delete(path);
        return true;
    }
}
