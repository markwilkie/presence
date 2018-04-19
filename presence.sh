
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
# INCLUDES & VARIABLES
# ----------------------------------------------------------------------------------------

Version=0.3.66

#base directory regardless of installation
Base=$(dirname "$(readlink -f "$0")")
MQTTPubPath=$(which mosquitto_pub)

#load preferences if present
MQTT_CONFIG=$Base/mqtt_preferences ; [ -f $MQTT_CONFIG ] && source $MQTT_CONFIG

# ----------------------------------------------------------------------------------------
# Set Program Variables
# ----------------------------------------------------------------------------------------

#or load from a source file
DELAY_CONFIG=$Base/behavior_preferences ; [ -f $DELAY_CONFIG ] && source $DELAY_CONFIG

#current guest
currentGuestIndex=0

# ----------------------------------------------------------------------------------------
# SCAN FOR GUEST DEVICES DURING OWNER DEVICE TIMEOUTS
# ----------------------------------------------------------------------------------------

function scanForGuests () {
	#to determine correct exit time for while loop
	STARTTIME=$(date +%s)

	#init end time
	ENDTIME=0

	#this time
	seen=()

	#if we have guest devices to scan for, then scan for them!
	if [ ! -z "$macaddress_guests" ]; then 

		#calculate 
		DIFFERENCE=$((ENDTIME - STARTTIME))

		#start while loop during owner scans
		while [ $DIFFERENCE -lt $delayBetweenOwnerScansWhenPresent ]
		do

			#cache bluetooth results 
			nameScanResult=""

			#obtain individual address
			currentGuestDeviceAddress="${macaddress_guests[$currentGuestIndex]}"

			#check if seen
			if [ "${seen[$currentGuestIndex]}" == "1" ]; then 
				
				#calculate remainder of delay
				DELAY=$((delayBetweenOwnerScansWhenPresent - DIFFERENCE)) 

				#delay
				sleep $DELAY 

				break
			fi

			#mark as seen
			seen[$currentGuestIndex]=1

			#obtain results and append each to the same
			nameScanResult=$(scan $currentGuestDeviceAddress)
			
			#this device name is present
			if [ "$nameScanResult" != "" ]; then
				#publish the presence of the guest 
				publish "/$mqtt_room/$currentGuestDeviceAddress" '100' "$nameScanResult"
			fi

			#iterate the current guest that we're looking for
			currentGuestIndex=$((currentGuestIndex+1))

			#correct the guest index
			if [ "$numberOfGuests" == "$currentGuestIndex" ]; then 
				currentGuestIndex=0
			fi

			#sleep between guest scans
			sleep $delayBetweenGuestScans 

			#set endtime 
			ENDTIME=$(date +%s)

			#refersh differnce
			DIFFERENCE=$((ENDTIME - STARTTIME)) 
		done

	else
		sleep $1
    fi
}

# ----------------------------------------------------------------------------------------
# Scan script
# ----------------------------------------------------------------------------------------

function scan () {
	if [ ! -z "$1" ]; then 
		result=$(hcitool name "$1" 2>&1 | grep -v 'not available')
		echo "$result" 
	fi
}

# ----------------------------------------------------------------------------------------
# Publish Message
# device mac address; percentage
# ----------------------------------------------------------------------------------------

function publish () {
	if [ ! -z "$1" ]; then 
		distance_approx=$(convertTimeToDistance $4)
		name="$3"

		#if no name, return "unknown"
		if [ -z "$3" ]; then 
			name="Unknown"
		fi 

		#timestamp
		stamp=$(date "+%a %b %d %Y %H:%M:%S GMT%z (%Z)")

		#present or not
		state="Away"
		if [ "$2" -gt 90 ]; then
			state="Present"
		elif [ "$2" -gt 10 ]; then
			state="Just Left"
		fi

		#fix bt mac address
		macaddress=${1//:/_}

		#post to mqtt
		$MQTTPubPath -h "$mqtt_address" -t "$mqtt_topicpath$macaddress" -m "{\"state\":\"$state\",\"confidence\":\"$2\",\"name\":\"$3\",\"distance\":\"$distance_approx\",\"timestamp\":\"$stamp\"}"
	fi
}

# ----------------------------------------------------------------------------------------
# Translate ms scan times into distance approximation
# ----------------------------------------------------------------------------------------

function convertTimeToDistance () {
	#very early ALPHA testing of distance measurement
	#these numbers can/should be adjusted based on environmental conditions

	#the thought process is that the speed with which a name query is completed
	#can be used as a proxy for the signal quality between a source and a remote
	#device. The signal quality might be able to be used as a proxy for distance. 

	#ALPHA ALPHA

	if [ ! -z "$1" ]; then 
		if [ "$1" -lt 500 ]; then 
			echo "very close"
		elif [ "$1" -lt 1000 ]; then 
			echo "nearby"
		elif [ "$1" -lt 1500 ]; then 
			echo "far"
		elif [ "$1" -lt 2000 ]; then 
			echo "distant"
		elif [ "$1" -gt 2000 ]; then 
			echo "very distant"
		fi 
	else
		echo "undefinable"
	fi
}


# ----------------------------------------------------------------------------------------
# Preliminary Notifications
# ----------------------------------------------------------------------------------------

#Fill Address Array
IFS=$'\n' read -d '' -r -a macaddress_guests < "$Base/guest_devices"
IFS=$'\n' read -d '' -r -a macaddress_owners < "$Base/owner_devices"

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

		#check for additional blank lines in address file
		if [ -z "$currentDeviceAddress" ]; then 
			continue;
		fi

		#mark beginning of scan operation
		STARTSCAN=$(date +%s%N)

		#obtain results and append each to the same
		nameScanResult=$(scan $currentDeviceAddress)
		
		#mark end of scan operation
		ENDSCAN=$(date +%s%N)
		
		#calculate difference
		SCAN_DURATION=$(( (ENDSCAN - STARTSCAN) / 1000000 )) 

		#echo to stderr for debug and testing
		#(>&2 echo "Duration: $SCAN_DURATION ms")

		#this device name is present
		if [ "$nameScanResult" != "" ]; then

			#no duplicate messages
			publish "/$mqtt_room/$currentDeviceAddress" '100' "$nameScanResult" "$SCAN_DURATION"

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

				#mark beginning of scan operation
				STARTSCAN=$(date +%s%N)

				#perform scan
				nameScanResultRepeat=$(scan $currentDeviceAddress)

				#mark end of scan operation
				ENDSCAN=$(date +%s%N)
				
				#calculate difference
				SCAN_DURATION=$(( (ENDSCAN - STARTSCAN) / 1000000 )) 

				#(>&2 echo "Duration: $SCAN_DURATION ms")

				#checkstan
				if [ "$nameScanResultRepeat" != "" ]; then
					#we know that we must have been at a previously-seen user status
					publish "/$mqtt_room/$currentDeviceAddress" '100' "$nameScanResult" "$SCAN_DURATION"\
					deviceStatusArray[$index]="100"
					deviceNameArray[$index]="$nameScanResult"

					scanForGuests $delayBetweenOwnerScansWhenPresent
					break
				fi 

				#update percentage
				deviceStatusArray[$index]="$percentage"
				expectedName="${deviceNameArray[$index]}"

				#report confidence drop
				publish "/$mqtt_room/$currentDeviceAddress" "$percentage" "$expectedName" "$SCAN_DURATION_MILISECONDS"

				#set to percentage
				deviceStatusArray[$index]="$percentage"

				#delay default time
				scanForGuests $delayBetweenOwnerScansWhenAway
			done

			#publication of zero confidence in currently-tested device
			if [ "${deviceStatusArray[$index]}" == "0" ]; then 
				publish "/$mqtt_room/$currentDeviceAddress" '0'
			fi

			#continue with scan list
			scanForGuests $delayBetweenOwnerScansWhenAway
		fi
	done
done
