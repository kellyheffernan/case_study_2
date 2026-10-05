# Tracks resource usage on the VM and sends a message to the team through Discord if the usage exceeds a certain threshold.
# Then automatically reacts to the high resource usage by some action, such as temporarily switching to a smaller model or 
# reject/delay new requests until the usage drops back to normal levels.
# Then documents the threshold used, how resouce usage is measured, what automated actions are taken, and how the system returns to normal operation 
# once the resource usage drops back to normal levels.

import os
import time
import requests
import psutil

#Flag file path for local application cross-process communication
FLAG_FILE_PATH = "/tmp/overload_activate.flag"

# Persistent ledger of overloads
HISTORY_LOG_PATH = "/home/student-admin/case_study_2/overload_history.log"

# Automated local architectural documentation
DOCS_MANIFEST_PATH = "/home/student-admin/case_study_2/system_manifest.md"

GPU_AVAILABLE = False
try:
    import pynvml
    pynvml.nvmlInit()
    GPU_AVAILABLE = True
except Exception as e:
    print("GPU monitoring disabled: NVML library or hardware not detected. Details: {e}")

# Load Configuration from GitHub Action Environment Variables
DISCORD_WEBHOOK_URL = os.getenv("DISCORD_WEBHOOK_URL")
THRESHOLD_GPU_UTIL = float(os.getenv("THRESHOLD_GPU_UTIL", 5.0))  # Utilization threshold in percentage
THRESHOLD_GPU_MEM = float(os.getenv("THRESHOLD_GPU_MEM", 5.0))  # Memory usage threshold in percentage
THRESHOLD_CPU = float(os.getenv("THRESHOLD_CPU", 5.0))  # CPU usage threshold in percentage
THRESHOLD_RAM = float(os.getenv("THRESHOLD_RAM", 5.0))  # RAM usage threshold in percentage

# Maps each metric name to its threshold so readings and limits stay in sync
LIMITS = {
    "CPU Usage": THRESHOLD_CPU,
    "RAM Usage": THRESHOLD_RAM,
    "GPU Core Utilization": THRESHOLD_GPU_UTIL,
    "GPU VRAM Usage": THRESHOLD_GPU_MEM,
}

def read_recent_history(n=10):
    """[NEW] Returns the last n lines of the overload ledger (empty list if none)."""
    try:
        with open(HISTORY_LOG_PATH) as f:
            return f.readlines()[-n:]
    except Exception:
        return []
 
 
def write_system_documentation(state, readings, surpassed, actions):
    """[CHANGED] Writes a manifest describing what THIS run measured, decided, and did."""
    now = time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())
    over = {name for name, _, _ in surpassed}
 
    rows = "\n".join(
        f"| {name} | {val:.1f}% | {LIMITS[name]:.1f}% | {'EXCEEDED' if name in over else 'OK'} |"
        for name, val in readings.items()
    )
    actions_md = "\n".join(f"{i}. {a}" for i, a in enumerate(actions, 1))
    history_md = "".join(f"- {line}" for line in read_recent_history()) or "- No events logged yet.\n"
    gpu_note = "GPU metrics read via NVML (device 0)." if GPU_AVAILABLE else "No GPU detected; GPU metrics skipped."
 
    if state == "RECOVERED":
        recovery = (f"Recovery happened this run: all metrics fell below their thresholds, "
                    f"so `{FLAG_FILE_PATH}` was deleted and the application resumed normal operation.")
    elif state.startswith("OVERLOAD"):
        recovery = (f"Still overloaded. On the first scheduled check (every 5 min) where ALL metrics are below "
                    f"their thresholds, `{FLAG_FILE_PATH}` is deleted and the application resumes normal operation.")
    else:
        recovery = "System is normal; no recovery needed."
 
    content = f"""# System Resource Monitoring Report
 
Generated: {now}
Current state: **{state}**
 
## 1. Thresholds and Readings (this run)
| Resource | Measured | Threshold | Status |
|---|---|---|---|
{rows}
 
## 2. How Usage Is Measured
- CPU: `psutil.cpu_percent(interval=1)` (1-second sample). RAM: `psutil.virtual_memory().percent`.
- {gpu_note} VRAM % = used / total memory.
- Checked every 5 minutes by the GitHub Actions self-hosted runner.
 
## 3. Automated Actions Taken This Run
{actions_md}
 
## 4. Return to Normal
{recovery}
 
## 5. Recent Event History (from ledger)
{history_md}"""
    try:
        with open(DOCS_MANIFEST_PATH, "w") as f:
            f.write(content)
        print(f"Documentation manifest updated at: {DOCS_MANIFEST_PATH}")
    except Exception as e:
        print(f"Failed to write documentation file: {e}")

def send_discord_message(resource_name, current_val, threshold_val, action_taken):
    """
    Sends a message to the Discord channel if resource usage exceeds the threshold.
    """
    # Ensure hostname is a clean, pure string data type
    try:
        hostname = str(os.uname().nodename)
    except Exception:
        hostname = "VPN-Isolated VM"

    # Generate an ISO 8601 string that Discord's embed processor expects
    iso_timestamp = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())

    # Formatted payload matching Discord Webhook execution specs
    payload = {
        "content": "@here **Resource Warning and Auto-Action Alert!**",
        "embeds": [{
            "title": "High VM Resource Usage - Automated Action Triggered",
            "description": f"Resource limit surpassed on host: **{hostname}**.",
            "color": 15158332,  # Red color
            "fields": [
                {"name": "Resource Type", "value": resource_name, "inline": True},
                {"name": "Current Usage", "value": f"{float(current_val):.2f}%", "inline": True},
                {"name": "Threshold Limit", "value": f"{float(threshold_val):.2f}%", "inline": True},
                {"name": "Automated Action Taken", "value": f"{action_taken}", "inline": False}
            ],
           "timestamp": iso_timestamp
        }]
    }

    print(f"Attempting to send Discord notification for {resource_name}...")
    try:
        res = requests.post(DISCORD_WEBHOOK_URL, json=payload, timeout=10)
        if res.status_code in [200, 201, 204]:
            print("Discord alert successfully sent!")
            return True
        else:
            print(f"Discord rejected the message format. Code: {res.status_code}")
            print(f"Response details: {res.text}")
            return False
    except Exception as e:
        print(f"Failed to transmit network notification: {e}")
        return False

def run_resource_audit():
    actions = []
    now = lambda: time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())
 
    # 1) Evaluate core system telemetry
    readings = {
        "CPU Usage": psutil.cpu_percent(interval=1),
        "RAM Usage": psutil.virtual_memory().percent,
    }
 
    # 2) Evaluate hardware GPU telemetry (NVIDIA NVML)
    if GPU_AVAILABLE:
        try:
            handle = pynvml.nvmlDeviceGetHandleByIndex(0)
            mem = pynvml.nvmlDeviceGetMemoryInfo(handle)
            readings["GPU Core Utilization"] = float(pynvml.nvmlDeviceGetUtilizationRates(handle).gpu)
            readings["GPU VRAM Usage"] = (mem.used / mem.total) * 100
        except Exception as err:
            print(f"Error accessing NVML: {err}")
            actions.append(f"GPU read failed ({err}); GPU metrics skipped this run.")
    print("Current Metrics ->", {k: f"{v:.1f}%" for k, v in readings.items()})
 
    # 3) Check resource surpasses and trigger automated actions
    surpassed = [(n, v, LIMITS[n]) for n, v in readings.items() if v >= LIMITS[n]]
 
    if surpassed:
        exceeded = ", ".join(f"{n} ({v:.1f}% >= {l:.1f}%)" for n, v, l in surpassed)
 
        if not os.path.exists(FLAG_FILE_PATH):
            state = "OVERLOAD (newly triggered)"
            actions.append(f"Detected threshold breach: {exceeded}.")
            try:
                with open(FLAG_FILE_PATH, "w") as f:
                    f.write("--- RESOURCE OVERLOAD DETECTED ---\n")
                    f.write(f"Timestamp: {now()}\n")
                    for n, v, l in surpassed:
                        f.write(f"Resource: {n} | Current: {v:.2f}% | Threshold: {l:.2f}%\n")
                actions.append(f"Created lock file `{FLAG_FILE_PATH}`; the application sees it and throttles / falls back to a smaller model.")
                print(f"Automated Action: Incident written to {FLAG_FILE_PATH}. Application throttling engaged.")
            except Exception as e:
                actions.append(f"FAILED to create lock file: {e}")
                print(f"Failed to create system state file: {e}")
 
            # Notify only on the transition into overload (prevents notification spam)
            for n, v, l in surpassed:
                ok = send_discord_message(n, v, l, action_taken="Traffic Throttling & Fallback Model Engaged")
                actions.append(f"Discord alert for {n}: {'delivered' if ok else 'FAILED'}.")
        else:
            state = "OVERLOAD (ongoing)"
            actions.append(f"Still exceeding: {exceeded}.")
            actions.append("Lock file already present; throttling stays active. No new Discord alert (spam prevention).")
            print("System remains in an overloaded state. Application mitigation action is currently active.")
 
        # Append metrics to history ledger
        try:
            with open(HISTORY_LOG_PATH, "a") as log_file:
                log_file.write(f"[{now()}] Alert Active: " +
                               ", ".join(f"{n}={v:.1f}% (Limit {l}%)" for n, v, l in surpassed) + "\n")
            actions.append("Appended this event to the history ledger.")
        except Exception as e:
            actions.append(f"FAILED to write history ledger: {e}")
            print(f"Failed to append to history log: {e}")
 
    else:
        # AUTOMATED RETURN TO NORMAL: clear the flag file once loads settle below thresholds
        if os.path.exists(FLAG_FILE_PATH):
            state = "RECOVERED"
            actions.append("All metrics are below their thresholds.")
            try:
                os.remove(FLAG_FILE_PATH)
                actions.append(f"Deleted lock file `{FLAG_FILE_PATH}`; throttling lifted, normal operation restored.")
                print("Recovery Action Triggered: System operating safely. Overload flag removed. Normal operations restored.")
                with open(HISTORY_LOG_PATH, "a") as log_file:
                    log_file.write(f"[{now()}] SYSTEM COOLDOWN: All metrics recovered below threshold limits.\n")
                actions.append("Logged the recovery to the history ledger.")
            except Exception as e:
                actions.append(f"FAILED during recovery cleanup: {e}")
                print(f"Error removing system flag file: {e}")
        else:
            state = "NORMAL"
            actions.append("All metrics below thresholds; no mitigation or notification needed.")
            print("All resources are below thresholds. No notification or mitigation required.")
 
    # 4) Documentation is generated last, from what actually happened this run
    write_system_documentation(state, readings, surpassed, actions)


if __name__ == "__main__":
    if not DISCORD_WEBHOOK_URL or DISCORD_WEBHOOK_URL.strip() == "":
        print("Fatal Error: Discord Webhook URL is not set. Please set the DISCORD_WEBHOOK_URL environment variable.")
    else:
        run_resource_audit()