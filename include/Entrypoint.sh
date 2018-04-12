#!/bin/bash
#############################################
#
# MASTER_ADDRESSES must be a comma delimited environment variable
# HOSTGROUPS must be a comma delimted environment variable
# SELF_HOSTNAME must be set
# PEER_ADDRESSES must be set
# DEBUG is a boolean, accepts 1 or true
#
#############################################

# Create Array From Comma Delimited List
masters=(${MASTER_ADDRESSES//,/ })
peers=(${PEER_HOSTNAMES//,/ })

print(){
    if [ $1 == "info" ];then 
        echo -e '\033[36m' [INFO] $2 '\033[39;49m'
    elif [ $1 == "warn" ];then
        echo -e '\033[33m' [WARN] $2 '\033[39;49m'
    elif [ $1 == "error" ]; then
        echo -e '\033[31m' [ERROR] $2 '\033[39;49m'
    elif [ $1 == "success" ]; then
        echo -e '\033[32m' [SUCCESS] $2 '\033[39;49m'
    fi 
}

service_online(){
    service sshd start
    service mysqld start
    service merlind start
    service naemon start
    service httpd start
    service nrpe start
    service processor start
    service rrdcached start
    service synergy start
    service smsd start
    service collector start
}

advertise_masters(){
    for i in "${!masters[@]}"
    do
        if [ $1 == "add" ]; then
            print "info" "Performing Add On ${masters[i]}"
            mon sshkey fetch ${masters[i]}
            asmonitor mon sshkey fetch ${masters[i]}
            mon node add ${masters[i]} type=master
            mon node ctrl ${masters[i]} mon node add ${SELF_HOSTNAME} type=poller hostgroup=${HOSTGROUPS} takeover=no
	    mon node ctrl  ${masters[i]} -- /usr/local/scripts/add_sync.sh ${SELF_HOSTNAME}
            mon node ctrl ${masters[i]} mon restart
        else
            print "info" "Performing Remove On ${masters[i]}"
            mon node ctrl ${masters[i]} mon node remove ${SELF_HOSTNAME}
            mon node ctrl ${masters[i]} mon restart
        fi
    done
}

advertise_peers(){
#    if [ -z ${PEER_ADDRESSES} ]; then
#        return
#    fi

    if [ $1 == "add" ]; then
        for i in "${!peers[@]}"
            do
                nc -z ${peers[i]} 15551
                if [[ "$?" == "0" ]]; then
                    print "info" "Performing Add On ${peers[i]}"
                    mon sshkey fetch ${peers[i]}
                    asmonitor mon sshkey fetch ${peers[i]}
                    mon node add ${peers[i]} type=peer
                    mon node ctrl ${peers[i]} mon node add ${SELF_HOSTNAME} type=peer
                    mon node ctrl ${peers[i]} mon restart
                else
                    print "error" "${peers[i]} not up, ignoring."
                fi
            done
     else
         # We need to parse the merlin.conf file to remove peers that we didnt used to know about
         # when we were started.
         # This can be changed when OP5 implements a way to get a peer list.
         toremove=$( grep "^peer" /opt/monitor/op5/merlin/merlin.conf | awk '{print $2}' | paste -d " " -s )

         for i in "${!toremove[@]}"
            do
                print "info" "Performing Remove On ${toremove[i]}"
                mon node ctrl ${toremove[i]} mon node remove ${SELF_HOSTNAME}
                mon node ctrl ${toremove[i]} mon restart
            done
    fi
   
}

get_config(){
    # Only getting config from one master because mon oconf always exits 0
    # The fetch will initiate a restart of the the local merlind.
    # This should be the only time we need to to restart locally since new pollers will restart us.
    print "info" "Syncing Configuration With ${masters[0]}"
    mon node ctrl ${masters[0]} asmonitor mon oconf push ${SELF_HOSTNAME}
}


shutdown(){
    # If container is gracefully shutdown with SIGTERM (e.g. docker stop), remove
    # pre-emptively remove itself
    print "warn" "SIGTERM Caught! Removing From Cluster"
    advertise_peers remove
    advertise_masters remove
}


keep_swimming(){
    # This function should be the last thing to run. This is how the Container will
    # persist. Under normal conditions we show a tail of merlins log and fork it 
    # because this script needs to be PID 1 with NO CHILDREN due to the way parent
    # processes handle SIGTERM                                                      
    # The container must be run with -it for proper console access
    if [ "${debugging}" == "1" ]; then
        read -n1 -r -p "Press Any Key To Enter The Debug Console..."
        debug_console
    else    
        print "info" "Checking For Online Peers"
        
        advertise_peers add 
        
        print "info" "Getting Config From Master"
        get_config

        tail -f /var/log/op5/merlin/daemon.log &
        wait $!


        
    fi
}

debug_console(){
    tmux new-session -d '/bin/bash' \; rename-window -t 0 Shell \; new-window -d 'multitail --mergeall /var/log/op5/merlin/daemon.log /var/log/op5/merlin/neb.log' \; rename-window -t 1 Merlind \; attach
}

check_debug(){
    # This should be the first thing to run. Other functions that need to
    # figure out if we are in debug mode should check if ${debugging} is 1
    if [ "${DEBUG,,}" == "true" ] || [ "${DEBUG}" == "1" ]; then
        debugging=1
        print "warn" "DEBUG INFORMATION WILL BE DISPLAYED"
        run_debug
    else
        return
    fi
}


run_debug(){
    # If debugging is 1, anything to run before the debug console
    # should be placed here.
    
    if [ -z ${MASTER_ADDRESSES} ]; then
        print "error" "No Master Addresses Are Set!"
    else
        print "success" "Master Addresses Are: ${MASTER_ADDRESSES}"
    fi
    if [ -z ${PEER_ADDRESSES} ]; then
        print "warn" "No Peer Addresses Are Set!"
    else
        print "success" "Peer Addresses Are: ${PEER_ADDRESSES}"
    fi
    if [ -z ${SELF_HOSTNAME} ]; then
        print "error" "Hostname Is Not Set!"
    else
        print "success" "My Hostname Is: ${SELF_HOSTNAME}"
    fi
    if [ -z ${HOSTGROUPS} ]; then
        print "error" "I Am Not A Member Of Any Hostgroups!"
    else
        print "success" "My Hostgroups Are: ${HOSTGROUPS}"
    fi
    
    # Change OP5 Log levels 
    sed -i 's/level:.*/level: debug/' /etc/op5/log.yml
    sed -i 's/log_level = info;/log_level = debug;/' /opt/monitor/op5/merlin/merlin.conf

}


main(){
    check_debug
    service_online
    advertise_masters add
#    advertise_peers add
#    get_config
#
# We will no longer try to add ourselves to peers or get configuration on startup.
# This functionaility will now be handled in Keep swimming.
#
    keep_swimming
}

# Graceful shutdown handling and run main()
trap "shutdown" SIGTERM
main