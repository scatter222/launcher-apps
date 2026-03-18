using Microsoft.AspNetCore.Mvc;

namespace LauncherApi.Controllers;

[ApiController]
[Route("api/[controller]")]
public class UserController : ControllerBase
{
    /// <summary>
    /// Returns the authenticated user's identity info from their Kerberos ticket.
    /// </summary>
    [HttpGet]
    public IActionResult Get()
    {
        var identity = User.Identity;

        if (identity is null || !identity.IsAuthenticated)
        {
            return Unauthorized(new { error = "Not authenticated" });
        }

        return Ok(new
        {
            name = identity.Name,
            authenticationType = identity.AuthenticationType,
            isAuthenticated = identity.IsAuthenticated,
            claims = User.Claims.Select(c => new
            {
                type = c.Type,
                value = c.Value
            })
        });
    }
}
