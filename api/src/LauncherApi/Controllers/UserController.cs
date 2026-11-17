using System.Security.Claims;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace LauncherApi.Controllers;

[ApiController]
[Route("api/[controller]")]
public class UserController : ControllerBase
{
    private readonly IConfiguration _configuration;
    private readonly IAuthorizationService _authorization;

    public UserController(IConfiguration configuration, IAuthorizationService authorization)
    {
        _configuration = configuration;
        _authorization = authorization;
    }

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
            groups = GetGroups(),
            claims = User.Claims.Select(c => new
            {
                type = c.Type,
                value = c.Value
            })
        });
    }

    /// <summary>
    /// Returns the caller's FreeIPA groups and which policies those groups
    /// satisfy. The launcher can call this once at startup and grey out the
    /// actions that come back false, instead of discovering the 403 after the
    /// user clicks.
    /// </summary>
    [HttpGet("groups")]
    public async Task<IActionResult> GetGroupsAndPermissions()
    {
        var policies = _configuration.GetSection("Authorization:Policies")
            .Get<Dictionary<string, string[]>>() ?? new Dictionary<string, string[]>();

        var permissions = new Dictionary<string, bool>();
        foreach (var name in policies.Keys.OrderBy(k => k))
        {
            permissions[name] = (await _authorization.AuthorizeAsync(User, name)).Succeeded;
        }

        return Ok(new
        {
            user = User.Identity?.Name,
            groups = GetGroups(),
            permissions
        });
    }

    /// <summary>FreeIPA groups added to the principal by the claims transformation.</summary>
    private List<string> GetGroups() =>
        User.FindAll(ClaimTypes.Role).Select(c => c.Value).ToList();
}
