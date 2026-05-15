# 02 — Authentication

Grafana's auth model is unusual for a mobile target. Grafana is always the
OAuth *client* (it consumes Google / GitHub / Okta / generic OIDC and turns
the result into a session cookie). It does not expose its identity provider
to other clients — there is no documented PKCE endpoint a native app can
exchange a code at to receive a credential Grafana will accept.

This doc spells out the three credential acquisition flows we support, the
storage layout for the resulting credentials, and the request-time logic
that picks the right header.

## Credentials

A credential is one of three shapes:

```swift
enum Credential {
  case bearerToken(String)           // service-account token
  case sessionCookie(String)         // value of `grafana_session`
}
```

We don't store basic-auth `username:password` long-term. Basic-auth login
runs the password through `POST /login`, captures the resulting
`grafana_session` cookie, and stores that cookie. The password is discarded
after the request returns. Same for OIDC: we store the harvested cookie,
not the OAuth tokens.

`bearerToken` is sent as `Authorization: Bearer <token>`.
`sessionCookie` is sent as `Cookie: grafana_session=<value>`.

## Flow 1 — Service-account token (primary path)

Recommended, documented, future-proof. This is the path we steer users
toward in the UI.

### UX

```
┌─────────────────────────────────┐
│  Sign in to Grafana             │
│                                 │
│  Server URL                     │
│  [https://grafana.example.com ] │
│                                 │
│  Auth method  [Token ▾]         │
│                                 │
│  Service-account token          │
│  [glsa_••••••••••••••       ]   │
│                                 │
│  [ Help: how to create one ▾]   │
│                                 │
│        [   Continue   ]         │
└─────────────────────────────────┘
```

The "Help" disclosure shows step-by-step instructions to create a
service-account token in the Grafana UI (`Administration → Users and access
→ Service accounts → Add service account → Add token`) plus a recommendation
to use a Viewer role token if the user only intends to view, and Editor if
they want to silence alerts.

### Flow

```
[user enters URL + token, taps Continue]
       │
       ▼
   Validate URL format (http:// or https://, no path)
       │
       ▼
   GET <url>/api/user
   Header: Authorization: Bearer <token>
       │
       ├─ 200 ──► capture User { login, name, email, id }
       │         store credential in Keychain (account = host)
       │         set as active server
       │         navigate to Home
       │
       ├─ 401 ──► "Token is invalid or expired"
       ├─ 403 ──► "Token works but has no permissions"
       ├─ 404 ──► "Server URL did not respond — check the URL"
       └─ network error ──► "Could not reach <host>"
```

### Notes

- Token format hint: Grafana service-account tokens are prefixed `glsa_` in
  v10+. We don't enforce the prefix (older tokens differ; some Enterprise
  deployments rewrite them), but we use it as a heuristic for the
  paste-detection helper.
- Roles ≠ scopes. The token's permissions come from the service account's
  role (Viewer / Editor / Admin) + Enterprise RBAC role assignments. There
  is no OAuth scope parameter we can ask for at acquire-time.

## Flow 2 — Basic auth (username + password)

Common on small self-hosted OSS deployments where SSO isn't set up. The
trade-off vs token auth is real: the user has to type a password on a
phone, and the resulting credential (a cookie) has a 30-day default
lifetime so we need a sensible re-auth path.

### UX

```
┌─────────────────────────────────┐
│  Sign in to Grafana             │
│                                 │
│  Server URL                     │
│  [https://grafana.example.com ] │
│                                 │
│  Auth method  [Username ▾]      │
│                                 │
│  Username  [admin             ] │
│  Password  [••••••••••••      ] │
│                                 │
│        [   Sign in    ]         │
└─────────────────────────────────┘
```

### Flow

```
[user enters URL + username + password, taps Sign in]
       │
       ▼
   POST <url>/api/login
   Body: {"user": username, "password": password}
   Header: Content-Type: application/json
       │
       ├─ 200 ──► response sets `Set-Cookie: grafana_session=<value>; ...`
       │         extract cookie value (manually, not via HTTPCookieStorage)
       │         GET /api/user with Cookie: grafana_session=<value>
       │         on 200: store cookie in Keychain, navigate
       │
       ├─ 401 ──► "Invalid username or password"
       ├─ 429 ──► "Too many login attempts — wait a minute"
       └─ network error ──► same as flow 1
```

### Why not `HTTPCookieStorage`?

`HTTPCookieStorage.shared` is global and cross-app-launch persistent.
Behaviors that hurt us:

- Cookies aren't scoped to *our* notion of "current server" — they're
  scoped to a domain. If a user switches between two Grafanas on the same
  domain (rare but possible: `g1.example.com` and `g2.example.com` won't
  overlap, but `example.com/g1` and `example.com/g2` will), we get cross-
  contamination.
- They survive logout unless we explicitly clear them.
- They're inspectable from anywhere in the process; Keychain entries are
  encrypted at rest.

So we use a custom storage in Keychain and *manually* read the `Set-Cookie`
header, parse out the `grafana_session` value, and apply it to subsequent
requests as a `Cookie:` header.

### Cookie parsing

We don't need a full RFC 6265 parser. We need:

```swift
extension HTTPURLResponse {
  func grafanaSessionCookie() -> String? {
    guard let setCookie = value(forHTTPHeaderField: "Set-Cookie") else { return nil }
    // Set-Cookie can be a single line with multiple cookies joined by `, `
    // (Foundation already collapses multiple Set-Cookie headers this way).
    // Split on `, ` only when followed by an attribute pattern; safer: use
    // HTTPCookie.cookies(withResponseHeaderFields:forURL:) and filter.
    let url = self.url!
    let cookies = HTTPCookie.cookies(
      withResponseHeaderFields: ["Set-Cookie": setCookie], for: url)
    return cookies.first { $0.name == "grafana_session" }?.value
  }
}
```

We use `HTTPCookie.cookies(withResponseHeaderFields:forURL:)` for the parse
itself (it's well-tested) but extract the *value* and store it ourselves,
rather than letting `HTTPCookieStorage` retain the cookie object.

## Flow 3 — OIDC via cookie harvest

This is the SSO fallback for users whose Grafana is configured against
Google / GitHub / Okta / generic OIDC. As established, there is no PKCE
path. The flow:

```
[user picks "SSO" auth method, enters server URL]
       │
       ▼
   GET /api/auth/keys/oauth   (no — that endpoint doesn't exist)
   GET /login                  ──► HTML, we read it not as html but ...

   Actually we use a simpler probe:
   GET /api/frontend/settings
       │
       ▼
   Parse `oauth` map from the response — for each provider P, the URL is
   `<server>/login/<P>` (canonical Grafana convention).
       │
       ▼
   If multiple providers, show a picker. If one, skip the picker.
       │
       ▼
   ASWebAuthenticationSession with:
     URL:               <server>/login/<P>
     callbackURLScheme: <server's URL scheme>  ── see below
       │
       ▼
   The session navigates the browser through:
     /login/<P> ──► <provider's authorize URL> ──► <provider's login UI>
       ──► <provider's callback> ──► <server>/login/<P>?code=... ──►
       <server> sets `grafana_session` and redirects to `/`
       │
       ▼
   At some point the redirect target matches our `callbackURLScheme`. We
   need to wait until *after* the cookie is set, which happens on the
   final Grafana 302 → "/". The cookie is then in the WKWebView's cookie
   store inside ASWebAuthenticationSession.
       │
       ▼
   Read cookies for the server host from the session's WKWebsiteDataStore:
     WKWebsiteDataStore.nonPersistent.httpCookieStore.getAllCookies { … }
       │
       ▼
   Extract `grafana_session`, store in Keychain, validate with GET /api/user.
```

### The callback-URL problem

`ASWebAuthenticationSession` requires a `callbackURLScheme` so the system
knows when to dismiss the in-app browser and hand control back to the app.
With ArgoCD's Dex, the app registers a custom scheme (`argocd://`) and
configures Dex to accept that as a redirect URI. We can't do that — Grafana
doesn't let us declare a redirect URI; the OAuth client lives in Grafana's
config and its redirect URI is `<server>/login/<provider>`.

We work around this with **prefersEphemeralWebBrowserSession + URL
monitoring**: we still pass a synthetic `callbackURLScheme` so the API is
happy, but we monitor the in-session navigation using a separate route:

#### Option A — Universal Link interception

Configure a universal link to *our* domain (e.g. `grafanaviewer.app`) and
have a tiny HTML page hosted there that, when loaded by Grafana's final
redirect, does `window.location = 'grafanaviewer://done'`. Then we
configure Grafana to redirect to that page after login (via
`root_url` + `redirect_uris` for the OAuth client, depending on provider).

Reality: this works in theory but requires server-side configuration
on every Grafana the user wants to connect to. Bad UX.

#### Option B — Cookie peeking via WKWebView, not ASWebAuthenticationSession

Skip `ASWebAuthenticationSession`; present a `WKWebView` modally. We
control the cookie store and the navigation delegate, so we can:

- Watch `WKNavigationDelegate.decidePolicyFor` for navigations to
  `<server>/` (the post-login landing).
- Once that lands, read the session cookie via
  `WKWebView.configuration.websiteDataStore.httpCookieStore.getAllCookies`.
- Close the modal, store the cookie.

**This is the chosen approach** for v1. It costs us iOS's nicely
sandboxed OIDC UX (`ASWebAuthenticationSession` shows a system "wants to
use [provider] to sign in" prompt), but it works without server-side
configuration and is fully documented.

We will note in the doc / UI that the user is signing in through Grafana's
web flow, and we will use a fresh, ephemeral `WKWebsiteDataStore` so the
session doesn't persist after the modal closes — only the harvested cookie
in our Keychain does.

### Flow summary (option B)

```
[user picks SSO, enters server URL, picks provider]
       │
       ▼
   Modal sheet hosts WKWebView at <server>/login/<provider>
       │
       ▼
   WKNavigationDelegate watches each navigation. When destination is
   <server>/ AND we see `grafana_session` in the cookie store:
       │
       ▼
   Harvest cookie value, dismiss sheet, validate with GET /api/user,
   store credential.
```

Cancel button on the sheet aborts the flow.

## Keychain layout

One item per server.

| Field | Value |
| --- | --- |
| `kSecClass` | `kSecClassGenericPassword` |
| `kSecAttrService` | `grafana-viewer-credential` |
| `kSecAttrAccount` | the server host (e.g. `grafana.example.com`) |
| `kSecValueData` | UTF-8 encoded JSON: `{"kind":"bearer","value":"glsa_…"}` or `{"kind":"cookie","value":"…"}` |
| `kSecAttrAccessible` | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |

`*ThisDeviceOnly` ensures iCloud Keychain sync does not propagate the
credential — server credentials should not move between devices.

Multi-server: a user with two Grafanas has two Keychain items. The "active
server" is recorded in `UserDefaults` as a host string; on launch we read
that host and load the matching Keychain item.

## Active-server selection

`UserDefaults` keys:

- `grafanaviewer.knownServers` — `[String]` of host names (preserves order
  user added them).
- `grafanaviewer.activeServer` — `String?` host name of the current server,
  or `nil` if logged out.

The login screen, on success, prepends the host to `knownServers` (if not
already present) and sets `activeServer`.

The Settings screen lets the user pick a different known server (loads its
Keychain credential, sets it active) or delete a server (clears Keychain +
removes from `knownServers`).

## Token / cookie validation

Two layers:

1. **Acquire-time** — every login flow ends with `GET /api/user`. If that
   call fails with 401, the credential is discarded and the user sees the
   error. We never store an unvalidated credential.
2. **Use-time** — `GrafanaClient` translates any 401 from any endpoint into
   a `GrafanaError.unauthorized`. The feature layer surfaces this as "Your
   session has expired" + a button that returns to the login screen with
   the server URL prefilled. We **do not** silently re-prompt for the
   password.

For cookie-based credentials with a 30-day lifetime, the expiry happens
quietly; the user is bumped back to login when they next open the app and
their cookie is rejected.

## Logout

- Remove the Keychain item for the active server's host.
- Remove the host from `knownServers` if the user chose "forget this
  server" (otherwise leave it).
- Clear `activeServer`.
- For cookie credentials: best-effort `POST <server>/logout` to invalidate
  server-side. Don't block UX on it.
- Reset all `@Observable` state holders by reseating `ServerContext`.

## Open question to resolve here

> If the user's Grafana is behind an enterprise SSO that wraps `/login` in
> *another* redirect chain (e.g. Cloudflare Access), does the cookie-harvest
> path still work?

**Likely yes.** Cloudflare Access intercepts the request *before* Grafana,
authenticates via its own OIDC, sets its own `CF_Authorization` cookie,
then proxies the request through. The Grafana login flow then runs as
usual and sets `grafana_session`. Our WKWebView sees both cookies, but we
only need to harvest `grafana_session` — every subsequent request we make
from the app needs to include *both* the `CF_Authorization` and the
`grafana_session` cookies.

Concrete plan: when we harvest, we harvest *all* cookies from the cookie
store scoped to the server host, not only `grafana_session`. We store
them as a `Set<HTTPCookie>` (or equivalent) in the credential blob.
`GrafanaClient` joins them with `; ` and sets the `Cookie` header.

Failure mode to call out in UI: if the proxied cookie expires before the
Grafana cookie, the user gets an unhelpful 403 on next request. We'll
detect 403 + Cloudflare's response headers (`cf-mitigated`, `server:
cloudflare`) and surface a specific "Your SSO session has expired —
sign in again" message rather than the generic 403.

---

Onward: [`03-api-and-models.md`](03-api-and-models.md).
