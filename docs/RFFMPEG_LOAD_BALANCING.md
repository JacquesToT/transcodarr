# rffmpeg Load Balancing

Dit document beschrijft het load balancing probleem met rffmpeg en onze oplossing.

## Het Probleem

### rffmpeg Weight Selectie is Broken

**Verwachting:** rffmpeg zou hosts moeten selecteren op basis van gewogen random selectie.

**Realiteit:** rffmpeg selecteert hosts op **ID volgorde**, niet op weight.
- De host met de laagste ID wordt altijd eerst geprobeerd
- Als SSH werkt, wordt die host gebruikt - ongeacht load of weight
- Andere hosts worden alleen gebruikt als de eerste faalt

### Geen Load Awareness

rffmpeg checkt NIET:
- Hoeveel ffmpeg processen al draaien op een host
- Of de host overbelast is
- Of een andere host "beter" zou zijn

**Resultaat:** Als je 5 transcodes start, gaan ze allemaal naar dezelfde Mac terwijl andere Macs idle zijn.

---

## Onze Oplossing: Load-Aware Balancer

We hebben een **load-aware load balancer** geïmplementeerd die:

1. **Elke 3 seconden** de load op elke Mac checkt via SSH
2. **ffmpeg processen telt** om te bepalen hoeveel transcodes actief zijn
3. **Load score berekent** op basis van: `(transcodes × 1000) / weight`
4. **Hosts herordent** zodat de minst belaste host altijd eerst wordt gekozen

### Hoe Het Werkt

```
Mac A: Weight 4, 2 actieve transcodes → Score: 496
Mac B: Weight 2, 1 actieve transcode  → Score: 498

Mac A wint (lagere score) → komt bovenaan
```

Bij gelijke load wint de Mac met hogere weight (kan meer aan).

### Voorbeeld: 7 Streams op 2 Macs

```
Start situatie: Mac A (W:4), Mac B (W:2), beide idle

Stream 1 → Mac A (beide idle, A heeft hogere weight)
Stream 2 → Mac B (A:1, B:0 → B is relatief leger)
Stream 3 → Mac A (A:1, B:1 → gelijk, A wint op weight)
Stream 4 → Mac B (A:2, B:1 → B is relatief leger)
Stream 5 → Mac A (A:2, B:2 → gelijk, A wint op weight)
Stream 6 → Mac B (A:3, B:2 → B is relatief leger)
Stream 7 → Mac A (A:3, B:3 → gelijk, A wint op weight)

Resultaat: Mac A = 4 streams, Mac B = 3 streams
```

---

## Gebruik

### Via de Installer (Aanbevolen)

1. Start de installer: `./install.sh`
2. Kies **"🔄 Load Balancer"** uit het menu
3. Gebruik de submenu opties:
   - **Start Load Balancer** - Start de daemon
   - **Stop Load Balancer** - Stop de daemon
   - **Rebalance Now** - Handmatig herbalanceren
   - **View Logs** - Bekijk recente log entries

### Via Command Line

```bash
# Status bekijken (toont load per node)
./load-balancer.sh status

# Daemon starten
./load-balancer.sh start

# Daemon stoppen
./load-balancer.sh stop

# Handmatig herbalanceren
./load-balancer.sh balance

# Huidige host volgorde met loads tonen
./load-balancer.sh show

# Logs bekijken
./load-balancer.sh logs
```

### Als Systemd Service (Synology/Linux)

Voor automatische start bij boot:

```bash
cd services/
sudo ./install-service.sh install
```

---

## Configuratie

| Variabele | Default | Beschrijving |
|-----------|---------|--------------|
| `JELLYFIN_CONTAINER` | `jellyfin` | Naam van de Jellyfin Docker container |
| `CHECK_INTERVAL` | `3` | Seconden tussen load checks |

Voorbeeld:
```bash
CHECK_INTERVAL=5 ./load-balancer.sh start
```

---

## Weight Uitleg

Weight bepaalt de **relatieve capaciteit** van een node:

| Weight | Betekenis |
|--------|-----------|
| 1 | Basis capaciteit |
| 2 | 2× capaciteit van weight 1 |
| 4 | 4× capaciteit van weight 1 |

**Vuistregel:** Stel weight in op basis van hardware:
- Mac Mini M1: Weight 2
- Mac Studio M1 Max: Weight 4
- Mac Pro: Weight 6+

Bij gelijke load krijgt de Mac met hogere weight de volgende transcode.

---

## Technische Details

### Load Score Berekening

```
score = (active_transcodes × 1000) / weight - weight
```

- **Lagere score = betere kandidaat**
- Factor 1000 zorgt voor integer precisie
- `-weight` is tiebreaker bij gelijke load

### SSH Connectie

De load balancer checkt load via SSH:
```bash
docker exec jellyfin ssh user@mac "pgrep -c ffmpeg"
```

Dit gebruikt de SSH keys die al in de Jellyfin container zijn geconfigureerd.

### Bestanden

| Bestand | Beschrijving |
|---------|--------------|
| `load-balancer.sh` | Hoofd daemon script |
| `services/transcodarr-lb.service` | Systemd service |
| `services/install-service.sh` | Service installer |

### Logs

- Log file: `/tmp/transcodarr-lb.log`
- PID file: `/tmp/transcodarr-lb.pid`

---

## Beperkingen

1. **Check interval**: Als meerdere transcodes binnen 3 seconden starten, kunnen ze naar dezelfde node gaan voordat rebalancing plaatsvindt
2. **SSH latency**: Elke check doet SSH calls naar alle nodes (~100ms per node)
3. **Vereist 2+ nodes**: Met 1 node is load balancing niet nodig

---

## Vergelijking: Oude vs Nieuwe Aanpak

| Situatie | Zonder LB | Round-Robin (oud) | Load-Aware (nieuw) |
|----------|-----------|-------------------|---------------------|
| 2 streams tegelijk | Beide Mac A | Beide Mac A | 1 per Mac ✓ |
| 5 streams snel | Alle Mac A | Alle Mac A | Verdeeld ✓ |
| 2 streams na elkaar | Beide Mac A | Verdeeld | Verdeeld ✓ |
| Ongelijke hardware | Ignoreert | Ignoreert | Respecteert weight ✓ |
