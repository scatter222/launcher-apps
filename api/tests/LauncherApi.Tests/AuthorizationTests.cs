using System.Security.Claims;
using LauncherApi.Authorization;
using LauncherApi.Configuration;
using LauncherApi.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace LauncherApi.Tests;

public class LdapParsingTests
{
    [Theory]
    [InlineData("testuser@LAB.FORGE.LOCAL", "testuser")]
    [InlineData("TestUser@lab.forge.local", "testuser")]
    [InlineData("LAB\\testuser", "testuser")]
    [InlineData("testuser", "testuser")]
    [InlineData("", "")]
    public void NormalizeUsername_strips_the_realm(string input, string expected)
    {
        Assert.Equal(expected, IpaGroupService.NormalizeUsername(input));
    }

    [Fact]
    public void GroupNameFromDn_returns_the_leftmost_rdn()
    {
        Assert.Equal("launcher-admins",
            IpaGroupService.GroupNameFromDn("cn=launcher-admins,cn=groups,cn=accounts,dc=lab,dc=forge,dc=local"));
    }

    [Fact]
    public void EscapeFilterValue_neutralises_filter_metacharacters()
    {
        // Unescaped, "*)(uid=admin" would turn the uid filter into an injection.
        Assert.Equal("\\2a\\29\\28uid=admin", IpaGroupService.EscapeFilterValue("*)(uid=admin"));
    }

    [Fact]
    public void BaseDn_is_derived_from_the_realm_when_unset()
    {
        var options = new FreeIpaOptions { Realm = "LAB.FORGE.LOCAL", BaseDn = string.Empty };

        Assert.Equal("dc=lab,dc=forge,dc=local", options.ResolveBaseDn());
        Assert.Equal("cn=groups,cn=accounts,dc=lab,dc=forge,dc=local",
            options.ResolveContainer("cn=groups,cn=accounts"));
    }
}

public class ClaimsTransformationTests
{
    /// <summary>Stands in for the LDAP lookup.</summary>
    private class StubGroupService : IIpaGroupService
    {
        private readonly string[] _groups;

        public StubGroupService(params string[] groups) => _groups = groups;

        public Task<IReadOnlyList<string>> GetGroupsAsync(string principal) =>
            Task.FromResult<IReadOnlyList<string>>(_groups);
    }

    private static ClaimsPrincipal Authenticated(string name) =>
        new(new ClaimsIdentity(new[] { new Claim(ClaimTypes.Name, name) }, "Negotiate"));

    [Fact]
    public async Task Groups_become_role_claims()
    {
        var transformation = new IpaGroupsClaimsTransformation(new StubGroupService("launcher-vm-users"));

        var principal = await transformation.TransformAsync(Authenticated("testuser@LAB.FORGE.LOCAL"));

        Assert.True(principal.IsInRole("launcher-vm-users"));
        Assert.False(principal.IsInRole("launcher-admins"));
    }

    [Fact]
    public async Task Running_twice_does_not_duplicate_claims()
    {
        var transformation = new IpaGroupsClaimsTransformation(new StubGroupService("launcher-users"));

        var once = await transformation.TransformAsync(Authenticated("testuser"));
        var twice = await transformation.TransformAsync(once);

        Assert.Single(twice.FindAll(ClaimTypes.Role));
    }

    [Fact]
    public async Task An_anonymous_principal_is_left_alone()
    {
        var transformation = new IpaGroupsClaimsTransformation(new StubGroupService("launcher-admins"));

        var principal = await transformation.TransformAsync(new ClaimsPrincipal(new ClaimsIdentity()));

        Assert.Empty(principal.FindAll(ClaimTypes.Role));
    }
}

public class PolicyTests
{
    /// <summary>Registers the configured policies the same way Program.cs does.</summary>
    private static IAuthorizationService BuildAuthorizationService()
    {
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Authorization:Policies:vm.manage:0"] = "launcher-vm-users",
                ["Authorization:Policies:vm.manage:1"] = "launcher-admins"
            })
            .Build();

        var policies = configuration.GetSection("Authorization:Policies").Get<Dictionary<string, string[]>>()!;

        var services = new ServiceCollection();
        services.AddLogging();
        services.AddAuthorization(options =>
        {
            foreach (var (name, groups) in policies)
                options.AddPolicy(name, policy => policy.RequireRole(groups));
        });

        return services.BuildServiceProvider().GetRequiredService<IAuthorizationService>();
    }

    private static ClaimsPrincipal UserInGroups(params string[] groups) =>
        new(new ClaimsIdentity(groups.Select(g => new Claim(ClaimTypes.Role, g)), "Negotiate"));

    [Theory]
    [InlineData("launcher-vm-users", true)]
    [InlineData("launcher-admins", true)]
    [InlineData("launcher-users", false)]
    public async Task A_policy_is_satisfied_by_any_of_its_groups(string group, bool expected)
    {
        var result = await BuildAuthorizationService().AuthorizeAsync(UserInGroups(group), "vm.manage");

        Assert.Equal(expected, result.Succeeded);
    }

    [Fact]
    public async Task A_user_with_no_groups_is_denied()
    {
        var result = await BuildAuthorizationService().AuthorizeAsync(UserInGroups(), "vm.manage");

        Assert.False(result.Succeeded);
    }
}
