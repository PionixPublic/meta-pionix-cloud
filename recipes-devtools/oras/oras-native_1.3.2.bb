SUMMARY = "ORAS CLI — OCI Registry As Storage"
DESCRIPTION = "Command-line tool for pushing and pulling OCI artifacts. \
Used at build time by cloudconnector-install.bbclass to fetch the cloud \
connector binary and plugins from an OCI registry."
HOMEPAGE = "https://oras.land"
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://LICENSE;md5=019fcb726ce54798fc2e56a02520dae8"

inherit native

# Map build-host CPU to the ORAS release archive name and sha256.
# Checksums from oras_1.3.2_checksums.txt on the GitHub release page.
python __anonymous() {
    build_arch = d.getVar('BUILD_ARCH')
    pv = d.getVar('PV')

    arch_map = {
        'x86_64':  ('amd64', '9229ccc6d17bb282039ad4a69abb16dcb887a5bce567c075d731d9b3c7ad8eaf'),
        'aarch64': ('arm64', '8db4a223bd6034deff198e791ea7cb3af0840df25b7e9f370e2f1f3fd20d389b'),
    }

    if build_arch not in arch_map:
        bb.fatal('oras-native: unsupported build host architecture: %s' % build_arch)

    oras_arch, sha256 = arch_map[build_arch]
    url = 'https://github.com/oras-project/oras/releases/download/v%s/oras_%s_linux_%s.tar.gz' % (pv, pv, oras_arch)
    d.setVar('SRC_URI', url)
    d.setVarFlag('SRC_URI', 'sha256sum', sha256)
}

S = "${WORKDIR}"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${S}/oras ${D}${bindir}/oras
}
