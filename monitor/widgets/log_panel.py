"""Panel showing rffmpeg logs."""

from textual.app import ComposeResult
from textual.widgets import Static, RichLog
from textual.containers import VerticalScroll


class LogPanel(Static):
    """Widget showing rffmpeg log output."""

    DEFAULT_CSS = """
    LogPanel {
        height: 1fr;
        background: $surface;
        border: solid $primary;
        padding: 0 1;
    }

    LogPanel #log-title {
        text-style: bold;
        color: $primary;
        padding: 0 0 1 0;
    }

    LogPanel #log-content {
        height: 1fr;
        background: $background;
        scrollbar-gutter: stable;
    }

    LogPanel .log-line {
        color: $text-muted;
    }

    LogPanel .log-error {
        color: $error;
    }

    LogPanel .log-success {
        color: $success;
    }
    """

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self._logs: list[str] = []

    def compose(self) -> ComposeResult:
        yield Static("Logs", id="log-title")
        yield RichLog(id="log-content", highlight=True, markup=True)

    def update_logs(self, logs: list[str]) -> None:
        """Update the log display with new log entries."""
        log_widget = self.query_one("#log-content", RichLog)

        if not logs:
            # No logs available - show message if we haven't already
            if not self._logs:
                log_widget.write("[dim]No rffmpeg logs found. Logs appear after transcoding activity.[/dim]")
                self._logs = ["__no_logs__"]
            return

        # Check if logs have changed
        if logs == self._logs:
            return  # No changes

        # Determine what's new
        if not self._logs or self._logs == ["__no_logs__"]:
            # First real logs - show all
            log_widget.clear()
            new_logs = logs
        elif len(logs) >= len(self._logs):
            # Logs grew or same size - check for new entries at end
            # Compare last known log to find where new ones start
            try:
                last_known = self._logs[-1]
                if last_known in logs:
                    idx = logs.index(last_known)
                    new_logs = logs[idx + 1:]
                else:
                    # Last known log not found - log probably rotated
                    log_widget.clear()
                    new_logs = logs
            except (ValueError, IndexError):
                new_logs = logs[len(self._logs):]
        else:
            # Logs shrunk (rotation) - refresh all
            log_widget.clear()
            new_logs = logs

        self._logs = logs.copy()

        for line in new_logs:
            styled_line = self._style_log_line(line)
            log_widget.write(styled_line)

    def clear_logs(self) -> None:
        """Clear the log display."""
        self._logs = []
        log_widget = self.query_one("#log-content", RichLog)
        log_widget.clear()

    def _style_log_line(self, line: str) -> str:
        """Apply styling to a log line based on content."""
        lower = line.lower()

        # Determine log source and style prefix
        prefix_style = ""
        if line.startswith("[balancer]"):
            prefix_style = "[magenta][balancer][/magenta]"
            line = line[10:].strip()  # Remove prefix for content styling
        elif line.startswith("[rffmpeg]"):
            prefix_style = "[cyan][rffmpeg][/cyan]"
            line = line[9:].strip()  # Remove prefix for content styling

        # Style content based on keywords
        if "error" in lower or "failed" in lower:
            content = f"[red]{line}[/red]"
        elif "success" in lower or "completed" in lower or "reorder" in lower:
            content = f"[green]{line}[/green]"
        elif "warning" in lower:
            content = f"[yellow]{line}[/yellow]"
        elif "ssh" in lower or "connecting" in lower or "started" in lower:
            content = f"[cyan]{line}[/cyan]"
        elif "host order" in lower or "moving" in lower:
            content = f"[blue]{line}[/blue]"
        else:
            content = f"[dim]{line}[/dim]"

        if prefix_style:
            return f"{prefix_style} {content}"
        return content
