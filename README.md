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

### Rebooting

The service runs unprivileged, so it cannot reboot the device on its own — for
example after an OTA update. logind authorizes reboots for `uid 0` only unless
polkit says otherwise.

The `polkit-reboot` PACKAGECONFIG (enabled by default) installs a polkit rule
that lets the `cloud-connector` user call logind's reboot actions, and pulls
`polkit` into the image. polkit only builds when its distro feature is enabled:

```
DISTRO_FEATURES:append = " polkit "
```

The service runs `cloud_connector.runtime.reboot_command` from your
`cloud-connector.yaml` (default `reboot`). On Raspberry Pi + RAUC, point it at a
`tryboot` wrapper so the update boots the new slot.

Disable the grant if your image authorizes reboots another way (running as root,
or `CAP_SYS_BOOT`):

```
PACKAGECONFIG:remove:pn-cloudconnector = "polkit-reboot"
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
