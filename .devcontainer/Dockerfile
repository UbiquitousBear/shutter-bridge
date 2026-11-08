# Linux development container for Shutter Bridge: PTPKit's tests, the docs and the fixture scripts. It can't build
# the spike app or reach a camera; those need Xcode 27 on a Mac and a physical iPhone.
#
# The base image is the one CI's Linux job (.github/workflows/ptpkit.yml) and `make test-docker` use: Swift 6.4,
# the compiler in Xcode 27. Change it there, in the Makefile and in docs/ci.md too (AGENTS.md).
FROM swift:6.4-noble

# make for the Makefile, python3 for scripts/redact-fixtures.py (`make fixtures`), openssh-client for git over SSH,
# sudo so the container's user can add packages.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        make python3 openssh-client less sudo \
 && rm -rf /var/lib/apt/lists/* \
 && echo 'ubuntu ALL=(root) NOPASSWD:ALL' > /etc/sudoers.d/ubuntu \
 && chmod 0440 /etc/sudoers.d/ubuntu
