# cloudconnector-install.bbclass
#
# Reads a cloud-connector.yaml config file at recipe-parse time, derives all
# install-time values from it, then fetches OCI artifacts with `oras` and
# installs them at the paths declared in the config.
#
# Consumer usage (local.conf or machine config):
#   CLOUDCONNECTOR_CONFIG_FILE = "/path/to/cloud-connector.yaml"
#
# The recipe that inherits this class must also set:
#   DEPENDS += "oras-native python3-pyyaml-native"

CLOUDCONNECTOR_CONFIG_FILE ?= ""

# Derive all install-time values from the config at parse time.
python __anonymous() {
    import json
    import os

    config_file = d.getVar('CLOUDCONNECTOR_CONFIG_FILE')
    if not config_file:
        bb.fatal("CLOUDCONNECTOR_CONFIG_FILE is not set. "
                 "Add it to local.conf or your machine config.")
    if not os.path.isfile(config_file):
        bb.fatal("CLOUDCONNECTOR_CONFIG_FILE does not exist: %s" % config_file)

    # Reparse when the config changes, else BitBake reports non-deterministic
    # metadata (cached vs. fresh parse disagree).
    bb.parse.mark_dependency(d, config_file)

    try:
        import yaml
    except ImportError:
        bb.fatal("PyYAML is not available. Add python3-pyyaml-native to DEPENDS.")

    with open(config_file) as f:
        cfg = yaml.safe_load(f)

    inst = cfg.get('device', {}).get('installation', {})
    registry    = inst.get('registry', '')
    default_tag = inst.get('tag', 'stable')

    cc_inst = inst.get('cloud_connector', {})
    cc_name = cc_inst.get('name')
    if not cc_name:
        bb.fatal("device.installation.cloud_connector.name is required in %s" % config_file)
    cc_dir   = cc_inst.get('directory', '/opt/pionix')
    cc_ref   = cc_inst.get('digest') or ('%s/%s:%s' % (registry, cc_name, cc_inst.get('tag') or default_tag))

    plugins_cfg  = cfg.get('cloud_connector', {}).get('plugins', {})
    plugins_dir  = plugins_cfg.get('directory', '/opt/pionix')
    oci_plugins  = [
        lib for lib in plugins_cfg.get('libraries', [])
        if lib.get('source', {}).get('type') == 'oci'
    ]

    # Qualified name mirrors Rust's qualify_oci_name(): registry-prefixed unless
    # the name's first segment already contains '.' or ':'. The daemon uses it as
    # the on-disk subdir, so the install path must match.
    for plugin in oci_plugins:
        src = plugin['source']
        name = src.get('name', '')
        tag_or_digest = src.get('digest') or src.get('tag') or default_tag
        first_segment = name.split('/')[0] if name else ''
        if '.' in first_segment or ':' in first_segment:
            src['_qualified_name'] = name
            src['_ref'] = '%s:%s' % (name, tag_or_digest)
        else:
            src['_qualified_name'] = '%s/%s' % (registry, name)
            src['_ref'] = '%s/%s:%s' % (registry, name, tag_or_digest)

    # EVerest config dirs needing group-write (the daemon swaps a symlink there),
    # derived per plugin from config_symlink/config_dir.
    everest_dirs = []
    for lib in plugins_cfg.get('libraries', []):
        ev = (lib.get('config') or {}).get('everest')
        if not isinstance(ev, dict):
            continue
        symlink = ev.get('config_symlink')
        target = os.path.dirname(symlink) if symlink else ev.get('config_dir')
        if target and target not in everest_dirs:
            everest_dirs.append(target)

    # The systemd plugin reads the journal (needs the systemd-journal group).
    # Grant it via SupplementaryGroups= only when enabled. Match the OCI image
    # basename, not the user-chosen id.
    systemd_plugin_enabled = any(
        lib.get('enabled', False)
        and lib.get('source', {}).get('name', '').rsplit('/', 1)[-1].split(':')[0]
            == 'cc-plugin-systemd'
        for lib in plugins_cfg.get('libraries', [])
    )
    d.setVar('SYSTEMD_JOURNAL_ACCESS', '1' if systemd_plugin_enabled else '')

    creds = inst.get('registry_creds', {})
    auths = creds.get('auths', {})

    client_creds_dir = (cfg.get('cloud_connector', {})
                          .get('mqtt', {})
                          .get('cloud', {})
                          .get('tls', {})
                          .get('client_credentials', {})
                          .get('directory', '/etc/mosquitto'))

    # StateDirectory= provisions only paths under /var/lib (owned by the service
    # user at runtime). Outside that tree the integrator owns the dir; warn.
    state_prefix = '/var/lib/'
    state_rel = ''
    if client_creds_dir.startswith(state_prefix):
        state_rel = client_creds_dir[len(state_prefix):].strip('/')
    if not state_rel:
        bb.warn(
            "cloud-connector: client_credentials.directory '%s' is not under "
            "/var/lib/, so the systemd unit cannot provision it via "
            "StateDirectory=. This layer will NOT create it or grant the "
            "'cloud-connector' user write access. Either move it under /var/lib/ "
            "(recommended) or ensure the directory exists and is writable by the "
            "cloud-connector user yourself." % client_creds_dir
        )
    d.setVar('STATE_DIRECTORY_REL', state_rel)

    cc_config_path = cc_inst.get('config_path') or (cc_dir + '/cloud-connector.yaml')

    d.setVar('CC_DIRECTORY',             cc_dir)
    d.setVar('CC_REF',                   cc_ref)
    d.setVar('CC_CONFIG_PATH',           cc_config_path)
    d.setVar('PLUGINS_DIRECTORY',        plugins_dir)
    d.setVar('OCI_PLUGINS_JSON',         json.dumps(oci_plugins))
    d.setVar('REGISTRY_AUTHS_JSON',      json.dumps(auths))
    d.setVar('CLIENT_CREDENTIALS_DIR',   client_creds_dir)
    d.setVar('EVEREST_CONFIG_DIRS',      ' '.join(everest_dirs))
}

# ── Fetch OCI artifacts ───────────────────────────────────────────────────────
# Separate task so the standard do_fetch/do_unpack still handle file:// SRC_URI.
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
        qualified_name = plugin['source']['_qualified_name']
        oras_pull(plugin['source']['_ref'],
                  os.path.join(workdir, 'plugins', qualified_name))
}

addtask do_fetch_oci after do_unpack before do_install
do_fetch_oci[depends] = "oras-native:do_populate_sysroot"
do_fetch_oci[network] = "1"

# ── Install ───────────────────────────────────────────────────────────────────

python do_install() {
    import json, os, shutil

    workdir  = d.getVar('WORKDIR')
    destdir  = d.getVar('D')
    cc_dir          = d.getVar('CC_DIRECTORY')
    cc_config_path  = d.getVar('CC_CONFIG_PATH')
    plugins_dir     = d.getVar('PLUGINS_DIRECTORY')
    cfg_file        = d.getVar('CLOUDCONNECTOR_CONFIG_FILE')

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

    def chmod_entrypoint(src_dir, dst_dir, label):
        oci_json_path = os.path.join(src_dir, 'oci.json')
        if not os.path.isfile(oci_json_path):
            bb.warn("cloud-connector: %s has no oci.json in its OCI artifact; "
                    "no entrypoint could be marked executable. The subprocess "
                    "will fail to spawn with 'Permission denied' at runtime."
                    % label)
            return
        with open(oci_json_path) as f:
            oci = json.load(f)
        entrypoint = oci.get('entrypoint')
        if not entrypoint:
            bb.warn("cloud-connector: %s oci.json has no 'entrypoint' field; no "
                    "binary marked executable. The subprocess will fail to "
                    "spawn with 'Permission denied' at runtime." % label)
            return
        ep_path = os.path.join(dst_dir, entrypoint)
        if not os.path.isfile(ep_path):
            bb.warn("cloud-connector: %s entrypoint '%s' (from oci.json) is not "
                    "present in the artifact; cannot mark it executable. The "
                    "subprocess will fail to spawn at runtime."
                    % (label, entrypoint))
            return
        os.chmod(ep_path, 0o755)

    # Cloud-connector binary + libs → CC_DIRECTORY
    cc_src = os.path.join(workdir, 'cc')
    cc_dest = os.path.join(destdir, cc_dir.lstrip('/'))
    install_flat(cc_src, cc_dest)
    chmod_entrypoint(cc_src, cc_dest, 'cloud-connector')

    # Plugins → PLUGINS_DIRECTORY/<qualified-oci-name>/ (matches config.rs).
    oci_plugins = json.loads(d.getVar('OCI_PLUGINS_JSON') or '[]')
    for plugin in oci_plugins:
        qualified_name = plugin['source']['_qualified_name']
        plugin_src = os.path.join(workdir, 'plugins', qualified_name)
        plugin_dest = os.path.join(destdir, plugins_dir.lstrip('/'), qualified_name)
        install_flat(plugin_src, plugin_dest)
        chmod_entrypoint(plugin_src, plugin_dest, qualified_name)

    # Config YAML → cc_config_path
    cfg_dst = os.path.join(destdir, cc_config_path.lstrip('/'))
    os.makedirs(os.path.dirname(cfg_dst), exist_ok=True)
    shutil.copy2(cfg_file, cfg_dst)

    # systemd unit → ${systemd_unitdir}/system/
    unit_src = os.path.join(workdir, 'cloud-connector.service')
    systemd_unitdir = d.getVar('systemd_unitdir') or '/lib/systemd'
    unit_dst_dir = os.path.join(destdir, systemd_unitdir.lstrip('/'), 'system')
    os.makedirs(unit_dst_dir, exist_ok=True)
    unit_dst = os.path.join(unit_dst_dir, 'cloud-connector.service')
    shutil.copy2(unit_src, unit_dst)

    # Substitute placeholders in the unit file.
    state_rel = d.getVar('STATE_DIRECTORY_REL') or ''
    if state_rel:
        state_block = 'StateDirectory=%s\nStateDirectoryMode=0700' % state_rel
    else:
        state_block = ''
    if d.getVar('SYSTEMD_JOURNAL_ACCESS'):
        supp_groups_block = 'SupplementaryGroups=systemd-journal'
    else:
        supp_groups_block = ''
    with open(unit_dst) as f:
        unit = f.read()
    with open(unit_dst, 'w') as f:
        f.write(unit.replace('@CC_DIRECTORY@', cc_dir)
                    .replace('@CC_CONFIG_PATH@', cc_config_path)
                    .replace('@STATE_DIRECTORY_BLOCK@', state_block)
                    .replace('@SUPPLEMENTARY_GROUPS_BLOCK@', supp_groups_block))

    # polkit reboot rule (polkit-reboot PACKAGECONFIG only).
    if 'polkit-reboot' in (d.getVar('PACKAGECONFIG') or '').split():
        import subprocess
        rule_src = os.path.join(workdir, '10-cloud-connector-reboot.rules')
        sysconfdir = d.getVar('sysconfdir')
        rules_dir = os.path.join(destdir, sysconfdir.lstrip('/'), 'polkit-1', 'rules.d')
        os.makedirs(rules_dir, exist_ok=True)
        shutil.copy2(rule_src, os.path.join(rules_dir, '10-cloud-connector-reboot.rules'))
        # rules.d is shared with polkit; match its 0700 polkitd:root or rpm
        # rejects the conflicting dir metadata.
        os.chmod(rules_dir, 0o700)
        subprocess.check_call(['chown', 'polkitd:root', rules_dir])

    # /usr/bin/cloud-connector wrapper: binary on PATH with --config baked in.
    wrapper_dir = os.path.join(destdir, 'usr', 'bin')
    os.makedirs(wrapper_dir, exist_ok=True)
    wrapper_path = os.path.join(wrapper_dir, 'cloud-connector')
    with open(wrapper_path, 'w') as f:
        f.write('#!/bin/sh\nexec %s/cloud-connector --config %s "$@"\n' % (cc_dir, cc_config_path))
    os.chmod(wrapper_path, 0o755)

    # The TLS credentials dir is not created here: under /var/lib it is
    # provisioned by StateDirectory=; elsewhere it is the integrator's (warned
    # at parse time).

    # tmpfiles.d: grant the cloud-connector group write on each EVerest config dir
    # so the daemon can swap the config symlink. Non-recursive.
    everest_dirs = (d.getVar('EVEREST_CONFIG_DIRS') or '').split()
    if everest_dirs:
        sysconfdir = d.getVar('sysconfdir')
        tmpfiles_dir = os.path.join(destdir, sysconfdir.lstrip('/'), 'tmpfiles.d')
        os.makedirs(tmpfiles_dir, exist_ok=True)
        lines = [
            "# Generated by cloudconnector-install.bbclass.",
            "# Lets the cloud-connector group write the EVerest config dir(s) so",
            "# the daemon can swap the config symlink (config switching).",
        ]
        lines += ['z %s 0775 root cloud-connector -' % p for p in everest_dirs]
        with open(os.path.join(tmpfiles_dir, 'cloud-connector-everest.conf'), 'w') as f:
            f.write('\n'.join(lines) + '\n')
}

inherit systemd
