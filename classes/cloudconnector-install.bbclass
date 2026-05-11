# cloudconnector-install.bbclass
#
# Reads a cloudconnector.yaml config file at recipe-parse time, derives all
# install-time values from it, then fetches OCI artifacts with `oras` and
# installs them at the paths declared in the config.
#
# Consumer usage (local.conf or machine config):
#   CLOUDCONNECTOR_CONFIG_FILE = "/path/to/cloudconnector.yaml"
#
# The recipe that inherits this class must also set:
#   DEPENDS += "oras-native python3-pyyaml-native"

CLOUDCONNECTOR_CONFIG_FILE ?= ""

# Parse the config at recipe-parse time so all variables are available to
# every task without re-reading the file at execution time.
python __anonymous() {
    import json
    import os

    config_file = d.getVar('CLOUDCONNECTOR_CONFIG_FILE')
    if not config_file:
        bb.fatal("CLOUDCONNECTOR_CONFIG_FILE is not set. "
                 "Add it to local.conf or your machine config.")
    if not os.path.isfile(config_file):
        bb.fatal("CLOUDCONNECTOR_CONFIG_FILE does not exist: %s" % config_file)

    try:
        import yaml
    except ImportError:
        bb.fatal("PyYAML is not available. Add python3-pyyaml-native to DEPENDS.")

    with open(config_file) as f:
        cfg = yaml.safe_load(f)

    inst = cfg.get('device', {}).get('installation', {})
    registry    = inst.get('registry', '')
    default_tag = inst.get('tag', 'stable')

    cc_inst = inst.get('cloudconnector', {})
    cc_name = cc_inst.get('name')
    if not cc_name:
        bb.fatal("device.installation.cloudconnector.name is required in %s" % config_file)
    cc_dir   = cc_inst.get('directory', '/opt/pionix')
    cc_ref   = cc_inst.get('digest') or ('%s/%s:%s' % (registry, cc_name, cc_inst.get('tag') or default_tag))

    plugins_cfg  = cfg.get('cloudconnector', {}).get('plugins', {})
    plugins_dir  = plugins_cfg.get('directory', '/opt/pionix')
    oci_plugins  = [
        lib for lib in plugins_cfg.get('libraries', [])
        if lib.get('source', {}).get('type') == 'oci'
    ]

    # Build a fully-qualified ref for each OCI plugin.
    for plugin in oci_plugins:
        src = plugin['source']
        name = src.get('name', '')
        tag_or_digest = src.get('digest') or src.get('tag') or default_tag
        # A fully-qualified name (contains '/') overrides the default registry.
        if '/' in name:
            src['_ref'] = '%s:%s' % (name, tag_or_digest)
        else:
            src['_ref'] = '%s/%s:%s' % (registry, name, tag_or_digest)

    creds = inst.get('registry_creds', {})
    auths = creds.get('auths', {})

    client_creds_dir = (cfg.get('cloudconnector', {})
                          .get('mqtt', {})
                          .get('cloud', {})
                          .get('tls', {})
                          .get('client_credentials', {})
                          .get('directory', '/etc/mosquitto'))

    d.setVar('CC_DIRECTORY',             cc_dir)
    d.setVar('CC_REF',                   cc_ref)
    d.setVar('PLUGINS_DIRECTORY',        plugins_dir)
    d.setVar('OCI_PLUGINS_JSON',         json.dumps(oci_plugins))
    d.setVar('REGISTRY_AUTHS_JSON',      json.dumps(auths))
    d.setVar('CLIENT_CREDENTIALS_DIR',   client_creds_dir)
}

# ── Fetch OCI artifacts ───────────────────────────────────────────────────────
# We use a separate named task so the standard do_fetch → do_unpack chain
# still handles the file:// SRC_URI entries (e.g. the systemd unit template).
# do_fetch_oci runs after do_unpack (WORKDIR is ready) and before do_install.

python do_fetch_oci() {
    import json, os, subprocess

    workdir = d.getVar('WORKDIR')

    # Write auth config scoped to WORKDIR so we never touch ~/.docker/config.json.
    auths = json.loads(d.getVar('REGISTRY_AUTHS_JSON') or '{}')
    docker_cfg_dir = os.path.join(workdir, '.docker')
    os.makedirs(docker_cfg_dir, exist_ok=True)
    with open(os.path.join(docker_cfg_dir, 'config.json'), 'w') as f:
        json.dump({'auths': auths}, f)

    env = dict(os.environ)
    env['DOCKER_CONFIG'] = docker_cfg_dir

    # Map BitBake TARGET_ARCH to OCI platform string.
    _arch_map = {'x86_64': 'amd64', 'aarch64': 'arm64', 'arm': 'arm'}
    target_arch = d.getVar('TARGET_ARCH') or ''
    oci_arch = _arch_map.get(target_arch, target_arch)
    platform = 'linux/' + oci_arch

    def oras_pull(ref, dest):
        os.makedirs(dest, exist_ok=True)
        subprocess.check_call(
            ['oras', 'pull', '--platform', platform, '--output', dest, ref],
            env=env,
        )

    # Cloud-connector binary and libs.
    oras_pull(d.getVar('CC_REF'), os.path.join(workdir, 'cc'))

    # OCI plugins.
    oci_plugins = json.loads(d.getVar('OCI_PLUGINS_JSON') or '[]')
    for plugin in oci_plugins:
        plugin_name = plugin['source']['name'].split('/')[-1]
        oras_pull(plugin['source']['_ref'],
                  os.path.join(workdir, 'plugins', plugin_name))
}

addtask do_fetch_oci after do_unpack before do_install
do_fetch_oci[depends] = "oras-native:do_populate_sysroot"
do_fetch_oci[network] = "1"

# ── Install ───────────────────────────────────────────────────────────────────

python do_install() {
    import json, os, shutil

    workdir  = d.getVar('WORKDIR')
    destdir  = d.getVar('D')
    cc_dir      = d.getVar('CC_DIRECTORY')
    plugins_dir = d.getVar('PLUGINS_DIRECTORY')
    cfg_file    = d.getVar('CLOUDCONNECTOR_CONFIG_FILE')

    def install_flat(src_dir, dst_dir):
        os.makedirs(dst_dir, exist_ok=True)
        for name in os.listdir(src_dir):
            src = os.path.join(src_dir, name)
            dst = os.path.join(dst_dir, name)
            if os.path.islink(src):
                link_target = os.readlink(src)
                if os.path.exists(dst) or os.path.islink(dst):
                    os.remove(dst)
                os.symlink(link_target, dst)
            elif os.path.isfile(src):
                shutil.copy2(src, dst)

    # Cloud-connector binary + libs → CC_DIRECTORY
    cc_dest = os.path.join(destdir, cc_dir.lstrip('/'))
    install_flat(os.path.join(workdir, 'cc'), cc_dest)

    # Plugins → PLUGINS_DIRECTORY/<plugin-name>/
    oci_plugins = json.loads(d.getVar('OCI_PLUGINS_JSON') or '[]')
    for plugin in oci_plugins:
        plugin_name = plugin['source']['name'].split('/')[-1]
        plugin_dest = os.path.join(destdir, plugins_dir.lstrip('/'), plugin_name)
        install_flat(os.path.join(workdir, 'plugins', plugin_name), plugin_dest)

    # Config YAML → /etc/cloudconnector/
    cfg_dst_dir = os.path.join(destdir, 'etc', 'cloudconnector')
    os.makedirs(cfg_dst_dir, exist_ok=True)
    shutil.copy2(cfg_file, os.path.join(cfg_dst_dir, 'cloudconnector.yaml'))

    # systemd unit → ${systemd_unitdir}/system/
    # The service file is fetched by SRC_URI in the recipe and placed in WORKDIR.
    unit_src = os.path.join(workdir, 'cloudconnector.service')
    systemd_unitdir = d.getVar('systemd_unitdir') or '/lib/systemd'
    unit_dst_dir = os.path.join(destdir, systemd_unitdir.lstrip('/'), 'system')
    os.makedirs(unit_dst_dir, exist_ok=True)
    unit_dst = os.path.join(unit_dst_dir, 'cloudconnector.service')
    shutil.copy2(unit_src, unit_dst)

    # Substitute @CC_DIRECTORY@ placeholder in the unit file.
    with open(unit_dst) as f:
        unit = f.read()
    with open(unit_dst, 'w') as f:
        f.write(unit.replace('@CC_DIRECTORY@', cc_dir))
}

# ── Post-install (runs on target at image-creation or first boot) ─────────────

pkg_postinst_${PN}() {
#!/bin/sh
set -e
groupadd -r cloudconnector 2>/dev/null || true
useradd -r -g cloudconnector -s /sbin/nologin -d /nonexistent cloudconnector 2>/dev/null || true
install -d -m 0750 -o cloudconnector -g cloudconnector "${CLIENT_CREDENTIALS_DIR}"
}

inherit systemd

SYSTEMD_SERVICE_${PN} = "cloudconnector.service"
SYSTEMD_AUTO_ENABLE_${PN} = "enable"
