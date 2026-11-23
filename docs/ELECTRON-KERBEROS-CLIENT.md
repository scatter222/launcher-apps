# Electron client: sending the Kerberos ticket

**You do not send the ticket.** Chromium's network stack does the whole SPNEGO
exchange for you: it gets the 401, asks the KDC for a service ticket, and
retries with an `Authorization: Negotiate` header. Your code never touches a
token, a keytab or a credentials cache.

What you do instead is four things: turn the behaviour on with two command-line
switches, make requests through **Chromium's** HTTP stack rather than Node's,
trust the server's certificate, and make sure the user has a ticket.

Substitute `api.example.com` and `example.com` for your own names.

---

## 1. The two switches

These must be set **before the app is ready**, at the very top of the main
process entry point. Setting them later silently does nothing.

```ts
// main.ts, before app.whenReady()
import { app } from 'electron'

const DOMAIN = 'example.com'

// Modern Chromium name
app.commandLine.appendSwitch('auth-server-allowlist', `*.${DOMAIN}`)
app.commandLine.appendSwitch('auth-negotiate-delegate-allowlist', `*.${DOMAIN}`)

// Older Electron builds used these names; harmless to set both
app.commandLine.appendSwitch('auth-server-whitelist', `*.${DOMAIN}`)
app.commandLine.appendSwitch('auth-negotiate-delegate-whitelist', `*.${DOMAIN}`)
```

`auth-server-allowlist` is the one that matters. Without it Chromium will not
attempt Negotiate at all, and your app sees a bare 401.

`auth-negotiate-delegate-allowlist` forwards the user's credentials onward so
the API can act as them against another service. If the API reads groups with
its own keytab, which is the usual design, **you do not need delegation**. It
gets cargo-culted into configs; set it only if something downstream requires it.

The pattern is matched against the URL's hostname. **An IP address never
matches**, so a request to `https://10.0.0.5/...` gets no token no matter what
you configure.

---

## 2. Use Chromium's HTTP stack, not Node's

This is the mistake that costs the most time. Electron has two completely
separate networking paths, and only one of them does Kerberos:

| How you call | Stack | Negotiate |
| --- | --- | --- |
| `net.fetch` / `net.request` in the main process | Chromium | **Yes** |
| `fetch` / `XMLHttpRequest` in a renderer | Chromium | **Yes** |
| `axios`, `node-fetch`, `http`, `https` in the main process | Node | **No, never** |

Node's HTTP client knows nothing about the allowlist or GSSAPI. If your IPC
handlers use `axios`, no amount of switch-tweaking will help.

The clean version is `net.fetch`, which is a normal Fetch API over Chromium's
stack:

```ts
// main.ts
import { app, net, ipcMain } from 'electron'

const API_BASE = 'https://api.example.com:9444'

// Only allow the paths the app actually uses, so a compromised renderer
// cannot turn this handler into a general-purpose proxy.
const ALLOWED = /^\/api\/(user|session|tools|vms)(\/|$)/

ipcMain.handle('api:get', async (_event, path: string) => {
  if (!ALLOWED.test(path)) throw new Error(`blocked path: ${path}`)

  const response = await net.fetch(`${API_BASE}${path}`)
  return {
    status: response.status,
    body: response.ok ? await response.json() : await response.text()
  }
})
```

On Electron older than 25 there is no `net.fetch`, so use `net.request`:

```ts
function apiGet(path: string): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const request = net.request({ method: 'GET', url: `${API_BASE}${path}` })
    let body = ''
    request.on('response', (response) => {
      response.on('data', (chunk) => { body += chunk.toString() })
      response.on('end', () => resolve({ status: response.statusCode, body }))
    })
    request.on('error', reject)
    request.end()
  })
}
```

Expose it to the renderer through a preload bridge rather than enabling node
integration:

```ts
// preload.ts
import { contextBridge, ipcRenderer } from 'electron'

contextBridge.exposeInMainWorld('api', {
  get: (path: string) => ipcRenderer.invoke('api:get', path)
})
```

```ts
// renderer
const { body } = await window.api.get('/api/user/groups')
console.log(body.groups, body.permissions)
```

Calling `fetch` directly from the renderer also works, since that is Chromium
too. Going through the main process is worth it for the path allowlist and for
keeping the base URL in one place.

---

## 3. Trust the certificate

A self-signed certificate fails before authentication is even attempted, which
looks like an auth problem.

**Do it properly on the workstation.** Install the FreeIPA CA into the system
trust store, which Chromium on RHEL-family Linux reads through p11-kit:

```bash
sudo cp /etc/ipa/ca.crt /etc/pki/ca-trust/source/anchors/ipa-ca.crt
sudo update-ca-trust extract
```

Better still, replace the self-signed certificate with one issued by FreeIPA's
own CA, so the whole realm already trusts it.

**If you must do it in the app**, pin it narrowly. For `net.fetch` and
`net.request` the hook is the session's verify proc, not the
`certificate-error` event, which only fires for page loads:

```ts
import { app, session } from 'electron'

const API_HOST = 'api.example.com'

app.whenReady().then(() => {
  session.defaultSession.setCertificateVerifyProc((request, callback) => {
    if (request.hostname === API_HOST) {
      callback(0)      // 0 = trust this one
    } else {
      callback(-3)     // -3 = use Chromium's own verdict
    }
  })
})
```

Two things not to do. Do not call `callback(0)` unconditionally, which disables
TLS verification for every host the app ever contacts. And do not set
`NODE_TLS_REJECT_UNAUTHORIZED=0`: it only affects Node's TLS, so it does
nothing for Chromium requests while still weakening anything Node does.

---

## 4. The user needs a ticket

The app uses the logged-in user's credentials cache. On a domain-joined
workstation with SSSD, the graphical login obtains a TGT automatically, so
there is nothing to do. It breaks when the app is launched from a session that
has no ticket, such as over SSH, or from a service account.

```bash
klist          # before launching: expect krbtgt/EXAMPLE.COM@EXAMPLE.COM
kinit jsmith   # if there is none
```

Nothing in the app can create a ticket, and it should not try.

---

## What success looks like

Your code only ever sees the final response. The 401 and the retry happen
inside Chromium and never reach you.

The proof is in the user's ticket cache. After the first request:

```bash
klist
```

```
Default principal: jsmith@EXAMPLE.COM

Valid starting       Expires              Service principal
11/23/26 09:14:02    11/24/26 09:13:58    krbtgt/EXAMPLE.COM@EXAMPLE.COM
11/23/26 09:14:05    11/24/26 09:13:58    HTTP/api.example.com@EXAMPLE.COM
```

That second line is the service ticket Chromium fetched. If it is absent, no
Negotiate attempt was made.

---

## When it does not work

Check in this order.

**1. Does `curl` work from the same workstation, as the same user?**

```bash
kinit jsmith
curl -k --negotiate -u : https://api.example.com:9444/api/user
```

If `curl` fails, the problem is not Electron. Go to
[KERBEROS-TROUBLESHOOTING.md](KERBEROS-TROUBLESHOOTING.md).

If `curl` works and Electron does not, it is one of the next three.

**2. Are you using a Node HTTP client?** Search the app for `axios`,
`node-fetch`, `require('https')`. Any of those in the request path means no
Kerberos, ever. This is the most common cause.

**3. Is the URL a hostname?** An IP address never matches the allowlist. Check
`config/api.yaml` or wherever the base URL lives.

**4. Were the switches set before the app was ready?** They must be at the top
of the main entry point, before `app.whenReady()`. Confirm what Chromium
actually got:

```ts
console.log(app.commandLine.getSwitchValue('auth-server-allowlist'))
```

### Reading the symptom

| What the app sees | Cause |
| --- | --- |
| 401, no service ticket in `klist` | Chromium never attempted Negotiate: allowlist, or an IP in the URL |
| 401, service ticket **is** in `klist` | The ticket was sent and the server rejected it. Server-side keytab problem. |
| `ERR_CERT_AUTHORITY_INVALID` | Certificate trust, section 3 |
| 403 with a JSON body | Authentication worked. This is authorization: the user lacks the group. |
| 401 only from the main process | A Node HTTP client is in use there |

A 403 is good news. It means the whole Kerberos path succeeded and the API is
telling you the user's groups do not satisfy the policy.

### Verbose logging

```bash
ELECTRON_ENABLE_LOGGING=1 ./launcher --log-net-log=/tmp/netlog.json
KRB5_TRACE=/dev/stderr ELECTRON_ENABLE_LOGGING=1 ./launcher
```

`KRB5_TRACE` is the useful one: it prints which service principal the client
asked the KDC for, which immediately shows an IP or a wrong name.

---

## Driving the UI from the user's groups

`GET /api/user/groups` returns the groups and a verdict per policy, so the app
can disable what the user cannot do instead of letting them click into a 403:

```ts
const { body } = await window.api.get('/api/user/groups')
// body.permissions: { "vm.manage": false, "vm.view": true, ... }
setCanManageVms(body.permissions['vm.manage'] === true)
```

Call it once after the connection is established and cache it for the session.
Treat it as a hint for presentation only. The API enforces the same policies on
every request regardless of what the client believes.
