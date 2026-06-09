using LauncherApi.Persistence;
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

// SQLite persistence layer: registers IDocumentStore, IRepository<T>, and
// IDbConnectionFactory for storing/retrieving anything across the app.
builder.Services.AddSqlitePersistence(builder.Configuration);

builder.Services.AddSingleton<VmService>();
builder.Services.AddControllers();

var app = builder.Build();

app.UseAuthentication();
app.UseAuthorization();

app.MapControllers();

app.Run();
