using System.Security.Claims;
using LauncherApi.Services;
using Microsoft.AspNetCore.Authentication;

namespace LauncherApi.Authorization;

/// <summary>
/// Runs after Negotiate authentication and adds the caller's FreeIPA groups to
/// the principal as role claims, so <c>[Authorize(Policy = ...)]</c> and
/// <c>[Authorize(Roles = ...)]</c> both work against group names.
/// </summary>
public class IpaGroupsClaimsTransformation : IClaimsTransformation
{
    /// <summary>Marker claim proving the transformation already ran for this principal.</summary>
    public const string ResolvedClaim = "ipa:groups-resolved";

    private readonly IIpaGroupService _groups;

    public IpaGroupsClaimsTransformation(IIpaGroupService groups) => _groups = groups;

    public async Task<ClaimsPrincipal> TransformAsync(ClaimsPrincipal principal)
    {
        if (principal.Identity is not { IsAuthenticated: true })
            return principal;

        // TransformAsync can be called more than once per request.
        if (principal.HasClaim(c => c.Type == ResolvedClaim))
            return principal;

        var groups = await _groups.GetGroupsAsync(principal.Identity.Name ?? string.Empty);

        var identity = new ClaimsIdentity();
        identity.AddClaim(new Claim(ResolvedClaim, "true"));
        foreach (var group in groups)
            identity.AddClaim(new Claim(ClaimTypes.Role, group));

        principal.AddIdentity(identity);
        return principal;
    }
}
