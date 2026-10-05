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
HISTORY_LOG_PATH = "/home/student-admin/actions-runner/overload_history.log"  # Persistent ledger

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
    # 1) Evaluate Core System Telemetry
    cpu_usage = psutil.cpu_percent(interval=1)
    ram_usage = psutil.virtual_memory().percent

    gpu_util = 0.0
    gpu_mem = 0.0

    print(f"Current Metrics -> CPU: {cpu_usage}%, RAM: {ram_usage}%")

    # 2) Evaluate Hardware GPU Telemetry (NVIDIA NVML)
    if GPU_AVAILABLE:
        try:
            handle = pynvml.nvmlDeviceGetHandleByIndex(0)
            gpu_util = float(pynvml.nvmlDeviceGetUtilizationRates(handle).gpu)
            mem_info = pynvml.nvmlDeviceGetMemoryInfo(handle)
            gpu_mem = (mem_info.used / mem_info.total) * 100
            
            print(f"Current GPU Metrics -> GPU Util: {gpu_util}%, VRAM: {gpu_mem:.1f}%")
        except Exception as err:
            print(f"Error accessing hardware NVML registers: {err}")

    # 3) Check Resource Surpasses & Trigger Automated Actions
    surpassed_resources = []
    if cpu_usage >= THRESHOLD_CPU: surpassed_resources.append(("CPU Usage", cpu_usage, THRESHOLD_CPU))
    if ram_usage >= THRESHOLD_RAM: surpassed_resources.append(("RAM Usage", ram_usage, THRESHOLD_RAM))
    if gpu_util >= THRESHOLD_GPU_UTIL: surpassed_resources.append(("GPU Core Utilization", gpu_util, THRESHOLD_GPU_UTIL))
    if gpu_mem >= THRESHOLD_GPU_MEM: surpassed_resources.append(("GPU VRAM Usage", gpu_mem, THRESHOLD_GPU_MEM))

    if surpassed_resources:
        # --- [PLACEMENT 1]: Handle Active State Lock File ("w") ---
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
                send_discord_message(name, current, limit)
        else:
            print("System remains in an overloaded state. Application mitigation action is currently active.")

        # --- [PLACEMENT 2]: Append Metrics to History Ledger File ("a") ---
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
                
                # --- [PLACEMENT 3]: Log System Recovery to History Ledger File ("a") ---
                timestamp_str = time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())
                with open(HISTORY_LOG_PATH, "a") as log_file:
                    log_file.write(f"[{timestamp_str}] ✅ SYSTEM COOLDOWN: All metrics recovered below threshold limits.\n")
                    
            except Exception as e:
                print(f"Error removing system flag file: {e}")
        else:
            print("All resources are below thresholds. No notification or mitigation required.")


if __name__ == "__main__":
    if not DISCORD_WEBHOOK_URL or DISCORD_WEBHOOK_URL.strip() == "":
        print("Fatal Error: Discord Webhook URL is not set. Please set the DISCORD_WEBHOOK_URL environment variable.")
    else:
        run_resource_audit()