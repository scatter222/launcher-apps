namespace LauncherApi.Authorization;

/// <summary>
/// Policy names used by the controllers. Each maps to a list of FreeIPA groups
/// in the <c>Authorization:Policies</c> configuration section; membership of any
/// listed group satisfies the policy.
/// </summary>
public static class LauncherPolicies
{
    public const string VmView = "vm.view";
    public const string VmManage = "vm.manage";
    public const string ToolsView = "tools.view";
    public const string ToolsLaunch = "tools.launch";
}
