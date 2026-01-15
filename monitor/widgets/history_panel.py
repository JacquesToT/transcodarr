"""Panel showing transcode history."""

from textual.app import ComposeResult
from textual.widgets import Static, DataTable
from textual.containers import VerticalScroll

from ..data_collector import TranscodeHistoryItem


class HistoryPanel(Static):
    """Widget showing recent transcode history."""

    DEFAULT_CSS = """
    HistoryPanel {
        height: auto;
        min-height: 6;
        max-height: 12;
        background: $surface;
        border: solid $primary;
        padding: 0 1;
    }

    HistoryPanel #history-title {
        text-style: bold;
        color: $primary;
        padding: 0 0 1 0;
    }

    HistoryPanel #history-table {
        height: auto;
    }

    HistoryPanel .success {
        color: $success;
    }

    HistoryPanel .error {
        color: $error;
    }
    """

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self._history: list[TranscodeHistoryItem] = []

    def compose(self) -> ComposeResult:
        yield Static("Recent Transcodes", id="history-title")
        table = DataTable(id="history-table")
        table.add_columns("Time", "Status", "File", "Duration")
        yield table

    def update_history(self, history: list[TranscodeHistoryItem]) -> None:
        """Update the history display."""
        self._history = history
        table = self.query_one("#history-table", DataTable)

        # Clear existing rows
        table.clear()

        if not history:
            return

        # Add rows (most recent first)
        for item in reversed(history[-10:]):
            time_str = item.timestamp.strftime("%H:%M")
            status = "[green]\u2713[/green]" if item.success else "[red]\u2717[/red]"
            filename = item.filename[:30] + "..." if len(item.filename) > 30 else item.filename
            duration = item.duration or "-"

            table.add_row(time_str, status, filename, duration)
