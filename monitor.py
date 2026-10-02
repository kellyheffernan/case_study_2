# Tracks resource usage on the VM and sends a message to the team through Discord if the usage exceeds a certain threshold.
# Then automatically reacts to the high resource usage by some action, such as temporarily switching to a smaller model or 
# reject/delay new requests until the usage drops back to normal levels.
# Then documents the threshold used, how resouce usage is measured, what automated actions are taken, and how the system returns to normal operation 
# once the resource usage drops back to normal levels.