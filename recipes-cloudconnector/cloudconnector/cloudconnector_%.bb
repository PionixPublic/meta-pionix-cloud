SUMMARY = "Pionix Cloud Connector"
DESCRIPTION = "Cloud connectivity service for EV charging devices. \
Fetches the cloud-connector binary and OCI plugins from a registry, \
installs them at paths declared in cloudconnector.yaml, and installs \
a systemd unit to run the service."
HOMEPAGE = "https://pionix.com"
LICENSE = "CLOSED"

# _%.bb gives PV="%", which breaks RPM spec generation. Pin to a valid version.
PV = "0.0.1"

# The systemd unit template lives alongside this recipe in files/.
# BitBake's standard do_unpack places it in WORKDIR for do_install to consume.
SRC_URI = "file://cloudconnector.service"

# oras-native provides the `oras` command used in do_fetch_oci.
# python3-pyyaml-native is needed for YAML parsing in __anonymous().
DEPENDS = "oras-native python3-pyyaml-native"

inherit cloudconnector-install

# CC_DIRECTORY, PLUGINS_DIRECTORY, and CLIENT_CREDENTIALS_DIR are set by
# cloudconnector-install.bbclass __anonymous() at parse time.
FILES:${PN} = " \
    ${CC_DIRECTORY} \
    ${PLUGINS_DIRECTORY} \
    /etc/cloudconnector \
    ${systemd_unitdir}/system/cloudconnector.service \
    ${CLIENT_CREDENTIALS_DIR} \
"

# Runtime deps of the pre-compiled OCI artifacts.
RDEPENDS:${PN} += "libcurl openssl zlib"

# The binary is pulled pre-compiled from the registry; there is no source to
# reference debug symbols against, so suppress the QA split.
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_PACKAGE_DEBUG_SPLIT = "1"
# Pre-compiled OCI artifacts: shlibs auto-detection can't resolve all providers.
INSANE_SKIP:${PN} += "file-rdeps"
# libprotobuf/libprotoc are bundled privately by both the cc binary and each plugin
# OCI artifact, landing in multiple directories within this package. Exclude them
# from the global shlib database so Yocto does not see duplicate providers.
EXCLUDE_FROM_SHLIBS = "1"
