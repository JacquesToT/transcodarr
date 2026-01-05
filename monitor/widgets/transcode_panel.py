"""Panel showing active transcoding jobs."""

from textual.app import ComposeResult
from textual.widgets import Static, DataTable, ProgressBar
from textual.containers import Vertical

from ..data_collector import TranscodeJob


class TranscodePanel(Static):
    """Widget showing active transcode jobs."""

    DEFAULT_CSS = """
    TranscodePanel {
        height: auto;
        min-height: 8;
        background: $surface;
        border: solid $primary;
        padding: 0 1;
    }

    TranscodePanel #transcode-title {
        text-style: bold;
        color: $primary;
        padding: 0 0 1 0;
    }

    TranscodePanel .no-transcodes {
        color: $text-muted;
        text-style: italic;
    }

    TranscodePanel .job-card {
        background: $panel;
        padding: 1;
        margin: 0 0 1 0;
        border: solid $secondary;
    }

    TranscodePanel .job-filename {
        text-style: bold;
    }

    TranscodePanel .job-codec {
        color: $accent;
    }

    TranscodePanel .job-stats {
        color: $text-muted;
    }
    """

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self._jobs: list[TranscodeJob] = []

    def compose(self) -> ComposeResult:
        yield Static("Active Transcodes", id="transcode-title")
        yield Vertical(id="transcode-list")

    def update_jobs(self, jobs: list[TranscodeJob]) -> None:
        """Update the list of active jobs."""
        self._jobs = jobs
        container = self.query_one("#transcode-list", Vertical)

        # Clear existing content
        container.remove_children()

        if not jobs:
            # Don't use a fixed ID - IDs must be unique and remove_children()
            # is async, which can cause "widget already exists" errors
            container.mount(Static(
                "[dim]No active transcodes[/dim]",
                classes="no-transcodes"
            ))
            return

        for job in jobs:
            card = self._create_job_card(job)
            container.mount(card)

    def _create_job_card(self, job: TranscodeJob) -> Static:
        """Create a card widget for a transcode job."""
        filename = job.filename[:50] + "..." if len(job.filename) > 50 else job.filename

        content = f"""[bold]{filename}[/bold]
[cyan]{job.output_codec or 'Encoding...'}[/cyan]
"""

        if job.speed:
            content += f"Speed: {job.speed} | "
        if job.progress > 0:
            content += f"Progress: {job.progress:.1f}%"
        if job.eta:
            content += f" | ETA: {job.eta}"

        # Add progress bar representation
        if job.progress > 0:
            filled = int(job.progress / 5)
            empty = 20 - filled
            bar = "\u2588" * filled + "\u2591" * empty
            content += f"\n[green]{bar}[/green]"

        card = Static(content, classes="job-card")
        return card
