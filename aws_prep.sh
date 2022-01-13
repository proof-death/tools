#!/bin/bash
DEVICE_NAME=
DEVICE_DATA=
SCRIPT=$(echo $0 | awk -F "/" '{print $NF}')
REV="v0.1"
LOG="$SCRIPT.log"

Log() {
        NOW=$(date +"%b %d %H:%M:%S %Y")
        echo "$NOW: $@" >> $LOG 
}

Run() {
	Log $@
        OUT=$("$@" 2>&1 | tee -a $LOG)
        RET=$?
        if [ $RET -gt 0 ] 
	then
		echo -e "ERROR: An error occurred running '$@':\n$OUT"
		exit $RET
	fi
}

LogVar() {
        value=`eval echo '$'$1`
        Log "$1 = '$value'"
}

Error() {
        echo ""
        echo ""
        Log "[ERROR] $@"
        >&2 echo "ERROR: $@"
        exit 255
}

function Version()
{
        echo "$SCRIPT $REV"
}

function Usage()
{
        Version
	echo "This script is intended to be used to prep the AWS RHEL-7.3_HVM_GA-20161026-x86_64-1-Hourly2-GP2 AMI for the installation or upgrade of QRadar 7.3"
	echo "Usage: $SCRIPT {ARGS}"
	echo -e "\t-i|--install\t\t:: Preps the ec2 instance for the installation of QRadar. The system will automatically reboot upon completion."
	echo -e "\t-u|--upgrade\t\t:: Preps the ec2 instance for the upgrade of QRadar. The system will automatically reboot upon completion."
	echo
}


OSChanges() {
	echo "INFO: Disabling SELINUX and external repos..."
	Run sed -i -e 's/LANG.*/LANG="en_US.UTF-8"/g' /etc/locale.conf
	Run sed -i -e 's/^SELINUX=.*$/SELINUX=disabled/g' /etc/selinux/config
	Run sed -i -e 's/plugins=1/plugins=0/' /etc/yum.conf
	Run mkdir -p /etc/yum.repos.d.old
	Run mv /etc/yum.repos.d/* /etc/yum.repos.d.old/
	Run yum clean all
	
	# Enable root auth and direct ssh access, this is required if you want to add multiple hosts to QRadar
	echo "INFO: Enabling root login and ssh password authentication."
	Run sed -i -e 's/^PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
	Run sed -i -e 's/^#*PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config
	Run systemctl reload sshd.service
	
	#Run yum update -y rh-amazon-rhui-client
	#Run yum-config-manager --enable rhui-REGION-rhel-server-optional
	
	
	echo "INFO: Rebooting to completely disable SELINUX."
	Run shutdown -r now
}

DiskSetup() { 
	# Discover all the disks without partitions
	echo "INFO: Discovering non root devices that can be partitioned..."
	#declare -a DISKS=($(lsblk | grep -v $(lsblk | grep -B1 part | grep disk | awk '{print $1}') | grep disk | awk '{print $1}')) 
	declare -a DISKS=nvme1n1 
	if [ "${#DISKS[@]}" -eq 0 ]
	then
		Error "There does not appear to be any devices that are not curently partitioned. Please free up a device."
	fi
	echo "INFO: Found ${#DISKS[@]} devices."
	
	# Install the LVM tools 
	echo "INFO: Installing lvm tools..."
	Run yum install -y lvm2
	
	
	# Partition, setup LVM, and fstab
	if [ "${#DISKS[@]}" -eq 1 ]
	then
		DEVICE_NAME="/dev/"${DISKS[0]}
		echo "INFO: Partitioning $DEVICE_NAME and creating LVM groups."
		Run parted -a optimal --script ${DEVICE_NAME} -- mklabel gpt
		Run parted -a optimal --script ${DEVICE_NAME} -- mkpart swap 0% 24GiB # SWAP
		Run parted -a optimal --script ${DEVICE_NAME} -- mkpart xfs 24GiB 64GiB # /var/log /storetmp
		Run parted -a optimal --script ${DEVICE_NAME} -- mkpart xfs 64GiB 100% # /store /transient
	
		# A sleep of 1 would likely work here
		COUNTER=0
		while [ ! -b ${DEVICE_NAME}p2 ]
		do
			sleep 1
			let COUNTER=$((COUNTER+1))
			if [ $COUNTER -ge 30 ]
			then
				Error "Unable to find ${DEVICE_NAME}2 after $COUNTER seconds."
			fi
		done
	
		Run pvcreate ${DEVICE_NAME}p2
		Run vgcreate rootrhel ${DEVICE_NAME}p2
		Run lvcreate -l 50%FREE -n varlog rootrhel
		Run lvcreate -l 100%FREE -n storetmp rootrhel
		Run mkfs.xfs /dev/mapper/rootrhel-varlog
		Run mkfs.xfs /dev/mapper/rootrhel-storetmp	
	
		Run pvcreate ${DEVICE_NAME}p3
		Run vgcreate storerhel ${DEVICE_NAME}p3
		Run lvcreate -l 80%FREE -n store storerhel
		Run lvcreate -l 100%FREE -n transient storerhel
		
		Run mkswap -L swap1 ${DEVICE_NAME}p1
		Run mkfs.xfs /dev/mapper/storerhel-store
		Run mkfs.xfs /dev/mapper/storerhel-transient
		
		Run sed -i -e "s/\(.*${DISKS[0]}.*\)/#\1/g" /etc/fstab
		Run sed -i -e "s/\(.*rootrhel.*\)/#\1/g" /etc/fstab
		Run sed -i -e "s/\(.*storerhel.*\)/#\1/g" /etc/fstab
		
		echo "${DEVICE_NAME}1 swap  swap defaults 0 0" >> /etc/fstab
		echo "/dev/mapper/rootrhel-storetmp /storetmp xfs inode64,logbsize=256k,noatime,nobarrier 0 0" >> /etc/fstab
		echo "/dev/mapper/rootrhel-varlog /var/log xfs inode64,logbsize=256k,noatime,nobarrier 0 0" >> /etc/fstab
		echo "/dev/mapper/storerhel-store /store xfs inode64,logbsize=256k,noatime,nobarrier 0 0" >> /etc/fstab
		echo "/dev/mapper/storerhel-transient /transient xfs inode64,logbsize=256k,noatime,nobarrier 0 0" >> /etc/fstab
	else
		echo "INFO: There are ${#DISKS[@]} available but we're only using up to 1 automatically at present. Ignoring the rest..."
		break
	fi
	
	# Make directories and mount them
	echo "INFO: Making directories and mounting..."
	Run mkdir -p /store
	Run mount /store
	Run mkdir -p /storetmp
	Run mount /storetmp
	Run mkdir -p /transient
	Run mount /transient
	Run mv /var/log /var/oldlog
	Run mkdir -p /var/log
	Run mount /var/log
	Run mv /var/oldlog/* /var/log/
	Run mkdir -p /media/cdrom
	
	Run swapon -a
}

InstallPrep() {
	DiskSetup
	OSChanges
}

UpgradePrep() {
	eval `blkid -t LABEL=storetmp -o export`
	eval `blkid -t LABEL=/store/tmp -o export`
	echo UUID=$UUID /storetmp $TYPE defaults,noatime 1 1 >> /etc/fstab

	mkdir -p /media/cdrom
	mkdir -p /storetmp
	mount /storetmp

	# Change MAC in AUTO_INSTALL_INSTRUCTIONS
	IFACE=$(grep ai_ip_management_interface /storetmp/AUTO_INSTALL_INSTRUCTIONS | awk -F= '{print $2}')
	MAC=$(cat /sys/class/net/$IFACE/address)
	sed -i -e s/ai_ip_management_interface.*$/ai_ip_management_interface=$IFACE=$MAC/ /storetmp/AUTO_INSTALL_INSTRUCTIONS

	mkdir -p /store
	mkdir -p /transient
	eval `blkid -t LABEL=/store -o export` ; eval `blkid -t LABEL=store -o export` ; echo UUID=$UUID /store $TYPE defaults,noatime 1 1 >> /etc/fstab
	eval `blkid -t LABEL=transient -o export` ; eval `blkid -t LABEL=/store/transient -o export` ; echo UUID=$UUID /transient $TYPE defaults,noatime 1 1 >> /etc/fstab
	eval `blkid -t LABEL=/var/log -o export` ; echo UUID=$UUID $LABEL $TYPE defaults,noatime 1 1 >> /etc/fstab
	echo  "$(blkid -t LABEL=swap1 | cut -d: -f1) swap  swap defaults 0 0" >> /etc/fstab
	OSChanges
}


################################################################################################################################
#
# MAIN
#

# Runas root
if [ $(id -u) -ne 0 ]
then
        echo "ERROR: You must run this as root."
	Usage
	exit 255
elif [ "$#" -eq 0 ]
then
	echo "ERROR: No arguments were passed."
	Usage
	exit 255
fi

# Read in command line arguments
while getopts "iuvh-:" OPT
do
        case $OPT in
        h)
                Usage
                exit 0
                ;;
        v)
                Version
                exit 0
                ;;
	i)
		InstallPrep
		;;
	u)
		UpgradePrep
		;;
        -)
                case $OPTARG in
                        help)
                                Usage
                                exit 0
                                ;;
                        version)
                                Version
                                exit 0
                                ;;
                        upgrade)
                                UpgradePrep
                                ;;
			install)
				InstallPrep
				;;
                esac
                ;;
        *)
                echo "ERROR: Unknown argument '$OPTARG' was passed."
                Usage
                exit 255
                ;;
        esac
done
