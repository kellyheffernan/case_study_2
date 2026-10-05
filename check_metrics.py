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
HISTORY_LOG_PATH = "/home/student-admin/actions-runner/overload_history.log"

# Automated local architectural documentation
DOCS_MANIFEST_PATH = "/home/student-admin/actions-runner/system_manifest.md"

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

def write_system_documentation():
    """
    Automated Local Action: Explicitly generates and maintains system architecture 
    documentation on the local VM filesystem to satisfy operational compliance logs.
    """
    markdown_content = f"""#System Architecture & Resource Monitoring Manifest

Generated/Validated on: {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())}

## 1. Configured Thresholds Used
The monitoring engine evaluates hardware performance boundaries against the following specific configuration guidelines:
* **CPU Usage:** Overload triggered at \(\ge {THRESHOLD_CPU}\%\)
* **System Memory (RAM):** Overload triggered at \(\ge {THRESHOLD_RAM}\%\)
* **GPU Core Utilization:** Overload triggered at \(\ge {THRESHOLD_GPU_UTIL}\%\)
* **GPU Memory (VRAM):** Overload triggered at \(\ge {THRESHOLD_GPU_MEM}\%\)

## 2. How Resource Usage is Measured
* **CPU & RAM Tracking:** Monitored using standard library hooks in the kernel space via Python's `psutil` engine package. CPU load is calculated over a 1-second dynamic sample time interval (`interval=1`).
* **GPU & VRAM Tracking:** Captured natively at the hardware level using the official `nvidia-ml-py` (`pynvml`) engine wrapper to read registry index `0`.

## 3. Automated Mitigation Actions Taken
If any pool exceeds its target limit, the environment handles triage through a multi-tiered fallback architecture:
1. **Local System Flag:** An active lock file is deployed to the system path at `{FLAG_FILE_PATH}`.
2. **Workload Throttling:** Downstream services look up the lock file's existence and restrict throughput, deploy query delay rules, or downgrade parameters to lighter model variations.
3. **Discord Notification:** A structured embed payload featuring an active channel ping (`@here`) is dispatched directly out via the configured Webhook tunnel.

## 4. How the System Returns to Normal Operation
* Once a resource check notes that **all four metrics** are operating within safe bounds below the limits, the runtime engine executes a recovery cleanup sequence.
* The script unlinks and permanently deletes the local lock file flag at `{FLAG_FILE_PATH}`.
* Downstream application infrastructure detects the file removal step, tears down active defensive throttling scripts, and shifts back into maximum processing mode automatically.
"""
    try:
        with open(DOCS_MANIFEST_PATH, "w") as doc_file:
            doc_file.write(markdown_content)
        print(f"Local Compliance Documentation Manifest synchronized at: {DOCS_MANIFEST_PATH}")
    except Exception as e:
        print(f"Failed to write local markdown documentation file: {e}")

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
        else:
            print(f"Discord rejected the message format. Code: {res.status_code}")
            print(f"Response details: {res.text}")
    except Exception as e:
        print(f"Failed to transmit network notification: {e}")

def run_resource_audit():
    # 1) Update/Ensure architectural verification records are present locally
    write_system_documentation()

    # 2) Evaluate Core System Telemetry
    cpu_usage = psutil.cpu_percent(interval=1)
    ram_usage = psutil.virtual_memory().percent

    gpu_util = 0.0
    gpu_mem = 0.0

    print(f"Current Metrics -> CPU: {cpu_usage}%, RAM: {ram_usage}%")

    # 3) Evaluate Hardware GPU Telemetry (NVIDIA NVML)
    if GPU_AVAILABLE:
        try:
            handle = pynvml.nvmlDeviceGetHandleByIndex(0)
            gpu_util = float(pynvml.nvmlDeviceGetUtilizationRates(handle).gpu)
            mem_info = pynvml.nvmlDeviceGetMemoryInfo(handle)
            gpu_mem = (mem_info.used / mem_info.total) * 100
            
            print(f"Current GPU Metrics -> GPU Util: {gpu_util}%, VRAM: {gpu_mem:.1f}%")
        except Exception as err:
            print(f"Error accessing hardware NVML registers: {err}")

    # 34 Check Resource Surpasses & Trigger Automated Actions
    surpassed_resources = []
    if cpu_usage >= THRESHOLD_CPU: surpassed_resources.append(("CPU Usage", cpu_usage, THRESHOLD_CPU))
    if ram_usage >= THRESHOLD_RAM: surpassed_resources.append(("RAM Usage", ram_usage, THRESHOLD_RAM))
    if gpu_util >= THRESHOLD_GPU_UTIL: surpassed_resources.append(("GPU Core Utilization", gpu_util, THRESHOLD_GPU_UTIL))
    if gpu_mem >= THRESHOLD_GPU_MEM: surpassed_resources.append(("GPU VRAM Usage", gpu_mem, THRESHOLD_GPU_MEM))

    if surpassed_resources:
        # Handle Active State Lock File ("w")
        if not os.path.exists(FLAG_FILE_PATH):
            try:
                timestamp_str = time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())
                with open(FLAG_FILE_PATH, "w") as f:
                    f.write(f"--- RESOURCE OVERLOAD DETECTED ---\n")
                    f.write(f"Timestamp: {timestamp_str}\n")
                    for name, current, limit in surpassed_resources:
                        f.write(f"Resource: {name} | Current: {current:.2f}% | Threshold: {limit:.2f}%\n")
                
                print(f"Automated Action: Incident written to {FLAG_FILE_PATH}. Application throttling engaged.")
            except Exception as e:
                print(f"Failed to create system state file: {e}")

            # Send notifications only when transitioning into the overload state (prevents notification spam)
            for name, current, limit in surpassed_resources:
                send_discord_message(name, current, limit, action_taken="Traffic Throttling & Fallback Model Engaged")
        else:
            print("System remains in an overloaded state. Application mitigation action is currently active.")

        # Append Metrics to History Ledger File ("a")
        try:
            timestamp_str = time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())
            with open(HISTORY_LOG_PATH, "a") as log_file:
                log_file.write(f"[{timestamp_str}] Alert Active: ")
                metrics_list = [f"{name}={current:.1f}% (Limit {limit}%)" for name, current, limit in surpassed_resources]
                log_file.write(", ".join(metrics_list) + "\n")
        except Exception as e:
            print(f"Failed to append to history log: {e}")
            
    else:
        # AUTOMATED RETURN TO NORMAL: Clear the flag file once resource loads settle below safety thresholds
        if os.path.exists(FLAG_FILE_PATH):
            try:
                os.remove(FLAG_FILE_PATH)
                print("Recovery Action Triggered: System operating safely. Overload flag removed. Normal operations restored.")
                
                # Log System Recovery to History Ledger File ("a")
                timestamp_str = time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())
                with open(HISTORY_LOG_PATH, "a") as log_file:
                    log_file.write(f"[{timestamp_str}] SYSTEM COOLDOWN: All metrics recovered below threshold limits.\n")
                    
            except Exception as e:
                print(f"Error removing system flag file: {e}")
        else:
            print("All resources are below thresholds. No notification or mitigation required.")


if __name__ == "__main__":
    if not DISCORD_WEBHOOK_URL or DISCORD_WEBHOOK_URL.strip() == "":
        print("Fatal Error: Discord Webhook URL is not set. Please set the DISCORD_WEBHOOK_URL environment variable.")
    else:
        run_resource_audit()