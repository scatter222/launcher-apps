namespace LauncherApi.Configuration;

/// <summary>Binds the <c>FreeIpa</c> configuration section.</summary>
public class FreeIpaOptions
{
    public const string SectionName = "FreeIpa";

    /// <summary>LDAP URI of the FreeIPA directory.</summary>
    public string LdapUri { get; set; } = "ldaps://idm.lab.forge.local:636";

    /// <summary>Kerberos realm, used to derive <see cref="BaseDn"/> when it is empty.</summary>
    public string Realm { get; set; } = "LAB.FORGE.LOCAL";

    /// <summary>Directory base DN. Empty means derive it from <see cref="Realm"/>.</summary>
    public string BaseDn { get; set; } = string.Empty;

    /// <summary>Container holding user entries, relative to the base DN.</summary>
    public string UserSearchBase { get; set; } = "cn=users,cn=accounts";

    /// <summary>Container holding groups. Used to pick groups out of <c>memberOf</c>.</summary>
    public string GroupSearchBase { get; set; } = "cn=groups,cn=accounts";

    /// <summary>How long a lookup is cached.</summary>
    public int CacheSeconds { get; set; } = 300;

    public int TimeoutSeconds { get; set; } = 10;

    /// <summary>LAB.FORGE.LOCAL becomes dc=lab,dc=forge,dc=local.</summary>
    public string ResolveBaseDn() =>
        string.IsNullOrWhiteSpace(BaseDn)
            ? string.Join(",", Realm.Split('.', StringSplitOptions.RemoveEmptyEntries)
                .Select(part => $"dc={part.ToLowerInvariant()}"))
            : BaseDn;

    /// <summary>Appends the base DN to a relative container.</summary>
    public string ResolveContainer(string container)
    {
        var baseDn = ResolveBaseDn();
        if (string.IsNullOrWhiteSpace(container))
            return baseDn;

        return container.EndsWith(baseDn, StringComparison.OrdinalIgnoreCase)
            ? container
            : $"{container},{baseDn}";
    }
}
