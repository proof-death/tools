#!/bin/bash
#
# Author: Chris Fredericks
# Date: Jan 22, 2016
# Update: Feb 17, 2017
# Desc: This script is designed to sync /store/ariel from system to another.
#	It does it one month at a time per DB/TYPE directory (e.g. events/records).
# 	It records completed directories in case the script gets interrupted.
#
# TODO: Add remove key option for cleanup. Or just a cleanup that removes the remote key
#	and cleans up the report file.

SCRIPT=$(echo $0 | awk -F\/ '{print $NF}')
REV="0.7"
declare -a DBS=( events flows )
declare -a TYPES=( records payloads )
declare -a MONTHS

function version {
        echo "$SCRIPT $REV"
}

function usage {
	version
	echo "Usage:"
        echo -e "\t-i {ip}\t\t:: The IP address of the destination system. Required."
	echo -e "\t-k\t\t:: Setup ssh key. You will be prompted for a root/user password."
        echo -e "\t-d\t\t:: Peform a dry-run. No sync will occur."
	echo -e "\t-u {user}\t:: username for ssh.  root is default."
	echo
}

# Show usage if there were no arguments passed
# Getopts does not deal with long arguments
if [[ $@ =~ --help || $# -eq 0 ]]
then
        usage
        exit 0
fi

# Read in command line arguments
while getopts "u:hvdki:" OPT
do
        case $OPT in
        h)
                usage
                exit 0
                ;;
	u)
		SSHUSER=$OPTARG
		;;
        v)
                version
                exit 0
                ;;
	i)
		IP=$OPTARG
		;;
	d)
		DRYRUN=true
		echo "INFO: Executing in dry-run mode."
		;;
	k)
		SSHKEY=true
		;;
	*)
		usage
		exit 2
		;;
	esac
done

if [ "$IP" == "" ]
then
	usage
	exit 2
fi

if [ "$SSHUSER" == "" ]
then
	SSHUSER="root"
fi

# TODO: Change this so that it doesn't add a duplicate key if one already exists
if [ ! -z $SSHKEY ]
then
	echo "INFO: Setting up ssh keys on $IP. You may be prompted for the $SSHUSER password:"
	ssh-copy-id -i ~/.ssh/id_rsa.pub $SSHUSER@$IP >/dev/null
	RET=$?
	if [ $RET -ne 0 ]
	then
		echo "ERROR: Return code was $RET. Try setting up ssh keys manually."
		exit $RET
	fi	
fi


RECORD=$IP.RECORD
if [ -f $RECORD ]
then
        read -p "A sync has been run before on this system. Would you like to continue it? (Y|n) "
        if [[ "$REPLY" =~ N|n ]]
        then
                rm -f $RECORD
                echo "INFO: Restarting full sync."
        else
                echo "INFO: Continuing from previous sync."
        fi
fi

for DB in ${DBS[@]}
do
        for TYPE in ${TYPES[@]}
        do
                MONTHS=( `find /store/ariel/$DB/$TYPE -maxdepth 2 -mindepth 2 -type d 2>/dev/null` )
                CTR=0
                for MONTH in ${MONTHS[@]}
                do
                                CTR=$((CTR+1))

                                if [ "$(grep $MONTH $RECORD 2>/dev/null)" != "" ] # Don't sync dirs recorded as completed
                                then
                                        continue
                                fi
                                echo -n "RUNNING: rsync -az --exclude='.*' $MONTH/ $SSHUSER@$IP:$MONTH/"
				if [ -z $DRYRUN ]
				then
					START=$(date +%s)
					ssh $SSHUSER@$IP "mkdir -p $MONTH 2>/dev/null"
                        	        rsync -az --exclude='.*' $MONTH/ $SSHUSER@$IP:$MONTH/

					# Record the directory as completed if successful and not the latest month
                                	if [[ $? -eq 0 && $CTR -lt ${#MONTHS[@]} ]]  
                                	then
                                	        echo $MONTH >> $RECORD
                                	fi

					END=$(date +%s)
					echo ". Completed in $((END-START)) seconds."
				else 
					echo
				fi
				

                done
        done
done

echo "COMPLETE"
echo
exit 0
