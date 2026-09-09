# Test container for the AVD image-setup scripts.
#
# Runs both suites: Pester against the guest PowerShell script, and the zsh
# behavioural tests against deploy.sh with a mocked Azure CLI. Neither suite
# touches Azure or a Windows host, so this runs identically in CI and locally.
#
# PowerShell is installed from Microsoft's own release tarball rather than the
# mcr.microsoft.com/powershell image, which publishes no linux/arm64 variant -
# on Apple silicon that image only runs under emulation, where the Pester
# install reliably OOMs.
FROM debian:12-slim

ARG PS_VERSION=7.4.7
ARG PESTER_VERSION=5.6.1
ENV PESTER_VERSION=${PESTER_VERSION}

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      zsh curl ca-certificates libicu72 less \
 && rm -rf /var/lib/apt/lists/*

# Map Debian's arch name onto the one PowerShell releases use.
RUN set -eux; \
    deb_arch="$(dpkg --print-architecture)"; \
    case "$deb_arch" in \
      amd64) ps_arch=x64   ;; \
      arm64) ps_arch=arm64 ;; \
      *) echo "unsupported architecture: $deb_arch" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/PowerShell/PowerShell/releases/download/v${PS_VERSION}/powershell-${PS_VERSION}-linux-${ps_arch}.tar.gz"; \
    echo "installing PowerShell ${PS_VERSION} for ${ps_arch}"; \
    mkdir -p /opt/microsoft/powershell/7; \
    curl -fsSL "$url" -o /tmp/powershell.tar.gz; \
    tar zxf /tmp/powershell.tar.gz -C /opt/microsoft/powershell/7; \
    rm /tmp/powershell.tar.gz; \
    chmod +x /opt/microsoft/powershell/7/pwsh; \
    ln -sf /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh; \
    pwsh --version

RUN pwsh -NoLogo -NonInteractive -Command \
      "Set-PSRepository PSGallery -InstallationPolicy Trusted; \
       Install-Module Pester -RequiredVersion \$env:PESTER_VERSION -Scope AllUsers -Force; \
       (Import-Module Pester -MinimumVersion 5.0 -PassThru).Version"

WORKDIR /work
COPY . /work

RUN chmod +x /work/run-tests.sh /work/deploy.sh /work/update.sh /work/teardown.sh \
             /work/repair.sh /work/shortcuts.sh /work/common.sh \
             /work/tests/test_deploy.zsh /work/tests/test_repair.zsh \
             /work/tests/test_shortcuts.zsh /work/tests/mocks/az

ENTRYPOINT ["/work/run-tests.sh"]
