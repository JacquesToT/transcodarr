"""
Transcodarr Monitor - Main TUI Application.
A terminal-based monitoring tool for Transcodarr transcoding.
"""

import asyncio
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Container, Vertical, VerticalScroll
from textual.widgets import Header, Footer, Static, TabbedContent, TabPane

from .config import get_config, reload_config
from .data_collector import DataCollector, NodeStats
from .widgets import StatusBar, LogPanel, NodeCard


class TranscodarrMonitor(App):
    """Main Transcodarr Monitor application."""

    TITLE = "Transcodarr Monitor"
    SUB_TITLE = "Distributed Live Transcoding for Jellyfin"

    CSS = """
    Screen {
        background: $background;
    }

    #main-container {
        width: 100%;
        height: 100%;
    }

    #status-bar {
        dock: top;
        height: 3;
        margin: 0 1;
    }

    TabbedContent {
        height: 1fr;
    }

    TabPane {
        height: 1fr;
        padding: 1;
    }

    #nodes-container {
        height: 1fr;
        overflow-y: auto;
    }

    #logs-container {
        height: 100%;
    }

    #config-container {
        height: 100%;
        padding: 1;
    }

    .detail-toggle {
        dock: top;
        height: 1;
        text-align: right;
        padding-right: 2;
        color: $text-muted;
    }

    NodeCard {
        margin: 0 0 1 0;
    }

    LogPanel {
        height: 100%;
    }

    .no-nodes {
        text-align: center;
        padding: 2;
        color: $text-muted;
    }
    """

    BINDINGS = [
        Binding("q", "quit", "Quit"),
        Binding("r", "refresh", "Refresh"),
        Binding("d", "toggle_details", "Toggle Details"),
        Binding("c", "reload_config", "Reload Config"),
        Binding("1", "switch_tab('dashboard')", "Dashboard", show=False),
        Binding("2", "switch_tab('logs')", "Logs", show=False),
        Binding("3", "switch_tab('config')", "Config", show=False),
    ]

    def __init__(self):
        super().__init__()
        self.config = get_config()
        self.collector = DataCollector(self.config)
        self._refresh_task = None
        self._compact_mode = False  # False = detailed, True = compact
        self._node_cards: dict[str, NodeCard] = {}

    def compose(self) -> ComposeResult:
        yield Header()
        with Container(id="main-container"):
            yield StatusBar(id="status-bar")
            with TabbedContent(id="tabs"):
                with TabPane("Dashboard", id="dashboard"):
                    yield Static("[D] Toggle Details", classes="detail-toggle")
                    yield VerticalScroll(id="nodes-container")
                with TabPane("Logs", id="logs"):
                    yield Vertical(id="logs-container")
                with TabPane("Config", id="config"):
                    yield Vertical(id="config-container")
        yield Footer()

    async def on_mount(self) -> None:
        """Start the refresh loop when the app mounts."""
        # Initialize logs panel
        logs_container = self.query_one("#logs-container", Vertical)
        logs_container.mount(LogPanel(id="log-panel"))

        # Initialize config panel
        config_container = self.query_one("#config-container", Vertical)
        config_content = self._render_config()
        config_container.mount(Static(config_content, id="config-content"))

        # Initial refresh
        await self._do_refresh()
        self._refresh_task = asyncio.create_task(self._refresh_loop())

    async def on_unmount(self) -> None:
        """Stop the refresh loop when the app unmounts."""
        if self._refresh_task:
            self._refresh_task.cancel()
            try:
                await self._refresh_task
            except asyncio.CancelledError:
                pass

    async def _refresh_loop(self) -> None:
        """Background task that refreshes data periodically."""
        while True:
            await asyncio.sleep(self.config.refresh_interval)
            await self._do_refresh()

    async def _do_refresh(self) -> None:
        """Perform a data refresh."""
        try:
            data = await self.collector.collect_all()

            # Update status bar
            status_bar = self.query_one("#status-bar", StatusBar)
            status_bar.update_status(data.status)

            # Update node cards - use node_stats if available, else create from rffmpeg_hosts
            nodes = data.node_stats
            if not nodes and data.rffmpeg_hosts:
                # Fallback: create basic NodeStats from rffmpeg_hosts
                from .data_collector import NodeStats
                nodes = [
                    NodeStats(
                        hostname=host.get("hostname", "Unknown"),
                        ip=host.get("hostname", ""),
                        state=host.get("state", "unknown"),
                        weight=int(host.get("weight", 1)),
                        is_online=False,
                        error="Stats unavailable"
                    )
                    for host in data.rffmpeg_hosts
                ]

            await self._update_node_cards(nodes, data.active_transcodes)

            # Update logs
            log_panel = self.query_one("#log-panel", LogPanel)
            log_panel.update_logs(data.logs)

        except Exception as e:
            self.notify(f"Refresh error: {e}", severity="error")

    async def _update_node_cards(
        self,
        nodes: list[NodeStats],
        all_jobs: list
    ) -> None:
        """Update the node cards display."""
        container = self.query_one("#nodes-container", VerticalScroll)

        if not nodes:
            # Show placeholder if no nodes
            if not container.children or not isinstance(
                container.children[0], Static
            ):
                await container.remove_children()
                await container.mount(Static(
                    "[dim]No transcode nodes registered.\n\n"
                    "Add nodes with: rffmpeg add <mac-ip>[/dim]",
                    classes="no-nodes"
                ))
            return

        # Remove placeholder if it exists
        for child in list(container.children):
            if isinstance(child, Static) and "no-nodes" in child.classes:
                child.remove()

        # Group jobs by node IP
        jobs_by_node: dict[str, list] = {}
        for job in all_jobs:
            node_ip = job.node_ip or "unknown"
            if node_ip not in jobs_by_node:
                jobs_by_node[node_ip] = []
            jobs_by_node[node_ip].append(job)

        # Update or create node cards
        current_ips = {node.ip for node in nodes}

        # Remove cards for nodes that no longer exist
        for ip in list(self._node_cards.keys()):
            if ip not in current_ips:
                card = self._node_cards.pop(ip)
                card.remove()

        # Update or create cards for each node
        for node in nodes:
            node_jobs = jobs_by_node.get(node.ip, [])

            if node.ip in self._node_cards:
                # Update existing card
                await self._node_cards[node.ip].update_node(
                    node, node_jobs, self._compact_mode
                )
            else:
                # Create new card
                card = NodeCard(
                    node=node,
                    jobs=node_jobs,
                    compact=self._compact_mode,
                    id=f"node-{node.ip.replace('.', '-')}"
                )
                self._node_cards[node.ip] = card
                await container.mount(card)

    def _render_config(self) -> str:
        """Render the config panel content."""
        cfg = self.config

        content = "[bold cyan]Transcodarr Configuration[/bold cyan]\n\n"

        content += "[bold]Mode:[/bold]\n"
        if cfg.is_synology:
            content += "  Running on Synology (local mode)\n\n"
        else:
            content += "  Running on Mac (SSH to NAS mode)\n\n"

        content += "[bold]NAS Connection:[/bold]\n"
        content += f"  IP: {cfg.nas_ip}\n"
        content += f"  User: {cfg.nas_user}\n"
        content += f"  SSH Timeout: {cfg.ssh_timeout}s\n\n"

        content += "[bold]Paths:[/bold]\n"
        content += f"  Media: {cfg.media_path}\n"
        content += f"  Cache: {cfg.cache_path}\n\n"

        content += "[bold]Monitor Settings:[/bold]\n"
        content += f"  Refresh Interval: {cfg.refresh_interval}s\n"
        content += f"  Log Lines: {cfg.log_lines}\n\n"

        content += "[bold]Jellyfin:[/bold]\n"
        content += f"  URL: {cfg.jellyfin_url}\n"
        content += f"  API Key: {'Configured' if cfg.jellyfin_api_key else 'Not set'}\n"

        return content

    def action_quit(self) -> None:
        """Quit the application."""
        self.exit()

    async def action_refresh(self) -> None:
        """Manual refresh."""
        self.notify("Refreshing...", severity="information")
        await self._do_refresh()
        self.notify("Refreshed!", severity="information")

    def action_toggle_details(self) -> None:
        """Toggle between compact and detailed view."""
        self._compact_mode = not self._compact_mode
        mode_name = "Compact" if self._compact_mode else "Detailed"
        self.notify(f"View: {mode_name}", severity="information")

        # Update the toggle indicator
        try:
            toggle = self.query_one(".detail-toggle", Static)
            toggle.update(
                f"[D] {'Compact' if self._compact_mode else 'Detailed'} View"
            )
        except Exception:
            pass

        # Update all node cards
        for card in self._node_cards.values():
            card.compact = self._compact_mode
            card._update_display()

    def action_switch_tab(self, tab_id: str) -> None:
        """Switch to specified tab."""
        tabs = self.query_one("#tabs", TabbedContent)
        tabs.active = tab_id

    def action_reload_config(self) -> None:
        """Reload configuration from disk."""
        self.config = reload_config()
        self.collector = DataCollector(self.config)

        # Update config panel
        try:
            config_content = self.query_one("#config-content", Static)
            config_content.update(self._render_config())
        except Exception:
            pass

        self.notify("Configuration reloaded", severity="information")


def check_ssh_before_ui(config) -> bool:
    """Test SSH connection before starting UI.

    This allows the user to enter their password in the terminal
    BEFORE Textual takes over the screen.
    """
    import subprocess

    print(f"Connecting to {config.nas_user}@{config.nas_ip}...")

    cmd = config.get_ssh_command("echo ok")

    try:
        # Run with stdin/stdout connected to terminal (allows password input)
        result = subprocess.run(
            cmd,
            timeout=30,
            capture_output=False  # Let password prompt show in terminal
        )

        if result.returncode == 0:
            print("✓ SSH connection successful\n")
            return True
        else:
            print("✗ SSH connection failed")
            return False

    except subprocess.TimeoutExpired:
        print("✗ SSH connection timed out")
        return False
    except Exception as e:
        print(f"✗ SSH error: {e}")
        return False


def main():
    """Entry point for the monitor."""
    import sys

    config = get_config()

    if config.is_synology:
        # Running directly on Synology - no SSH needed
        print("Detected Synology NAS - running in local mode")
        print("✓ Direct access to Jellyfin container\n")
    else:
        # Running on Mac - need SSH to NAS
        # Test SSH BEFORE starting UI so password prompt is visible
        if not check_ssh_before_ui(config):
            print("\nSSH connection required for monitoring.")
            print(f"Make sure you can SSH to: {config.nas_user}@{config.nas_ip}")
            print("\nTip: Set up SSH key authentication to avoid password prompts:")
            print(f"  ssh-copy-id {config.nas_user}@{config.nas_ip}")
            sys.exit(1)

    # Start UI
    app = TranscodarrMonitor()
    app.run()


if __name__ == "__main__":
    main()
