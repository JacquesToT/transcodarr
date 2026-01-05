"""
Data collector for Transcodarr Monitor.
Collects data from various sources: local processes, SSH, NFS mounts.

Security note: This module uses asyncio.create_subprocess_exec with explicit
argument lists, which is safe from shell injection attacks.
"""

import asyncio
import re
import subprocess
from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional
from enum import Enum

from .config import get_config, TranscodarrConfig


class ConnectionStatus(Enum):
    """Status of a connection."""
    CONNECTED = "connected"
    DISCONNECTED = "disconnected"
    CHECKING = "checking"
    ERROR = "error"


@dataclass
class TranscodeJob:
    """Represents an active transcode job."""
    filename: str
    input_codec: str = ""
    output_codec: str = ""
    progress: float = 0.0
    speed: str = ""
    eta: str = ""
    bitrate: str = ""
    started_at: Optional[datetime] = None


@dataclass
class TranscodeHistoryItem:
    """A completed transcode from history."""
    filename: str
    timestamp: datetime
    duration: str
    success: bool
    error_message: str = ""


@dataclass
class SystemStatus:
    """Overall system status."""
    ssh_status: ConnectionStatus = ConnectionStatus.CHECKING
    nfs_media_status: ConnectionStatus = ConnectionStatus.CHECKING
    nfs_cache_status: ConnectionStatus = ConnectionStatus.CHECKING
    jellyfin_status: ConnectionStatus = ConnectionStatus.CHECKING

    ssh_error: str = ""
    nfs_media_error: str = ""
    nfs_cache_error: str = ""
    jellyfin_error: str = ""

    # Mode indicator
    is_synology: bool = False


@dataclass
class CollectedData:
    """All collected data for the monitor."""
    status: SystemStatus = field(default_factory=SystemStatus)
    active_transcodes: list[TranscodeJob] = field(default_factory=list)
    history: list[TranscodeHistoryItem] = field(default_factory=list)
    logs: list[str] = field(default_factory=list)
    rffmpeg_hosts: list[dict] = field(default_factory=list)
    last_updated: Optional[datetime] = None


class DataCollector:
    """Collects monitoring data from various sources."""

    def __init__(self, config: Optional[TranscodarrConfig] = None):
        self.config = config or get_config()
        self._data = CollectedData()

    @property
    def data(self) -> CollectedData:
        """Get the current collected data."""
        return self._data

    async def collect_all(self) -> CollectedData:
        """Collect all data, ensuring connection check completes before dependent tasks."""
        if self.config.is_synology:
            # Local Synology mode: No SSH needed, docker exec directly
            self._data.status.is_synology = True
            self._data.status.ssh_status = ConnectionStatus.CONNECTED
            self._data.status.ssh_error = ""

            # Check local paths exist (instead of NFS mounts)
            await self.check_local_paths()

            # Get rffmpeg data directly
            await asyncio.gather(
                self.get_rffmpeg_status(),
                self.get_rffmpeg_logs(),
                return_exceptions=True
            )
        else:
            # Remote Mac mode: SSH to NAS
            # Phase 1: Check connections first (SSH must complete before rffmpeg checks)
            await asyncio.gather(
                self.check_ssh_connection(),
                self.check_nfs_mounts(),
                self.get_local_ffmpeg_processes(),
                return_exceptions=True
            )

            # Phase 2: SSH-dependent tasks (only run after SSH status is known)
            await asyncio.gather(
                self.get_rffmpeg_status(),
                self.get_rffmpeg_logs(),
                return_exceptions=True
            )

        self._data.last_updated = datetime.now()
        return self._data

    async def check_local_paths(self) -> None:
        """Check paths inside Jellyfin container (for Synology mode).

        On Synology, we check inside the container because that's where
        the paths are mounted, not on the host filesystem.
        """
        # Check media path inside container
        try:
            cmd = self.config.get_docker_command("test -d /data/media && echo ok")
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=5)
            if b"ok" in stdout:
                self._data.status.nfs_media_status = ConnectionStatus.CONNECTED
            else:
                self._data.status.nfs_media_status = ConnectionStatus.DISCONNECTED
                self._data.status.nfs_media_error = "/data/media not in container"
        except Exception:
            self._data.status.nfs_media_status = ConnectionStatus.ERROR
            self._data.status.nfs_media_error = "Check failed"

        # Check cache path inside container
        try:
            cmd = self.config.get_docker_command("test -d /config/cache && echo ok")
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=5)
            if b"ok" in stdout:
                self._data.status.nfs_cache_status = ConnectionStatus.CONNECTED
            else:
                self._data.status.nfs_cache_status = ConnectionStatus.DISCONNECTED
                self._data.status.nfs_cache_error = "/config/cache not in container"
        except Exception:
            self._data.status.nfs_cache_status = ConnectionStatus.ERROR
            self._data.status.nfs_cache_error = "Check failed"

    async def check_ssh_connection(self) -> bool:
        """Check if SSH to NAS is working."""
        self._data.status.ssh_status = ConnectionStatus.CHECKING

        try:
            cmd = self.config.get_ssh_command("echo ok")
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            stdout, stderr = await asyncio.wait_for(
                proc.communicate(),
                timeout=self.config.ssh_timeout + 2
            )

            if proc.returncode == 0 and b"ok" in stdout:
                self._data.status.ssh_status = ConnectionStatus.CONNECTED
                self._data.status.ssh_error = ""
                return True
            else:
                self._data.status.ssh_status = ConnectionStatus.ERROR
                error_msg = stderr.decode().strip()
                # Make the error more user-friendly
                if "Permission denied" in error_msg or "password" in error_msg.lower():
                    self._data.status.ssh_error = f"Auth failed for {self.config.nas_user}@{self.config.nas_ip}"
                elif "Connection refused" in error_msg:
                    self._data.status.ssh_error = f"SSH refused at {self.config.nas_ip}:22"
                elif "No route to host" in error_msg or "Host unreachable" in error_msg:
                    self._data.status.ssh_error = f"Cannot reach {self.config.nas_ip}"
                else:
                    self._data.status.ssh_error = error_msg[:100]
                return False

        except asyncio.TimeoutError:
            self._data.status.ssh_status = ConnectionStatus.DISCONNECTED
            self._data.status.ssh_error = "Connection timeout"
            return False
        except Exception as e:
            self._data.status.ssh_status = ConnectionStatus.ERROR
            self._data.status.ssh_error = str(e)[:100]
            return False

    async def check_nfs_mounts(self) -> tuple[bool, bool]:
        """Check if NFS mounts are active."""
        try:
            proc = await asyncio.create_subprocess_exec(
                "mount",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            stdout, _ = await proc.communicate()
            mount_output = stdout.decode()

            # Check media mount
            if "/data/media" in mount_output:
                self._data.status.nfs_media_status = ConnectionStatus.CONNECTED
            else:
                self._data.status.nfs_media_status = ConnectionStatus.DISCONNECTED
                self._data.status.nfs_media_error = "Not mounted"

            # Check cache mount
            if "jellyfin" in mount_output.lower() and "cache" in mount_output.lower():
                self._data.status.nfs_cache_status = ConnectionStatus.CONNECTED
            elif "/config/cache" in mount_output:
                self._data.status.nfs_cache_status = ConnectionStatus.CONNECTED
            else:
                self._data.status.nfs_cache_status = ConnectionStatus.DISCONNECTED
                self._data.status.nfs_cache_error = "Not mounted"

            return (
                self._data.status.nfs_media_status == ConnectionStatus.CONNECTED,
                self._data.status.nfs_cache_status == ConnectionStatus.CONNECTED
            )

        except Exception as e:
            self._data.status.nfs_media_status = ConnectionStatus.ERROR
            self._data.status.nfs_cache_status = ConnectionStatus.ERROR
            self._data.status.nfs_media_error = str(e)[:50]
            self._data.status.nfs_cache_error = str(e)[:50]
            return False, False

    async def get_local_ffmpeg_processes(self) -> list[TranscodeJob]:
        """Get active ffmpeg processes on this Mac."""
        try:
            proc = await asyncio.create_subprocess_exec(
                "pgrep", "-lf", "ffmpeg",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            stdout, _ = await proc.communicate()

            if proc.returncode != 0:
                self._data.active_transcodes = []
                return []

            jobs = []
            for line in stdout.decode().strip().split("\n"):
                if not line or "pgrep" in line:
                    continue

                job = self._parse_ffmpeg_process(line)
                if job:
                    jobs.append(job)

            self._data.active_transcodes = jobs
            return jobs

        except Exception:
            return []

    def _parse_ffmpeg_process(self, line: str) -> Optional[TranscodeJob]:
        """Parse an ffmpeg process line into a TranscodeJob."""
        try:
            input_match = re.search(r'-i\s+["\']?([^"\']+)["\']?', line)
            if input_match:
                input_path = input_match.group(1)
                filename = input_path.split("/")[-1]
            else:
                filename = "Unknown"

            video_codec = ""
            if "h264_videotoolbox" in line:
                video_codec = "H.264 (VideoToolbox)"
            elif "hevc_videotoolbox" in line:
                video_codec = "HEVC (VideoToolbox)"
            elif "libx264" in line:
                video_codec = "H.264 (CPU)"
            elif "libx265" in line:
                video_codec = "HEVC (CPU)"

            return TranscodeJob(
                filename=filename,
                output_codec=video_codec,
            )
        except Exception:
            return None

    async def get_rffmpeg_status(self) -> list[dict]:
        """Get rffmpeg status from Jellyfin container.

        Works in both modes:
        - Synology: Direct docker command
        - Mac: SSH to NAS then docker command
        """
        if self._data.status.ssh_status != ConnectionStatus.CONNECTED:
            return []

        try:
            # get_docker_command handles both local Synology and remote Mac modes
            cmd = self.config.get_docker_command(
                "rffmpeg status 2>/dev/null || echo 'rffmpeg not available'"
            )
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            stdout, _ = await asyncio.wait_for(
                proc.communicate(),
                timeout=10
            )

            output = stdout.decode().strip()
            if "not available" in output or not output:
                return []

            hosts = self._parse_rffmpeg_status(output)
            self._data.rffmpeg_hosts = hosts
            return hosts

        except Exception:
            return []

    def _parse_rffmpeg_status(self, output: str) -> list[dict]:
        """Parse rffmpeg status output."""
        hosts = []
        lines = output.strip().split("\n")

        for line in lines[1:]:
            if not line.strip():
                continue

            parts = line.split()
            if len(parts) >= 5:
                hosts.append({
                    "hostname": parts[0],
                    "servername": parts[1] if len(parts) > 1 else "",
                    "id": parts[2] if len(parts) > 2 else "",
                    "weight": parts[3] if len(parts) > 3 else "",
                    "state": parts[4] if len(parts) > 4 else "",
                    "active": parts[5] if len(parts) > 5 else "0",
                })

        return hosts

    async def get_rffmpeg_logs(self, lines: int = 50) -> list[str]:
        """Get recent rffmpeg logs from Jellyfin container.

        Works in both modes:
        - Synology: Direct docker command
        - Mac: SSH to NAS then docker command
        """
        if self._data.status.ssh_status != ConnectionStatus.CONNECTED:
            return []

        try:
            # get_docker_command handles both local Synology and remote Mac modes
            cmd = self.config.get_docker_command(
                f"tail -{lines} /config/log/rffmpeg.log 2>/dev/null || echo 'No logs'"
            )
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            stdout, _ = await asyncio.wait_for(
                proc.communicate(),
                timeout=10
            )

            output = stdout.decode().strip()
            if "No logs" in output:
                return []

            log_lines = output.split("\n")
            self._data.logs = log_lines
            self._parse_history_from_logs(log_lines)
            return log_lines

        except Exception:
            return []

    def _parse_history_from_logs(self, log_lines: list[str]) -> list[TranscodeHistoryItem]:
        """Parse transcode history from log lines."""
        history = []

        for line in log_lines:
            if "completed" in line.lower() or "finished" in line.lower():
                try:
                    timestamp_match = re.search(r"(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})", line)
                    timestamp = datetime.now()
                    if timestamp_match:
                        timestamp = datetime.strptime(
                            timestamp_match.group(1),
                            "%Y-%m-%d %H:%M:%S"
                        )

                    file_match = re.search(r"([^\s/]+\.(mkv|mp4|avi|mov|m4v))", line, re.I)
                    filename = file_match.group(1) if file_match else "Unknown"

                    history.append(TranscodeHistoryItem(
                        filename=filename,
                        timestamp=timestamp,
                        duration="",
                        success="error" not in line.lower() and "failed" not in line.lower(),
                    ))
                except Exception:
                    continue

        self._data.history = history[-20:]
        return history

    async def check_jellyfin_api(self) -> bool:
        """Check if Jellyfin API is accessible (optional)."""
        if not self.config.jellyfin_api_key:
            self._data.status.jellyfin_status = ConnectionStatus.DISCONNECTED
            self._data.status.jellyfin_error = "No API key"
            return False

        try:
            import aiohttp
            async with aiohttp.ClientSession() as session:
                url = f"{self.config.jellyfin_url}/System/Info"
                headers = {"X-Emby-Token": self.config.jellyfin_api_key}
                async with session.get(url, headers=headers, timeout=5) as resp:
                    if resp.status == 200:
                        self._data.status.jellyfin_status = ConnectionStatus.CONNECTED
                        return True
                    else:
                        self._data.status.jellyfin_status = ConnectionStatus.ERROR
                        self._data.status.jellyfin_error = f"HTTP {resp.status}"
                        return False
        except ImportError:
            self._data.status.jellyfin_status = ConnectionStatus.DISCONNECTED
            self._data.status.jellyfin_error = "aiohttp not installed"
            return False
        except Exception as e:
            self._data.status.jellyfin_status = ConnectionStatus.ERROR
            self._data.status.jellyfin_error = str(e)[:50]
            return False
