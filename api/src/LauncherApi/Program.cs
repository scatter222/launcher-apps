using LauncherApi.Authorization;
using LauncherApi.Configuration;
using LauncherApi.Services;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Negotiate;

var builder = WebApplication.CreateBuilder(args);

// Negotiate (Kerberos/SPNEGO) establishes *who* the caller is.
builder.Services.AddAuthentication(NegotiateDefaults.AuthenticationScheme)
    .AddNegotiate();

// FreeIPA answers *what they may do*: group membership read over LDAP and
// added to the principal as role claims.
builder.Services.Configure<FreeIpaOptions>(builder.Configuration.GetSection(FreeIpaOptions.SectionName));
builder.Services.AddMemoryCache();
builder.Services.AddSingleton<IIpaGroupService, IpaGroupService>();
builder.Services.AddTransient<IClaimsTransformation, IpaGroupsClaimsTransformation>();

// Each policy in Authorization:Policies lists the FreeIPA groups that satisfy
// it; membership of any one is enough.
var policies = builder.Configuration.GetSection("Authorization:Policies")
    .Get<Dictionary<string, string[]>>() ?? new Dictionary<string, string[]>();

builder.Services.AddAuthorization(options =>
{
    // Require an authenticated user by default on all endpoints.
    options.FallbackPolicy = options.DefaultPolicy;

    foreach (var (name, groups) in policies)
        options.AddPolicy(name, policy => policy.RequireRole(groups));
});

builder.Services.AddSingleton<VmService>();
builder.Services.AddControllers();

var app = builder.Build();

app.UseAuthentication();
app.UseAuthorization();

app.MapControllers();

app.Run();
