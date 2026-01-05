"""
Configuration loader for Transcodarr Monitor.
Loads settings from ~/.transcodarr/state.json
"""

import json
import os
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
    jellyfin_port: int = 8096
    jellyfin_api_key: Optional[str] = None

    # Paths
    media_path: str = "/volume1/data/media"
    cache_path: str = "/volume1/docker/jellyfin/cache"

    # SSH settings
    ssh_key_path: Optional[str] = None
    ssh_timeout: int = 5

    # Monitor settings
    refresh_interval: float = 5.0
    log_lines: int = 50

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

    def get_ssh_command(self, command: str) -> list[str]:
        """Build SSH command to run on NAS."""
        ssh_cmd = ["ssh"]

        # Add timeout
        ssh_cmd.extend(["-o", f"ConnectTimeout={self.ssh_timeout}"])

        # Disable strict host key checking for convenience
        ssh_cmd.extend(["-o", "StrictHostKeyChecking=no"])
        ssh_cmd.extend(["-o", "UserKnownHostsFile=/dev/null"])
        ssh_cmd.extend(["-o", "LogLevel=ERROR"])

        # Add key if available
        if self.ssh_key_path:
            ssh_cmd.extend(["-i", self.ssh_key_path])

        # Add host
        ssh_cmd.append(f"{self.nas_user}@{self.nas_ip}")

        # Add command
        ssh_cmd.append(command)

        return ssh_cmd


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
