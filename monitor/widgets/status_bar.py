"""Status bar widget showing connection statuses."""

from textual.app import ComposeResult
from textual.widgets import Static
from textual.reactive import reactive

from ..data_collector import ConnectionStatus, SystemStatus


class StatusBar(Static):
    """Widget showing connection status indicators."""

    DEFAULT_CSS = """
    StatusBar {
        height: 3;
        background: $surface;
        border: solid $primary;
        padding: 0 1;
    }

    StatusBar .status-label {
        width: auto;
    }

    StatusBar .connected {
        color: $success;
    }

    StatusBar .disconnected {
        color: $error;
    }

    StatusBar .checking {
        color: $warning;
    }
    """

    status: reactive[SystemStatus] = reactive(SystemStatus)

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self._status = SystemStatus()

    def compose(self) -> ComposeResult:
        yield Static(self._render_status(), id="status-content")

    def update_status(self, status: SystemStatus) -> None:
        """Update the status display."""
        self._status = status
        content = self.query_one("#status-content", Static)
        content.update(self._render_status())

    def _render_status(self) -> str:
        """Render the status bar content."""
        if self._status.is_synology:
            # Local Synology mode - show Docker and local paths
            docker = self._format_indicator("Docker", self._status.ssh_status)
            media = self._format_indicator("Media", self._status.nfs_media_status)
            cache = self._format_indicator("Cache", self._status.nfs_cache_status)
            return f"  [cyan]LOCAL[/cyan]    {docker}    {media}    {cache}"
        else:
            # Remote Mac mode - show SSH and NFS mounts
            ssh = self._format_indicator("SSH", self._status.ssh_status)
            nfs_media = self._format_indicator("NFS Media", self._status.nfs_media_status)
            nfs_cache = self._format_indicator("NFS Cache", self._status.nfs_cache_status)
            return f"  {ssh}    {nfs_media}    {nfs_cache}"

    def _format_indicator(self, label: str, status: ConnectionStatus) -> str:
        """Format a single status indicator."""
        if status == ConnectionStatus.CONNECTED:
            return f"[green]\u25cf[/green] {label}"
        elif status == ConnectionStatus.DISCONNECTED:
            return f"[red]\u25cb[/red] {label}"
        elif status == ConnectionStatus.CHECKING:
            return f"[yellow]\u25cb[/yellow] {label}"
        else:  # ERROR
            return f"[red]\u25cf[/red] {label}"
