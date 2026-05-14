using LauncherApi.Models;
using LauncherApi.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace LauncherApi.Controllers;

// Endpoints are AllowAnonymous so the YARA management quick-use button can
// reach the API even when the launcher is pointed at a standalone server
// without Kerberos. Remove [AllowAnonymous] to require Negotiate auth.
[ApiController]
[Route("api/yara")]
[AllowAnonymous]
public class YaraController : ControllerBase
{
    private readonly YaraService _yara;

    public YaraController(YaraService yara)
    {
        _yara = yara;
    }

    [HttpGet("rules")]
    public IActionResult ListRules()
    {
        var rules = _yara.ListRules();
        return Ok(new
        {
            directory = _yara.RulesDirectory,
            count = rules.Count,
            rules
        });
    }

    [HttpGet("rules/{filename}")]
    public IActionResult GetRule(string filename)
    {
        if (!_yara.TryReadRule(filename, out var content, out var error))
        {
            return NotFound(new { error });
        }
        return Ok(content);
    }

    [HttpPost("rules")]
    public IActionResult UploadRule([FromBody] YaraRuleUpload upload)
    {
        if (upload is null || string.IsNullOrWhiteSpace(upload.Name))
        {
            return BadRequest(new { error = "Missing rule name." });
        }

        var result = _yara.WriteRule(upload, out var error);
        return result switch
        {
            YaraService.WriteResult.Created
                => Created($"/api/yara/rules/{upload.Name}", new { name = upload.Name, status = "created" }),
            YaraService.WriteResult.Updated
                => Ok(new { name = upload.Name, status = "updated" }),
            YaraService.WriteResult.ConflictExists
                => Conflict(new { name = upload.Name, error = "File already exists. Set overwrite=true to replace it." }),
            YaraService.WriteResult.InvalidName
                => BadRequest(new { error }),
            YaraService.WriteResult.TooLarge
                => StatusCode(StatusCodes.Status413PayloadTooLarge, new { error }),
            _ => StatusCode(StatusCodes.Status500InternalServerError, new { error = "Unknown error." })
        };
    }

    [HttpDelete("rules/{filename}")]
    public IActionResult DeleteRule(string filename)
    {
        if (!_yara.DeleteRule(filename, out var error))
        {
            return NotFound(new { error });
        }
        return NoContent();
    }
}
