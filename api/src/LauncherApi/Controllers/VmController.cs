using LauncherApi.Models;
using LauncherApi.Services;
using Microsoft.AspNetCore.Mvc;

namespace LauncherApi.Controllers;

[ApiController]
[Route("api/vms")]
public class VmController : ControllerBase
{
    private readonly VmService _vmService;

    public VmController(VmService vmService)
    {
        _vmService = vmService;
    }

    private string GetOwner() => User.Identity?.Name ?? "anonymous";

    [HttpGet("templates")]
    public ActionResult<List<VmTemplate>> GetTemplates()
    {
        return Ok(_vmService.GetTemplates());
    }

    [HttpGet("instances")]
    public async Task<ActionResult<List<VmInstance>>> GetInstances()
    {
        var instances = await _vmService.GetUserInstances(GetOwner());
        return Ok(instances);
    }

    [HttpPost("instances")]
    public async Task<ActionResult<VmInstance>> CreateInstance([FromBody] CreateInstanceRequest request)
    {
        try
        {
            var instance = await _vmService.CreateInstance(GetOwner(), request.TemplateId);
            return CreatedAtAction(nameof(GetInstances), instance);
        }
        catch (ArgumentException ex)
        {
            return BadRequest(new { error = ex.Message });
        }
        catch (InvalidOperationException ex)
        {
            return Conflict(new { error = ex.Message });
        }
        catch (FileNotFoundException ex)
        {
            return NotFound(new { error = ex.Message });
        }
    }

    [HttpPost("instances/{id}/start")]
    public async Task<IActionResult> StartInstance(string id)
    {
        try
        {
            await _vmService.StartInstance(GetOwner(), id);
            return Ok(new { success = true });
        }
        catch (KeyNotFoundException ex)
        {
            return NotFound(new { error = ex.Message });
        }
    }

    [HttpPost("instances/{id}/stop")]
    public async Task<IActionResult> StopInstance(string id)
    {
        try
        {
            await _vmService.StopInstance(GetOwner(), id);
            return Ok(new { success = true });
        }
        catch (KeyNotFoundException ex)
        {
            return NotFound(new { error = ex.Message });
        }
    }

    [HttpPost("instances/{id}/restart")]
    public async Task<IActionResult> RestartInstance(string id)
    {
        try
        {
            await _vmService.RestartInstance(GetOwner(), id);
            return Ok(new { success = true });
        }
        catch (KeyNotFoundException ex)
        {
            return NotFound(new { error = ex.Message });
        }
    }

    [HttpDelete("instances/{id}")]
    public async Task<IActionResult> DeleteInstance(string id)
    {
        try
        {
            await _vmService.DeleteInstance(GetOwner(), id);
            return Ok(new { success = true });
        }
        catch (KeyNotFoundException ex)
        {
            return NotFound(new { error = ex.Message });
        }
    }

    [HttpGet("instances/{id}/console")]
    public async Task<ActionResult<ConsoleInfo>> GetConsole(string id)
    {
        try
        {
            var console = await _vmService.GetConsoleInfo(GetOwner(), id);
            return Ok(console);
        }
        catch (KeyNotFoundException ex)
        {
            return NotFound(new { error = ex.Message });
        }
    }
}
