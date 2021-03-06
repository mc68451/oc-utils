#!/bin/bash
#
# Copyright 2016, 2020 International Business Machines
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Usage: sudo oc-flash-script.sh <path-to-bin-file>

tool_version=2.31
# Changes History
# V2.0 code cleaning
# V2.1 reduce lines printed to screen (elasped times)
# V2.2 test if binary image is a capi2 image and correct printf error
# V2.3 adding 250SOC specific code
# V2.31 repaired the 4 bytes mode for 9H3

# get capi-utils root
[ -h $0 ] && package_root=`ls -l "$0" |sed -e 's|.*-> ||'` || package_root="$0"
package_root=$(dirname $package_root)
source $package_root/oc-utils-common.sh

printf "\n"
printf "===============================\n"
printf "== OpenCAPI programming tool ==\n"
printf "===============================\n"
echo oc-flash_script version is $tool_version
printf "Tool compiled on: "
ls -l $package_root/oc-flash|cut -d ' ' -f '6-8'

force=0
program=`basename "$0"`
card=-1

flash_address=""
flash_address2=""
flash_block_size=""
flash_type=""

reset_factory=0


# Print usage message helper function
function usage() {
  echo ""
  echo "Example: sudo ${program}  xxx_primary.bin xxx_secondary.bin"
  echo ""

  echo "Usage:  sudo ${program} [OPTIONS]"
  echo "    [-C <card>] card to flash."
  echo "    [-f] force execution without asking."
  echo "         warning: use with care e.g. for automation."
 # echo "    [-r] Reset adapter to factory before writing to flash."
  echo "    [-V] Print program version (${version})"
  echo "    [-h] Print this help message."
  echo "    <path-to-bin-file>"
  echo "    <path-to-secondary-bin-file> (Only for SPIx8 device)"
  echo
  echo "Utility to flash/write bitstreams to CAPI FPGA cards."
  echo "Please ensure that you are using the right bitstream data."
  echo "Using non-functional bitstream data or aborting the process"
  echo "can leave your card in a state where a hardware debugger is"
  echo "required to make the card usable again."
  echo
}

# Parse any options given on the command line
while getopts ":C:fVhr" opt; do
  case ${opt} in
      C)
      card=$OPTARG
      ;;
      f)
      force=1
      ;;
      r)
      printf "${bold}Warning:${normal} Factory/user reset option is unavailable in OC, ignoring -r option\n" >&2
      reset_factory=0
      ;;
      V)
      echo "${version}" >&2
      exit 0
      ;;
      h)
      usage;
      exit 0
      ;;
      \?)
      printf "${bold}ERROR:${normal} Invalid option: -${OPTARG}\n" >&2
      exit 1
      ;;
      :)
      printf "${bold}ERROR:${normal} Option -$OPTARG requires an argument.\n" >&2
      exit 1
      ;;
  esac
done

shift $((OPTIND-1))
# now do something with $@

ulimit -c unlimited

# make sure an input argument is provided
if [ $# -eq 0 ]; then
  printf "${bold}ERROR:${normal} Input argument missing\n"
  usage
  exit 1
fi

# make sure the input file exists
if [[ ! -e $1 ]]; then
  printf "${bold}ERROR:${normal} $1 not found\n"
  usage
  exit 1
fi

# check if OpenCAPI boards exists
capi_check=`ls /dev/ocxl 2>/dev/null | wc -l`
if [ $capi_check -eq 0 ]; then
  printf "${bold}ERROR:${normal} No OpenCAPI devices found\n"
  exit 1
fi

LockDir=/var/ocxl/oc-flash-script.lock

# make cxl dir if not present
mkdir -p `dirname $LockDir`

# mutual exclusion
if ! mkdir $LockDir 2>/dev/null; then
  echo
  printf "${bold}ERROR:${normal} Existing LOCK => Another instance of this script is maybe running\n"

  DateLastBoot=`who -b | awk '{print $3 " " $4}'`
  EpochLastBoot=`date -d "$DateLastBoot" +%s`

  EpochLockDir=`stat --format=%Y $LockDir`
  DateLockDir=`date --date @$EpochLockDir`

  echo
  echo "Last BOOT:              `date --date @$EpochLastBoot` ($EpochLastBoot)"
  echo "Last LOCK modification: $DateLockDir ($EpochLockDir)"

  echo;echo "======================================================="
  if [ $EpochLockDir -lt $EpochLastBoot ]; then
     echo "$LockDir modified BEFORE last boot"
     echo "LOCK is not supposed to still be here"
     echo "  ==> Deleting and recreating $LockDir"
     rmdir $LockDir
     mkdir $LockDir
  else
     echo "$LockDir modified AFTER last boot"
     printf "${bold}ERROR:${normal} Another instance of this script is running\n"
     echo "Exiting..."
     exit 1
  fi

fi
trap 'rm -rf "$LockDir"' EXIT

printf "\n"
# get number of cards in system
n=`ls /dev/ocxl 2>/dev/null | wc -l`
printf "In this server: $n OpenCAPI card(s) found."
# touch history files if not present
for i in `seq 0 $(($n - 1))`; do
  f="/var/ocxl/card$i"
  if [[ ! -f $f ]]; then
    touch $f
  fi
done

# print current date on server for comparison
printf "\n${bold}Current date is ${normal}$(date)\n\n"

# print table header
printf "Following logs show last programming files (except if hardware or capi version has changed):\n"
printf "${bold}%-20s %-30s %-29s %-20s %s${normal}\n" "#" "Card" "Flashed" "by" "Last Image"
# Find all OC cards in the system
allcards=`ls /dev/ocxl 2>/dev/null | awk -F"." '{ print $2 }' | sed s/$/.0/ | sort`
allcards_array=($allcards)

# print card information and flash history
i=0;
while read d ; do
  p[$i]=$(cat /sys/bus/pci/devices/${allcards_array[$i]}/subsystem_device)
  f=$(cat /var/ocxl/card$i)
  while IFS='' read -r line || [[ -n $line ]]; do
    if [[ ${line:0:6} == ${p[$i]:0:6} ]]; then
      parse_info=($line)
      board_vendor[$i]=${parse_info[1]}
      fpga_type[$i]=${parse_info[2]}
      flash_partition[$i]=${parse_info[3]}
      flash_block[$i]=${parse_info[4]}
      flash_interface[$i]=${parse_info[5]}
      flash_secondary[$i]=${parse_info[6]}
      printf "%-20s %-30s %-29s %-20s %s\n" "card$i:${allcards_array[$i]}" "${line:6:21}" "${f:0:29}" "${f:30:20}" "${f:51}"
      echo ""
    fi
  done < "$package_root/oc-devices"
  i=$[$i+1]
 done < <( lspci -d "1014":"062b" -s .1 )


printf "\n"
# card is set via parameter since it is positive
if (($card >= 0)); then
  c=$((10#$card))
  if (( "$c" >= "$n" )); then
    printf "${bold}ERROR:${normal} Wrong card number ${card}\n"
    exit 1
  fi
else
# prompt card to flash to
  while true; do
    read -p "Which card do you want to flash? [0-$(($n - 1))] " c
    if ! [[ $c =~ ^[0-9]+$ ]]; then
      printf "${bold}ERROR:${normal} Invalid input\n"
    else
      c=$((10#$c))
      if (( "$c" >= "$n" )); then
        printf "${bold}ERROR:${normal} Wrong card number\n"
        exit 1
      else
        break
      fi
    fi
  done
fi

printf "\n"

# check file type
FILE_EXT=${1##*.}
if [[ ${fpga_type[$c]} == "Altera" ]]; then
  if [[ $FILE_EXT != "rbf" ]]; then
    printf "${bold}ERROR: ${normal}Wrong file extension: .rbf must be used for boards with Altera FPGA\n"
    exit 0
  fi
elif [[ ${fpga_type[$c]} == "Xilinx" ]]; then
  if [[ $FILE_EXT != "bin" ]]; then
    printf "${bold}ERROR: ${normal}Wrong file extension: .bin must be used for boards with Xilinx FPGA\n"
    exit 0
  fi
else 
  printf "${bold}ERROR: ${normal}Card not listed in oc-devices or previous card failed or is not responding\n"
  exit 0
fi

# get flash address and block size
if [ -z "$flash_address" ]; then
  flash_address=${flash_partition[$c]}
  if [[ $1 =~ "fw_" ]]
  then
     printf "===================================================================================\n"
     echo "NOTE : You are in the process of programming a CAPI2 image in FACTORY area!"
     echo "       A reboot or power cycle will be needed to re-enumerate the cards."
     echo "       You may need to then switch your card back to USER area (capi-reset <card_nb> user)"
     printf "===================================================================================\n"
  fi
fi
if [ -z "$flash_block_size" ]; then
  flash_block_size=${flash_block[$c]}
fi
if [ -z "$flash_type" ]; then
  flash_type=${flash_interface[$c]}
fi
if [ -z "$flash_type" ]; then
  flash_type="BPIx16" #If it is not listed in oc-device file, use default value
fi

# Deal with the second argument
if [ $flash_type == "SPIx8" ]; then
    if [ $# -eq 1 ]; then
      printf "${bold}ERROR:${normal} Input argument missing. The selected device is SPIx8 and needs both primary and secondary bin files\n"
      usage
      exit 1
    fi
    #Check the second file
    if [[ ! -e $2 ]]; then
      printf "${bold}ERROR:${normal} $2 not found\n"
      usage
      exit 1
    fi
    #Assign secondary address
    flash_address2=${flash_secondary[$c]}
    if [ -z "$flash_address2" ]; then
        printf "${bold}ERROR:${normal} The second address must be assigned in file oc-device\n"
        exit 1
    fi
fi


# card is set via parameter since it is positive
if (($force != 1)); then
  # prompt to confirm
  while true; do
    printf "REMINDER: It is MANDATORY to CLOSE all JTAG tools (SDK, hardware_manager) before starting programming.\n" 
    printf "You will flash ${bold}card$c${normal} with:\n     ${bold}$1${normal}\n" 
    if [ $flash_type == "SPIx8" ]; then
        printf " and ${bold}$2${normal}\n" 
    fi
    read -p "Do you want to continue? [y/n] " yn
    case $yn in
      [Yy]* ) break;;
      [Nn]* ) exit;;
      * ) printf "${bold}ERROR:${normal} Please answer with y or n\n";;
    esac
  done
else
  printf "Continue to flash ${bold}$1${normal} ";
  if [ $flash_type == "SPIx8" ]; then
    printf "and ${bold}$2${normal} " 
  fi
  printf "to ${bold}card$c${normal}\n"
fi

printf "\n"

# update flash history file
if [ $flash_type == "SPIx8" ]; then
  printf "%-29s %-20s %s %s\n" "$(date)" "$(logname)" $1 $2 > /var/ocxl/card$c
else
  printf "%-29s %-20s %s\n" "$(date)" "$(logname)" $1 > /var/ocxl/card$c
fi
# Check if lowlevel flash utility is existing and executable
if [ ! -x $package_root/oc-flash ]; then
  printf "${bold}ERROR:${normal} Utility capi-flash not found!\n"
  exit 1
fi

# Reset to card/flash registers to known state (factory) 
if [ "$reset_factory" -eq 1 ]; then
  oc-reset $c factory "Preparing card for flashing"
fi

trap 'kill -TERM $PID; perst_factory $c' TERM INT
# flash card with corresponding binary
bdf=`echo ${allcards_array[$c]}`
#echo $bdf
if [ $flash_type == "SPIx8" ]; then
# SPIx8 needs two file inputs (primary/secondary)
#  $package_root/oc-flash --type $flash_type --file $1 --file2 $2   --card ${allcards_array[$c]} --address $flash_address --address2 $flash_address2 --blocksize $flash_block_size &
# until multiboot is enabled, force writing to 0x0
   $package_root/oc-flash --image_file1 $1 --image_file2 $2   --devicebdf $bdf --startaddr 0x0 
else
  $package_root/oc-flash  --image_file1 $1 --devicebdf $bdf --startaddr 0x0
fi

PID=$!
wait $PID
trap - TERM INT
wait $PID
RC=$?
if [ $RC -eq 0 ]; then
#  reload card only if Flashing was good, TBD
  printf "Auto reload the image from flash:\n"
  #./oc-reload.sh -C ${allcards_array[$c]}
  source $package_root/oc-reload.sh -C ${allcards_array[$c]}
fi
