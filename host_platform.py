"""Choose the default build platform from the Windows build host's own architecture.

Apps must not record which architecture a given PC has (AI-13), so the bridge works it
out per build: the local transport uses this WSL distro's architecture, which always
matches its Windows host (WSL 2 distros run natively, never emulated), and the VM
transport asks the guest. --platform still overrides either.
"""
import platform

# Architecture names as reported by uname (Linux) and by .NET's OSArchitecture (Windows).
_PLATFORMS = {
    'x86_64': 'x64', 'amd64': 'x64', 'x64': 'x64',
    'aarch64': 'ARM64', 'arm64': 'ARM64',
}


def platform_for(architecture):
    """Map an OS architecture name to the bridge's --platform value.

    Raises ValueError for architectures the bridge does not build (such as 32-bit x86),
    so the caller can ask for an explicit --platform instead of guessing.
    """
    name = architecture.strip().lower()
    if name not in _PLATFORMS:
        raise ValueError(f'Unsupported build host architecture "{architecture.strip()}"; pass --platform ARM64 or --platform x64')
    return _PLATFORMS[name]


def local_platform():
    """Return the platform of the Windows host this WSL distro runs on."""
    return platform_for(platform.machine())
