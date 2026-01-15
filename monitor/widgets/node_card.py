"""Node card widget showing per-node stats and active transcodes."""

from textual.app import ComposeResult
from textual.widgets import Static
from textual.containers import Container

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
        rank: int = 0,
        **kwargs
    ):
        super().__init__(**kwargs)
        self.node = node
        self.jobs = jobs
        self.compact = compact
        self.rank = rank  # Priority rank (1 = highest weight, first to be selected)

    def compose(self) -> ComposeResult:
        yield Static(id="node-header")
        yield Static(id="node-stats")
        yield Static(id="node-jobs")

    async def on_mount(self) -> None:
        """Update content when mounted."""
        await self._update_display()
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

    async def _update_display(self) -> None:
        """Update all display elements."""
        # Header: Node name, weight, rank, and status
        header = self.query_one("#node-header", Static)
        status_icon = "●" if self.node.is_online else "○"
        status_color = "green" if self.node.is_online else "red"

        # Weight badge with color coding (higher weight = more prominent)
        weight = self.node.weight
        if weight >= 4:
            weight_badge = f"[bold cyan]W:{weight}[/bold cyan]"
        elif weight >= 2:
            weight_badge = f"[blue]W:{weight}[/blue]"
        else:
            weight_badge = f"[dim]W:{weight}[/dim]"

        # Rank badge (lower rank = higher priority)
        rank_badge = f"[yellow]#{self.rank}[/yellow]" if self.rank > 0 else ""

        if self.node.is_online:
            header_text = (
                f"[{status_color}]{status_icon}[/{status_color}] "
                f"[bold]{self.node.hostname}[/bold]  "
                f"{weight_badge}  {rank_badge}"
            )
        else:
            # Escape error message to prevent Rich markup interpretation
            safe_error = self.node.error.replace("[", "\\[").replace("]", "\\]")
            header_text = (
                f"[{status_color}]{status_icon}[/{status_color}] "
                f"[bold dim]{self.node.hostname}[/bold dim]  "
                f"{weight_badge}  {rank_badge}  "
                f"[red]({safe_error})[/red]"
            )
        header.update(header_text)

        # Stats: CPU and Memory gauges
        stats = self.query_one("#node-stats", Static)
        if self.node.is_online:
            cpu_bar = self._make_gauge(self.node.cpu_percent, 20)
            mem_bar = self._make_gauge(self.node.memory_percent, 10)

            stats_text = (
                f"CPU \\[{cpu_bar}\\] {self.node.cpu_percent:5.1f}%    "
                f"MEM \\[{mem_bar}\\] {self.node.memory_used_gb:.1f}/{self.node.memory_total_gb:.0f}GB    "
                f"Transcoding: {len(self.jobs)}"
            )
        else:
            stats_text = "[dim]No stats available[/dim]"
        stats.update(stats_text)

        # Jobs - render all as single text block (avoids mount/remove issues)
        jobs_widget = self.query_one("#node-jobs", Static)
        if not self.jobs:
            jobs_widget.update("[dim italic]No active transcodes[/dim italic]")
        else:
            job_lines = []
            for job in self.jobs:
                job_lines.append(self._format_job(job))
            jobs_widget.update("\n".join(job_lines))

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

    def _format_job(self, job: TranscodeJob) -> str:
        """Format a single transcode job as text."""
        # Truncate filename
        filename = job.filename
        if len(filename) > 50:
            filename = filename[:47] + "..."

        if self.compact:
            # Compact mode: single line
            line = f"[cyan]●[/cyan] {filename}"
            if job.output_codec:
                line += f" → {job.output_codec}"
            return line
        else:
            # Detailed mode: filename + full details on second line
            line = f"[cyan]●[/cyan] [bold]{filename}[/bold]"

            # Build detail parts
            parts = []

            # Resolution: input → output
            if job.input_resolution and job.output_resolution:
                parts.append(f"{job.input_resolution} → {job.output_resolution}")
            elif job.output_resolution:
                parts.append(f"→ {job.output_resolution}")
            elif job.input_resolution:
                parts.append(job.input_resolution)

            # Codec
            if job.output_codec:
                parts.append(job.output_codec)

            # Bitrate
            if job.bitrate:
                parts.append(job.bitrate)

            # CPU
            if job.cpu_percent > 0:
                parts.append(f"CPU: {job.cpu_percent:.0f}%")

            if parts:
                line += f"\n    [dim]{' | '.join(parts)}[/dim]"

            return line

    async def update_node(
        self,
        node: NodeStats,
        jobs: list[TranscodeJob],
        compact: bool = False,
        rank: int = 0
    ) -> None:
        """Update the node card with new data."""
        self.rank = rank
        self.node = node
        self.jobs = jobs
        self.compact = compact
        await self._update_display()
        self._set_state_class()
