# meta-pionix-cloud

Yocto layer that installs the Pionix Cloud Connector and its plugins onto a device image by pulling OCI artifacts from a registry. Compatible with **Kirkstone (4.0 LTS)** and **Scarthgap (5.0 LTS)**.

## How it works

The layer reads your existing `cloudconnector.yaml` at BitBake parse time and derives everything it needs from it — no separate Yocto-specific config required.

```
cloudconnector.yaml
  device.installation.registry         → OCI registry base URL
  device.installation.tag              → default artifact tag
  device.installation.cloudconnector   → binary artifact name + install dir
  device.installation.registry_creds   → auth (Docker config.json format)
  cloudconnector.plugins.libraries[]   → plugins with source.type == "oci"
  cloudconnector.plugins.directory     → plugin install root
  cloudconnector.mqtt.tls.client_credentials.directory → provisioned at postinst
```

## Adding to your build

**1. Add the layer** to your Yocto workspace:

```bash
git clone git@github.com:PionixPublic/meta-pionix-cloud.git layers/meta-pionix-cloud
```

Or as a submodule:

```bash
git submodule add git@github.com:PionixPublic/meta-pionix-cloud.git layers/meta-pionix-cloud
```

**2. Register the layer** in `bblayers.conf`:

```
BBLAYERS += "/path/to/layers/meta-pionix-cloud"
```

**3. Point it at your config** in `local.conf` (or your machine config):

```
CLOUDCONNECTOR_CONFIG_FILE = "/path/to/cloudconnector.yaml"
```

**4. Build:**

```bash
bitbake cloudconnector
```

Inspect the result:

```bash
find tmp/work/*/cloudconnector/*/image -type f | sort
```

Expected layout on the device:

| Path | Content |
|---|---|
| `{cloudconnector.directory}/` | Binary + bundled libs |
| `{plugins.directory}/{plugin-name}/` | Plugin `.so` + schema files |
| `/etc/cloudconnector/cloudconnector.yaml` | Config (copied from `CLOUDCONNECTOR_CONFIG_FILE`) |
| `/lib/systemd/system/cloudconnector.service` | systemd unit |
| `{tls.client_credentials.directory}/` | Provisioned at first boot (owned by `cloudconnector`) |

## Registry credentials

`registry_creds` in `cloudconnector.yaml` mirrors the Docker `config.json` `auths` block:

```yaml
device:
  installation:
    registry_creds:
      auths:
        ghcr.io/pionixpro:
          auth: "<base64(username:pat)>"  # echo -n "user:token" | base64
```

For public registries omit the block entirely.
