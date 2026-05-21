using LauncherApi.Models;

namespace LauncherApi.Services;

public class RulesService
{
    public enum WriteResult
    {
        Created,
        Updated,
        ConflictExists,
        InvalidName,
        TooLarge,
        UnknownSet
    }

    private readonly IReadOnlyList<RuleSetConfig> _sets;
    private readonly ILogger<RulesService> _logger;

    public RulesService(IReadOnlyList<RuleSetConfig> sets, ILogger<RulesService> logger)
    {
        _sets = sets;
        _logger = logger;
        foreach (var set in _sets) EnsureDirectoryExists(set);
    }

    public IReadOnlyList<RuleSetSummary> ListSets() => _sets
        .Select(s => new RuleSetSummary
        {
            Id = s.Id,
            Name = s.Name,
            Description = s.Description,
            Directory = s.Directory,
            AllowedExtensions = s.AllowedExtensions,
            MaxFileSizeBytes = s.MaxFileSizeBytes,
            RestartAvailable = s.Restart is not null && !string.IsNullOrWhiteSpace(s.Restart.VmName),
            RestartDescription = s.Restart?.Description,
            RestartVmName = s.Restart?.VmName
        })
        .ToList();

    public RuleSetConfig? FindSet(string id) =>
        _sets.FirstOrDefault(s => s.Id.Equals(id, StringComparison.OrdinalIgnoreCase));

    private void EnsureDirectoryExists(RuleSetConfig set)
    {
        if (string.IsNullOrWhiteSpace(set.Directory)) return;
        if (Directory.Exists(set.Directory)) return;
        try
        {
            Directory.CreateDirectory(set.Directory);
            _logger.LogInformation("Created rules directory for {Set} at {Path}", set.Id, set.Directory);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Could not create rules directory for {Set} at {Path}", set.Id, set.Directory);
        }
    }

    private static bool IsAllowedExtension(RuleSetConfig set, string filename)
    {
        var ext = Path.GetExtension(filename);
        if (string.IsNullOrEmpty(ext)) return false;
        return set.AllowedExtensions.Any(allowed =>
            allowed.Equals(ext, StringComparison.OrdinalIgnoreCase));
    }

    // Resolves the on-disk path for a filename within a rule set, refusing
    // anything that would escape the configured directory or use a disallowed
    // extension.
    private static string? ResolveSafePath(RuleSetConfig set, string filename)
    {
        if (string.IsNullOrWhiteSpace(filename)) return null;
        if (filename.Contains('/') || filename.Contains('\\') || filename.Contains("..")) return null;
        if (!IsAllowedExtension(set, filename)) return null;

        var rootFull = Path.GetFullPath(set.Directory);
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

    public IReadOnlyList<RuleFileSummary> ListFiles(string setId)
    {
        var set = FindSet(setId);
        if (set == null || !Directory.Exists(set.Directory))
            return Array.Empty<RuleFileSummary>();

        return new DirectoryInfo(set.Directory)
            .EnumerateFiles()
            .Where(f => IsAllowedExtension(set, f.Name))
            .Select(f => new RuleFileSummary
            {
                Name = f.Name,
                Size = f.Length,
                LastModified = f.LastWriteTimeUtc
            })
            .OrderBy(r => r.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    public bool TryRead(string setId, string filename, out RuleFileContent? content, out string? error)
    {
        content = null;
        error = null;
        var set = FindSet(setId);
        if (set == null) { error = "Unknown rule set."; return false; }

        var path = ResolveSafePath(set, filename);
        if (path is null) { error = "Invalid filename or extension."; return false; }
        if (!File.Exists(path)) { error = "File not found."; return false; }

        var info = new FileInfo(path);
        content = new RuleFileContent
        {
            Name = info.Name,
            Content = File.ReadAllText(path),
            Size = info.Length,
            LastModified = info.LastWriteTimeUtc
        };
        return true;
    }

    public WriteResult Write(string setId, RuleFileUpload upload, out string? error)
    {
        error = null;
        var set = FindSet(setId);
        if (set == null) { error = "Unknown rule set."; return WriteResult.UnknownSet; }

        var path = ResolveSafePath(set, upload.Name);
        if (path is null)
        {
            var allowed = string.Join(", ", set.AllowedExtensions);
            error = $"Invalid filename. Use a simple name with an allowed extension ({allowed}).";
            return WriteResult.InvalidName;
        }

        var byteCount = System.Text.Encoding.UTF8.GetByteCount(upload.Content ?? string.Empty);
        if (byteCount > set.MaxFileSizeBytes)
        {
            error = $"File exceeds maximum size of {set.MaxFileSizeBytes} bytes.";
            return WriteResult.TooLarge;
        }

        EnsureDirectoryExists(set);

        var exists = File.Exists(path);
        if (exists && !upload.Overwrite) return WriteResult.ConflictExists;

        File.WriteAllText(path, upload.Content ?? string.Empty);
        return exists ? WriteResult.Updated : WriteResult.Created;
    }

    public bool Delete(string setId, string filename, out string? error)
    {
        error = null;
        var set = FindSet(setId);
        if (set == null) { error = "Unknown rule set."; return false; }

        var path = ResolveSafePath(set, filename);
        if (path is null) { error = "Invalid filename."; return false; }
        if (!File.Exists(path)) { error = "File not found."; return false; }

        File.Delete(path);
        return true;
    }
}
