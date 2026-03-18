using Microsoft.AspNetCore.Mvc;

namespace LauncherApi.Controllers;

[ApiController]
[Route("api/[controller]")]
public class SessionController : ControllerBase
{
    /// <summary>
    /// Returns environment and session information for the authenticated user.
    /// </summary>
    [HttpGet]
    public IActionResult Get()
    {
        return Ok(new
        {
            user = User.Identity?.Name,
            hostname = Environment.MachineName,
            environment = Environment.GetEnvironmentVariable("ASPNETCORE_ENVIRONMENT") ?? "Unknown",
            serverTime = DateTime.UtcNow,
            osVersion = Environment.OSVersion.ToString(),
            dotnetVersion = Environment.Version.ToString()
        });
    }
}
