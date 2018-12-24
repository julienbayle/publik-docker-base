#!/usr/bin/env bash

# -------------------------------------------
# This script updates the whole system if a 
# Publik package in the list PUBLIK_PACKAGES
# has been updated by Entr'ouvert
#
# Logs are available in LOG_DIR
# 
# Author : Julien BAYLE
#
# -------------------------------------------

PUBLIK_PACKAGES="\s(authentic2-multitenant|combo|fargo|passerelle|hobo|wcs)\s"
PUBLIK_THEMES="https://github.com/departement-loire-atlantique/publik-themes"
set -e

if [ "$(id -u)" != "0" ]; then
   echo "ERROR - This script must be run as root" 1>&2
   exit 1
fi

# ------------------------------------------
# PUBLIK INSTALLATION DETECTION
# ------------------------------------------

PUBLIK_REPOSITORY=`cat /etc/apt/sources.list | grep "deb.entrouvert.org" | wc -l`
if [ $PUBLIK_REPOSITORY == "0" ]; then
        echo "ERROR - No any publik repository found in APT sources"
	exit 1
fi

IS_TESTING=`cat /etc/apt/sources.list | grep "deb.entrouvert.org/ jessie-testing" | wc -l`
if [ $IS_TESTING == "1" ]; then
	echo "INFO - Publik installation mode : Validation"
else
	echo "INFO - Publik installation mode : Production"
fi

# -----------------------------------------
# DOES THIS INSTALLATION NEED AN UPDATE ?
# -----------------------------------------

NOW=`date '+%Y-%m-%d_%H-%M-%S'`
LOG_DIR=/var/log/publik_updates
LOG_FILE=$LOG_DIR/$NOW
mkdir -p $LOG_DIR

function log {
	echo $1
	echo -e "\n----------------------------" >> $LOG_FILE
	echo -e $1 >> $LOG_FILE
	echo -e "----------------------------\n" >> $LOG_FILE	
}

echo "INFO - Execution details available in $LOG_FILE"

log "APT-GET UPDATE"
apt-get update >> $LOG_FILE 

log "GET CURRENT PACKAGES VERSION" 
dpkg -l | egrep -E $PUBLIK_PACKAGES >> $LOG_FILE

log "GET NEW PACKAGES VERSION"
apt-get --dry-run upgrade >> $LOG_FILE

NEEDUPDATE=`cat $LOG_FILE | egrep -E "Inst$PUBLIK_PACKAGES" | wc -l`
if [ $NEEDUPDATE -gt 0 ]; then
	if [ $IS_TESTING == "1" ]; then
		log "STOPPRING GRU..."
		/opt/cg/tools/bin/cg_start_gru.sh
		
		log "UPGRADING..."
		apt-get -y upgrade >> $LOG_FILE
		
		log "UPGRADE DONE, GRU IS RESTARTING..."
		/opt/cg/tools/bin/cg_start_gru.sh
		
		log "GRU IS UP"
	else
		#TODO : Production, test packages are validated
        	log "Production mode not implemented"
		exit 1	
	fi
 
else
	log "PACKAGES ARE UP TO DATE"
fi 

# -------------------------------------
# PATCHS
# -------------------------------------

# https://serverfault.com/questions/102324/apply-multiple-patch-files

# -------------------------------------
# THEME
# -------------------------------------

log "UPDATING THEME..."

if [ -d /tmp/publik-themes ]; then
	rm /tmp/publik-themes -Rf
fi

cd /tmp
git clone $PUBLIK_THEMES --recurse-submodules --depth=1 >> $LOG_FILE
cd publik-themes
make install >> $LOG_FILE
cd /tmp

log "THEME HAS BEEN UPDATED SUCCESSFULLY"

