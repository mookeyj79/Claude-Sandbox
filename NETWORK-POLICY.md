# Allow public websites, block private networks

The `balanced` network policy blocks any site that isn't on its list, which means constant approval prompts during research-heavy work. This guide opens up the public internet while keeping the sandbox away from your machine and local network.

> **Status: not yet tested.** The commands are based on the Docker docs, but the docs don't describe this exact combination. Run the [checks](#3-check-that-it-works) before relying on it.

## What changes

| | `balanced` | This setup |
|---|---|---|
| Public websites | Only those on the list, others need approval | Allowed |
| Your host's services and private networks | Blocked unless approved | Blocked by explicit deny rules |
| Files outside the mounted workspace | Not accessible | Not accessible |
| Real credentials inside the container | None, the proxy injects them | None, the proxy injects them |

It works because [a deny rule always takes precedence over an allow rule](https://docs.docker.com/ai/sandboxes/governance/access-controls/local/), even a wildcard allow.

## 1. Check your version

```bash
sbx version
```

You need **0.49.1 or later**. In earlier versions, a site allowed by name wasn't checked against CIDR deny rules, so a hostname that resolves to a private address could get through. The [0.49.1 release notes](https://docs.docker.com/ai/sandboxes/release-notes/) cover the fix.

## 2. Apply the rules

Run these on your host, not in the sandbox. They apply to all sandboxes. The denies come first so nothing is exposed in between.

```bash
# Your machine, by name
sbx policy deny network host.docker.internal

# Private IPv4
sbx policy deny network 10.0.0.0/8
sbx policy deny network 172.16.0.0/12
sbx policy deny network 192.168.0.0/16

# Link-local (includes the cloud metadata address) and carrier-grade NAT (includes Tailscale)
sbx policy deny network 169.254.0.0/16
sbx policy deny network 100.64.0.0/10

# Loopback
sbx policy deny network 127.0.0.0/8
sbx policy deny network "[::1]"

# Private and link-local IPv6
sbx policy deny network "fc00::/7"
sbx policy deny network "fe80::/10"

# Everything else
sbx policy allow network "**"
```

Confirm they all registered:

```bash
sbx policy ls
```

The IPv6 entries are the most likely to be rejected, because the docs don't show the format. If `"[::1]"` fails, try `"::1"`.

## 3. Check that it works

Run these inside the sandbox. You can also ask Claude to run them.

```bash
# Should be blocked
for url in \
  http://host.docker.internal \
  http://10.0.0.1 \
  http://172.16.0.1 \
  http://192.168.1.1 \
  http://169.254.169.254 \
  http://100.64.0.1 \
  http://10.0.0.1.nip.io; do
  printf '%s -> ' "$url"
  curl -s -o /dev/null -m 5 -w '%{http_code}\n' "$url"
done

# Should succeed
curl -s -o /dev/null -m 10 -w '%{http_code}\n' https://example.com
```

A policy block returns **403**, and `curl -s "$url"` shows the reason. A `000` means the connection failed or timed out, so nothing was reached, but it doesn't prove the rule did the blocking. Any other status means something answered, so treat that as a failure.

`10.0.0.1.nip.io` is a public hostname that resolves to a private address, so it tests the 0.49.1 behaviour.

Then repeat the blocked list with `curl --noproxy '*'`. The first pass only tests traffic that goes through the proxy, and this shows what happens to a program that ignores the proxy settings. These requests should fail too.

Loopback addresses skip the proxy on purpose (they're in `NO_PROXY`) and reach the sandbox's own loopback, not your host's. A local service running inside the sandbox answering on `127.0.0.1` is therefore expected, not a failure.

## Allowing a specific local service

If Claude needs a service on your machine, such as a local API, a deny rule will block it. Try a specific allow for that port first:

```bash
sbx policy allow network localhost:3000
```

Because denies win, this may stay blocked by the `host.docker.internal` deny. If it does, remove that deny rule, allow only the port you need, and rerun the checks.

## What this doesn't protect against

- **Data leaving through a malicious page:** a web page can contain instructions aimed at Claude, and with the public internet open, anything in the workspace could be sent to any site. Keep secrets out of research projects where you can.
- **GitHub access:** the proxy adds your GitHub token to requests, so a hijacked session could act on any repo the token can reach. `balanced` has this risk too. A narrowly scoped token limits the damage.
- **Non-TCP traffic:** this isn't opened up by these rules. [Non-TCP protocols are blocked by default](https://docs.docker.com/ai/sandboxes/security/policy/).
- **Organization policy:** if your organization manages Sandboxes, its rules can still block sites. Contact IT if they do.

## Undo

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
