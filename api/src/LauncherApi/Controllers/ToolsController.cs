using Microsoft.AspNetCore.Mvc;
using LauncherApi.Models;

namespace LauncherApi.Controllers;

[ApiController]
[Route("api/[controller]")]
public class ToolsController : ControllerBase
{
    /// <summary>
    /// Returns available tools for the authenticated user.
    /// </summary>
    [HttpGet]
    public IActionResult GetTools()
    {
        // TODO: Source from database or config in future
        var tools = new[]
        {
            new ToolInfo { Id = "nmap", Name = "Nmap", Category = "Reconnaissance", Available = true },
            new ToolInfo { Id = "metasploit", Name = "Metasploit", Category = "Exploitation", Available = true },
            new ToolInfo { Id = "wireshark", Name = "Wireshark", Category = "Digital Forensics", Available = true },
            new ToolInfo { Id = "burpsuite", Name = "Burp Suite", Category = "Web Security", Available = true },
            new ToolInfo { Id = "ghidra", Name = "Ghidra", Category = "Reverse Engineering", Available = true },
        };

        return Ok(new
        {
            user = User.Identity?.Name,
            tools
        });
    }

    /// <summary>
    /// Log a tool launch event for the authenticated user.
    /// </summary>
    [HttpPost("{id}/launch")]
    public IActionResult LaunchTool(string id)
    {
        var userName = User.Identity?.Name ?? "unknown";

        // TODO: Persist audit log to database
        var auditEntry = new
        {
            toolId = id,
            user = userName,
            timestamp = DateTime.UtcNow,
            action = "launch"
        };

        return Ok(new
        {
            message = $"Tool launch '{id}' recorded for user '{userName}'",
            audit = auditEntry
        });
    }
}
