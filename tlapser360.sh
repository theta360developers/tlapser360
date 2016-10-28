#! /bin/bash

# tlapser360 - take timelaspe photos at given interval for given number of times.

# Copyright 2016 - Jason Charcalla

# Prereqs: 
# - GPS support relies on gpsd and gpsd-clients being installed and configured.
# - The bc package is needed for maths.
# - LUX meter support was tested with a adafruit TSL2561 and some tweaks to IainColledge's
#   example script. See this variable "LUX_METER_SCRIPT"
#   https://github.com/IainColledge/Adafruit-Raspberry-Pi-Python-Code
# - Theta s Usb support with libptp, Thanks to codetricity for the howto 
#   http://lists.theta360.guide/t/ricoh-theta-s-api-over-usb-cable/65/3

# Changelog:
# .1 - ugly script uploaded to github.
# .2 - added usb support via libptp
# .3 - function for converting decimal shutter speeds to hex for raw usb


PROGNAME=$(basename "$0")
#PROGPATH=$(echo "$0" | /bin/sed -e 's,[\\/][^\\/][^\\/]*$,,')
#. $PROGPATH/utils.sh

#Set some defaults in case they are not specified
CAMIP=192.168.1.1
PORT=80
CONNECTION="W"
GETIMAGES=0
RES="l"
METER=0
GPS=0
# Default DELIMG to off, unless it gets over written below
DELIMG=0
#METER_GPIO=4
#METER_VALUE=0
WHITE_B="auto"
# If no sunrise or sunset it specfied we spefify sunset as now
# this should allow longer exposures after some amount of time with the meter
AM=0
PM=1
SUNSET=$(date +%s)
# Delay in seconds till shutter change after or befor sunset default 3000
AMPMDELAY=3000
AMPMSCALE1=420
AMPMSCALE2=480

# If you have a script for the lux meter, define its location here.
LUX_METER_SCRIPT="~/Adafruit-Raspberry-Pi-Python-Code-IainColledge/Adafruit_TSL2561/Adafruit_TSL2561_example.py"
#LUX=$(${LUX_METER_SCRIPT})
#echo "LUX IS ${LUX}"
  
print_usage() {
	echo "Usage: $PROGNAME 
	-I <Interval seconds> 
	-U Usb mode for theta s
	-W Wifi mode
	-C <Image count> 
	-m <Exposure Program mode 1 2 4 9> 
	-G <GPS support 0/1 - This may introduce added latency!> 
	-T <GPS Track log path and file name> 
	-r <image resolution size h/l> 
	-i <iso> 
	-s <shutter speed> 
	-w <White Balance> 
	-O <Output path /> 
	-d <0/1 if images are downloaded delete them from the camera.> 
	-F <Config file - NOT SUPPORTED> 
	-M < 0/1 use a TSL2561 LUX sensor for metering. if used we will add time to your interval > 
	-R <Ramp exposure speed up (longer shutter - Sunset) or down (shorter/faster shutter - Sunrise) based on external LUX meter.> 
	-A <Sunrise time (24hr no : ex, 6:00AM=600)> -P <Sunset time (24hr no ":" ex, 7:00PM=1900)>
	"
       echo "ISO and Shutter speed are only needed if Exposure mode is set to 1"                                                               
       exit 1
}
  
  while getopts h?I:U:W:C:G:T:O:F:d:m:r:i:s:w:M:R:A:P: arg ; do
      case $arg in
	I) INTERVAL=$OPTARG
	ORIGINAL_INTERVAL=$INTERVAL;;
	W) CONNECTION=W ;;
	U) CONNECTION=U ;;
	C) ICOUNT=$OPTARG ;;
	G) GPS=$OPTARG 
	TRACKLOG="/dev/null" ;;
        T) TRACKLOG=$OPTARG ;;
	O) OUTPATH=$OPTARG
	GETIMAGES=1 ;;
#	F) CONF=$OPTARG ;;
	d) DELIMG=$OPTARG ;;
	m) MODE=$OPTARG ;;
	r) RES=$OPTARG ;;
	i) ISO=$OPTARG ;;
	s) SSPEED=$OPTARG ;;
	w) WHITE_B=$OPTARG ;;
	M) METER=$OPTARG ;;
	R) RAMP=$OPTARG ;;
	A) AM=1
	   PM=0
	   SUNRISE=$(date --date="$OPTARG" +%s) ;;
	P) PM=1
 	   SUNSET=$(date --date="$OPTARG" +%s) ;;
        h|\?) print_usage; exit ;;
      esac
  done

# Function to convert decimal shutter speed to hex for ptpcam raw
ss_convert () {
if (( $(echo "${SSPEED} < 1" | bc -l) ))
then 
    # If the shutter speed is less than 1 we do it this way (looks something like 1/60)
    SSPEED_FRACTION=$(echo "1/${SSPEED}" | bc)
    SSPEED_HEX2=$(printf "%08x\n" ${SSPEED_FRACTION} | awk '{print substr ($0,7,2) substr ($0,5,2) substr ($0,3,2) substr ($0,1,2)}' | sed 's/.\{2\}/&\\x/g' | sed -e 's/^/\\x/' | awk '{print substr($0,1,length()-2)}')
    # The 1st hex intiger in this case is always a 1.
    SSPEED_HEX1="\x01\x00\x00\x00"
    # if its a decimal greater than 1 (1.3 or 1.6 looks something like 13/10)
elif [ $(echo ${SSPEED} | grep "\.") ]
then 
    #echo "Decimal found, greater than 1"
    # If the shutter speed is less than 1 we do it this way (looks something like 1/60)
    # move the decimal
    SSPEED_SCALED=$(echo "scale=0; ${SSPEED}*10/1" | bc -l)
    SSPEED_HEX1=$(printf "%08x\n" ${SSPEED_SCALED} | awk '{print substr ($0,7,2) substr ($0,5,2) substr ($0,3,2) substr ($0,1,2)}' | sed 's/.\{2\}/&\\x/g' | sed -e 's/^/\\x/' | awk '{print substr($0,1,length()-2)}')
    # The 2nd hex intiger in this case is always a 10, or a
    SSPEED_HEX2="\x0a\x00\x00\x00"
else 
    #echo "Greater then 1"
    # If its greater than one but not a decimal or something like this 30/1
    SSPEED_HEX1=$(printf "%08x\n" ${SSPEED} | awk '{print substr ($0,7,2) substr ($0,5,2) substr ($0,3,2) substr ($0,1,2)}' | sed 's/.\{2\}/&\\x/g' | sed -e 's/^/\\x/' | awk '{print substr($0,1,length()-2)}')
    # The 2nd hex intiger in this case is always a 1, or a
    SSPEED_HEX2="\x01\x00\x00\x00"
fi
echo -e -n "${SSPEED_HEX1}${SSPEED_HEX2}" > /dev/shm/ss_hex_tmp.bin
}
# somewhere here I would need to parse a config file if I had one

# If were using USB we can skip this step
if [ "$CONNECTION" == W ]
then
	# connect to the camera, retrive the last session id
	echo "Connecting to camera with WIFI"
	SID=$(curl -s -X POST http://${CAMIP}:${PORT}/osc/commands/execute -d '{"name": "camera.startSession"}' | cut -d "\"" -f 14 | cut -d "_" -f2)

	echo "$SID"

# take photos durring a while loop and wget them in the background.
JSON_TAKEPIC_REQ=$(< <(cat <<EOF
{
  "name": "camera.takePicture",
  "parameters": {
    "sessionId": "SID_${SID}"
    }
}
EOF
))
	#echo $JSON_REQ
	JSON_FILE_REQ="null"
else
	echo "Using direct USB connection"
fi

# Set the image resolution

if [ "$RES" == h ]
then
  RES_WIDTH=5376
  RES_HEIGHT=2688
else
  RES_WIDTH=2048
  RES_HEIGHT=1024
fi

# exposure program mapping
#if [ "$MODE" -eq 1 ]
#then
#	USB_MODE="0x0001"
#elif [ "$MODE" -eq 2 ]
#then
#	USB_MODE="0x0002"
#elif [ "$MODE" -eq 4 ]
#then
#	USB_MODE="0x0004"
#elif [ "$MODE" -eq 9 ]
#then
#	USB_MODE="0x8003"
#fi

# JSON for wifi or else ptpcam for usb
if [ "$CONNECTION" == W ]
then

	if [ "$MODE" == 1 ]
	then

JSON_SET_REQ=$(< <(cat <<EOF
{
  "name": "camera.setOptions",
  "parameters": {
    "sessionId": "SID_${SID}",
    "options": {
	  "fileFormat": {
          "type": "jpeg",
		  "width": ${RES_WIDTH},
		  "height": ${RES_HEIGHT}
	  },  
	"exposureProgram": ${MODE},
	"iso": ${ISO},
	"whiteBalance":"${WHITE_B}",
	"shutterSpeed": ${SSPEED}
	}
  }
}
EOF
))
	else
JSON_SET_REQ=$(< <(cat <<EOF
{
  "name": "camera.setOptions",
  "parameters": {
    "sessionId": "SID_${SID}",
    "options": {
          "fileFormat": {
          "type": "jpeg",
                  "width": ${RES_WIDTH},
                  "height": ${RES_HEIGHT}
          },
        "exposureProgram": ${MODE}
        }
  }
}
EOF
))
	fi
	echo "Setting mode via WIFI"
	# make the actual request to the camera in wifi mode
	curl -s -X POST http://${CAMIP}:${PORT}/osc/commands/execute -d "${JSON_SET_REQ}"
	# debug
	echo "$JSON_SET_REQ"
else
	echo "Setting mode via USB"
	# set the mode
	ptpcam --set-property=0x500e --val=${MODE}
	# Set the resolution (imagesize)
	ptpcam --set-property=0x5003 --val="${RES_WIDTH}x${RES_HEIGHT}"	
	# set the iso if mode != 2 (auto)
	# Set the white balance if mode !=2 (auto)
	# Set the shutter speed if mode !=2 (auto) 
	if [ ${MODE} -ne 2 ]
       	then
		ptpcam --set-property=0x500F --val="${ISO}"
		ptpcam --set-property=0x5005 --val="${WHITE_B}"
		ss_convert
		ptpcam -R 0x1016,0xd00f,0,0,0,0,/dev/shm/ss_hex_tmp.bin
		#ptpcam --set-property=0xD00F --val="${SSPEED}"
	fi
fi


i=1
while [ $i -le "$ICOUNT" ]
do
    if [ "$METER" -eq 1 ]
    then
	echo "METER IS ON"

# This is the old section for the home made LUX sensor, I replace it with a real one
#	# This section based on http://www.raspberrypi-spy.co.uk/2012/08/reading-analogue-sensors-with-one-gpio-pin/
#	# Get epoch in miliseconds    
#	#METER_START=$(date +%s%3N)
#	METER_VALUE=0
#	METER_COUNT=0
#	# EXPORT the GPIO pin (this should have an if already exported skip)
#	if [ ! -f /sys/class/gpio/gpio${METER_GPIO}/value ]; then
#	        echo "${METER_GPIO}" > /sys/class/gpio/export
#   	fi
#	# Set to an output port to discharge capacitor
#	echo "out" > /sys/class/gpio/gpio${METER_GPIO}/direction
#	echo "0" > /sys/class/gpio/gpio${METER_GPIO}/value
#	# Charge the capacitor
#	echo "in" > /sys/class/gpio/gpio${METER_GPIO}/direction
#	while [ $METER_VALUE -eq 0 ]
#	do
#	#  sleep .01
#	  METER_VALUE=$(cat /sys/class/gpio/gpio${METER_GPIO}/value)
#         METER_COUNT=$(( $METER_COUNT + 1 ))
#      #  echo METER = $METER_COUNT
#
#	done
#	echo "out" > /sys/class/gpio/gpio${METER_GPIO}/direction
#
#	
#	SSPEED_COUNT=$(( $SSPEED_COUNT + 1 ))
#	echo SSPEED_COUNT = $SSPEED_COUNT

	RAW=$(${LUX_METER_SCRIPT}| cut -d " " -f1)
	LUX=$(${LUX_METER_SCRIPT}| cut -d " " -f2)
	echo "LUX IS ${LUX}"
	echo "RAW IS ${RAW}"

	# I need a bunch of if statments here to select a shutter speed based on the light
	# also some logic to make the ramp only go a single dirrection.
	# AKA if shutter speed is slower than the previous dont do it

	#
	# eventually this should actually step though shutter speed and ISO to give a
	# better gradient.
	#

	#
	# This calibration is based on my dock in the afternoon (which is in shade).
	# While the meter is shaded the sky is not. this is more of an ambient reading
	# instead of direct. at a reading of 2125 I used a shutter speed of 1/1600 @ iso 100.
	#
	# It should be noted that until I can figure out how to get decimals out of
	# LUX meter some of the longer exposures have been disabled :(
	#
	if [ "$LUX" -ge 8000 ]
	then
                SSPEED=0.00015625
                  ISO=100
        elif [ "$LUX" -ge 6250 ]
        then
                SSPEED=0.0002
                  ISO=100
        elif [ "$LUX" -ge 5000 ]
        then
                SSPEED=0.00025
                  ISO=100
        elif [ "$LUX" -ge 4000 ]
        then
                SSPEED=0.0003125
                  ISO=100
        elif [ "$LUX" -ge 3150 ]
        then
                SSPEED=0.0004
                  ISO=100
        elif [ "$LUX" -ge 2500 ]
        then
                SSPEED=0.0005
                  ISO=100
        elif [ "$LUX" -ge 2000 ]
        then
                SSPEED=0.000625
                  ISO=100
		  #DOCKNUM=2000
        elif [ "$LUX" -ge 1600 ]
        then
                SSPEED=0.0008
                  ISO=100
        elif [ "$LUX" -ge 1250 ]
        then
		SSPEED=0.001
                  ISO=100
	elif [ "$LUX" -ge 1000 ]
	then
		SSPEED=0.00125
                  ISO=100
                #DOCKNUM=1000
        elif [ "$LUX" -ge 825 ]
	then
                SSPEED=0.0015625
                  ISO=100
	 # 1/500 @ iso 100 = 1400 ish (1300-1500) shade. reading was only 800 when pointed away from light
        elif [ "$LUX" -ge 625 ]
	then
                SSPEED=0.002
                  ISO=100
        elif [ "$LUX" -ge 500 ]
	then
                SSPEED=0.0025
                  ISO=100
                #DOCKNUM=500
        elif [ "$LUX" -ge 405 ]
	then
                SSPEED=0.003125
                  ISO=100
	# 1/250th @iso 100 = 150 ish
        elif [ "$LUX" -ge 325 ]
	then
                SSPEED=0.004
                  ISO=100
          elif [ "$LUX" -ge 250 ]
          then
                  SSPEED=0.005
                  ISO=100
                #DOCKNUM=250
          elif [ "$LUX" -ge 184 ]
          then
                  SSPEED=0.00625
                  ISO=100
          elif [ "$LUX" -ge 125 ]
          then
		  # 1/125 @ iso 100 = LUX 115
                  SSPEED=0.008
                  ISO=100
          elif [ "$LUX" -ge 92 ]
          then
                  SSPEED=0.01
                  ISO=100
                #DOCKNUM=125
	## This should technically be the same as the above exposure
	## so we skip it
        #        SSPEED=0.005
	#	ISO=200
        elif [ "$LUX" -ge 82 ]
	then
                SSPEED=0.00625
		ISO=200
        elif [ "$LUX" -ge 72 ]
	then
                SSPEED=0.008
		ISO=200
        elif [ "$LUX" -ge 62 ]
	then
                SSPEED=0.01
		ISO=200
                #DOCKNUM=62
	# maybe 1/60 @ iso 100 = 25ish
        elif [ "$LUX" -ge 51 ]
	then
                SSPEED=0.0125
		ISO=200
        elif [ "$LUX" -ge 41 ]
	then
                SSPEED=0.01666666
		ISO=200
        elif [ "$LUX" -ge 31 ]
	then
                SSPEED=0.02
		ISO=200
                #DOCKNUM=31
        elif [ "$LUX" -ge 25 ]
	then
                SSPEED=0.025
		ISO=200
        elif [ "$LUX" -ge 20 ]
	then
                SSPEED=0.03333333
		ISO=200
		#
		# At this point LUX values alone do not provide enough resolution for shutter speed test. 
		# I will now use full spectrum raw reading
		#
		# Scale RAW valuse from here starting at 38 = 1/25th to 0 = 6sec.
		#

        elif [ "$RAW" -ge 38 ]
	then
                SSPEED=0.04
		ISO=200
                #DOCKNUM=15
        elif [ "$RAW" -ge 36 ]
	then
                SSPEED=0.05
		ISO=200
        elif [ "$RAW" -ge 34 ]
	then
                SSPEED=0.06666666
		ISO=200
        elif [ "$RAW" -ge 32 ]
	then
                SSPEED=0.07692307
		ISO=200
		#DOCKNUM=7
        elif [ "$RAW" -ge 30 ]
        then
                SSPEED=0.1
		ISO=200
        elif [ "$RAW" -ge 29 ]
        then
#		# 1/8th
                SSPEED=0.125
		ISO=200
        elif [ "$RAW" -ge 28 ]
        then
                SSPEED=0.16666666
		ISO=200
        elif [ "$RAW" -ge 26 ]
        then
                SSPEED=0.2
		ISO=200

        elif [ "$RAW" -ge 24 ]
          then
		#1/4
                  SSPEED=0.25
                  ISO=200
		# SSPEED=0.125
		# ISO=400

        elif [ "$RAW" -ge 22 ]
	then
                SSPEED=0.16666666
		ISO=400
        elif [ "$RAW" -ge 21 ]
	then
                SSPEED=0.2
		ISO=400
        elif [ "$RAW" -ge 14 ]
	then
		# iso 400 1/4 shutter speed at LUX reading of 12
                SSPEED=0.25
		ISO=400
        elif [ "$RAW" -ge 22 ]
	then
                SSPEED=0.33333333
		ISO=400
        elif [ "$RAW" -ge 20 ]
	then
                SSPEED=0.4
		ISO=400
        elif [ "$RAW" -ge 18 ]
	then
                SSPEED=0.5
		ISO=400
        elif [ "$RAW" -ge 16 ]
	then
                SSPEED=0.625
		ISO=400
        elif [ "$RAW" -ge 14 ]
	then
                SSPEED=0.76923076
		ISO=400
        elif [ "$RAW" -ge 12 ]
	then
                SSPEED=1
		ISO=400
        elif [ "$RAW" -ge 10 ]
	then
                SSPEED=1.3
		ISO=400
        elif [ "$RAW" -ge 8 ]
	then
                SSPEED=1.6
		ISO=400
        elif [ "$RAW" -ge 7 ]
	then
               SSPEED=2
		ISO=400
	elif [ "$RAW" -ge 5 ] 
	then
                SSPEED=2.5
		ISO=400
        elif [ "$RAW" -ge 4 ]
	then
               SSPEED=3.2
		ISO=400
        elif [ "$RAW" -ge 3 ]
	then
                # iso 400 4s shutter speed at LUX reading of 6
                SSPEED=4
		ISO=400
        elif [ "$RAW" -ge 1 ]
	then
                SSPEED=5
		ISO=400
	#
	# Zero should probably start around this point as 1st detection of light needs about
	# a 6 second exposure based on real world testing.
	# I may need to shift this threshold.
	#
	# Anything below zero will be based off time. This 0 point shold be aprox
	# 50 min befor sunrise or 50 min after sunset.
	# We should scale from here to 15sec over 30 min.
	else
	    CTIME=$(date +%s)
	    echo "Current time in epoch $CTIME"
	    if [ "$AM" -eq 1 ]
	    then
		    # Seconds = current epoch - sunrise
		    #AMPMSEC=$(($(date +%s) - $SUNRISE))
		    AMPMSEC=$(($SUNRISE - $CTIME))
		    echo "Sunrise mode set - $SUNRISE"
	    elif [ "$PM" -eq 1 ]
	    then
		    # Seconds = sunset - current epoch
		    #AMPMSEC=$(($SUNSET - $(date +%s)))
		    AMPMSEC=$(($CTIME - $SUNSET))
		    echo "Sunset mode set - $SUNSET"
	    fi

	    echo "AMPMSEC=$AMPMSEC"
	    # I should make this 3000 a variable and then add other variables to allow for 
	    # quick scaling
	    if [ "$AMPMSEC" -le "$AMPMDELAY" ]	
	    then
            	 SSPEED=6
		 ISO=400
	 elif [ "$AMPMSEC" -le $(($AMPMDELAY + $AMPMSCALE1)) ]
	    then
                SSPEED=8
		ISO=400
	elif [ "$AMPMSEC" -le $(($AMPMDELAY + $AMPMSCALE1 + $AMPMSCALE1)) ]
	    then
  	         SSPEED=10
	  	 ISO=400
	 elif [ "$AMPMSEC" -le $(($AMPMDELAY + $AMPMSCALE1 + $AMPMSCALE1 + $AMPMSCALE2)) ]
	    then
        	 SSPEED=13
	 	 ISO=400
    	    #elif [ "AMPMSEC" -le 4800 ]
	    #then
    	    else
                SSPEED=15
		ISO=400
	    fi
#        elif [ "$RAW" -ge 0 ]
#	then
#		SSPEED=20
#		ISO=400
#        elif [ "$RAW" -ge 128 ]
#        then
#                SSPEED=25
#        elif [ "$RAW" -ge 128 ]
#        then
#                SSPEED=30
#        elif [ "$RAW" -ge 128 ]
#        then
#                SSPEED=60
	fi

#	echo "METER COUNT = ${LUX}"

        # Check if shutter speed is set ramp and prevent from going the opposite direction

	#
	# I really need to sanity check this value in case i get a erronous one.
	# Maybe average the last 4 or something.
	#
          if [ "$i" -gt 1 ]
          then
		  echo "Checking for ramp"
                  # Ramp up
                  if [ "$RAMP" = u ]
                  then
		  echo "Ramp is set to up"
                          if [ $LUX -ge $LAST_LUX ]
                          then
                                  LUX=$LAST_LUX
				  SSPEED=$LAST_SSPEED
				  echo "Ramp Up, no change"
                          fi
                  #ramp down
                  elif [ "$RAMP" = d ]
                  then
	 	  echo "ramp is set to down"
		  echo $LAST_LUX
                          if [ $LUX -le $LAST_LUX ]
                          then
                                  LUX=$LAST_LUX
				  SSPEED=$LAST_SSPEED
				  echo "meter_count $LUX"
				  echo "Ramp Down, no change"
                          fi
                  fi
          fi
          LAST_LUX=$LUX
	  LAST_SSPEED=$SSPEED

    # Wait before setting the exposure and snapping a photo.
    # Note, you seem to get an error if you try to set the exposure while its still processing.
    sleep "${INTERVAL}"
    # set the new exposure


    if [ ${CONNECTION} == W ]
    then
	    # Set exposure from meter via wifi
JSON_METER_SET_REQ=$(< <(cat <<EOF
{
  "name": "camera.setOptions",
  "parameters": {
    "sessionId": "SID_${SID}",
    "options": {
          "fileFormat": {
          "type": "jpeg",
                  "width": ${RES_WIDTH},
                  "height": ${RES_HEIGHT}
          },
        "exposureProgram": ${MODE},
        "iso": ${ISO},
	"whiteBalance":"${WHITE_B}",
        "shutterSpeed": ${SSPEED}
        }
  }
}
EOF
))
    	echo ${JSON_METER_SET_REQ}
	# set the camera propertis via wifi
    	curl -s -X POST http://${CAMIP}:${PORT}/osc/commands/execute -d "${JSON_METER_SET_REQ}"
    	#echo "$JSON_METER_SET_REQ"
    else
	#set the camea properties via usb
        ptpcam --set-property=0x500e --val=${MODE}
        # Set the resolution (imagesize)
        ptpcam --set-property=0x5003 --val="${RES_WIDTH}x${RES_HEIGHT}"
        # set the iso 
        ptpcam --set-property=0x500F --val="${ISO}"
        # Set the white balance 
        ptpcam --set-property=0x5005 --val="${WHITE_B}"
        # Set the shutter speed 
	ss_convert
	ptpcam -R 0x1016,0xd00f,0,0,0,0,/dev/shm/ss_hex_tmp.bin
        #ptpcam --set-property=0xD00F --val="${SSPEED}"
    fi



    # If we set it to use a photo resistor circuiut "METER"  add time to the interval length accordingly. This prevents us from trying to take
    # the next picture durring an ongoing exposure, which causes an error.
    INTERVAL=$(echo $SSPEED + $ORIGINAL_INTERVAL | bc)
    echo "INTERVAL = ${INTERVAL}"


    #
    # Do something if were not metering here
    #
    else
      # Sleep here since we did it in the meter section.
      echo "Not using meter, sleeping now."
      sleep "${INTERVAL}"
      # This is where the meter section ends.
    fi
    #       curl -s -X POST http://${CAMIP}:${PORT}/osc/commands/execute -d "${JSON_FILE_REQ}" > ${5}${FILENAME} &
    echo $i
    date

    #
    # If GPS is enabled we shold set it on the camera prior to taking the picture.
    # Eventually I should have this watch the speed and if the camera is not moving only
    # set the location ever min or so as checking/setting could introduce latency.

    if [ $GPS -eq 1 ]
    then
	    echo "quering GPSD for location data."
	    # Get GPS info from gpsd and log it.

	    #
	    # use timeout to kill this off if it takes more then a couple seconds.
	    # this is useful because if the gps is not working we may wait forever.
	    #
	    #GPS_DATA=$(gpspipe -w -n 7 | grep -m1 TPV )
	    GPS_DATA=$(timeout 4 gpspipe -w -n 7 | grep -m1 TPV )
	    if [ $? -eq 0 ]
	    then
	    	GPS_DATA=$(echo "$GPS_DATA" | tee -a ${TRACKLOG} | sed s/\"//g | cut -d"," -f5,7,8,9)

		    GPS_DATE=$(echo "$GPS_DATA" | cut -d"," -f1 | cut -d":" -f2,3,4 | cut -d"T" -f1| sed s/\-/\:/g)
		    GPS_TIME=$(echo "$GPS_DATA" | cut -d"," -f1 | cut -d":" -f2,3,4 | cut -d"T" -f2 | cut -d"." -f1)
	    	    #GPS_TZ=$(echo "$GPS_DATA" | cut -d"," -f1 | cut -d":" -f2,3,4 | cut -d"T" -f2 | cut -d"." -f2)
	    	    GPS_LAT=$(echo "$GPS_DATA" | cut -d"," -f2 | cut -d":" -f2,3,4 | cut -d"T" -f2)
	    	    GPS_LON=$(echo "$GPS_DATA" | cut -d"," -f3 | cut -d":" -f2,3,4 | cut -d"T" -f2)
	    	    GPS_ALT=$(echo "$GPS_DATA" | cut -d"," -f4 | cut -d":" -f2,3,4 | cut -d"T" -f2)
	    	    # Write GPS info to the camera.


		        if [ ${CONNECTION} == W ]
		        then
JSON_GPS_SET_REQ=$(< <(cat <<EOF
{
  "name": "camera.setOptions",
  "parameters": {
    "sessionId": "SID_${SID}",
    "options": {
                  "gpsInfo": {
        	      "lat": ${GPS_LAT},
        	      "lng": ${GPS_LON},
        	      "_altitude": ${GPS_ALT},
        	      "_dateTimeZone":"${GPS_DATE} ${GPS_TIME}+00:00",
         	      "_datum":"WGS84"
    		  }
        }
  }
}
EOF
))
	   	    		# Set the gps values on the camera via wifi
		    		echo ${JSON_GPS_SET_REQ}
	   	    		curl -s -X POST -d "${JSON_GPS_SET_REQ}" http://${CAMIP}:${PORT}/osc/commands/execute >> /dev/null
		    	else
				# Set the gps via usb
				ptpcam --set-property=0xD801 --val="${GPS_LAT},${GPS_LON},${GPS_ALT}m@${GPS_DATE}${GPS_TIME}Z,WGS84"
			fi

	    else
		    echo "GPS enabled but now location found."
	    fi
    fi



    #echo "SSPEED = ${SSPEED}"
    ####
    #### This is where we take the actual picture
    ####
    if [ ${CONNECTION} == W ]
    then
	 # take picture over wifi
	 curl -s -X POST -d "${JSON_TAKEPIC_REQ}" http://${CAMIP}:${PORT}/osc/commands/execute >> /dev/null
    else
	 # take picture over usb
	 # ptp cam seemed to lock up the camera
	 #ptpcam -c
	 gphoto2 --capture-image
    fi

    # Decide if we are going to retrive and delete photos from the cam
    # this will vary greatly from wifi to USB
    #
 if [ ${CONNECTION} == W ]
 then
 # WIFI image retrival/deletion	 
    #curl -v -X POST http://${CAMIP}:${PORT}/osc/commands/execute -d '{"name": "camera.takePicture", "parameters": {"sessionId": "SID_$SID"}}'
    # Retrive the file name, but lets wait a couple iterations.
    if [ $i -eq 2 ]
    then
	  FILEPATH=$(curl -s -X POST http://${CAMIP}:${PORT}/osc/state | cut -d "\"" -f 26)
	  FILENAME=$(echo "$FILEPATH" | cut -d "/" -f2)
	  FILENUM=$(echo "$FILEPATH" | cut -d "/" -f2 | cut -d . -f1 | cut -d R -f2)
	  FILEEXT=$(echo "$FILEPATH" | cut -d . -f2)
	  # This needs some checking if its there
	  FILEDIR=$(echo "$FILEPATH" | cut -d "/" -f1)
	  echo "$FILEPATH"
	  echo "$FILENAME"
	  echo "$FILEDIR"
	  echo "$FILEEXT"
    fi
    
    if [ $i -ge 3 ]
    then
	  # If NEWFILEPATH was set last time around set OLDFILEPATH to its last value
	  # beforit increments up one
	  if [ -z ${NEWFILEPATH+x} ] 
	  then 
		  echo "No previous filename."
	  else 
		  OLDFILEPATH=${NEWFILEPATH}
	  fi

	  # do some addition
	  # remove any zero padding
	  FILENUM=$(echo "$FILENUM" | sed 's/^0*//')
	  FILENUM=$(( $FILENUM + 1 ))
	  # Add the zero padding back in
	  FILENUM=$(printf "%07d\n" $FILENUM)
	  echo "$FILENUM"
	  NEWFILEPATH=${FILEDIR}/R${FILENUM}.${FILEEXT}	 
	  echo "$NEWFILEPATH"
	  # download the image
	  JSON_FILE_REQ=$(< <(cat <<EOF
{
  "name": "camera.getImage",
  "parameters": {
    "fileUri": "${NEWFILEPATH}"
    }
}
EOF
))
	if [ $GETIMAGES -eq 1 ]
	then
		# This is where we download the image to the raspberry pi.
       		curl -s -X POST http://${CAMIP}:${PORT}/osc/commands/execute -d "${JSON_FILE_REQ}" > "${OUTPATH}"TL_${FILENUM}.${FILEEXT} &

		# Verify the last image we downloaded was not zero bytes.
		# This can happen for numerous reasons. If it is zero bytes
		# it doesent nescisarly mean were not takeing pictures so we will
		# not quit, but we should disable further downloads and deletion.

		if [ -s ${OUTPATH}TL_${FILENUM}.${FILEEXT} ]
		then
			echo "nothing to see here"
		else
			echo "Last file was zero bytes, disableing download/deletions."
			GETIMAGES=0
			DELIMG=0
		fi


		# Delete image if requested.
		if [ $DELIMG -eq 1 ]
		then
		        if [ -z ${OLDFILEPATH+x} ]
			then
				echo "Waiting for next round to delete files."
			else
				JSON_DELIMG_REQ=$(< <(cat <<EOF
{
  "name": "camera.delete",
  "parameters": {
    "fileUri": "${OLDFILEPATH}"
    }
}
EOF
))
				# This is where we delete the image from the camera
				# We will delete the previous image. It appears that deleting the current one
				# might delete it prior to us getting it fully downloaded.
				# this gets backgrounded just in case it adds time.
				echo "Deleting image ${OLDFILEPATH} from the camera!"
				curl -s -X POST -d "${JSON_DELIMG_REQ}" http://${CAMIP}:${PORT}/osc/commands/execute >> /dev/null &
			fi
		fi
	fi
       
    fi
  else
  # USB image retreval and deleteion
  # On the 1st pass get the last image name/hex ID
  if [ $i -eq 1 ]
  then
	  cd ${OUTPATH}
    	  FILEHEX=$(ptpcam -L | tail -n -2 | head -n 1 | cut -d ":" -f1)
    	  echo Current file HEX ID:${FILEHEX}
  fi
  # Increment hex id, in effort to not waste time will will calculate the id
  #if [ $i -ge 1 ]
  #then
  #  FILEHEX=$(printf "0x%08x\n" $(( ${FILEHEX} + 1 )))
  #fi

  # if $GETIMAGES -eq 1 then lets download the image
  if [ $GETIMAGES -eq 1 ]
  then
	  if [ $i -gt 1 ]
	  then
		echo "Retriving file: ${FILEHEX}"
	  	ptpcam --get-file=${FILEHEX}
 	  	if [ $DELIMG -eq 1 ]
          	then
	  		# if $DELIMG -eq 1 then lets delete the image
			echo "Deleting file: ${FILEHEX}"
    	  		ptpcam --delete-object=${FILEHEX}
		fi
  		# Increment hex id, in effort to not waste time will will calculate the id
  		FILEHEX=$(printf "0x%08x\n" $(( ${FILEHEX} + 1 )))
	  fi
	  
  fi
  fi

# Get the file
#	if [ $FILENAME0 != f ]
#	then
#    fi  

#	curl -s -X POST http://${CAMIP}:${PORT}/osc/commands/execute -d "${JSON_FILE_REQ}" > ${3}${FILENAME} &
  	i=$(( $i + 1 ))

done

#close session (only for wifi mode)
if [ ${CONNECTION} == W ]
  then
JSON_CLOSE_REQ=$(< <(cat <<EOF
{
  "name": "camera.closeSession",
  "parameters": {
    "sessionId": "SID_${SID}"
    }
}
EOF
))
	curl -s -X POST -d "${JSON_CLOSE_REQ}" http://${CAMIP}:${PORT}/osc/commands/execute >> /dev/null
fi

exit 0
