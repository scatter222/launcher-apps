using LauncherApi.Models;
using LauncherApi.Services;
using Microsoft.AspNetCore.Authentication.Negotiate;

var builder = WebApplication.CreateBuilder(args);

// Add Negotiate (Kerberos/SPNEGO) authentication
builder.Services.AddAuthentication(NegotiateDefaults.AuthenticationScheme)
    .AddNegotiate();

builder.Services.AddAuthorization(options =>
{
    // Require authenticated users by default on all endpoints
    options.FallbackPolicy = options.DefaultPolicy;
});

builder.Services.AddSingleton<VmService>();

// Detection-rules service (Suricata, YARA, Zeek, ...) - configured via the
// "RuleSets" array in appsettings.json.
var ruleSets = builder.Configuration
    .GetSection("RuleSets")
    .Get<List<RuleSetConfig>>() ?? new List<RuleSetConfig>();
builder.Services.AddSingleton<IReadOnlyList<RuleSetConfig>>(ruleSets);
builder.Services.AddSingleton<RulesService>();

builder.Services.AddControllers();

var app = builder.Build();

app.UseAuthentication();
app.UseAuthorization();

app.MapControllers();

app.Run();
