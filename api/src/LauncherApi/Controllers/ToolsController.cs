using Microsoft.AspNetCore.Mvc;
using LauncherApi.Services;

namespace LauncherApi.Controllers;

[ApiController]
[Route("api/[controller]")]
public class ToolsController : ControllerBase
{
    private readonly ToolsService _tools;

    public ToolsController(ToolsService tools)
    {
        _tools = tools;
    }

    /// <summary>
    /// Returns the tool catalog so users can explore what is available across
    /// the lab's analysis VMs. This is informational only — tools are not
    /// launched from here; each runs on its own system (see the `system` field).
    /// Optional query filters: <c>?system=</c> and <c>?category=</c>.
    /// </summary>
    [HttpGet]
    public IActionResult GetTools([FromQuery] string? system = null, [FromQuery] string? category = null)
    {
        var tools = _tools.GetTools(system, category);

        return Ok(new
        {
            user = User.Identity?.Name,
            systems = _tools.GetSystems(),
            count = tools.Count,
            tools
        });
    }

    /// <summary>
    /// Returns the list of systems/VMs that host tools.
    /// </summary>
    [HttpGet("systems")]
    public IActionResult GetSystems()
    {
        return Ok(new
        {
            user = User.Identity?.Name,
            systems = _tools.GetSystems()
        });
    }
}
