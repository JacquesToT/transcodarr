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
from datetime import datetime, date
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
class NodeStats:
    """Statistics for a transcode node (Mac)."""
    hostname: str
    ip: str
    cpu_percent: float = 0.0
    memory_used_gb: float = 0.0
    memory_total_gb: float = 0.0
    memory_percent: float = 0.0
    network_down_mbps: float = 0.0
    network_up_mbps: float = 0.0
    transcodes_today: int = 0
    state: str = "unknown"  # idle, active, bad
    weight: int = 1
    is_online: bool = False
    error: str = ""


@dataclass
class TranscodeJob:
    """Represents an active transcode job."""
    filename: str
    node_ip: str = ""  # Which node is running this job
    pid: int = 0
    input_codec: str = ""
    output_codec: str = ""
    input_resolution: str = ""  # e.g., "1920x1080"
    output_resolution: str = ""  # e.g., "1280x720"
    fps: float = 0.0  # Current encoding fps
    speed: str = ""  # e.g., "1.2x"
    progress: float = 0.0
    eta: str = ""
    bitrate: str = ""
    audio_codec: str = ""
    started_at: Optional[datetime] = None
    cpu_percent: float = 0.0  # CPU usage of this specific ffmpeg process


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
    node_stats: list[NodeStats] = field(default_factory=list)  # Per-node CPU/Memory stats
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

            # Phase 1: Get rffmpeg status first (we need host list for stats)
            await self.get_rffmpeg_status()

            # Phase 2: Get node stats, active transcodes, and logs in parallel
            await asyncio.gather(
                self.get_all_node_stats(),
                self.get_rffmpeg_logs(),
                return_exceptions=True
            )
        else:
            # Remote Mac mode: SSH to NAS
            # Phase 1: Check connections first (SSH must complete before rffmpeg checks)
            await asyncio.gather(
                self.check_ssh_connection(),
                self.check_nfs_mounts(),
                self.get_active_transcodes(),
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

    async def get_active_transcodes(self) -> list[TranscodeJob]:
        """Get active ffmpeg/transcode processes.

        On Synology: Check inside jellyfin container
        On Mac: Check local processes
        """
        if self.config.is_synology:
            return await self._get_container_ffmpeg_processes()
        else:
            return await self._get_local_ffmpeg_processes()

    async def _get_container_ffmpeg_processes(self) -> list[TranscodeJob]:
        """Get active ffmpeg processes inside jellyfin container."""
        try:
            # Check for ffmpeg processes in the container
            cmd = self.config.get_docker_command("ps aux | grep -E 'ffmpeg|rffmpeg' | grep -v grep")
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=5)

            if not stdout.strip():
                self._data.active_transcodes = []
                return []

            jobs = []
            for line in stdout.decode().strip().split("\n"):
                if not line or "grep" in line:
                    continue
                job = self._parse_ffmpeg_process(line)
                if job:
                    jobs.append(job)

            self._data.active_transcodes = jobs
            return jobs

        except Exception:
            self._data.active_transcodes = []
            return []

    async def _get_local_ffmpeg_processes(self) -> list[TranscodeJob]:
        """Get active ffmpeg processes on local Mac."""
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
            cmd = self.config.get_docker_command("rffmpeg status")
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            stdout, stderr = await asyncio.wait_for(
                proc.communicate(),
                timeout=10
            )

            output = stdout.decode().strip()

            if not output or proc.returncode != 0:
                return []

            hosts = self._parse_rffmpeg_status(output)
            self._data.rffmpeg_hosts = hosts
            return hosts

        except Exception:
            return []

    def _parse_rffmpeg_status(self, output: str) -> list[dict]:
        """Parse rffmpeg status output.

        Output format:
        Hostname        Servername      ID  Weight  State   Active Commands
        192.168.175.43  192.168.175.43  1   4       active  PID 123: ffmpeg ...
                                                            PID 456: ffmpeg ...

        Note: Active Commands can span multiple lines with continuation.
        Only lines starting with an IP address or hostname are new entries.
        """
        hosts = []
        lines = output.strip().split("\n")

        # Skip header line
        for line in lines[1:]:
            if not line.strip():
                continue

            # Check if this line starts a new host entry
            # Host entries start with an IP address or non-whitespace hostname
            # Continuation lines start with whitespace
            if line[0].isspace():
                # This is a continuation line (more PIDs), skip it
                continue

            parts = line.split()
            if len(parts) >= 5:
                # Validate that this looks like a host entry
                # parts[0] should be IP/hostname, parts[2] should be numeric ID
                hostname = parts[0]
                try:
                    host_id = int(parts[2])
                    weight = int(parts[3])
                except (ValueError, IndexError):
                    # Not a valid host line, skip
                    continue

                hosts.append({
                    "hostname": hostname,
                    "servername": parts[1] if len(parts) > 1 else "",
                    "id": str(host_id),
                    "weight": str(weight),
                    "state": parts[4] if len(parts) > 4 else "unknown",
                    "active": "0",  # We'll count PIDs separately if needed
                })

        return hosts

    async def get_rffmpeg_logs(self, lines: int = 50) -> list[str]:
        """Get recent rffmpeg and load balancer logs.

        Works in both modes:
        - Synology: Direct docker command / file read
        - Mac: SSH to NAS then docker command / file read
        """
        if self._data.status.ssh_status != ConnectionStatus.CONNECTED:
            return []

        all_logs: list[str] = []

        # Get rffmpeg logs from container
        try:
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
            if "No logs" not in output:
                for line in output.split("\n"):
                    if line.strip():
                        all_logs.append(f"[rffmpeg] {line}")
        except Exception:
            pass

        # Get load balancer logs from host
        try:
            lb_logs = await self._get_load_balancer_logs(lines=20)
            for line in lb_logs:
                if line.strip():
                    all_logs.append(f"[balancer] {line}")
        except Exception:
            pass

        # Sort all logs by timestamp (best effort)
        all_logs = self._sort_logs_by_timestamp(all_logs)

        self._data.logs = all_logs
        self._parse_history_from_logs(all_logs)
        return all_logs

    async def _get_load_balancer_logs(self, lines: int = 20) -> list[str]:
        """Get load balancer logs from /tmp/transcodarr-lb.log.

        Uses asyncio.create_subprocess_exec for safe command execution.
        """
        lb_log_path = "/tmp/transcodarr-lb.log"

        try:
            if self.config.is_synology:
                # Direct file read on Synology using tail
                proc = await asyncio.create_subprocess_exec(
                    "tail", f"-{lines}", lb_log_path,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE
                )
            else:
                # SSH to NAS and read file using explicit arguments
                proc = await asyncio.create_subprocess_exec(
                    "ssh", "-o", "ConnectTimeout=5",
                    f"{self.config.nas_user}@{self.config.nas_ip}",
                    f"tail -{lines} {lb_log_path} 2>/dev/null",
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE
                )

            stdout, _ = await asyncio.wait_for(
                proc.communicate(),
                timeout=5
            )

            output = stdout.decode().strip()
            if output:
                return output.split("\n")
        except Exception:
            pass

        return []

    def _sort_logs_by_timestamp(self, logs: list[str]) -> list[str]:
        """Sort logs by timestamp, newest last."""
        def extract_timestamp(line: str) -> str:
            # Try to extract timestamp like [2024-01-08 15:30:45]
            match = re.search(r'\[(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})\]', line)
            if match:
                return match.group(1)
            # Also try format without brackets
            match = re.search(r'(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})', line)
            if match:
                return match.group(1)
            return ""

        try:
            return sorted(logs, key=extract_timestamp)
        except Exception:
            return logs

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

    async def get_all_node_stats(self) -> list[NodeStats]:
        """Get stats for all registered rffmpeg nodes.

        SSH to each Mac node and collect CPU, memory, network stats.
        Also gets active ffmpeg processes with details.
        """
        if not self._data.rffmpeg_hosts:
            return []

        # Clear active transcodes - will be repopulated from each node
        self._data.active_transcodes = []

        # Get mac_user from config (for SSH to Mac nodes)
        mac_user = self._get_mac_user()

        # Collect stats for all nodes in parallel
        tasks = []
        for host in self._data.rffmpeg_hosts:
            ip = host.get("hostname", "")
            if ip:
                # Safely convert weight to int
                try:
                    weight = int(host.get("weight", 1))
                except (ValueError, TypeError):
                    weight = 1

                tasks.append(self._get_single_node_stats(
                    ip=ip,
                    mac_user=mac_user,
                    state=host.get("state", "unknown"),
                    weight=weight
                ))

        if tasks:
            results = await asyncio.gather(*tasks, return_exceptions=True)
            node_stats = [r for r in results if isinstance(r, NodeStats)]
            self._data.node_stats = node_stats
            return node_stats

        return []

    def _get_mac_user(self) -> str:
        """Get the Mac username for SSH connections."""
        try:
            import json
            from pathlib import Path
            state_file = Path.home() / ".transcodarr" / "state.json"
            if state_file.exists():
                with open(state_file) as f:
                    state = json.load(f)
                    cfg = state.get("config", {})
                    if cfg.get("mac_user"):
                        return cfg["mac_user"]
        except Exception:
            pass

        import getpass
        return getpass.getuser()

    async def _get_single_node_stats(
        self,
        ip: str,
        mac_user: str,
        state: str,
        weight: int
    ) -> NodeStats:
        """Get stats for a single Mac node via SSH.

        On Synology: SSH is executed FROM the jellyfin container (which has keys)
        On Mac: SSH is executed directly from host
        """
        node = NodeStats(
            hostname=f"{mac_user}@{ip}",
            ip=ip,
            state=state,
            weight=weight
        )

        try:
            # Remote command to get all Mac stats
            # Use markers that won't be interpreted by zsh as operators
            stats_script = (
                'echo STATS_CPU_START && top -l 1 -n 0 | grep CPU && '
                'echo STATS_MEM_START && vm_stat | head -10 && sysctl hw.memsize && '
                'echo STATS_FFMPEG_START && ps aux | grep ffmpeg | grep -v grep'
            )

            if self.config.is_synology:
                # On Synology: run SSH from inside the jellyfin container
                # The container has SSH keys set up for Mac nodes
                # Use double quotes around the remote command to avoid quoting issues
                ssh_in_container = (
                    f'ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no '
                    f'-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR '
                    f'-o BatchMode=yes -i /config/rffmpeg/.ssh/id_rsa '
                    f'{mac_user}@{ip} "{stats_script}"'
                )
                cmd = self.config.get_docker_command(ssh_in_container)
            else:
                # On Mac: run SSH directly
                cmd = [
                    "ssh",
                    "-o", "ConnectTimeout=3",
                    "-o", "StrictHostKeyChecking=no",
                    "-o", "UserKnownHostsFile=/dev/null",
                    "-o", "LogLevel=ERROR",
                    "-o", "BatchMode=yes",
                    f"{mac_user}@{ip}",
                    stats_script
                ]

            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            stdout, stderr = await asyncio.wait_for(
                proc.communicate(),
                timeout=10
            )

            output = stdout.decode()
            error_output = stderr.decode().strip()

            # Check for our marker in output - don't rely on return code
            # because `grep ffmpeg` returns exit 1 when no processes found
            if "STATS_CPU_START" in output:
                node.is_online = True
                self._parse_mac_stats(output, node)
            else:
                node.is_online = False
                # Provide helpful error message
                if "Permission denied" in error_output:
                    node.error = "SSH key rejected"
                elif "Connection refused" in error_output:
                    node.error = "SSH refused"
                elif "No route" in error_output or "unreachable" in error_output.lower():
                    node.error = "Host unreachable"
                elif error_output:
                    node.error = error_output[:40]
                else:
                    node.error = f"No stats data"

        except asyncio.TimeoutError:
            node.is_online = False
            node.error = "Timeout"
        except Exception as e:
            node.is_online = False
            node.error = str(e)[:50]

        return node

    def _parse_mac_stats(self, output: str, node: NodeStats) -> None:
        """Parse Mac stats output and update NodeStats object."""
        # Split by our markers
        sections = re.split(r'STATS_(\w+)_START', output)

        for i, section in enumerate(sections):
            section = section.strip()

            if section == "CPU" and i + 1 < len(sections):
                # Parse: CPU usage: 12.34% user, 5.67% sys, 81.99% idle
                content = sections[i + 1]
                match = re.search(r"(\d+\.?\d*)% user.*?(\d+\.?\d*)% sys", content)
                if match:
                    user = float(match.group(1))
                    sys_pct = float(match.group(2))
                    node.cpu_percent = user + sys_pct

            elif section == "MEM" and i + 1 < len(sections):
                content = sections[i + 1]
                self._parse_memory_stats(content, node)

            elif section == "FFMPEG" and i + 1 < len(sections):
                content = sections[i + 1]
                jobs = self._parse_ffmpeg_processes(content, node.ip)
                node.transcodes_today = len(jobs)
                # Add jobs to global list (cleared at start of get_all_node_stats)
                self._data.active_transcodes.extend(jobs)

    def _parse_memory_stats(self, content: str, node: NodeStats) -> None:
        """Parse vm_stat and sysctl output for memory stats."""
        page_size = 16384  # Default for Apple Silicon

        # Get total memory from hw.memsize
        memsize_match = re.search(r"hw\.memsize:\s*(\d+)", content)
        if memsize_match:
            node.memory_total_gb = int(memsize_match.group(1)) / (1024**3)

        # Calculate used memory from vm_stat
        pages_active = 0
        pages_wired = 0
        pages_compressed = 0

        for line in content.split("\n"):
            if "Pages active:" in line:
                m = re.search(r"(\d+)", line)
                if m:
                    pages_active = int(m.group(1))
            elif "Pages wired down:" in line:
                m = re.search(r"(\d+)", line)
                if m:
                    pages_wired = int(m.group(1))
            elif "Pages occupied by compressor:" in line:
                m = re.search(r"(\d+)", line)
                if m:
                    pages_compressed = int(m.group(1))

        used_pages = pages_active + pages_wired + pages_compressed
        node.memory_used_gb = (used_pages * page_size) / (1024**3)

        if node.memory_total_gb > 0:
            node.memory_percent = (node.memory_used_gb / node.memory_total_gb) * 100

    def _parse_ffmpeg_processes(self, ps_output: str, node_ip: str) -> list[TranscodeJob]:
        """Parse ps aux output for ffmpeg processes."""
        jobs = []

        for line in ps_output.strip().split("\n"):
            if not line or "grep" in line:
                continue

            # ps aux format: USER PID %CPU %MEM VSZ RSS TTY STAT START TIME COMMAND
            parts = line.split(None, 10)
            if len(parts) < 11:
                continue

            try:
                pid = int(parts[1])
                cpu_percent = float(parts[2])
                command = parts[10]
            except (ValueError, IndexError):
                continue

            job = self._parse_ffmpeg_command(command, node_ip, pid, cpu_percent)
            if job:
                jobs.append(job)

        return jobs

    def _parse_ffmpeg_command(
        self,
        command: str,
        node_ip: str,
        pid: int,
        cpu_percent: float
    ) -> Optional[TranscodeJob]:
        """Parse an ffmpeg command line into a TranscodeJob."""

        # Extract input file
        input_match = re.search(r'-i\s+(?:file:)?(.+?\.(?:mkv|mp4|avi|mov|m4v))', command, re.I)
        if input_match:
            filename = input_match.group(1).split("/")[-1]
        else:
            filename = "Unknown"

        # Extract video codec
        output_codec = ""
        if "h264_videotoolbox" in command:
            output_codec = "H.264 (HW)"
        elif "hevc_videotoolbox" in command:
            output_codec = "HEVC (HW)"
        elif "libx264" in command:
            output_codec = "H.264 (CPU)"
        elif "libx265" in command:
            output_codec = "HEVC (CPU)"
        elif "-c:v copy" in command:
            output_codec = "Copy"

        # Extract audio codec
        audio_codec = ""
        if "aac_at" in command:
            audio_codec = "AAC"
        elif "-c:a copy" in command:
            audio_codec = "Copy"

        # Extract output resolution from scale filter
        output_resolution = ""
        scale_match = re.search(r'scale=(\d+):(\d+)', command)
        if scale_match:
            output_resolution = f"{scale_match.group(1)}x{scale_match.group(2)}"

        # Estimate input resolution from maxrate
        input_resolution = ""
        maxrate_match = re.search(r'-maxrate\s+(\d+)', command)
        if maxrate_match:
            maxrate = int(maxrate_match.group(1))
            if maxrate > 15000000:
                input_resolution = "4K"
            elif maxrate > 8000000:
                input_resolution = "1080p"
            elif maxrate > 4000000:
                input_resolution = "720p"
            else:
                input_resolution = "SD"

        # Extract bitrate
        bitrate = ""
        if maxrate_match:
            bitrate = f"{int(maxrate_match.group(1)) // 1000}k"

        return TranscodeJob(
            filename=filename[:60],
            node_ip=node_ip,
            pid=pid,
            output_codec=output_codec,
            audio_codec=audio_codec,
            input_resolution=input_resolution,
            output_resolution=output_resolution,
            bitrate=bitrate,
            cpu_percent=cpu_percent,
        )

    def _count_transcodes_today(self) -> int:
        """Count transcodes completed today from logs."""
        today = date.today().isoformat()
        count = 0

        for line in self._data.logs:
            if today in line and ("Finished" in line or "completed" in line.lower()):
                if "return code 0" in line:
                    count += 1

        return count

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
