# Tracks resource usage on the VM and sends a message to the team through Discord if the usage exceeds a certain threshold.
# Then automatically reacts to the high resource usage by some action, such as temporarily switching to a smaller model or 
# reject/delay new requests until the usage drops back to normal levels.
# Then documents the threshold used, how resouce usage is measured, what automated actions are taken, and how the system returns to normal operation 
# once the resource usage drops back to normal levels.

import os
import time
import requests
import psutil

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

def send_discord_message(resource_name, current_val, threshold_val):
    """
    Sends a message to the Discord channel if resource usage exceeds the threshold.
    """
    # Ensure hostname is a clean, pure string data type
    try:
        hostname = str(os.uname().nodename)
    except Exception:
        hostname = "VPN-Isolated VM"

    # Generate an ISO 8601 string that Discord's embed processor expects
   
    # Explicitly stringify metrics to pass strict JSON payload validation
    resource_str = str(resource_name)
    current_str = f"{float(current_val):.2f}%"
    threshold_str = f"{float(threshold_val):.2f}%"

    # Formatted payload matching Discord Webhook execution specs
    payload = {
        "content": "@here **Resource Warning Alert!**",
        "embeds": [{
            "title": "High VM Resource Usage Alert",
            "description": f"Resource limit surpassed on host: **{hostname}**.",
            "color": 15158332,  # Red color
            "fields": [
                {"name": "Resource Type", "value": resource_str, "inline": True},
                {"name": "Current Usage", "value": current_str, "inline": True},
                {"name": "Threshold Limit", "value": threshold_str, "inline": True}
            ],
           
        }]
    }

    print(f"Attempting to send Discord notification for {resource_name}...")
    try:
        target_url = f"{DISCORD_WEBHOOK_URL.strip()}?wait=true"
        res = requests.post(target_url, json=payload, timeout=10)

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

    print(f"Current Metrics -> CPU: {cpu_usage}%, RAM: {ram_usage}%")
    
    # Track if any alerts triggered
    alert_triggered = False

    if cpu_usage >= THRESHOLD_CPU:
        send_discord_message("CPU Usage", cpu_usage, THRESHOLD_CPU)
        alert_triggered = True
    if ram_usage >= THRESHOLD_RAM:
        send_discord_message("RAM Usage", ram_usage, THRESHOLD_RAM)
        alert_triggered = True

    # 2) Evaluate Hardware GPU Telemetry (NVIDIA NVML)
    if GPU_AVAILABLE:
        try:
            handle = pynvml.nvmlDeviceGetHandleByIndex(0)
            gpu_util = float(pynvml.nvmlDeviceGetUtilizationRates(handle).gpu)
            mem_info = pynvml.nvmlDeviceGetMemoryInfo(handle)
            gpu_mem = (mem_info.used / mem_info.total) * 100
            
            print(f"Current GPU Metrics -> GPU Util: {gpu_util}%, VRAM: {gpu_mem:.1f}%")

            if gpu_util >= THRESHOLD_GPU_UTIL:
                send_discord_message("GPU Core Utilization", gpu_util, THRESHOLD_GPU_UTIL)
                alert_triggered = True
            if gpu_mem >= THRESHOLD_GPU_MEM:
                send_discord_message("GPU VRAM Usage", gpu_mem, THRESHOLD_GPU_MEM)
                alert_triggered = True
        except Exception as err:
            print(f"Error accessing hardware NVML registers: {err}")

    if not alert_triggered:
        print("All resources are below thresholds. No notification required.")

if __name__ == "__main__":
    if not DISCORD_WEBHOOK_URL or DISCORD_WEBHOOK_URL.strip() == "":
        print("Fatal Error: Discord Webhook URL is not set. Please set the DISCORD_WEBHOOK_URL environment variable.")
    else:
        run_resource_audit()