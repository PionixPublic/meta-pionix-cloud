SUMMARY = "Pionix Cloud Connector"
DESCRIPTION = "Cloud connectivity service for EV charging devices. \
Fetches the cloud-connector binary and OCI plugins from a registry, \
installs them at paths declared in cloud-connector.yaml, and installs \
a systemd unit to run the service."
HOMEPAGE = "https://pionix.com"
LICENSE = "CLOSED"

# _%.bb yields PV="%", which is invalid for RPM packaging. Pin a real version.
PV = "0.3.0"

SRC_URI = "file://cloud-connector.service \
           file://10-cloud-connector-reboot.rules \
           file://dbus-cloudconnector-rauc.conf \
           "

# polkit-reboot: lets the unprivileged user reboot via logind. Always on;
# reboot_command is a free-form shell string, so unlike rauc-dbus-access below
# this can't be derived from the config. Remove it if reboots are authorized
# another way (root or CAP_SYS_BOOT).
PACKAGECONFIG ??= "polkit-reboot ${@'rauc-dbus-access' if d.getVar('CLOUDCONNECTOR_RAUC_UPDATER_ENABLED') else ''}"
PACKAGECONFIG[polkit-reboot] = ",,,polkit"

# rauc-dbus-access: D-Bus policy for RAUC's Installer interface (root-only by
# default). Defaults on iff the rauc-updater plugin is enabled in the config.
PACKAGECONFIG[rauc-dbus-access] = ""

DEPENDS = "oras-native python3-pyyaml-native"

inherit cloudconnector-install useradd systemd

SYSTEMD_SERVICE:${PN} = "cloud-connector.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

# Path vars are set at parse time by cloudconnector-install.bbclass.
FILES:${PN} = " \
    ${CC_DIRECTORY} \
    ${PLUGINS_DIRECTORY} \
    ${CC_CONFIG_PATH} \
    /usr/bin/cloud-connector \
    ${systemd_unitdir}/system/cloud-connector.service \
    ${sysconfdir}/tmpfiles.d/cloud-connector-everest.conf \
"

# Installed only under their respective PACKAGECONFIG flags; unlisted paths are fine.
FILES:${PN} += "${sysconfdir}/polkit-1/rules.d/10-cloud-connector-reboot.rules"
FILES:${PN} += "${sysconfdir}/dbus-1/system.d/dbus-cloudconnector-rauc.conf"

python do_install:append() {
    import os
    import shutil

    if 'rauc-dbus-access' in (d.getVar('PACKAGECONFIG') or '').split():
        workdir = d.getVar('WORKDIR')
        destdir = d.getVar('D')
        sysconfdir = d.getVar('sysconfdir')
        policy_dir = os.path.join(destdir, sysconfdir.lstrip('/'), 'dbus-1', 'system.d')
        os.makedirs(policy_dir, exist_ok=True)
        shutil.copy2(
            os.path.join(workdir, 'dbus-cloudconnector-rauc.conf'),
            os.path.join(policy_dir, 'dbus-cloudconnector-rauc.conf'),
        )
}

GROUPADD_PARAM:${PN} = "-r cloud-connector"
USERADD_PARAM:${PN} = "-r -g cloud-connector -s /sbin/nologin -d /nonexistent cloud-connector"
GROUPMEMS_PARAM:${PN} = "-g cloud-connector -a root"
USERADD_PACKAGES = "${PN}"

# Declare polkitd (matching polkit's own definition) so do_install can chown the
# shared rules.d to polkitd:root and avoid an rpm dir-ownership conflict.
USERADD_PARAM:${PN} += "${@bb.utils.contains('PACKAGECONFIG', 'polkit-reboot', '; --system --no-create-home --user-group --home-dir ${sysconfdir}/polkit-1 polkitd', '', d)}"

# Pre-compiled, fully static musl binaries: no .so consumed or provided, no
# source for debug info, and not to be rewritten (may be digest-pinned). Disable
# the QA checks that assume a source-built, dynamically-linked package.
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_PACKAGE_DEBUG_SPLIT = "1"
INSANE_SKIP:${PN} += "file-rdeps"
EXCLUDE_FROM_SHLIBS = "1"
