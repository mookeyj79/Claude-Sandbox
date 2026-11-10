# Allow public websites and your machine's localhost, block your local network

The `balanced` network policy blocks any site that isn't on its list, which means constant approval prompts during research-heavy work. This guide opens up the public internet and the services running on your own machine (such as a local API or dev server), while keeping the sandbox away from the rest of your local network.

> **Status: partly tested.** Inside a sandbox with these rules, the host's localhost answered, while private addresses and the cloud metadata address returned `Blocked by local rule`. The exact rule list below hasn't been applied from scratch on a clean machine yet. Run the [checks](#4-check-that-it-works) before relying on it.

## What changes

| | `balanced` | This setup |
|---|---|---|
| Public websites | Only those on the list, others need approval | Allowed |
| Services on your machine (`localhost`, any port) | Blocked unless approved | Allowed |
| Other devices on your network, cloud metadata, Tailscale | Blocked unless approved | Blocked by explicit deny rules |
| Files outside the mounted workspace | Not accessible | Not accessible |
| Real credentials inside the container | None, the proxy injects them | None, the proxy injects them |

It works because [a deny rule always takes precedence over an allow rule](https://docs.docker.com/ai/sandboxes/governance/access-controls/local/), even a wildcard allow. So the denies cover only the network, and nothing denies your machine's loopback.

## How a sandbox reaches your machine

The sandbox has its own `localhost`. `127.0.0.1` and `localhost` inside it skip the proxy (they're in `NO_PROXY`) and reach the sandbox itself, not your machine.

To reach a service on your machine, use **`host.docker.internal`**. The request goes through the `sbx` proxy, which connects to `localhost` on your machine:

```bash
curl http://host.docker.internal:3000    # your machine's localhost:3000
```

The service only needs to listen on your machine's `localhost`. You don't need to bind it to `0.0.0.0` or open it to your network.

## 1. Check your version

```bash
sbx version
```

You need **0.49.1 or later**. In earlier versions, a site allowed by name wasn't checked against CIDR deny rules, so a hostname that resolves to a private address could get through. The [0.49.1 release notes](https://docs.docker.com/ai/sandboxes/release-notes/) cover the fix.

## 2. Already applied an older version of this guide?

Earlier versions denied your machine's localhost too. Remove those denies first, because denies always win (skip any you don't have):

```bash
sbx policy rm network --resource host.docker.internal
sbx policy rm network --resource 127.0.0.0/8
sbx policy rm network --resource "[::1]"    # or "::1", whichever form you added
```

## 3. Apply the rules

Run these on your host, not in the sandbox. They apply to all sandboxes, including new ones. The denies come first so nothing is exposed in between.

```bash
# Private IPv4: other devices on your network
sbx policy deny network 10.0.0.0/8
sbx policy deny network 172.16.0.0/12
sbx policy deny network 192.168.0.0/16

# Link-local (includes the cloud metadata address) and carrier-grade NAT (includes Tailscale)
sbx policy deny network 169.254.0.0/16
sbx policy deny network 100.64.0.0/10

# Private and link-local IPv6
sbx policy deny network "fc00::/7"
sbx policy deny network "fe80::/10"

# Your machine's localhost, any port
sbx policy allow network host.docker.internal
sbx policy allow network localhost

# Everything else
sbx policy allow network "**"
```

A rule without a port [matches any port](https://docs.docker.com/ai/governance/reference/network-rules/). The `**` wildcard may already cover your machine's localhost, but the explicit allows make sure it's open even if you later remove `**` or go back to `balanced`.

Confirm they all registered:

```bash
sbx policy ls
```

The IPv6 entries are the most likely to be rejected, because the docs don't show the format.

## 4. Check that it works

Run these inside the sandbox. You can also ask Claude to run them.

```bash
# Should be blocked (403)
for url in \
  http://10.0.0.1 \
  http://172.16.0.1 \
  http://192.168.1.1 \
  http://169.254.169.254 \
  http://100.64.0.1 \
  http://10.0.0.1.nip.io; do
  printf '%s -> ' "$url"
  curl -s -o /dev/null -m 5 -w '%{http_code}\n' "$url"
done

# Should reach your machine (see below)
curl -s -m 5 http://host.docker.internal:3000; echo

# Should succeed
curl -s -o /dev/null -m 10 -w '%{http_code}\n' https://example.com
```

**The blocked list:** a policy block returns **403**, and `curl -s "$url"` shows the reason (`Blocked by local rule for ...`). A `000` means the connection failed or timed out, so nothing was reached, but it doesn't prove the rule did the blocking. Any other status means something answered, so treat that as a failure.

`10.0.0.1.nip.io` is a public hostname that resolves to a private address, so it tests the 0.49.1 behaviour.

Then repeat the blocked list with `curl --noproxy '*'`. The first pass only tests traffic that goes through the proxy, and this shows what happens to a program that ignores the proxy settings. These requests should fail too.

**Your machine:** if something listens on port 3000, you get its response. If nothing does, you get `sbx proxy: upstream request to localhost:3000 failed: ... actively refused it` (or `connection refused`). That also passes, because it means the proxy let the request through to your machine. A `Blocked by ...` message means a deny is still in place. Check `sbx policy ls` for leftover denies from [step 2](#2-already-applied-an-older-version-of-this-guide).

## Allowing only some ports

To open only the services you use instead of every port on your machine, use port-specific allows in place of the two localhost allows:

```bash
sbx policy rm network --resource host.docker.internal
sbx policy rm network --resource localhost
sbx policy allow network localhost:3000
sbx policy allow network localhost:5432
```

With `**` in place this makes no difference, because the wildcard may still allow the rest. Port-specific allows only narrow things under `balanced`, or if you remove `**`. To block a port for certain, deny it: `sbx policy deny network localhost:2375`.

## What this doesn't protect against

- **Services on your machine:** every service listening on your machine's localhost is reachable from every sandbox. That includes databases, admin consoles, and anything that trusts localhost and skips authentication, such as a Docker or Kubernetes API, a local model server, or a dev tool with an unauthenticated control port. Deny specific ports you don't want reachable (see [Allowing only some ports](#allowing-only-some-ports)).
- **Data leaving through a malicious page:** a web page can contain instructions aimed at Claude, and with the public internet open, anything in the workspace could be sent to any site. Keep secrets out of research projects where you can.
- **GitHub access:** the proxy adds your GitHub token to requests, so a hijacked session could act on any repo the token can reach. `balanced` has this risk too. A narrowly scoped token limits the damage.
- **Non-TCP traffic:** this isn't opened up by these rules. [Non-TCP protocols are blocked by default](https://docs.docker.com/ai/sandboxes/security/policy/).
- **Organization policy:** if your organization manages Sandboxes, its rules can still block sites. Contact IT if they do.

## Undo

To close your machine's localhost again:

```bash
sbx policy rm network --resource host.docker.internal
sbx policy rm network --resource localhost
sbx policy deny network host.docker.internal
sbx policy deny network localhost
```

Remove the wildcard to go back to needing approval for unlisted sites:

```bash
sbx policy rm network --resource "**"
```

The deny rules can stay, but to remove one:

```bash
sbx policy rm network --resource 10.0.0.0/8
```

To start over completely:

```bash
sbx policy reset
sbx policy init balanced
```
