using System.DirectoryServices.Protocols;
using System.Text;
using LauncherApi.Configuration;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Options;

namespace LauncherApi.Services;

/// <summary>Resolves the FreeIPA groups a Kerberos principal belongs to.</summary>
public interface IIpaGroupService
{
    /// <summary>
    /// Group names for <paramref name="principal"/>, which may be a bare login
    /// name or <c>user@REALM</c>. Returns an empty list if the user has no
    /// groups or the directory cannot be reached.
    /// </summary>
    Task<IReadOnlyList<string>> GetGroupsAsync(string principal);
}

/// <summary>
/// Reads group membership from FreeIPA's 389-DS directory over LDAP.
/// </summary>
/// <remarks>
/// FreeIPA runs MIT Kerberos and issues no PAC, so the ticket that authenticated
/// the caller carries no group information. One LDAP search of the user entry
/// returns <c>memberOf</c>, which FreeIPA keeps fully expanded, so nested groups
/// are already included. The bind is SASL/GSSAPI using the API host's own
/// Kerberos credentials, so no directory password is stored anywhere.
/// </remarks>
public class IpaGroupService : IIpaGroupService
{
    private readonly FreeIpaOptions _options;
    private readonly IMemoryCache _cache;
    private readonly ILogger<IpaGroupService> _logger;

    public IpaGroupService(IOptions<FreeIpaOptions> options, IMemoryCache cache, ILogger<IpaGroupService> logger)
    {
        _options = options.Value;
        _cache = cache;
        _logger = logger;
    }

    public async Task<IReadOnlyList<string>> GetGroupsAsync(string principal)
    {
        var username = NormalizeUsername(principal);
        if (string.IsNullOrEmpty(username))
            return Array.Empty<string>();

        if (_cache.TryGetValue($"ipa:{username}", out IReadOnlyList<string>? cached) && cached is not null)
            return cached;

        IReadOnlyList<string> groups;
        try
        {
            groups = await Task.Run(() => Search(username));
        }
        catch (Exception ex)
        {
            // Fail closed: no groups means group-gated endpoints deny.
            _logger.LogError(ex, "FreeIPA group lookup failed for {User} against {Uri}", username, _options.LdapUri);
            return Array.Empty<string>();
        }

        _cache.Set($"ipa:{username}", groups, TimeSpan.FromSeconds(_options.CacheSeconds));
        return groups;
    }

    private IReadOnlyList<string> Search(string username)
    {
        var uri = new Uri(_options.LdapUri);
        var useSsl = uri.Scheme.Equals("ldaps", StringComparison.OrdinalIgnoreCase);
        var port = uri.IsDefaultPort ? (useSsl ? 636 : 389) : uri.Port;

        using var connection = new LdapConnection(new LdapDirectoryIdentifier(uri.Host, port))
        {
            Timeout = TimeSpan.FromSeconds(_options.TimeoutSeconds),
            AuthType = AuthType.Negotiate
        };

        connection.SessionOptions.ProtocolVersion = 3;
        connection.SessionOptions.SecureSocketLayer = useSsl;
        connection.Bind();

        var request = new SearchRequest(
            _options.ResolveContainer(_options.UserSearchBase),
            $"(&(objectClass=posixaccount)(uid={EscapeFilterValue(username)}))",
            SearchScope.Subtree,
            "memberOf");

        var response = (SearchResponse)connection.SendRequest(request, TimeSpan.FromSeconds(_options.TimeoutSeconds));
        if (response.Entries.Count == 0)
        {
            _logger.LogWarning("No FreeIPA entry found for {User}", username);
            return Array.Empty<string>();
        }

        var groupContainer = _options.ResolveContainer(_options.GroupSearchBase);
        var memberOf = response.Entries[0].Attributes["memberOf"];

        var groups = (memberOf?.GetValues(typeof(string)) ?? Array.Empty<object>())
            .OfType<string>()
            .Where(dn => dn.EndsWith(groupContainer, StringComparison.OrdinalIgnoreCase))
            .Select(GroupNameFromDn)
            .OfType<string>()
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(name => name)
            .ToList();

        _logger.LogDebug("Resolved {User} to groups: {Groups}", username, string.Join(", ", groups));
        return groups;
    }

    /// <summary><c>testuser@LAB.FORGE.LOCAL</c> and <c>LAB\testuser</c> both become <c>testuser</c>.</summary>
    public static string NormalizeUsername(string principal)
    {
        if (string.IsNullOrWhiteSpace(principal))
            return string.Empty;

        var value = principal.Trim();

        var slash = value.LastIndexOf('\\');
        if (slash >= 0)
            value = value[(slash + 1)..];

        var at = value.IndexOf('@');
        if (at >= 0)
            value = value[..at];

        return value.ToLowerInvariant();
    }

    /// <summary><c>cn=launcher-admins,cn=groups,...</c> becomes <c>launcher-admins</c>.</summary>
    public static string? GroupNameFromDn(string distinguishedName)
    {
        var rdn = distinguishedName.Split(',')[0];
        var equals = rdn.IndexOf('=');

        return equals < 0 || equals == rdn.Length - 1 ? null : rdn[(equals + 1)..].Trim();
    }

    /// <summary>Escapes a value for use inside an LDAP filter (RFC 4515).</summary>
    public static string EscapeFilterValue(string value)
    {
        var builder = new StringBuilder(value.Length);
        foreach (var c in value)
        {
            builder.Append(c switch
            {
                '\\' => "\\5c",
                '*' => "\\2a",
                '(' => "\\28",
                ')' => "\\29",
                '\0' => "\\00",
                _ => c.ToString()
            });
        }

        return builder.ToString();
    }
}
