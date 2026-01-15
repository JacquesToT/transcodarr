"""
Configuration loader for Transcodarr Monitor.
Loads settings from ~/.transcodarr/state.json

Supports two modes:
- Synology mode: Running directly on NAS, uses docker exec directly
- Remote mode: Running on Mac, uses SSH to connect to NAS
"""

import json
import os
import subprocess
from pathlib import Path
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class TranscodarrConfig:
    """Configuration for Transcodarr Monitor."""

    # NAS/Synology settings
    nas_ip: str = "192.168.1.100"
    nas_user: str = ""  # Loaded from config, with fallbacks

    # Jellyfin settings
    jellyfin_container_name: str = "jellyfin"
    jellyfin_port: int = 8096
    jellyfin_api_key: Optional[str] = None

    # Paths
    media_path: str = "/volume1/data/media"
    cache_path: str = "/volume1/docker/jellyfin/cache"

    # SSH settings
    ssh_key_path: Optional[str] = None
    ssh_timeout: int = 5

    # Monitor settings
    refresh_interval: float = 10.0  # Refresh every 10 seconds
    log_lines: int = 100  # Show last 100 log lines

    # Runtime detection (set after load)
    _is_synology: Optional[bool] = field(default=None, repr=False)

    @property
    def is_synology(self) -> bool:
        """Check if running directly on Synology NAS.

        Detection criteria:
        1. /volume1 exists (Synology-specific path)
        2. Docker is available
        3. Jellyfin container exists
        """
        if self._is_synology is None:
            self._is_synology = self._detect_synology()
        return self._is_synology

    def _detect_synology(self) -> bool:
        """Detect if we're running on a Synology NAS.

        Detection methods (in order):
        1. Check for /etc/synoinfo.conf (Synology-specific file)
        2. Check for /volume1 (Synology path structure)
        3. Verify docker/jellyfin is accessible (with sudo if needed)
        """
        # Method 1: Synology-specific config file (most reliable)
        if Path("/etc/synoinfo.conf").exists():
            return True

        # Method 2: Check for Synology path structure
        if not Path("/volume1").exists():
            return False

        # Method 3: Check if docker is available (try with sudo for Synology)
        for docker_cmd in [["docker"], ["sudo", "-n", "docker"]]:
            try:
                result = subprocess.run(
                    docker_cmd + ["ps", "-q", "-f", "name=jellyfin"],
                    capture_output=True,
                    timeout=5
                )
                if result.returncode == 0 and result.stdout.strip():
                    return True
            except (subprocess.TimeoutExpired, FileNotFoundError):
                continue

        # If /volume1 exists but docker check failed, still assume Synology
        # (docker might just need interactive sudo)
        return Path("/volume1").exists()

    @classmethod
    def load(cls) -> "TranscodarrConfig":
        """Load configuration from state.json."""
        config = cls()
        state_file = Path.home() / ".transcodarr" / "state.json"

        if state_file.exists():
            try:
                with open(state_file, "r") as f:
                    state = json.load(f)

                # Extract config section
                cfg = state.get("config", {})

                if "nas_ip" in cfg:
                    config.nas_ip = cfg["nas_ip"]
                if "nas_user" in cfg and cfg["nas_user"]:
                    config.nas_user = cfg["nas_user"]
                elif "mac_user" in cfg and cfg["mac_user"]:
                    # Fallback: use mac_user for NAS SSH (common on home setups)
                    config.nas_user = cfg["mac_user"]
                if "media_path" in cfg:
                    config.media_path = cfg["media_path"]
                if "cache_path" in cfg:
                    config.cache_path = cfg["cache_path"]
                # Check both possible key names for container
                if "jellyfin_container" in cfg:
                    config.jellyfin_container_name = cfg["jellyfin_container"]
                elif "jellyfin_container_name" in cfg:
                    config.jellyfin_container_name = cfg["jellyfin_container_name"]
                if "jellyfin_port" in cfg:
                    config.jellyfin_port = cfg["jellyfin_port"]
                if "jellyfin_api_key" in cfg:
                    config.jellyfin_api_key = cfg["jellyfin_api_key"]

            except (json.JSONDecodeError, KeyError) as e:
                print(f"Warning: Could not load config: {e}")

        # Check for SSH key
        ssh_key = Path.home() / ".ssh" / "id_rsa"
        if ssh_key.exists():
            config.ssh_key_path = str(ssh_key)

        # Ensure nas_user has a value (fallback to current user)
        if not config.nas_user:
            import getpass
            config.nas_user = getpass.getuser()

        return config

    @property
    def jellyfin_url(self) -> str:
        """Get the Jellyfin base URL."""
        return f"http://{self.nas_ip}:{self.jellyfin_port}"

    def get_ssh_command(self, command: str, use_control_master: bool = True) -> list[str]:
        """Build SSH command to run on NAS.

        Args:
            command: The command to run on the NAS
            use_control_master: If True, use ControlMaster for connection reuse.
                               This allows the initial password auth to be reused
                               by subsequent connections without re-prompting.
        """
        ssh_cmd = ["ssh"]

        # Add timeout
        ssh_cmd.extend(["-o", f"ConnectTimeout={self.ssh_timeout}"])

        # Disable strict host key checking for convenience
        ssh_cmd.extend(["-o", "StrictHostKeyChecking=no"])
        ssh_cmd.extend(["-o", "UserKnownHostsFile=/dev/null"])
        ssh_cmd.extend(["-o", "LogLevel=ERROR"])

        # Use ControlMaster for connection reuse
        # This allows the initial interactive password auth to be reused
        # by subsequent async connections without re-prompting
        if use_control_master:
            control_path = f"/tmp/ssh-transcodarr-{self.nas_user}@{self.nas_ip}"
            ssh_cmd.extend(["-o", f"ControlPath={control_path}"])
            ssh_cmd.extend(["-o", "ControlMaster=auto"])
            ssh_cmd.extend(["-o", "ControlPersist=600"])  # Keep alive 10 minutes

        # Add key if available
        if self.ssh_key_path:
            ssh_cmd.extend(["-i", self.ssh_key_path])

        # Add host
        ssh_cmd.append(f"{self.nas_user}@{self.nas_ip}")

        # Add command
        ssh_cmd.append(command)

        return ssh_cmd

    def get_local_command(self, command: str) -> list[str]:
        """Build command for local execution on Synology.

        Wraps the command in sh -c for proper shell interpretation.
        """
        return ["sh", "-c", command]

    def get_docker_command(self, docker_cmd: str) -> list[str]:
        """Get command to run inside jellyfin container.

        Args:
            docker_cmd: Command to run inside the container

        Returns:
            Full command list - either direct docker exec (Synology with sudo)
            or via SSH (remote Mac)
        """
        if self.is_synology:
            # On Synology, docker typically requires sudo
            full_cmd = f"sudo docker exec {self.jellyfin_container_name} {docker_cmd}"
            return self.get_local_command(full_cmd)
        else:
            # Via SSH, the remote user likely has docker permissions
            full_cmd = f"docker exec {self.jellyfin_container_name} {docker_cmd}"
            return self.get_ssh_command(full_cmd)


# Global config instance
_config: Optional[TranscodarrConfig] = None


def get_config() -> TranscodarrConfig:
    """Get the global configuration instance."""
    global _config
    if _config is None:
        _config = TranscodarrConfig.load()
    return _config


def reload_config() -> TranscodarrConfig:
    """Reload configuration from disk."""
    global _config
    _config = TranscodarrConfig.load()
    return _config
