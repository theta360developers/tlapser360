#!/bin/bash
#
# Test script to convert a decimal theata s shutter speed to raw hex for usb
#
# Usage: ./shutterspeed_to_hex.sh -s <shutter speed in decimal or whole number>
# Usage: ./shutterspeed_to_hex.sh -s 0.0025
#
OUTPUT_BIN=0

print_usage() {
	echo "Usage: $0 [-s shutter speed] [-b binfile (optional) ]"
}

if [ $# -lt 2 ]
then
	print_usage
	exit 1
fi

while getopts h?b:s: opt
do	case "$opt" in
	s)	SSPEED="$OPTARG";;
	b)	BINFILE="$OPTARG"
		OUTPUT_BIN="1";;
	h|\?)   print_usage	
		exit 1;;
	esac
done


ss_convert () {  
     if (( $(echo "${SSPEED} < 1" | bc -l) ))
     then
          # If the shutter speed is less than 1 we do it this way (looks something like 1/60)
          SSPEED_FRACTION=$(echo "1/${SSPEED}" | bc)
	  # Convert to a hex value and rearange it.
          SSPEED_HEX2=$(printf "%08x\n" ${SSPEED_FRACTION} | awk '{print substr ($0,7,2) substr ($0,5,2) substr ($0,3,2) substr ($0,1,2)}' | sed 's/.\{2\}/&\\x/g' | sed -e 's/^/\\x/' | awk '{print substr($0,1,length()-2)}')
          # The 1st hex intiger in this case is always a 1.
          SSPEED_HEX1="\x01\x00\x00\x00"
     elif [ $(echo ${SSPEED} | grep "\.") ]
     then
          # if its a decimal greater than 1 (1.3 or 1.6 looks something like 13/10)
	  #echo "Decimal found, greater than 1"
          # move the decimal
          SSPEED_SCALED=$(echo "scale=0; ${SSPEED}*10/1" | bc -l)
	  # Convert to a hex value and rearange it.
          SSPEED_HEX1=$(printf "%08x\n" ${SSPEED_SCALED} | awk '{print substr ($0,7,2) substr ($0,5,2) substr ($0,3,2) substr ($0,1,2)}' | sed 's/.\{2\}/&\\x/g' | sed -e 's/^/\\x/' | awk '{print substr($0,1,length()-2)}')
          # The 2nd hex intiger in this case is always a 10, or a
          SSPEED_HEX2="\x0a\x00\x00\x00"
     else
	  #echo "Greater then 1"
          # If its greater than one but not a decimal or something like this 30/1
	  # Convert to a hex value and rearange it.
          SSPEED_HEX1=$(printf "%08x\n" ${SSPEED} | awk '{print substr ($0,7,2) substr ($0,5,2) substr ($0,3,2) substr ($0,1,2)}' | sed 's/.\{2\}/&\\x/g' | sed -e 's/^/\\x/' | awk '{print substr($0,1,length()-2)}')
          # The 2nd hex intiger in this case is always a 1, or a
          SSPEED_HEX2="\x01\x00\x00\x00"
     fi
}

ss_convert

if [ $OUTPUT_BIN -eq 1 ]
then
    echo -e -n "${SSPEED_HEX1}${SSPEED_HEX2}" > ${BINFILE}
else
    echo "HEX Shutter speed: ${SSPEED_HEX1}${SSPEED_HEX2}"
fi
