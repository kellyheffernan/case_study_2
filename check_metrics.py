# Tracks resource usage on the VM and sends a message to the team through Discord if the usage exceeds a certain threshold.
# Then automatically reacts to the high resource usage by some action, such as temporarily switching to a smaller model or 
# reject/delay new requests until the usage drops back to normal levels.
# Then documents the threshold used, how resouce usage is measured, what automated actions are taken, and how the system returns to normal operation 
# once the resource usage drops back to normal levels.

import os
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
    hostname = os.uname().nodename if hasattr(os, "uname") else "VPN-Isolated VM"
    playload = {
        "username": "Internal Resource Monitor",
        "embeds": [{
            "title": "High VM Resource Usage Alert",
            "description": f"Resource limit surpassed on host: **{hostname}**.",
            "color": 151158332,  # Red color
            "fields": [
                {"name": "Resource Type", "value": resource_name, "inline": True},
                {"name": "Current Usage", "value": f"{current_val:.2f}%", "inline": True},
                {"name": "Threshold Limit", "value": f"{threshold_val:.2f}%", "inline": True}
            ],
            "timestamp": requests.utils.time.strftime('%Y-%m-%dT%H:%M:%SZ')
        }]
    }

    try:
        res = requests.post(DISCORD_WEBHOOK_URL, json=playload, timeout=10)
        if res.status_code not in [200, 204]:
            print(f"Discord responded with error code: {res.status_code}")
    except Exception as e:
        print(f"Failed to transmit network notification: {e}")

def run_resource_audit():
    # 1) Evaluate Core System Telemetry
    cpu_usage = psutil.cpu_percent(interval=1)
    ram_usage = psutil.virtual_memory().percent

    if cpu_usage >= THRESHOLD_CPU:
        send_discord_message("CPU Usage", cpu_usage, THRESHOLD_CPU)
    if ram_usage >= THRESHOLD_RAM:
        send_discord_message("RAM Usage", ram_usage, THRESHOLD_RAM)

    # 2) Evaluate Hardware GPU Telemetry (NVIDIA NVML)
    if GPU_AVAILABLE:
        try:
            handle = pynvml.nvmlDeviceGetHandleByIndex(0) 

            # GPU Core Utilization
            utilization = pynvml.nvmlDeviceGetUtilizationRates(handle)
            gpu_util = float(utilization.gpu)

            # GPU Memory Allocation
            mem_info = pynvml.nvmlDeviceGetMemoryInfo(handle)
            gpu_mem = (mem_info.used / mem_info.total) * 100

            if gpu_util >= THRESHOLD_GPU_UTIL:
                send_discord_message("GPU Core Utilization", gpu_util, THRESHOLD_GPU_UTIL)
            if gpu_mem >= THRESHOLD_GPU_MEM:
                send_discord_message("GPU VRAM Usage", gpu_mem, THRESHOLD_GPU_MEM)

        except Exception as err:
            print(f"Error acessing hardware NVML registers: {err}")

if __name__ == "__main__":
    if not DISCORD_WEBHOOK_URL:
        print("Fatal Error: Discord Webhook URL is not set. Please set the DISCORD_WEBHOOK_URL environment variable.")
    else:
        run_resource_audit()