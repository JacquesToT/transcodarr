"""Node card widget showing per-node stats and active transcodes."""

from textual.app import ComposeResult
from textual.widgets import Static
from textual.containers import Vertical, Container

from ..data_collector import NodeStats, TranscodeJob


class NodeCard(Container):
    """Widget showing a single transcode node with stats and jobs."""

    DEFAULT_CSS = """
    NodeCard {
        height: auto;
        min-height: 5;
        background: $surface;
        border: solid $primary;
        padding: 0 1;
        margin: 0 0 1 0;
    }

    NodeCard.offline {
        border: solid $error;
    }

    NodeCard.idle {
        border: solid $success-darken-2;
    }

    NodeCard.active {
        border: solid $warning;
    }

    NodeCard #node-header {
        height: 1;
        margin-bottom: 1;
    }

    NodeCard #node-stats {
        height: 1;
        margin-bottom: 1;
    }

    NodeCard #node-jobs {
        height: auto;
    }

    NodeCard .job-line {
        height: 1;
    }

    NodeCard .job-detail {
        color: $text-muted;
        height: 1;
    }
    """

    def __init__(
        self,
        node: NodeStats,
        jobs: list[TranscodeJob],
        compact: bool = False,
        **kwargs
    ):
        super().__init__(**kwargs)
        self.node = node
        self.jobs = jobs
        self.compact = compact

    def compose(self) -> ComposeResult:
        import os
        debug_file = os.path.expanduser("~/.transcodarr/monitor_debug.log")
        with open(debug_file, "a") as f:
            f.write(f"\n--- NodeCard.compose() called for {self.node.ip} ---\n")
        # Test: yield hardcoded content to see if ANYTHING renders
        yield Static(f"[bold red]TEST NODE: {self.node.ip}[/bold red]", id="node-test")
        yield Static(id="node-header")
        yield Static(id="node-stats")
        yield Vertical(id="node-jobs")

    def on_mount(self) -> None:
        """Update content when mounted."""
        import os
        debug_file = os.path.expanduser("~/.transcodarr/monitor_debug.log")
        with open(debug_file, "a") as f:
            f.write(f"\n--- NodeCard.on_mount() called for {self.node.ip} ---\n")
        self._update_display()
        self._set_state_class()

    def _set_state_class(self) -> None:
        """Set CSS class based on node state."""
        self.remove_class("offline", "idle", "active")
        if not self.node.is_online:
            self.add_class("offline")
        elif self.node.state == "idle" or not self.jobs:
            self.add_class("idle")
        else:
            self.add_class("active")

    def _update_display(self) -> None:
        """Update all display elements."""
        import os
        import traceback
        debug_file = os.path.expanduser("~/.transcodarr/monitor_debug.log")

        try:
            with open(debug_file, "a") as f:
                f.write(f"\n--- NodeCard._update_display() for {self.node.ip} ---\n")

            # Header: Node name and status
            header = self.query_one("#node-header", Static)
            status_icon = "●" if self.node.is_online else "○"
            status_color = "green" if self.node.is_online else "red"

            if self.node.is_online:
                header_text = (
                    f"[{status_color}]{status_icon}[/{status_color}] "
                    f"[bold]{self.node.hostname}[/bold]"
                )
            else:
                # Escape error message to prevent Rich markup interpretation
                safe_error = self.node.error.replace("[", "\\[").replace("]", "\\]")
                header_text = (
                    f"[{status_color}]{status_icon}[/{status_color}] "
                    f"[bold dim]{self.node.hostname}[/bold dim] "
                    f"[red]({safe_error})[/red]"
                )
            header.update(header_text)

            with open(debug_file, "a") as f:
                f.write(f"header_text: {header_text}\n")

            # Stats: CPU and Memory gauges
            stats = self.query_one("#node-stats", Static)
            if self.node.is_online:
                cpu_bar = self._make_gauge(self.node.cpu_percent, 20)
                mem_bar = self._make_gauge(self.node.memory_percent, 10)

                stats_text = (
                    f"CPU \\[{cpu_bar}\\] {self.node.cpu_percent:5.1f}%    "
                    f"MEM \\[{mem_bar}\\] {self.node.memory_used_gb:.1f}/{self.node.memory_total_gb:.0f}GB    "
                    f"Today: {self.node.transcodes_today} transcodes"
                )
            else:
                stats_text = "[dim]No stats available[/dim]"
            stats.update(stats_text)

            with open(debug_file, "a") as f:
                f.write(f"stats_text: {stats_text}\n")

            # Jobs
            jobs_container = self.query_one("#node-jobs", Vertical)
            jobs_container.remove_children()

            if not self.jobs:
                jobs_container.mount(Static(
                    "[dim italic]No active transcodes[/dim italic]",
                    classes="job-line"
                ))
            else:
                for job in self.jobs:
                    job_widget = self._create_job_widget(job)
                    jobs_container.mount(job_widget)

            with open(debug_file, "a") as f:
                f.write(f"_update_display completed OK\n")

        except Exception as e:
            with open(debug_file, "a") as f:
                f.write(f"ERROR in _update_display: {e}\n")
                f.write(traceback.format_exc())

    def _make_gauge(self, percent: float, width: int) -> str:
        """Create a text-based gauge bar."""
        percent = max(0, min(100, percent))  # Clamp to 0-100
        filled = int((percent / 100) * width)
        empty = width - filled

        # Color based on usage
        if percent >= 90:
            color = "red"
        elif percent >= 70:
            color = "yellow"
        else:
            color = "green"

        filled_char = "█"
        empty_char = "░"

        return f"[{color}]{filled_char * filled}[/{color}]{empty_char * empty}"

    def _create_job_widget(self, job: TranscodeJob) -> Static:
        """Create a widget for a single transcode job."""
        # Truncate filename
        filename = job.filename
        if len(filename) > 45:
            filename = filename[:42] + "..."

        if self.compact:
            # Compact mode: single line
            content = (
                f"[cyan]●[/cyan] {filename} - "
                f"{job.output_codec or 'Encoding'}"
            )
            if job.cpu_percent > 0:
                content += f" - CPU: {job.cpu_percent:.0f}%"
        else:
            # Detailed mode: filename + details
            details = []

            if job.input_resolution and job.output_resolution:
                details.append(f"{job.input_resolution} → {job.output_resolution}")
            elif job.input_resolution:
                details.append(job.input_resolution)

            if job.output_codec:
                details.append(job.output_codec)

            if job.audio_codec:
                details.append(f"Audio: {job.audio_codec}")

            if job.bitrate:
                details.append(job.bitrate)

            if job.cpu_percent > 0:
                details.append(f"CPU: {job.cpu_percent:.0f}%")

            content = f"[cyan]●[/cyan] [bold]{filename}[/bold]\n"
            if details:
                content += f"    [dim]{' | '.join(details)}[/dim]"

        return Static(content, classes="job-line")

    def update_node(
        self,
        node: NodeStats,
        jobs: list[TranscodeJob],
        compact: bool = False
    ) -> None:
        """Update the node card with new data."""
        self.node = node
        self.jobs = jobs
        self.compact = compact
        self._update_display()
        self._set_state_class()
