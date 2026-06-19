SUMMARY = "Pionix Cloud Connector"
DESCRIPTION = "Cloud connectivity service for EV charging devices. \
Fetches the cloud-connector binary and OCI plugins from a registry, \
installs them at paths declared in cloudconnector.yaml, and installs \
a systemd unit to run the service."
HOMEPAGE = "https://pionix.com"
LICENSE = "CLOSED"

# _%.bb yields PV="%", which is invalid for RPM packaging. Pin a real version.
PV = "0.0.1"

SRC_URI = "file://cloudconnector.service \
           file://10-cloudconnector-reboot.rules \
           "

# polkit-reboot: install a polkit rule authorizing the unprivileged service user
# to reboot via logind (needed after an OTA). Default on; remove it if the image
# authorizes reboots another way (root or CAP_SYS_BOOT).
PACKAGECONFIG ??= "polkit-reboot"
PACKAGECONFIG[polkit-reboot] = ",,,polkit"

DEPENDS = "oras-native python3-pyyaml-native"

inherit cloudconnector-install useradd systemd

SYSTEMD_SERVICE:${PN} = "cloudconnector.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

# Path vars are set at parse time by cloudconnector-install.bbclass.
FILES:${PN} = " \
    ${CC_DIRECTORY} \
    ${PLUGINS_DIRECTORY} \
    ${CC_CONFIG_PATH} \
    /usr/bin/cloudconnector \
    ${systemd_unitdir}/system/cloudconnector.service \
    ${sysconfdir}/tmpfiles.d/cloudconnector-everest.conf \
"

# Installed only under the polkit-reboot PACKAGECONFIG; unlisted paths are fine.
FILES:${PN} += "${sysconfdir}/polkit-1/rules.d/10-cloudconnector-reboot.rules"

GROUPADD_PARAM:${PN} = "-r cloudconnector"
USERADD_PARAM:${PN} = "-r -g cloudconnector -s /sbin/nologin -d /nonexistent cloudconnector"
GROUPMEMS_PARAM:${PN} = "-g cloudconnector -a root"
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
