using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LauncherApi.Models;

namespace LauncherApi.Services;

// Runs commands inside a libvirt guest VM via the QEMU guest agent by
// shelling out to `virsh qemu-agent-command`. Used to restart Suricata /
// Zeek / etc. in the Malcolm box after the user uploads new rules.
public class GuestAgentService
{
    private readonly ILogger<GuestAgentService> _logger;

    public GuestAgentService(ILogger<GuestAgentService> logger)
    {
        _logger = logger;
    }

    public async Task<RestartResult> RunAsync(RestartConfig cfg, CancellationToken ct = default)
    {
        var sw = Stopwatch.StartNew();
        var result = new RestartResult
        {
            VmName = cfg.VmName,
            Command = $"{cfg.Path} {string.Join(' ', cfg.Args)}".Trim()
        };

        if (string.IsNullOrWhiteSpace(cfg.VmName) || string.IsNullOrWhiteSpace(cfg.Path))
        {
            result.Error = "Restart config is missing VmName or Path.";
            return result;
        }

        try
        {
            // 1) Kick off the command inside the guest.
            var execArgs = new JsonArray();
            foreach (var a in cfg.Args) execArgs.Add(a);
            var execPayload = new JsonObject
            {
                ["execute"] = "guest-exec",
                ["arguments"] = new JsonObject
                {
                    ["path"] = cfg.Path,
                    ["arg"] = execArgs,
                    ["capture-output"] = true
                }
            }.ToJsonString();

            var (stdout, stderr, exit) = await RunVirshAsync(cfg.VmName, execPayload, ct);
            if (exit != 0)
            {
                result.Error = $"virsh qemu-agent-command failed (exit {exit}): {stderr.Trim()}";
                result.DurationSeconds = sw.Elapsed.TotalSeconds;
                return result;
            }

            int pid;
            try
            {
                using var doc = JsonDocument.Parse(stdout);
                pid = doc.RootElement.GetProperty("return").GetProperty("pid").GetInt32();
            }
            catch (Exception ex)
            {
                result.Error = $"Could not parse guest-exec response: {ex.Message}; raw: {stdout}";
                result.DurationSeconds = sw.Elapsed.TotalSeconds;
                return result;
            }

            // 2) Poll guest-exec-status until the process has exited or we time out.
            var deadline = DateTime.UtcNow.AddSeconds(Math.Max(1, cfg.TimeoutSeconds));
            while (DateTime.UtcNow < deadline)
            {
                if (ct.IsCancellationRequested) break;

                var statusPayload = new JsonObject
                {
                    ["execute"] = "guest-exec-status",
                    ["arguments"] = new JsonObject { ["pid"] = pid }
                }.ToJsonString();

                var (sout, serr, sexit) = await RunVirshAsync(cfg.VmName, statusPayload, ct);
                if (sexit != 0)
                {
                    result.Error = $"virsh status check failed (exit {sexit}): {serr.Trim()}";
                    result.DurationSeconds = sw.Elapsed.TotalSeconds;
                    return result;
                }

                try
                {
                    using var doc = JsonDocument.Parse(sout);
                    var ret = doc.RootElement.GetProperty("return");
                    if (ret.TryGetProperty("exited", out var exitedProp) && exitedProp.GetBoolean())
                    {
                        if (ret.TryGetProperty("exitcode", out var ec)) result.ExitCode = ec.GetInt32();
                        if (ret.TryGetProperty("out-data", out var od))
                            result.Stdout = SafeDecodeBase64(od.GetString());
                        if (ret.TryGetProperty("err-data", out var ed))
                            result.Stderr = SafeDecodeBase64(ed.GetString());
                        result.Success = result.ExitCode == 0;
                        if (!result.Success && string.IsNullOrEmpty(result.Error))
                        {
                            result.Error = $"Guest command exited with code {result.ExitCode}.";
                        }
                        result.DurationSeconds = sw.Elapsed.TotalSeconds;
                        return result;
                    }
                }
                catch (Exception ex)
                {
                    result.Error = $"Could not parse guest-exec-status: {ex.Message}; raw: {sout}";
                    result.DurationSeconds = sw.Elapsed.TotalSeconds;
                    return result;
                }

                try { await Task.Delay(500, ct); } catch (OperationCanceledException) { break; }
            }

            result.Error = $"Timed out after {cfg.TimeoutSeconds}s waiting for restart command to finish in guest.";
            result.DurationSeconds = sw.Elapsed.TotalSeconds;
            return result;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Guest agent restart failed for {Vm}", cfg.VmName);
            result.Error = ex.Message;
            result.DurationSeconds = sw.Elapsed.TotalSeconds;
            return result;
        }
    }

    private static string? SafeDecodeBase64(string? s)
    {
        if (string.IsNullOrEmpty(s)) return null;
        try { return Encoding.UTF8.GetString(Convert.FromBase64String(s)); }
        catch { return s; }
    }

    private static async Task<(string stdout, string stderr, int exitCode)> RunVirshAsync(
        string vmName, string payload, CancellationToken ct)
    {
        using var perCallCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        perCallCts.CancelAfter(TimeSpan.FromSeconds(15));

        var psi = new ProcessStartInfo
        {
            FileName = "virsh",
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        // ArgumentList side-steps shell-escaping the JSON payload.
        psi.ArgumentList.Add("qemu-agent-command");
        psi.ArgumentList.Add(vmName);
        psi.ArgumentList.Add(payload);

        using var proc = Process.Start(psi)
            ?? throw new InvalidOperationException("Failed to start virsh.");

        var stdoutTask = proc.StandardOutput.ReadToEndAsync();
        var stderrTask = proc.StandardError.ReadToEndAsync();
        try
        {
            await proc.WaitForExitAsync(perCallCts.Token);
        }
        catch (OperationCanceledException)
        {
            try { proc.Kill(entireProcessTree: true); } catch { /* ignore */ }
            throw new TimeoutException("virsh qemu-agent-command timed out.");
        }

        return (await stdoutTask, await stderrTask, proc.ExitCode);
    }
}
