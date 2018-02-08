
#!/bin/bash

# ----------------------------------------------------------------------------------------
# GENERAL INFORMATION
# ----------------------------------------------------------------------------------------
#
# Written by Andrew J Freyer
# GNU General Public License
#
# ----------------------------------------------------------------------------------------
#
# ----------------------------------------------------------------------------------------

# ----------------------------------------------------------------------------------------
# INCLUDES
# ----------------------------------------------------------------------------------------
Version=0.1

#source the support files
mqtt_address=""
mqtt_user=""
mqtt_password=""
mqtt_topicpath="" 

# ----------------------------------------------------------------------------------------
# Set Program Variables
# ----------------------------------------------------------------------------------------

delayBetweenOwnerScansWhenAway=7		#high number advised for bluetooth hardware 
delayBetweenOwnerScansWhenPresent=15	#high number advised for bluetooth hardware 
delayBetweenGuestScans=4				#high number advised for bluetooth hardware 
verifyByRepeatedlyQuerying=5 			#lower means more false rejection 

#current guest
currentGuestIndex=0

# ----------------------------------------------------------------------------------------
# SCAN FOR GUEST DEVICES DURING OWNER DEVICE TIMEOUTS
# ----------------------------------------------------------------------------------------

function scanForGuests () {
	#to determine correct exit time for while loop
	STARTTIME=$(date +%s)

	#if we have guest devices to scan for, then scan for them!
	if [ ! -z "$macaddress_guests" ]; then 

		#start while loop during owner scans
		while [ $((ENDTIME - STARTTIME)) -lt $delayBetweenOwnerScans ]
		do
			#set endtime 
			ENDTIME=$(date +%s)

			#cache bluetooth results 
			nameScanResult=""

			#obtain individual address
			currentGuestDeviceAddress="${macaddress_guests[$currentGuestIndex]}"

			#obtain results and append each to the same
			nameScanResult=$(scan $currentDeviceAddress)
			
			#this device name is present
			if [ "$nameScanResult" != "" ]; then
				#publish the presence of the guest 
				publish "/guest/$currentDeviceAddress" '100' "$nameScanResult"
			else
				#publishe that the guest is not here
				publish "/guest/$currentDeviceAddress" '0'
			fi

			#iterate the current guest that we're looking for
			currentGuestIndex=$((currentGuestIndex+1))

			#correct the guest index
			if [ "$numberOfGuests" == "$currentGuestIndex" ]; then 
				currentGuestIndex=0
			fi 

			delay $delayBetweenGuestScans

		done
	else
		delay $1
    fi
}

# ----------------------------------------------------------------------------------------
# Scan script
# ----------------------------------------------------------------------------------------

function scan () {
	if [ ! -z "$1" ]; then 
		echo $(hcitool name "$1" 2>&1 | grep -v 'not available')
	fi
}

# ----------------------------------------------------------------------------------------
# Publish Message
# device mac address; percentage
# ----------------------------------------------------------------------------------------

function publish () {
	if [ ! -z "$1" ]; then 
		echo "MQTT MESSAGE: $1 {'confidence':'$2','name':'$3'}"
		/usr/bin/mosquitto_pub -h "$mqtt_address" -u "$mqtt_user" -P "$mqtt_password" -t "$mqtt_topicpath/$1" -m "{'confidence':'$2','name':'$3'}"
	fi
}

# ----------------------------------------------------------------------------------------
# ARGV processing 
# ----------------------------------------------------------------------------------------

#argv updates
if [ ! -z "$1" ]; then 
	#very rudamentary process here, only limited support for input functions
	case "$1" in
		--version )
			echo "$Version"
			exit 1
		;;
	esac
fi 

# ----------------------------------------------------------------------------------------
# Preliminary Notifications
# ----------------------------------------------------------------------------------------

#Fill Address Array
IFS=$'\n' read -d '' -r -a macaddress_guests < "guest_devices"
IFS=$'\n' read -d '' -r -a macaddress_owners < "owner_devices"

#Number of clients that are monitored
numberOfOwners=$((${#macaddress_owners[@]}))
numberOfGuests=$((${#macaddress_guests[@]}))

# ----------------------------------------------------------------------------------------
# Main Loop
# ----------------------------------------------------------------------------------------

deviceStatusArray=()
deviceNameArray=()

#begin the operational loop
while (true); do	

	#--------------------------------------
	#	UPDATE STATUS OF ALL USERS
	#--------------------------------------
	for index in "${!macaddress_owners[@]}"
	do
		#cache bluetooth results 
		nameScanResult=""

		#obtain individual address
		currentDeviceAddress="${macaddress_owners[$index]}"

		#obtain results and append each to the same
		nameScanResult=$(scan $currentDeviceAddress)
		
		#this device name is present
		if [ "$nameScanResult" != "" ]; then

			#publish message
			publish "/owner/$currentDeviceAddress" '100' "$nameScanResult"

			#user status			
			deviceStatusArray[$index]="100"

			#set name array
			deviceNameArray[$index]="$nameScanResult"

			#we're sure that we're home, so scan for guests
			scanForGuests $delayBetweenOwnerScansWhenPresent

		else
			#user status			
			status="${deviceStatusArray[$index]}"

			if [ -z "$status" ]; then 
				status="0"
			fi 

			#should verify absense
			for repetition in $(seq 1 $verifyByRepeatedlyQuerying); 
			do 
				#get percentage
				percentage=$(($status * ( $verifyByRepeatedlyQuerying - $repetition) / $verifyByRepeatedlyQuerying))

				#perform scan
				nameScanResultRepeat=$(scan $currentDeviceAddress)

				#checkstan
				if [ "$nameScanResultRepeat" != "" ]; then
					#we know that we must have been at a previously-seen user status
					publish "/owner/$currentDeviceAddress" '100' "$nameScanResult"

					deviceStatusArray[$index]="100"
					deviceNameArray[$index]="$nameScanResult"

					scanForGuests $delayBetweenOwnerScansWhenPresent
					break
				fi 

				#if we have 0, then we know we haven't been found yet
				if [ "${deviceStatusArray[$index]}" == "0" ]; then 
					break
				fi  

				#update percentage
				deviceStatusArray[$index]="$percentage"
				expectedName="${deviceNameArray[$index]}"

				#report confidence drop
				publish "/owner/$currentDeviceAddress" '$percentage' '$expectedName'

				#set to percentage
				deviceStatusArray[$index]="$percentage"

				#delay default time
				scanForGuests $delayBetweenOwnerScansWhenAway
			
			done

			#publication of zero confidence in currently-tested device
			if [ "${deviceStatusArray[$index]}" == "0" ]; then 
				publish "/owner/$currentDeviceAddress" '0'
			fi

			#continue with scan list
			scanForGuests $delayBetweenOwnerScansWhenAway
		fi
	done
done