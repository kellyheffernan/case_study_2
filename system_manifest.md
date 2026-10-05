# System Resource Monitoring Report
 
Generated: 2026-10-05 18:42:44 UTC
Current state: **OVERLOAD (ongoing)**
 
## 1. Thresholds and Readings (this run)
| Resource | Measured | Threshold | Status |
|---|---|---|---|
| CPU Usage | 4.0% | 5.0% | OK |
| RAM Usage | 34.1% | 5.0% | EXCEEDED |
 
## 2. How Usage Is Measured
- CPU: `psutil.cpu_percent(interval=1)` (1-second sample). RAM: `psutil.virtual_memory().percent`.
- No GPU detected; GPU metrics skipped. VRAM % = used / total memory.
- Checked every 5 minutes by the GitHub Actions self-hosted runner.
 
## 3. Automated Actions Taken This Run
Mitigation (randomly selected once per overload event): None (system normal).
1. Still exceeding: RAM Usage (34.1% >= 5.0%).
2. Lock file already present (scheduled run); no new Discord alert (alerts only fire on transitions into overload).
3. Appended this event to the history ledger.
 
## 4. Return to Normal
Still overloaded. On the first scheduled check (every 5 min) where ALL metrics are below their thresholds, `/tmp/overload_activate.flag` is deleted and the application resumes normal operation.
 
## 5. Recent Event History (from ledger)
- [2026-10-05 01:34:01 UTC] Alert Active: CPU Usage=21.4% (Limit 5.0%), RAM Usage=35.3% (Limit 5.0%)
- [2026-10-05 06:09:45 UTC] Alert Active: CPU Usage=7.6% (Limit 5.0%), RAM Usage=17.9% (Limit 5.0%)
- [2026-10-05 14:30:08 UTC] Alert Active: CPU Usage=8.0% (Limit 5.0%), RAM Usage=17.9% (Limit 5.0%)
- [2026-10-05 18:38:48 UTC] Alert Active: CPU Usage=6.5% (Limit 5.0%), RAM Usage=34.5% (Limit 5.0%)
- [2026-10-05 18:39:37 UTC] Alert Active: RAM Usage=35.0% (Limit 5.0%)
- [2026-10-05 18:39:59 UTC] Alert Active: RAM Usage=35.0% (Limit 5.0%)
- [2026-10-05 18:40:46 UTC] Alert Active: CPU Usage=6.1% (Limit 5.0%), RAM Usage=35.0% (Limit 5.0%)
- [2026-10-05 18:42:26 UTC] Alert Active: RAM Usage=34.2% (Limit 5.0%)
- [2026-10-05 18:42:44 UTC] Alert Active: RAM Usage=34.1% (Limit 5.0%)
