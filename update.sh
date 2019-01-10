#!/usr/bin/env bash

# -------------------------------------------
# This script updates the whole system if a 
# Publik package in the list PUBLIK_PACKAGES
# has been updated by Entr'ouvert
#
# It also applies patches and deploys 
# local thme
#
# Logs are available in LOG_DIR
# 
# Author : Julien BAYLE
#
# -------------------------------------------

set -eu

# ------------------------------------------
# CONFIGURATION
# ------------------------------------------

PUBLIK_PACKAGES="\s(authentic2-multitenant|combo|fargo|passerelle|hobo|wcs)\s"
PUBLIK_THEMES_GIT="https://github.com/departement-loire-atlantique/publik-themes"
PUBLIK_PYTHON_MODULES="/usr/lib/python2.7/dist-packages"
PUBLIK_PATCHES_GIT="https://github.com/departement-loire-atlantique/publik"
PUBLIK_PATCHES_DIR="/root/publik-patches"
PUBLIK_APT_PREFERENCES_GIT="https://raw.githubusercontent.com/departement-loire-atlantique/publik-docker-base/master/"
PUBLIK_APT_PREFERENCES_FILE="publik-prod-apt-preferences"
LOG_DIR=/var/log/publik_updates
NOW=`date '+%Y-%m-%d_%H-%M-%S'`

# ------------------------------------------
# ARGUMENT PARSING
# ------------------------------------------

PARAMS=""
DO_LOG=""
DO_THEME=""
DO_PATCH=""
DO_APT=""
DO_PREF=""
DO_RESTART_GRU=""

while (( "$#" )); do
  case "$1" in
    -t|--update-theme)
      DO_LOG="1"
      DO_THEME="1"
      shift
      ;;
    -s|--update-packages)
      DO_LOG="1"
      DO_APT="1"
      shift
      ;;
    -p|--patch)
      DO_LOG="1"
      DO_PATCH="1"
      shift
      ;;
    -g|--generate-apt-preferences)
      DO_PREF="1"
      shift
      ;;
    -a|--all)
      DO_LOG="1"
      DO_THEME="1"
      DO_APT="1"
      DO_PATCH="1"
      shift
      ;;
    --) # end argument parsing
      shift
      break
      ;;
    -*|--*=) # unsupported flags
      echo "ERROR - Unsupported flag $1" >&2
      exit 1
      ;;
    *) # preserve positional arguments
      PARAMS="$PARAMS $1"
      shift
      ;;
  esac
done

if [ -z "$DO_THEME$DO_APT$DO_PATCH$DO_PREF" ]; then
	echo "ERROR - Nothing to do. Please use --update-theme, --generate-apt-preferences, --update-packages, --patch or --all"
	exit 1
fi

# ------------------------------------------
# ROOT PRIVILEGES TEST
# ------------------------------------------

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

# ------------------------------------------
# INIT LOGS
# ------------------------------------------

if [ "$DO_LOG" == "1" ]; then

	LOG_FILE=$LOG_DIR/$NOW
	mkdir -p $LOG_DIR

	echo "INFO - Execution details available in $LOG_FILE"

fi

# -----------------------------------------
# FUNCTIONS
# -----------------------------------------

function log {
	echo $1
	echo -e "\n----------------------------" >> $LOG_FILE
	echo -e $1 >> $LOG_FILE
	echo -e "----------------------------\n" >> $LOG_FILE	
}

function error_report {
	echo "ERROR - Process failed at line $1. Details in $LOG_FILE"
}

trap 'error_report $LINENO' ERR

# -----------------------------------------
# DOES THIS INSTALLATION NEED AN UPDATE ?
# -----------------------------------------

if [ "$DO_APT" == "1" ]; then

	IS_TESTING=`cat /etc/apt/sources.list | grep "deb.entrouvert.org/ jessie-testing" | wc -l`
	if [ $IS_TESTING == "1" ]; then
		log "INFO - Publik installation mode : Validation"
	else
		log "INFO - Publik installation mode : Production"
		log "UPDATE APT PREFERENCES"
		cd /etc/apt/preferences.d/
		if [ -f $PUBLIK_APT_PREFERENCES_FILE ]; then
			rm $PUBLIK_APT_PREFERENCES_FILE 
		fi
		wget -qO- "$PUBLIK_APT_PREFERENCES_GIT$PUBLIK_APT_PREFERENCES_FILE" >> $PUBLIK_APT_PREFERENCES_FILE 		
	fi

	log "APT-GET UPDATE"
	apt-get update >> $LOG_FILE 

	log "GET CURRENT PACKAGES VERSION" 
	dpkg -l | egrep -E $PUBLIK_PACKAGES >> $LOG_FILE

	log "GET NEW PACKAGES VERSION"
	apt-get --dry-run upgrade >> $LOG_FILE

	NEEDUPDATE=`cat $LOG_FILE | egrep -E "Inst$PUBLIK_PACKAGES" | wc -l`
	if [ $NEEDUPDATE -gt 0 ]; then
	
		# Beware : All publik services must be up during the update process
		log "UN-PATCH BEFORE UPDATE"
		cd $PUBLIK_PYTHON_MODULES
		quilt pop -a >> $LOG_FILE
	
		log "UPGRADING..."
		apt-get -y upgrade >> $LOG_FILE
		
		log "UPGRADE DONE"
		DO_RESTART_GRU="1"
		DO_PATCH="1"
	else
		log "PACKAGES ARE UP TO DATE"
	fi 
fi

# -------------------------------------
# PATCHS
# -------------------------------------

if [ "$DO_PATCH" == "1" ]; then

	log "DOWNLOAD PATCHES FROM REPOSITORY"

	if [ -d $PUBLIK_PATCHES_DIR ]; then
		cd $PUBLIK_PATCHES_DIR
		git config core.sparseCheckout true
		git fetch --all >> $LOG_FILE
		git reset --hard origin/master >> $LOG_FILE

	else
		mkdir $PUBLIK_PATCHES_DIR
		cd $PUBLIK_PATCHES_DIR
		git init >> $LOG_FILE
		git remote add -f origin $PUBLIK_PATCHES_GIT >> $LOG_FILE
		git config core.sparseCheckout true 
		echo "patches/" >> .git/info/sparse-checkout
		git pull origin master >> $LOG_FILE
	fi

	log "LINK WITH PYTHON PACKAGE MODULE"

	if [ ! -d "$PUBLIK_PYTHON_MODULES/patches" ]; then
		ln -s $PUBLIK_PATCHES_DIR/patches $PUBLIK_PYTHON_MODULES/patches
	fi

	log "APPLYING PATCHES..."

	cd $PUBLIK_PYTHON_MODULES
	patch=`quilt next` || true
	while [ -n "$patch" ]; do
		# Only apply patch if module is installed
		patch_app=`echo "$patch" | awk -F'[+]' '{print $1}' | cut -c9- `
		if [ -d $patch_app ]; then
			log " - Apply patch $patch into python module $patch_app"
			quilt push >> $LOG_FILE
			find $patch_app -type f -name "*.pyc" -exec rm {} \;
			python2.7 -m compileall $patch_app >> $LOG_FILE
		else
			log " - Unable to apply patch $patch, module $patch_app not found. Skipping."
			quilt delete $patch >> $LOG_FILE
		fi
		patch=`quilt next` || true
	done

	log "PATCHES APPLIED"
	DO_RESTART_GRU="1"
fi

# -------------------------------------
# THEME
# -------------------------------------

if [ "$DO_THEME" == "1" ]; then

	log "UPDATING THEME..."

	if [ -d /tmp/publik-themes ]; then
		rm /tmp/publik-themes -Rf
	fi

	cd /tmp
	git clone $PUBLIK_THEMES_GIT --recurse-submodules --depth=1 >> $LOG_FILE
	cd publik-themes
	make install >> $LOG_FILE

	log "THEME HAS BEEN UPDATED SUCCESSFULLY"
fi
			
# -------------------------------------
# APT PREFERENCES
# -------------------------------------

if [ "$DO_PREF" == "1" ]; then
	
	echo "# Generated on $NOW"
	echo "" 

	dpkg-query -W | while read line
	do
   		# generate apt preferences
		paquet=`echo "$line" | cut -f1`
		version=`echo "$line" | cut -f2`
		echo "Package: $paquet"
		echo "Pin: version $version"
		echo "Pin-Priority: 999"
		echo ""
	done
fi
			
# -------------------------------------
# RESTART
# -------------------------------------

if [ "$DO_RESTART_GRU" == "1" ]; then
	
	log "STOPPING GRU..."
	/opt/cg/tools/bin/cg_stop_gru.sh >> $LOG_FILE
		
	log "DONE, GRU IS RESTARTING..."
	/opt/cg/tools/bin/cg_start_gru.sh >> $LOG_FILE
		
	log "GRU IS UP"
fi
