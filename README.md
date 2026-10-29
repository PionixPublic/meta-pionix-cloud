# meta-pionix-cloud

Yocto layer that installs the Pionix Cloud Connector and its plugins onto a
device image. It pulls pre-built OCI artifacts (the cloud-connector binary and
each plugin) from a registry and installs them at the paths you declare in your
`cloud-connector.yaml`. Compatible with **Kirkstone (4.0)** and **Scarthgap (5.0)**.

## How it works

The layer reads your `cloud-connector.yaml` at BitBake parse time and derives
everything from it. There is no separate Yocto-specific config file — the same
YAML drives both the Yocto build and the running service.

At parse time it reads:

| `cloud-connector.yaml` key | Used for |
|---|---|
| `device.installation.registry` | OCI registry base URL |
| `device.installation.tag` | Default artifact tag |
| `device.installation.cloud_connector` | Binary artifact name, install directory, optional `digest`/`config_path` |
| `device.installation.registry_creds.auths` | Registry auth (Docker `config.json` format) |
| `cloud_connector.plugins.directory` | Plugin install root |
| `cloud_connector.plugins.libraries[]` | Plugins with `source.type: oci` |
| `cloud_connector.mqtt.cloud.tls.client_credentials.directory` | TLS credentials directory (see [Credentials directory](#credentials-directory)) |
| each plugin's `config.everest.config_dir` / `config_symlink` | EVerest config-switch grant (see [EVerest config switching](#everest-config-switching)) |

`do_fetch_oci` then pulls each artifact with `oras` for the build's
`TARGET_ARCH`, and `do_install` lays them out on the image.

## Add it to your build

**1. Add the layer** to `bblayers.conf`:

```
BBLAYERS += "/path/to/meta-pionix-cloud"
```

**2. Set two variables** in `local.conf` (or your machine config):

```
# Accept the Pionix Commercial BaseCamp license (required to build the layer).
# Terms: https://www.pionix.com/pionix-license-terms
LICENSE_FLAGS_ACCEPTED += "PionixCommercialBaseCamp-1.0"

# Path to your cloud-connector.yaml — every other setting comes from this file.
CLOUDCONNECTOR_CONFIG_FILE = "/path/to/cloud-connector.yaml"
```

**3. Build:**

```
bitbake cloudconnector
```

Add `cloudconnector` to your image (e.g. `IMAGE_INSTALL:append = " cloudconnector"`)
to ship it.

## Pre-release channel

The `kirkstone` and `scarthgap` branches only move when a Cloud Connector
release is tagged. To try layer changes *before* a release, use the pre-release
branches, which track the upstream `main`:

| Branch | Content |
|---|---|
| `kirkstone` / `scarthgap` | latest tagged release |
| `kirkstone-next` / `scarthgap-next` | current upstream `main` — unreleased |

Each release is also tagged `vX.Y.Z` — the same version as the OCI artifacts,
on the commit both release branches point at — so a layer manifest can pin
`v0.3.2` instead of a branch or a hash.

```
git clone -b kirkstone-next https://github.com/PionixPublic/meta-pionix-cloud.git
```

An unreleased layer generally expects the artifacts built from the same `main`,
so point the default tag at the rolling `main` build instead of `stable`:

```yaml
device:
  installation:
    tag: "main"
```

This is a testing channel, not a release. Three things to know:

- **Nothing here is reproducible.** Both the `-next` branch and the `main`
  artifact tag are mutable and move whenever upstream `main` advances — the same
  build run twice can produce different content. Once you need a fixed snapshot,
  pin a digest (see [Pinning versions](#pinning-versions)); the branch is still
  a convenient way to *find* the layer revision you want to pin against.
- **`PV` is not bumped.** A `-next` build reports the last released version, so
  it is indistinguishable from the release by package version alone. Don't ship
  a `-next` build to a fleet.
- **Switching back is cheap.** `-next` is a fast-forward of its release branch,
  so moving to `kirkstone` is an ordinary checkout, not a history rewrite.

`git log` on a `-next` branch shows the upstream commits verbatim (message,
author and date are preserved), so you can see exactly which changes you picked
up relative to the release.

## Install layout

| Path | Content |
|---|---|
| `{cloud_connector.directory}/` | Binary and bundled files; entrypoint marked executable |
| `{plugins.directory}/{qualified-oci-name}/` | Each plugin's files |
| `{cloud_connector.config_path}` (default `{cloud_connector.directory}/cloud-connector.yaml`) | Your config, copied verbatim |
| `/usr/bin/cloud-connector` | Wrapper that puts the binary on `PATH` for the client subcommands (`status`, `ping`, `get-config`, plugin actions) |
| `${systemd_unitdir}/system/cloud-connector.service` | systemd unit (auto-enabled) |
| `/etc/tmpfiles.d/cloud-connector-everest.conf` | EVerest config-dir grant, when an EVerest plugin is present |

Plugins install under their **qualified OCI name**. If the image name already
starts with a registry (its first path segment contains `.` or `:`), it is used
as-is; otherwise the default `registry` is prepended. This matches the path the
daemon derives at runtime, so the names must agree.

## Service account

The recipe creates a system user and group `cloud-connector`. The service runs as
that user, not root. This shapes how two directories are handled.

### Credentials directory

`cloud_connector.mqtt.cloud.tls.client_credentials.directory` holds the TLS client
certificate the device enrolls. The service user must be able to write there.

- **Under `/var/lib/`** (recommended, e.g. `/var/lib/cloud-connector/certs`): the
  systemd unit gets a `StateDirectory=` entry. systemd creates the directory and
  chowns it to the `cloud-connector` user on every start. It survives a volatile
  `/var` and a factory reset. The subdirectory name is yours to choose.
- **Anywhere else**: the layer does **not** create it or change its permissions.
  You own its existence and ownership. The build prints a warning naming the path.

### EVerest config switching

The EVerest plugin switches the active EVerest config by replacing a symlink at
runtime. Replacing a symlink needs write access on the directory that contains
it, so the layer grants the `cloud-connector` group write access to that directory
via `/etc/tmpfiles.d/cloud-connector-everest.conf`.

The directory is derived per plugin from `config.everest.config_symlink` (its
parent) or `config.everest.config_dir`. The grant is applied at boot and is
non-recursive, so the config files and EVerest's own state keep their ownership.
The directory and the symlink themselves must already exist — typically shipped
by your EVerest recipe.

### Trust model

The service runs as the unprivileged `cloud-connector` account, with no systemd
sandbox. Everything it starts runs as that account with its normal Unix rights:
the plugins, remote SSH session shells, generic-updater hooks and
`reboot_command`.

That account is the security boundary. It gets extra rights only from the
grants this layer installs and from whatever you add yourself (groups, sudoers
rules, polkit rules):

| Grant | Installed when | Allows |
|---|---|---|
| logind reboot (polkit) | always (`polkit-reboot`) | Rebooting the device |
| RAUC `Installer` (D-Bus) | rauc-updater plugin enabled | Installing bundles signed with your key |
| `manage-units` (polkit) | systemd plugin enabled | Start, stop, restart, reload, reset-failed on any unit |
| `manage-unit-files`, `reload-daemon` (polkit) | systemd plugin enabled | Enable and disable units; polkit cannot narrow this action, so it also allows linking a unit file from any path and starting it. Treat it as root. |
| `systemd-journal` group | systemd plugin enabled | Reading every unit's journal |
| EVerest config dir (group write) | EVerest plugin present | Switching the active EVerest config |

Treat the `cloud-connector` account as privileged. Anyone who can open a remote
SSH session, or run code in the connector, has its rights. The connector's own
protections are upstream of the device: TLS with a validated server
certificate, cloud-side authorization of every action, the plugins' allow-lists,
and the peer-credential check on the local IPC socket.

The unit keeps resource bounds so a runaway connector cannot starve EVerest:
`MemoryHigh=96M` throttles it, `OOMScoreAdjust=500` makes it the kernel's first
OOM victim, and `TasksMax=128` caps its processes. Session shells and hooks count
against the same bounds.

**Remote SSH.** A session's shell runs as `cloud-connector`. To let support
sessions do more, grant that account what they need, for example a sudoers rule.
The daemon gets the same rights, since it is the same account.

### Hardening options

None of these are on by default, because each one restricts something an
integration may rely on. Pick the ones whose cost fits your device.

| Option | Protects against | Costs |
|---|---|---|
| Leave out plugins you don't use | Their attack surface and grants | The cloud features they provide |
| Drop the `polkit-manage-units` `PACKAGECONFIG` | The root-equivalent unit-file grant | Cloud service actions; the systemd plugin withholds them |
| Set the plugins' allow-lists: remote-ssh `allowed_public_keys`, systemd `log_units` and `service_actions`, mqtt-bridge `allowed_topic_prefixes` | A compromised cloud account reaching beyond what you listed | Updating the list when the cloud side changes |
| Narrow sudoers rules (named commands, not `ALL`) | A session or compromised connector getting full root | Support can only run the listed commands as root |
| Sandbox drop-in (below) | Code execution in the connector escalating through setuid binaries, kernel namespace bugs, or writable system files | `sudo`/`su` in sessions and hooks; hooks writing outside the listed paths; containers in hooks; `dmesg` |
| `MemoryMax=` drop-in | A connector leak growing past `MemoryHigh` | The kernel kills the whole service, sessions and running hooks included, when it is hit |
| Egress firewall allowing only your cloud endpoints | Exfiltration and lateral movement from a compromised connector | Maintaining the endpoint list |

A sandbox drop-in, to adapt. `ReadWritePaths=` must list every directory the
connector or its hooks write: the database and credentials directories, the
EVerest config directories, `packet_capture_path`, `ocpp_session_log_path`, the
generic-updater `working_directory`, and `/tmp` for the local broker socket.

```
# /etc/systemd/system/cloud-connector.service.d/50-hardening.conf
[Service]
NoNewPrivileges=yes
RestrictSUIDSGID=yes
CapabilityBoundingSet=
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=-/var/lib/cloud-connector -/etc/everest /tmp
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
RestrictNamespaces=yes
LockPersonality=yes
RestrictRealtime=yes
SystemCallArchitectures=native
```

Don't set `PrivateTmp=`: it hides the local broker socket in `/tmp` from
mqtt-bridge and the EVerest plugin. Check the result with
`systemd-analyze security cloud-connector.service`.

### Rebooting

The service runs unprivileged, so it cannot reboot the device on its own — for
example after an OTA update. logind authorizes reboots for `uid 0` only unless
polkit says otherwise.

The `polkit-reboot` PACKAGECONFIG (always on by default) installs a polkit rule
that lets the `cloud-connector` user call logind's reboot actions, and pulls
`polkit` into the image. polkit only builds when its distro feature is enabled:

```
DISTRO_FEATURES:append = " polkit "
```

The service runs `cloud_connector.runtime.reboot_command` from your
`cloud-connector.yaml`. Hard reboot tries sysrq first and runs the command if
sysrq is sealed; soft reboot runs the command directly. If unset, soft reboot
uses raw sysrq instead of logind, and hard reboot has no fallback. On Raspberry
Pi + RAUC, point it at a `tryboot` wrapper.

Unlike `rauc-dbus-access` below, this can't be derived from the config —
`reboot_command` is a free-form shell string. Disable the grant only if your
image authorizes reboots another way (root, or `CAP_SYS_BOOT`):

```
PACKAGECONFIG:remove:pn-cloudconnector = "polkit-reboot"
```

### RAUC OTA access

RAUC's own default D-Bus policy restricts its mutating methods (`InstallBundle`,
`Mark`) to root. The `rauc-dbus-access` PACKAGECONFIG installs a D-Bus policy
granting the unprivileged `cloud-connector` user access to
`de.pengutronix.rauc.Installer`, needed by the rauc-updater plugin.

Unlike `polkit-reboot`, this defaults on exactly when the `rauc-updater`
plugin is enabled in the config. Override explicitly if needed:

```
PACKAGECONFIG:remove:pn-cloudconnector = "rauc-dbus-access"
# or, to force it on regardless of the config:
PACKAGECONFIG:append:pn-cloudconnector = " rauc-dbus-access"
```

## Registry credentials

For a private registry, put Docker-style auth in `cloud-connector.yaml`. It maps
directly to a `config.json` `auths` block and is written to a build-local
`DOCKER_CONFIG`, never to `~/.docker`:

```yaml
device:
  installation:
    registry_creds:
      auths:
        cr.pionix.com:
          auth: "<base64(username:token)>"   # printf '%s' 'user:token' | base64
```

Omit the block for public registries.

## Architecture matching

`do_fetch_oci` maps `TARGET_ARCH` to an OCI platform (`x86_64`→`amd64`,
`aarch64`→`arm64`, `arm`→`arm`) and pulls that variant. `oras` pulls nothing and
does not error when an artifact lacks your platform, which later surfaces as a
"no entrypoint to mark executable" warning at build time and a failure to spawn
at runtime. If you hit that, confirm the artifact publishes your target arch.

## Pinning versions

Tags such as `stable` are mutable. For reproducible builds, pin a digest instead
of a tag:

```yaml
device:
  installation:
    cloud_connector:
      digest: "cr.pionix.com/pionixpublic/cloud-connector@sha256:..."
```

Each entry in `plugins.libraries[].source` accepts a `digest` as well, taking
precedence over `tag`.
