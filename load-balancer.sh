#!/bin/bash
#
# Transcodarr Load Balancer - DEPRECATED
#
# The load balancer daemon has been removed because rffmpeg uses its own
# host selection algorithm (LRU/idle-first) that doesn't respect ID order.
#
# Use ./monitor.sh instead to view node status and load information.
#

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                   Load Balancer Deprecated                    ║"
echo "╠═══════════════════════════════════════════════════════════════╣"
echo "║                                                               ║"
echo "║  The load balancer daemon has been removed.                   ║"
echo "║                                                               ║"
echo "║  rffmpeg uses its own host selection algorithm that doesn't   ║"
echo "║  respect the ID order we tried to manipulate.                 ║"
echo "║                                                               ║"
echo "║  To view node status and load information, use:               ║"
echo "║                                                               ║"
echo "║     ./monitor.sh                                              ║"
echo "║                                                               ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

exit 0
