# Case Study 2 for DS553 - Group 16 - Full Documentation

## Baseline VM Hardware Specs./Notes:
Memory: 4 GB RAM
Swap: 2GB
GPU: no NVIDIA GPU
SSH port: 22016
Machines/Architecture: We are using the WPI Linux server on a private account to run the cron job of the check_and_recovery.sh script and make calls to deploy our scripts to our VM. The WPI Linux server is the brains of this operation. 

## Part 1 - Virtual Machine Setup - deploy_first_part.sh
### Required Configurations/Credentials in SSH Script:
1. Randy's bootstrap public/private key pair (if the ssh needs to be locked down again).
2. Group 16's secure public/private key pair.
3. Port for our group (22016)
(Note: See 'Part 2' below for environment configuration details)

### Steps Involved in Script:
1. We established the new key file name and other variables relevant to ssh calls to make it easier.
2. We also established our ssh and scp settings to keep them consistent across calls.
3. We first check if the new secure public/private key pair are available on my WPI Linux Server, then tries an ssh connection to see if the secure public key is already on the VM/works. 
4. If this connection works with our secure key, the script skips the bootstrap steps, removes Randy's public key if necessary from the VM, then finishes a final SSH connection check.
5. If the connection does not work, the script enters the "bootstrap" mode. This will use randy's originally provided bootstrap key to opens a new vm connection to check that his key works. Then it will upload my group 16 public key to the virtual machine from the linux machine,then open a new connection to check that it works. 
6. Once it verifies that it works, it deletes Randy's public key off the VM.
7. Then it doubles checks the connection one final time with the group 16 key. 

## Part 2 - Deployment of Products on VM - deploy_second_part.sh & app.py modifications 
### Modifications to app.py
1. The app no longer uses any GPU-related packages (see requirements.txt for full packages needed).
2. As the product is no longer running on Hugging Face, users now have to input an inference token to use the API model. This was created as a button that will send the inference token for validation to Hugging Face.
3. We noticed an error if we tried to use the remote model and then the local model without refreshing the page in between. A new function called normalize_history was added to allow for the previous remote model's inputs/outputs to be attached to the new local model query. This allows for the local model to still use information from the remote model that it output. It had to be converted into a regular string (Qwen could not handle list format).
4. We had to add a server name and server port to the Gradio app deployment function at the end. This allows the app to run on our internal Gradio port and be accessible to the outside, as well.

### Virtual Environment Configuration
1. All required packages for the app deployment are in the requirements.txt file. We chose to not install any NVIDIA PyTorch GPU packages that we used last time to speed up app deployment after a VM reset as those packages were large.
2. In deploy_second_part.sh, we also ensure certain commands are on the VM and python dependencies that I will specify in more detail below.

### Deployment Steps - deploy_second_part.sh
1. We establish the same variables to make ssh calls easier (port, username, key).
2. We also set the ssh and scp settings to be consistent.
3. We check that ssh, scp, and curl are available on the WPI linux server we are using to make the calls.
4. We also check that the secure group 16 private key is on the WPI linux server as that is necessary to establish ssh to the VM.
5. We then clone the github repository over to the VM after verifying it does not already exist on there.
6. Then we install python virtual environment support packages if needed with 'sudo apt install'. Then we remove any possible prior environments and create a new virtual python environment.
7. Then we install the requirements packages.
8. Then we create a systemd service file to support launching the app in a controlled manner after VM re-creations.
9. Then we deploy the app with the systemd service, wait for it to come back online, and then do a final webpage connection check to make sure the app is live on the Gradio page.

## Part 3 - Automated Deployment - check_and_recovery.sh
### Cron Job - cron_job_config.txt
1. The cron job is scheduled to run the check_and_recovery.sh script every one minute from the Linux server.
Note: See cron_job_config.txt for more details.

### check_and_recovery.sh Steps
1. First, like the other scripts, we set the variables for the SSH credentials, file locations of deploy_first_part.sh and deploy_second_part.sh, the app's url, the ssh and scp settings.
2. We also made a custom log function that logs recovery events in recovery.log file. 
3. We have a flock section then to lock the recovery process so the 1 minute cron jobs won't keep running over each other in the case that the app is down and needs time to re-establish a secure ssh and also re-deploy the app.
4. Then we once again check for curl and ssh commands necessary for the script to work once it starts doing calls.
5. We then have a function that checks that the app is healthy through a url call.
6. We also have a function that checks that the ssh is secure with the group 16 key. 
7. And a function that checks the app is back up and running after a recovery instance.
8. If the app is healthy, the script logs this and exits without any further recovery actions.
9. Then, if the ssh connection with the secure group 16 key fails after trying for two minutes, it runs the deploy_first_part.sh script.
10. Because this implies the VM was fully reset, it then runs the deploy_second_part.sh script.
11. If the ssh connection didn't fail but the app is down, the script will restart the systemd application and wait for 10 minutes to check if the app is healthy again.
12. If this doesn't work, then it follows the same path where it runs the deploy_second_part.sh script as well.
13. Then it waits for 10 minutes to check the app is healthy again.
14. If it is not, it prints a fail statement and logs this.