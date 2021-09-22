# Citrix_VDI__WeeklyReboot

## .SYNOPSIS

Utility used for performing weekly reboots of all Non-persistent VDI Citrix machines. Non-persistent virtual machines relies on caching user changes to a local hard drive on each VM given the nature of the streamed-OS technology. Given that cache on each VM would fill up towards the tail-end of the week, this utility properly forces all used and un-used VMs to efficiently reboot and allows for prisistine cache drives to be available for users at the start of the work week.

## .DESCRIPTION

Citrix currently has no utility to properly manage VDI reboots on an interval basis. Reboots are essential for business continuty to minimize user interruption when their cache drives are full and they either need to log off or are forcefully kicked-off due to crashing VM.

Legacy reboot implementations lasted several hours to complete and ran in a linear fashion. This implementation has a total runtime of a few seconds and gives users a generous amount of time to comfortably save all of their work and log off. Users can then iommediately log back in to a freshly rebooted machine from the pool.

This script leverages multi-threading to accomplish all of the reboots. 

Each thread responsible for a VM will provide the shutdown commend with a specified time interval.
VM Scenarioes:
  1. An unused VM will be given the shutdown command with a random interval between 0 and 60 seconds.
    a. This allows for unused VMs to quickly reboot and be on standby for any active users that log off and want to log back immediately.
  3. A used VM but in a disconnected state will be given the shutdown command with a random interval between 20-40 minutes.
    b. This allows for disconnected machines to log off after unused and before used in an effort to not stress hardware with boot storm.
  5. A used VM but with an active session will be given the shutdown command with a random interval between 55-60 minutes.
    c. This allows for active users to have a full hour of preparation to save their work and log off. If they choose to immediately log back in, they will obtain a freshly rebooted VM from steps 1/2.
    
The design implementation of the threads below was a Tree structure concept.
Rather than multithreading n linear runspaces where n is the number of virtual machines, the intent here was to generate 
m number of runspaces where m is the number of Hypervisor Hosts hosting the virtual machines. 
Each m runspace would then be responsible for rebooting the virtual machines it is hosting (j).
For example, you have 60 Hypervisor Hosts where each host services 30 Virtual Machines.
The script will generate M number of runspaces, one for each host (H_01 all the way to H_m). 
Each one of those Host runspaces will be responsible for generating and maintaining n number of runspaces (VM_01 all the way to VM_j)


       H_01        .............         H_m
    /        \     .............     /        \
    VM_01 ... VM_j   .............   VM_01 ... VM_j 
    
Keep in mind, the value of J is going to flucuate between each hypervisor host.
Host_01 can have 30 VMs and spawn 30 runspaces but Host_03 may have only 24 VMs and will only spawn 24 runspaces.
The script acknowledges dynamic host usage and will react appropriately.

Once a thread detects one of the 3 scenarios listed above, it will offload the shutdown command with the specified time to the endpoint. This allows for minimial resource consumption on the server.

## .ACCOMPLISHMENTS/WHAT I LEARNED

Legacy reboot implementations ran in a sequential fashion and leveraged Citrix Broker SDK for the reboot command. With this method, the Citrix Broker SDK will then send reboot requests to the vCenter for execution. All in all, you are incurring bottlenecks from Citrix Broker which limits about of power action commands done within a certain window as well as throttling from vCenter which limits amount of commands it can execute. By offloading the shutdown command to the client, we can bypass both of these limits and effectivly power manage the environment. Total runtime was reduced from a few hours to a few seconds. 

## .AREAS OF IMPROVEMENT

Areas of improvement would be to create a user interface where we would leverage this as a library to execute estate-wide shutdowns for maintenance work or add an interface for specifiying target VM conditions.

## .NOTES
Script was created using Powershell 5.1. 

PoshRSJob and Citrix Broker SDK are required.






