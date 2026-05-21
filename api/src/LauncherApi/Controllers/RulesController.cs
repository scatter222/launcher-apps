using LauncherApi.Models;
using LauncherApi.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace LauncherApi.Controllers;

// Generic detection-rules endpoints (Suricata, YARA, Zeek, etc.). The list
// of rule sets and their on-disk directories is configured server-side in
// appsettings.json under "RuleSets".
//
// Endpoints are AllowAnonymous so the launcher can reach the API even when
// pointed at a standalone server without Kerberos. Remove [AllowAnonymous]
// to require Negotiate auth.
[ApiController]
[Route("api/rules")]
[AllowAnonymous]
public class RulesController : ControllerBase
{
    private readonly RulesService _rules;
    private readonly GuestAgentService _guestAgent;

    public RulesController(RulesService rules, GuestAgentService guestAgent)
    {
        _rules = rules;
        _guestAgent = guestAgent;
    }

    [HttpGet("sets")]
    public IActionResult ListSets()
    {
        var sets = _rules.ListSets();
        return Ok(new { count = sets.Count, sets });
    }

    [HttpGet("{setId}/files")]
    public IActionResult ListFiles(string setId)
    {
        var set = _rules.FindSet(setId);
        if (set is null) return NotFound(new { error = "Unknown rule set." });
        var files = _rules.ListFiles(setId);
        return Ok(new
        {
            set = set.Id,
            name = set.Name,
            directory = set.Directory,
            count = files.Count,
            files
        });
    }

    [HttpGet("{setId}/files/{filename}")]
    public IActionResult GetFile(string setId, string filename)
    {
        if (!_rules.TryRead(setId, filename, out var content, out var error))
        {
            return NotFound(new { error });
        }
        return Ok(content);
    }

    [HttpPost("{setId}/files")]
    public IActionResult Upload(string setId, [FromBody] RuleFileUpload upload)
    {
        if (upload is null || string.IsNullOrWhiteSpace(upload.Name))
        {
            return BadRequest(new { error = "Missing rule name." });
        }

        var result = _rules.Write(setId, upload, out var error);
        return result switch
        {
            RulesService.WriteResult.Created
                => Created($"/api/rules/{setId}/files/{upload.Name}", new { name = upload.Name, status = "created" }),
            RulesService.WriteResult.Updated
                => Ok(new { name = upload.Name, status = "updated" }),
            RulesService.WriteResult.ConflictExists
                => Conflict(new { name = upload.Name, error = "File already exists. Set overwrite=true to replace it." }),
            RulesService.WriteResult.InvalidName
                => BadRequest(new { error }),
            RulesService.WriteResult.TooLarge
                => StatusCode(StatusCodes.Status413PayloadTooLarge, new { error }),
            RulesService.WriteResult.UnknownSet
                => NotFound(new { error }),
            _ => StatusCode(StatusCodes.Status500InternalServerError, new { error = "Unknown error." })
        };
    }

    [HttpDelete("{setId}/files/{filename}")]
    public IActionResult Delete(string setId, string filename)
    {
        if (!_rules.Delete(setId, filename, out var error))
        {
            return NotFound(new { error });
        }
        return NoContent();
    }

    // Restart the rule-consuming service (Suricata, Zeek, ...) inside the
    // libvirt guest configured for this rule set, via the QEMU guest agent.
    [HttpPost("{setId}/restart")]
    public async Task<IActionResult> Restart(string setId, CancellationToken ct)
    {
        var set = _rules.FindSet(setId);
        if (set is null) return NotFound(new { error = "Unknown rule set." });
        if (set.Restart is null || string.IsNullOrWhiteSpace(set.Restart.VmName))
        {
            return BadRequest(new { error = "Restart is not configured for this rule set." });
        }

        var result = await _guestAgent.RunAsync(set.Restart, ct);
        if (result.Success) return Ok(result);
        return StatusCode(StatusCodes.Status502BadGateway, result);
    }
}
