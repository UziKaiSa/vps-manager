# Komari WARP Agent Scripts

Scripts for enrolling headless Linux probe machines into Cloudflare Zero Trust WARP so Komari agents can report through the private network instead of the public Cloudflare hostname.

## Current Network Design

- Komari server private route: `192.0.2.10/32`
- Komari private DNS: `komari.example.internal -> 192.0.2.10`
- Komari private endpoint for remote agents: `http://komari.example.internal:8080`
- Komari endpoint for the Komari host itself: `http://127.0.0.1:8080`
- Cloudflare Zero Trust team: `uzikaisa`
- WARP device profile: `komari-agent-warp`
- Split Tunnel mode: Include only `192.0.2.10/32`
- Local Domain Fallback: `example.internal -> 192.0.2.10`

## Cloudflare Prerequisites

1. Publish the private route through Cloudflare Tunnel:

   ```bash
   cloudflared tunnel route ip add 192.0.2.10/32 example-tunnel
   ```

2. Create a Cloudflare Access Service Token for headless WARP enrollment.

3. Allow that Service Token in Device enrollment permissions:

   ```text
   Action: Service Auth
   Include: Service Token = <komari WARP token>
   ```

4. Ensure the matching device profile uses Include mode and contains only:

   ```text
   192.0.2.10/32
   ```

5. Ensure Local Domain Fallback contains:

   ```text
   example.internal -> 192.0.2.10
   ```

## Credentials

The script accepts credentials in this order:

1. Existing environment variables.
2. Optional `/root/warp-token.env`.
3. Interactive prompts.

For non-interactive runs, either export variables:

```bash
export CF_ACCESS_CLIENT_ID='xxx.access'
export CF_ACCESS_CLIENT_SECRET='xxx'
sudo -E ./install-komari-warp-agent.sh
```

Or create `/root/warp-token.env` on the target probe machine:

```bash
CF_ACCESS_CLIENT_ID='xxx.access'
CF_ACCESS_CLIENT_SECRET='xxx'
```

Do not commit secrets.

## Usage

Install and configure WARP:

```bash
sudo ./install-komari-warp-agent.sh
```

If no credentials are already available, the script will prompt:

```text
Cloudflare Access Client ID:
Cloudflare Access Client Secret:
```

After WARP verification, interactive runs ask whether to continue installing
Komari Agent:

```text
1) Continue to install/reinstall Komari Agent
2) Skip Komari Agent installation
```

If you choose `1`, the script prompts for the Komari client token and then uses
the verified private endpoint by default:

```text
http://komari.example.internal:8080
```

The script also auto-detects the machine public IPv4 and passes it as
`--custom-ipv4`, so Komari shows the machine's real public IP/country instead of
the WARP/private IP. Do not add `--get-ip-addr-from-nic` for WARP-based agents.

To force Komari Agent installation in a non-interactive run:

```bash
export CF_ACCESS_CLIENT_ID='xxx.access'
export CF_ACCESS_CLIENT_SECRET='xxx'
export KOMARI_AGENT_TOKEN='client-token-from-komari'
sudo -E ./install-komari-warp-agent.sh --install-agent
```

To only configure WARP and never prompt for Komari Agent:

```bash
sudo ./install-komari-warp-agent.sh --skip-agent
```

If the machine kernel lacks `nf_tables` support and WARP cannot start its firewall, upgrade only the kernel package:

```bash
sudo ./install-komari-warp-agent.sh --upgrade-kernel
sudo reboot
sudo ./install-komari-warp-agent.sh
```

For unattended maintenance windows:

```bash
sudo ./install-komari-warp-agent.sh --upgrade-kernel --reboot-if-needed
```

## Verification

```bash
warp-cli --accept-tos status
dig komari.example.internal
curl -i http://komari.example.internal:8080
```

Expected:

```text
Status update: Connected
Network: healthy
192.0.2.10
HTTP/1.1 200 OK
```

## Resource Notes

On the tested small `hk` Debian machine:

- RAM total: about `335MiB`
- `warp-svc` RSS after connected: about `100MiB`
- Swap usage after connected: `0B`

This is acceptable for the tested host but not lightweight. Monitor low-memory machines after onboarding.
