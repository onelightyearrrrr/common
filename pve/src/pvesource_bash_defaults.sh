#!/usr/bin/env bash
# ----------------------------------------------------------------------------------
# Filename:     pvesource_bash_defaults.sh
# Description:  Source script bash defaults
# ----------------------------------------------------------------------------------

#---- Source -----------------------------------------------------------------------
#---- Dependencies -----------------------------------------------------------------

# Proxmox Version Check
if command -v pveversion -v &> /dev/null; then
  CurrV="$(pveversion -v | grep '^proxmox-ve:.*' | sed -ne 's/[^0-9]*\(\([0-9]\.\)\{0,4\}[0-9]\).*/\1/p')"
  MinV="7.0"
  if [ "$(printf '%s\n' "$MinV" "$CurrV" | sort -V | head -n1)" != "$MinV" ]; then 
    echo "Proxmox version is not supported. Update Proxmox to version ${MinV} or later.\nBye..."
    exit 0
  fi
fi

#---- Static Variables -------------------------------------------------------------

# Regex for functions
ip4_regex='^(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
ip6_regex='^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$'
hostname_regex='^(([a-z0-9]|[a-z0-9][a-z0-9\-]*[a-z0-9])\.)*([a-z0-9]|[a-z0-9][a-z0-9\-]*[a-z0-9])$'
domain_regex='^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9]\.[a-zA-Z]{2,}$'
R_NUM='^[0-9]+$' # Check numerals only

#---- Other Variables --------------------------------------------------------------
#---- Other Files ------------------------------------------------------------------
#---- Body -------------------------------------------------------------------------

set -Eeuo pipefail
shopt -s expand_aliases
alias die='EXIT=$? LINE=$LINENO error_exit'
trap die ERR

function error_exit() {
  trap - ERR
  local DEFAULT='Unknown failure occurred.'
  local REASON="\e[97m${1:-$DEFAULT}\e[39m"
  local FLAG="\e[91m[ERROR] \e[93m$EXIT@$LINE"
  msg "$FLAG $REASON"
  [ ! -z ${CTID-} ] && cleanup_failed
  cleanup
  exit $EXIT
}
function ct_error_return() {
  [ ! -z ${CTID-} ] && cleanup_failed
  cleanup
  return
}
function cleanup_failed () {
  if [ ! -z ${MOUNT+x} ]
  then
    pct unmount $CTID
  fi
  if $(pct status $CTID &> /dev/null); then
    if [ "$(pct status $CTID | awk '{print $2}')" = 'running' ]
    then
      pct stop $CTID
    fi
    pct destroy $CTID
  elif [ "$(pvesm list $STORAGE --vmid $CTID)" != "" ]
  then
    pvesm free $ROOTFS
  fi
}
function pushd () {
  command pushd "$@" &> /dev/null
}
function popd () {
  command popd "$@" &> /dev/null
}
function cleanup() {
  popd
  rm -rf $TEMP_DIR &> /dev/null
  unset TEMP_DIR
  # rm -R /tmp/*
}
function load_module() {
  if ! $(lsmod | grep -Fq $1); then
    modprobe $1 &> /dev/null || \
      die "Failed to load '$1' module."
  fi
  MODULES_PATH=/etc/modules
  if ! $(grep -Fxq "$1" $MODULES_PATH); then
    echo "$1" >> $MODULES_PATH || \
      die "Failed to add '$1' module to load at boot."
  fi
}
# Installer cleanup
function installer_cleanup() {
rm -R $REPO_TEMP/$GIT_REPO &> /dev/null
if [ -f "$REPO_TEMP/${GIT_REPO}.tar.gz" ]
then
  rm $REPO_TEMP/${GIT_REPO}.tar.gz > /dev/null
fi
}

#---- User and Password Functions
# Make a USERNAME with validation
function input_username_val() {
  while true
  do
    read -p "Enter a new user name : " USERNAME < /dev/tty
    if [ ${#USERNAME} -gt 18 ]
    then
    msg "User name ${WHITE}'$USERNAME'${NC} is not valid. A user name is considered valid when all of the following constraints are satisfied:\n\n  --  it contains only lowercase characters\n  --  it begins with 3 alphabet characters\n  --  it contains at least 5 characters and at most is 18 characters long\n  --  it may include numerics and underscores\n  --  it doesn't contain any hyphens, periods or special characters [!#$&%*+-]\n  --  it doesn't contain any white space\n\nTry again...\n"
    elif [[ "$USERNAME" =~ ^([a-z]{3})([_]?[a-z\d]){2,15}$ ]]
    then
      info "Your user name is set : ${YELLOW}$USERNAME${NC}"
      echo
      break
    else
      msg "User name ${WHITE}'$USERNAME'${NC} is not valid. A user name is considered valid when all of the following constraints are satisfied:\n\n  --  it contains only lowercase characters\n  --  it begins with 3 alphabet characters\n  --  it contains at least 5 characters and at most is 18 characters long\n  --  it may include numerics and underscores\n  --  it doesn't contain any hyphens, periods or special characters [!#$&%*+-]\n  --  it doesn't contain any white space\n\nTry again...\n"
    fi
  done
}

# Input a user Email Address with validation.
function input_emailaddress_val() {
  while true
  do
    read -p "Enter a valid email address for the user: " EMAIL_VAR < /dev/tty
    USER_EMAIL=$(echo "$EMAIL_VAR" | sed 's/\s//g')
    i=$(echo "$EMAIL_VAR" | sed 's/\s//g')
    IFS="@"
    set -- $i
    msg "Validating email..."
    if [ "${#@}" -ne 2 ]
    then
      warn "Your email address '$USER_EMAIL' was rejected. Possible non-conforming input. Try again..."
    else
      # Check domain
      domain="$2"
      dig $domain | grep "ANSWER: 0" 1>/dev/null && domain_check=0
      if [ "${domain_check}" = 0 ]
      then
        warn "Your email address '$USER_EMAIL' was rejected. Email domain $domain check failed. Try again..."
      else
        info "User email is set is set : ${YELLOW}${USER_EMAIL}${NC}"
        echo
        break
      fi
    fi
  done
}

# Input a USER_PWD with validation. Requires libcrack2
function input_userpwd_val() {
  # Install libcrack2
  if [[ ! $(dpkg -s libcrack2 2>/dev/null) ]]
  then
  apt-get install -y libcrack2 > /dev/null
  fi
  while true
  do
    read -p "Enter a password for $USERNAME: " USER_PWD < /dev/tty
    msg "Testing password strength..."
    result="$(cracklib-check <<<"$USER_PWD")"
    # okay awk is  bad choice but this is a demo 
    okay="$(awk -F': ' '{ print $2}' <<<"$result")"
    if [[ "$okay" == "OK" ]]
    then
      info "Your password is set : ${YELLOW}$USER_PWD${NC}"
      echo
      break
    else
      warn "Your password was rejected - $result. Try again..."
      echo
    fi
  done
}

# Make a USER_PWD. Requires makepasswd
function make_userpwd() {
  # Install makepasswd
  if [[ ! $(dpkg -s makepasswd 2>/dev/null) ]]
  then
    apt-get install -y makepasswd > /dev/null
  fi
  msg "Creating a 13 character password..."
  USER_PWD=$(makepasswd --chars 13)
  info "Your password is set : ${YELLOW}$USER_PWD${NC}"
  echo
}

# PCT start and wait loop command
function pct_start_waitloop() {
  if [ "$(pct status $CTID)" = 'status: stopped' ]
  then
    msg "Starting CT $CTID..."
    pct start $CTID
    msg "Waiting to hear from CT ${CTID}..."
    while ! [[ "$(pct status $CTID)" == "status: running" ]]
    do
      echo -n .
    done
    sleep 2
    info "CT $CTID status: ${GREEN}running${NC}"
    echo
  fi
}

# PCT stop and wait loop command
function pct_stop_waitloop() {
  if [ "$(pct status ${CTID})" = 'status: running' ]
  then
    msg "Stopping CT $CTID..."
    pct stop $CTID
    msg "Waiting to hear from CT $CTID..."
    while ! [[ "$(pct status $CTID)" == "status: stopped" ]]
    do
      echo -n .
    done
    sleep 2
    info "CT $CTID status: ${GREEN}stopped${NC}"
    echo
  fi
}

# PCT list
function pct_list() {
  pct list | perl -lne '
  if ($. == 1) {
      @head = ( /(\S+\s*)/g );
      pop @head;
      $patt = "^";
      $patt .= "(.{" . length($_) . "})" for @head;
      $patt .= "(.*)\$";
  }
  print join ",", map {s/"/""/g; s/\s+$//; qq($_)} (/$patt/o);'
}

# QM list
function qm_list() {
  pct list | awk 'BEGIN{OFS=","} {print $1,$3,$2}'
}


#---- Systemd functions
# Stop System.d Services
function pct_stop_systemctl() {
  # Usage: pct_stop_systemctl "name.service"
  local service_name="$1"
  if [ "$(systemctl is-active $service_name)" = 'active' ]
  then
    # Stop service
    sudo systemctl stop $service_name
    # Waiting to hear from service
    while ! [[ "$(systemctl is-active $service_name)" == 'inactive' ]]
    do
      echo -n .
    done
  fi
}

# Start System.d Services
function pct_start_systemctl() {
  # Usage: pct_start_systemctl "jellyfin.service"
  local service_name="$1"
  # Reload systemd manager configuration
  sudo systemctl daemon-reload
  if [ "$(systemctl is-active $service_name)" = 'inactive' ]
  then
    # Start service
    sudo systemctl start $service_name
    # Waiting to hear from service
    while ! [[ "$(systemctl is-active $service_name)" == 'active' ]]
    do
      echo -n .
    done
  fi
}

# Start System.d Services
function pct_restart_systemctl() {
  # Usage: pct_restart_systemctl "jellyfin.service"
  local service_name="$1"
  # Reload systemd manager configuration
  sudo systemctl daemon-reload
  if [ "$(systemctl is-active $service_name)" = 'inactive' ]
  then
    # Start service
    sudo systemctl start $service_name
    # Waiting to hear from service
    while ! [[ "$(systemctl is-active $service_name)" == 'active' ]]
    do
      echo -n .
    done
  elif [ "$(systemctl is-active $service_name)" = 'active' ]
  then
    # Stop service
    sudo systemctl stop $service_name
    # Waiting to hear from service
    while ! [[ "$(systemctl is-active $service_name)" == 'inactive' ]]
    do
      echo -n .
    done
    # Start service
    sudo systemctl start $service_name
    # Waiting to hear from service
    while ! [[ "$(systemctl is-active $service_name)" == 'active' ]]
    do
      echo -n .
    done
  fi
}


#---- SW Systemctl checks
# Check Install CT SW status (active or abort script)
function pct_check_systemctl() {
  # Usage: check_systemctl_sw "jellyfin.service"
  local service_name="$1"
  msg "Checking '${service_name}' service status..."
  FAIL_MSG='Systemctl '${service_name}' has failed. Reason unknown.\nExiting installation script in 2 second.'
  i=0
  while true
  do
    if [ $(pct exec $CTID -- systemctl is-active ${service_name}) = 'active' ]
    then
      info "Systemctl '${service_name}' status: ${YELLOW}active${NC}"
      echo
      break
    elif [ ! $(pct exec $CTID -- systemctl is-active ${service_name}) = 'active' ] && [ "$i" = 5 ]
    then
      warn "$FAIL_MSG"
      echo
      trap error_exit EXIT
    fi
    ((i=i+1))
    sleep 1
  done
}


#---- USB reset
function usb_reset(){
  base="/sys/bus/pci/drivers"
  sleep_secs="1"

  # This might find a sub-set of these:
  # * 'ohci_hcd' - USB 3.0
  # * 'ehci-pci' - USB 2.0
  # * 'xhci_hcd' - USB 3.0

  # Looking for USB standards
  for usb_std in "$base/"?hci[-_]?c*
  do
    for dev_path in "$usb_std/"*:*
    do
        dev="$(basename "$dev_path")"
        printf '%s' "$dev" | tee "$usb_std/unbind" > /dev/null
        sleep "$sleep_secs"
        printf '%s' "$dev" | tee "$usb_std/bind" > /dev/null
    done
  done
}

#---- Folder name functions
# Make a folder name with validation
function input_dirname_val() {
  while true; do
    read -p "Enter a new folder name : " DIR_NAME < /dev/tty
    DIR_NAME=${DIR_NAME,,}
    if [[ "${DIR_NAME}" =~ ^([a-z])([_]?[a-z\d]){3,15}$ ]]
    then
      info "Your user name is set : ${YELLOW}$DIR_NAME${NC}"
      echo
      break
    else
      msg "The folder name ${WHITE}'$DIR_NAME'${NC} is not valid. A folder name is considered valid when all of the following constraints are satisfied:\n\n  --  it contains only lowercase characters\n  --  it contains at least 3 characters and at most is 12 characters long\n  --  it may include underscores\n  --  it doesn't start or end with a underscore\n  --  it doesn't contain any numerics or special characters [!#$&%*+-]\n  --  it doesn't contain any white space\n\nTry again..."
    fi
  done
}

#---- Menu item select functions
function makeselect_input1 () {
  # Example:
  # Use with two input cmd vars: makeselect_input1 "$OPTIONS_VALUES_INPUT" "$OPTIONS_LABELS_INPUT"
  # "$OPTIONS_VALUES_INPUT" "$OPTIONS_LABELS_INPUT" are two lists of input variables of equal number of lines.
  # "$OPTIONS_VALUES_INPUT" is the actual source vars ( OPTIONS_VALUES_INPUT=$(cat usb_disklist) )
  # "$OPTIONS_LABELS_INPUT" is a readable label input seen by the User ( OPTIONS_VALUES_INPUT=$(cat usb_disklist | awk -F':' '{ print "Disk ID:", $1, "Disk Size:"", $2 })' )
  # Works with Functions 'multiselect' and 'singleselect' and 'multiselect_confirm'
  mapfile -t OPTIONS_VALUES <<< "$1"
  mapfile -t OPTIONS_LABELS <<< "$2"
  unset OPTIONS_STRING
  unset RESULTS && unset results
  for i in "${!OPTIONS_VALUES[@]}"; do
    OPTIONS_STRING+="${OPTIONS_LABELS[$i]};"
  done
}
function makeselect_input2 () {
    # Example:
    # OPTIONS_VALUES_INPUT=( "TYPE01" "TYPE02" "TYPE03" )
    # OPTIONS_LABELS_INPUT=( "Destroy & Rebuild" "Use Existing" "None. Try again" )
    # Both input must be a array string
    # Use cmd: makeselect_input2
    unset OPTIONS_STRING
    unset RESULTS && unset results
    unset OPTIONS_VALUES
    unset OPTIONS_LABELS
    OPTIONS_VALUES+=("${OPTIONS_VALUES_INPUT[@]}")
    OPTIONS_LABELS+=("${OPTIONS_LABELS_INPUT[@]}")
    for i in "${!OPTIONS_VALUES[@]}"; do
        OPTIONS_STRING+="${OPTIONS_LABELS[$i]};"
    done
}
# Multiple item selection
function multiselect () {
  # Modded version of this persons work: https://stackoverflow.com/a/54261882/317605 (by https://stackoverflow.com/users/8207842/dols3m)
  # To run: multiselect SELECTED "$OPTIONS_STRING"
  # To get output results: printf '%s\n' "${RESULTS[@]}"
  echo -e "Select menu items (multiple) with 'arrow keys \U2191\U2193', 'space bar' to select or deselect, and confirm/done with 'Enter key'. You can select multiple menu items or nothing. Your options are:" | fmt -s -w 80
  ESC=$( printf "\033")
  cursor_blink_on()   { printf "$ESC[?25h"; }
  cursor_blink_off()  { printf "$ESC[?25l"; }
  cursor_to()         { printf "$ESC[$1;${2:-1}H"; }
  print_inactive()    { printf "  $2  $1 "; }
  print_active()      { printf "  $2 $ESC[7m $1 $ESC[27m"; }
  get_cursor_row()    { IFS=';' read -sdR -p $'\E[6n' ROW COL; echo ${ROW#*[}; }
  key_input()         {
    local key
    IFS= read -rsn1 key 2>/dev/null >&2
    if [[ $key = ""      ]]; then echo enter; fi;
    if [[ $key = $'\x20' ]]; then echo space; fi;
    if [[ $key = $'\x1b' ]]; then
      read -rsn2 key
      if [[ $key = [A ]]; then echo up;    fi;
      if [[ $key = [B ]]; then echo down;  fi;
    fi 
  }
  toggle_option() {
    local arr_name=$1
    eval "local arr=(\"\${${arr_name}[@]}\")"
    local option=$2
    if [[ ${arr[option]} == true ]]; then
      arr[option]=
    else
      arr[option]=true
    fi
    eval $arr_name='("${arr[@]}")'
  }

  local retval=$1
  local options
  local defaults

  IFS=';' read -r -a options <<< "$2"
  if [[ -z ${3:-default} ]]; then
    defaults=()
  else
    IFS=';' read -r -a defaults <<< "${3:-default}"
  fi
  local selected=()

  for ((i=0; i<${#options[@]}; i++)); do
    selected+=("${defaults[i]:-false}")
    printf "\n"
  done

  # determine current screen position for overwriting the options
  local lastrow=`get_cursor_row`
  local startrow=$(($lastrow - ${#options[@]}))

  # ensure cursor and input echoing back on upon a ctrl+c during read -s
  trap "cursor_blink_on; stty echo; printf '\n'; exit" 2
  cursor_blink_off

  local active=0
  while true; do
      set +ue
      trap - ERR
      # print options by overwriting the last lines
      local idx=0
      for option in "${options[@]}"; do
          local prefix="$(($idx + 1)). [ ]"
          if [[ ${selected[idx]} == true ]]; then
            prefix="$(($idx + 1)). [x]"
          fi

          cursor_to $(($startrow + $idx))
          if [ $idx -eq $active ]; then
              print_active "$option" "$prefix"
          else
              print_inactive "$option" "$prefix"
          fi
          ((idx++))
      done

      # user key control
      case `key_input` in
          space)  toggle_option selected $active;;
          enter)  break;;
          up)     ((active--));
                  if [ $active -lt 0 ]; then active=$((${#options[@]} - 1)); fi;;
          down)   ((active++));
                  if [ $active -ge ${#options[@]} ]; then active=0; fi;;
      esac
      set -ue
      trap die ERR
  done

  # cursor position back to normal
  cursor_to $lastrow
  printf "\n"
  cursor_blink_on

  eval $retval='("${selected[@]}")'

  # output
  unset PRINT_RESULTS
  unset results
  unset RESULTS
  for i in "${!selected[@]}"; do
    if [ "${selected[$i]}" == "true" ]; then
      results+=("${OPTIONS_VALUES[$i]}")
      RESULTS+=("${OPTIONS_VALUES[$i]}")
      PRINT_RESULTS+=("${OPTIONS_LABELS[$i]}")
    fi
  done
  echo "User has selected:"
  if [[ -z ${RESULTS} ]]; then
    echo -e "  ${YELLOW}None. The User has selected nothing.\n  ( Remember to use the 'space bar' to select or deselect a option. )${NC}"
  else
    printf '    %s\n' ${YELLOW}"${PRINT_RESULTS[@]}"${NC}
  fi
  echo
}
# Multiple item selection with confirmation loop
function multiselect_confirm () {
  # Modded version of this persons work: https://stackoverflow.com/a/54261882/317605 (by https://stackoverflow.com/users/8207842/dols3m)
  # To run: multiselect_confirm SELECTED "$OPTIONS_STRING"
  # To get output results: printf '%s\n' "${RESULTS[@]}"
  while true; do
    multiselect "$1" "$2"
    read -p "User accepts the final selection: [y/n]?" -n 1 -r YN < /dev/tty
    echo
    case $YN in
      [Yy]*)
        info "Selection status: ${YELLOW}accepted${NC}"
        echo
        break
        ;;
      [Nn]*)
        info "No problem. Try again..."
        echo
        ;;
      *)
        warn "Error! Entry must be 'y' or 'n'. Try again..."
        echo
        ;;
    esac
  done
}
# Single item selection only
function singleselect () {
  # Modded version of this persons work: https://stackoverflow.com/a/54261882/317605 (by https://stackoverflow.com/users/8207842/dols3m)
  # To run: singleselect SELECTED "$OPTIONS_STRING"
  # To get output results: printf '%s\n' "${RESULTS[@]}"
  unset RESULTS && unset results
  echo -e "Select menu item with 'arrow keys \U2191\U2193' and confirm/done with 'Enter key'. Your options are:" | fmt -s -w 80
  ESC=$( printf "\033")
  cursor_blink_on()   { printf "$ESC[?25h"; }
  cursor_blink_off()  { printf "$ESC[?25l"; }
  cursor_to()         { printf "$ESC[$1;${2:-1}H"; }
  print_inactive()    { printf "  $2  $1 "; }
  print_active()      { printf "  $2 $ESC[7m $1 $ESC[27m"; }
  get_cursor_row()    { IFS=';' read -sdR -p $'\E[6n' ROW COL; echo ${ROW#*[}; }
  key_input()         {
    local key
    IFS= read -rsn1 key 2>/dev/null >&2
    if [[ $key = ""      ]]; then echo enter; fi;
    # if [[ $key = $'\x20' ]]; then echo space; fi;
    if [[ $key = $'\x1b' ]]; then
      read -rsn2 key
      if [[ $key = [A ]]; then echo up;    fi;
      if [[ $key = [B ]]; then echo down;  fi;
    fi 
  }

  toggle_option()  {
    local arr_name=$1
    eval "local arr=(\"\${${arr_name}[@]}\")"
    local option=$2
    if [[ ${arr[option]} == true ]]; then
      arr[option]=
    else
      arr[option]=true
    fi
    eval $arr_name='("${arr[@]}")'
  }

  local retval=$1
  local options
  local defaults

  IFS=';' read -r -a options <<< "$2"
  if [[ -z ${3:-default} ]]; then
    defaults=()
  else
    IFS=';' read -r -a defaults <<< "${3:-default}"
  fi
  local selected=()

  for ((i=0; i<${#options[@]}; i++)); do
    selected+=("${defaults[i]:-false}")
    printf "\n"
  done

  # determine current screen position for overwriting the options
  local lastrow=`get_cursor_row`
  local startrow=$(($lastrow - ${#options[@]}))

  # ensure cursor and input echoing back on upon a ctrl+c during read -s
  trap "cursor_blink_on; stty echo; printf '\n'; exit" 2
  cursor_blink_off

  local active=0
  while true; do
      set +ue
      trap - ERR
      # print options by overwriting the last lines
      local idx=0
      for option in "${options[@]}"; do
          local prefix="$(($idx + 1)). [ ]"
          if [[ $idx -eq $active ]]; then
            prefix="$(($idx + 1)). [x]"
          fi

          cursor_to $(($startrow + $idx))
          if [ $idx -eq $active ]; then
              print_active "${option}" "$prefix"
          else
              print_inactive "$option" "$prefix"
          fi
          ((idx++))
      done

      # user key control
      case `key_input` in
          enter)  toggle_option selected $active; break;;
          up)     ((active--));
                  if [ $active -lt 0 ]; then active=$((${#options[@]} - 1)); fi;;
          down)   ((active++));
                  if [ $active -ge ${#options[@]} ]; then active=0; fi;;
      esac
      set -ue
      trap die ERR
  done

  # cursor position back to normal
  cursor_to $lastrow
  printf "\n"
  cursor_blink_on

  eval $retval='("${selected[@]}")'

  # output
  unset PRINT_RESULTS
  unset results
  unset RESULTS
  for i in "${!selected[@]}"; do
    if [ "${selected[$i]}" == "true" ]; then
      results+=("${OPTIONS_VALUES[$i]}")
      RESULTS+=("${OPTIONS_VALUES[$i]}")
      PRINT_RESULTS+=("${OPTIONS_LABELS[$i]}")
    fi
  done
  echo "User has selected:"
  printf '    %s\n' ${YELLOW}"${PRINT_RESULTS[@]}"${NC}
  echo
}
# Single item selection with confirmation loop
function singleselect_confirm () {
  # Modded version of this persons work: https://stackoverflow.com/a/54261882/317605 (by https://stackoverflow.com/users/8207842/dols3m)
  # To run: singleselect_confirm SELECTED "$OPTIONS_STRING"
  # To get output results: printf '%s\n' "${RESULTS[@]}"
  while true; do
    singleselect "$1" "$2"
    read -p "User accepts the final selection: [y/n]?" -n 1 -r YN < /dev/tty
    echo
    case $YN in
      [Yy]*)
        info "Selection status: ${YELLOW}accepted${NC}"
        echo
        break
        ;;
      [Nn]*)
        info "No problem. Try again..."
        echo
        ;;
      *)
        warn "Error! Entry must be 'y' or 'n'. Try again..."
        echo
        ;;
    esac
  done
}
# Match selection only - 3 input arrays required
function matchselect () {
  # Modded version of this persons work: https://stackoverflow.com/a/54261882/317605 (by https://stackoverflow.com/users/8207842/dols3m)
  # To run: matchselect SELECTED
  # 3 required input array files must precede running function:
  # 1)  ${OPTIONS_VALUES_INPUT[@]}
  #     i.e mapfile -t OPTIONS_VALUES_INPUT <<< $(cat ${SHARED_DIR}/src/pve_host_mount_list | awk -F'|' '{ print $1 }') # The actual value list to output
  # 2) ${OPTIONS_LABELS_INPUT[@]}
  #     i.e mapfile -t OPTIONS_LABELS_INPUT <<< $(cat ${SHARED_DIR}/src/pve_host_mount_list | awk -F'|' '{ print $2 }') # The actual value description list to display
  # 3) ${SRC_VALUES_INPUT[@]}
  #     i.e SRC_VALUES_INPUT=( $(pvesm nfsscan ${NAS_ID} | awk '{print $1}') ) # The source input to match or ignore and assign a value match to.
  # To get output display results:
  #     echo "User selected matches are:"
  #     printf '%s\n' "${PRINT_RESULTS[@]}" | awk -F':' '{OFS=FS} { print $1,">>",$2}' | column -s ":" -t -N "SOURCE INPUT, ,SELECTED PAIR DESCRIPTION" | indent2

  # Unset Results
  unset PRINT_RESULTS
  unset results
  unset RESULTS

  # Set counter
  j=0
  # Set counter maximum val
  if [ "${#SRC_VALUES_INPUT[@]}" -gt "${#OPTIONS_VALUES_INPUT[@]}" ]; then
    LOOP_CNT=${#OPTIONS_VALUES_INPUT[@]}
  elif [ "${#OPTIONS_VALUES_INPUT[@]}" -gt "${#SRC_VALUES_INPUT[@]}" ]; then
    LOOP_CNT=${#SRC_VALUES_INPUT[@]}
  elif [ "${#SRC_VALUES_INPUT[@]}" -lt "${#OPTIONS_VALUES_INPUT[@]}" ]; then
    LOOP_CNT=${#SRC_VALUES_INPUT[@]}
  elif [ "${#OPTIONS_VALUES_INPUT[@]}" -lt "${#SRC_VALUES_INPUT[@]}" ]; then
    LOOP_CNT=${#OPTIONS_VALUES_INPUT[@]}
  elif [ "${#OPTIONS_VALUES_INPUT[@]}" -eq "${#SRC_VALUES_INPUT[@]}" ]; then
    LOOP_CNT=${#OPTIONS_VALUES_INPUT[@]}
  fi

  # Func match loop
  while [ ${j} -lt ${LOOP_CNT} ]; do
    # Update input
    unset OPTIONS_STRING
    # Add input Values and Labels
    OPTIONS_VALUES=("${OPTIONS_VALUES_INPUT[@]}")
    OPTIONS_LABELS=("${OPTIONS_LABELS_INPUT[@]}")
    # Add none/ignore and exit
    OPTIONS_VALUES+=( "NONE" "TYPE00" )
    OPTIONS_LABELS+=( "Ignore this match" "Exit/Finished - Nothing more to match" )
    unset i
    for i in "${!OPTIONS_VALUES[@]}"; do
        OPTIONS_STRING+="${OPTIONS_LABELS[$i]};"
    done
    # Set ARGS
    set SELECTED "$OPTIONS_STRING"

    # Run match script
    echo -e "Select menu option with 'arrow keys \U2191\U2193' to match the source '${YELLOW}${SRC_VALUES_INPUT[j]}${NC}' and confirm/done with 'Enter key'.\nYour options are:\n" | fmt -s -w 80
    ESC=$( printf "\033")
    cursor_blink_on()   { printf "$ESC[?25h"; }
    cursor_blink_off()  { printf "$ESC[?25l"; }
    cursor_to()         { printf "$ESC[$1;${2:-1}H"; }
    print_inactive()    { printf "  $2  $1 "; }
    print_active()      { printf "  $2 $ESC[7m $1 $ESC[27m"; }
    get_cursor_row()    { IFS=';' read -sdR -p $'\E[6n' ROW COL; echo ${ROW#*[}; }
    key_input()         {
      local key
      IFS= read -rsn1 key 2>/dev/null >&2
      if [[ $key = ""      ]]; then echo enter; fi;
      # if [[ $key = $'\x20' ]]; then echo space; fi;
      if [[ $key = $'\x1b' ]]; then
        read -rsn2 key
        if [[ $key = [A ]]; then echo up;    fi;
        if [[ $key = [B ]]; then echo down;  fi;
      fi 
    }

    toggle_option()  {
      local arr_name=$1
      eval "local arr=(\"\${${arr_name}[@]}\")"
      local option=$2
      if [[ ${arr[option]} == true ]]; then
        arr[option]=
      else
        arr[option]=true
      fi
      eval $arr_name='("${arr[@]}")'
    }

    local retval=$1
    local options
    local defaults

    IFS=';' read -r -a options <<< "$2"
    if [[ -z ${3:-default} ]]; then
      defaults=()
    else
      IFS=';' read -r -a defaults <<< "${3:-default}"
    fi
    local selected=()

    for ((i=0; i<${#options[@]}; i++)); do
      selected+=("${defaults[i]:-false}")
      printf "\n"
    done

    # determine current screen position for overwriting the options
    local lastrow=`get_cursor_row`
    local startrow=$(($lastrow - ${#options[@]}))

    # ensure cursor and input echoing back on upon a ctrl+c during read -s
    trap "cursor_blink_on; stty echo; printf '\n'; exit" 2
    cursor_blink_off

    local active=0
    while true; do
        set +ue
        trap - ERR
        # print options by overwriting the last lines
        local idx=0
        for option in "${options[@]}"; do
            local prefix="$(($idx + 1)). [ ]"
            if [[ $idx -eq $active ]]; then
              prefix="$(($idx + 1)). [x]"
            fi

            cursor_to $(($startrow + $idx))
            if [ $idx -eq $active ]; then
                print_active "${option}" "$prefix"
            else
                print_inactive "$option" "$prefix"
            fi
            ((idx++))
        done

        # user key control
        case `key_input` in
            enter)  toggle_option selected $active; break;;
            up)     ((active--));
                    if [ $active -lt 0 ]; then active=$((${#options[@]} - 1)); fi;;
            down)   ((active++));
                    if [ $active -ge ${#options[@]} ]; then active=0; fi;;
        esac
        set -ue
        trap die ERR
    done

    # cursor position back to normal
    cursor_to $lastrow
    printf "\n"
    cursor_blink_on

    eval $retval='("${selected[@]}")'

    # Output
    for i in "${!selected[@]}"; do
      if [ "${selected[$i]}" == "true" ] && [ "${OPTIONS_VALUES[$i]}" != "NONE" ] && [ "${OPTIONS_VALUES[$i]}" != "TYPE00" ]; then
        results+=("${SRC_VALUES_INPUT[j]}:${OPTIONS_VALUES[$i]}")
        RESULTS+=("${SRC_VALUES_INPUT[j]}:${OPTIONS_VALUES[$i]}")
        PRINT_RESULTS+=("${SRC_VALUES_INPUT[j]}:${OPTIONS_LABELS[$i]}")

        # Unset Option value entry
        delete=("${OPTIONS_VALUES[$i]}")
        for target in "${delete[@]}"; do
          for i in "${!OPTIONS_VALUES_INPUT[@]}"; do
            if [[ ${OPTIONS_VALUES_INPUT[i]} = $target ]]; then
              unset 'OPTIONS_VALUES_INPUT[i]'
              unset 'OPTIONS_LABELS_INPUT[i]'
              # unset 'options[i]'
            fi
          done
        done
      elif [ "${selected[$i]}" == "true" ] && [ "${OPTIONS_VALUES[$i]}" == "TYPE00" ]; then
        break 2
      fi
    done

    # Counter update +1
    j=$(( $j + 1 ))
  done
}

#---- Get, Add or Modify configuration file values

# Get a Variable value
function get_config_value() {
  # Get a key value in a conf/cfg file
  # Example line of conf/cfg file:
  #   pf_enable=0 # This variable sets the 'pf_enable' variable
  #   pf_enable="0"
  #   pf_enable="once upon a time" # This variable sets the 'pf_enable' variable
  # Usage:
  #   get_var "/usr/local/bin/kodirsync/kodirsync.conf" "pf_enable"
  # Output:
  #   get_var=0 or get_var="once upon a time"

  # Check if all mandatory arguments have been provided
  if [ -z "$1" ] || [ -z "$2" ]
  then
    echo "Error: missing mandatory argument(s)"
    exit 1
  fi

  # Function arguments
  local config_file="$1"
  local key="$2"

  unset get_var
  get_var=$(awk -F "=" -v VAR="$key" '
    # Split the line into fields
    { split($0, fields, "=") }
    # Check if the first field matches the variable name
    fields[1] == VAR {
      # Set the value of the variable to the second field
      value = fields[2]
      # Remove any text after the # character
      gsub(/#.*/, "", value)
      # Print the value of the variable
      print value
    }' "${config_file}" | tr -d '"')
  # Check the exit status
  if [ -z "$get_var" ]
  then
    # Print a message if the command failed
    echo "No variable found."
  fi
}

# Edit or Add a Conf file key pair
function edit_config_value() {
  # Edit or Add key value pair in a conf/cfg file
  # Matches hashed-out # key-pairs and removes #
  # Usage:
  #   edit_config_value "/path/to/src/file" "key" "value" "comment"
  #   edit_config_value "/usr/local/bin/kodirsync/kodirsync.conf" "pf_enable" "1"
  # Output:
  #   variable="1" # Comment line here (optional)

  # Check if all three mandatory arguments have been provided
  # $4 (Comment) is optional
  if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]
  then
    echo "Error: missing mandatory argument(s)"
    exit 1
  fi

  # Function arguments
  local config_file="$1"
  local key="$2"
  local value="$3"
  local comment="${4:-}"

  # Escape any special characters in the value and comment
  value=$(echo "$value" | sed 's/[\/&]/\\&/g')
  comment=$(echo "$comment" | sed 's/[\/&]/\\&/g')

  # Check if the key exists in the config file
  if egrep -q "^(#)?(\s)?$key(\s)?=" "$config_file"
  then
    # Extract the existing comment line, if it exists
    existing_comment=$(egrep "^(#)?(\s)?$key(\s)?=" "$config_file" | sed -n "s/^\(\s*\)#\{0,1\}\(\s*\)$key\(\s*\)= *\([^#]*\) *#\(.*\)/#\2/p")

    # Replace the value in the config file
    if [ -z "$comment" ]
    then
      # If no comment is provided, use the existing comment line
      sed -i "s/^\(\s*\)#\{0,1\}\(\s*\)$key\(\s*\)=.*/$key=\"$value\" $existing_comment/" "$config_file"
    else
      # If a comment is provided, use the new comment line
      sed -i "s/^\(\s*\)#\{0,1\}\(\s*\)$key\(\s*\)=.*/$key=\"$value\" # $comment/" "$config_file"
    fi
  else
    # Add the key-value pair to the end of the config file
    if [ -z "$comment" ]
    then
      # If no comment is provided, don't include a comment line
      echo "$key=\"$value\"" >> "$config_file"
    else
      # If a comment is provided, include the comment line
      echo "$key=\"$value\" # $comment" >> "$config_file"
    fi
  fi
}

#---- Get, Add or Modify JSON configuration file values

# Edit json file value
edit_json_value() {
  # Usage: edit_json_value config.json name "Jane"
  # Check for jq SW
  if [[ ! $(dpkg -s jq 2>/dev/null) ]]
  then
    apt-get install jq -yqq
  fi

  local file=$1
  local key=$2
  local value=$3
  tmp_file=$(mktemp)
  jq ".$key = \"$value\"" $file > $tmp_file && mv $tmp_file $file
}

#---- SMTP checks

# Check PVE host SMTP status
function check_smtp_status() {
  # Host SMTP Option ('0' is inactive, '1' is active)
  var='ahuacate_smtp'
  file='/etc/postfix/main.cf'
  if [ -f $file ] && [ "$(systemctl is-active --quiet postfix; echo $?)" = 0 ]
  then
    SMTP_STATUS=$(grep --color=never -Po "^${var}=\K.*" "${file}" || true)
  else
    # Set SMTP inactive
    SMTP_STATUS=0
fi
}

#---- UID & GID mapping

# Check PVE host subid mapping
function check_host_subid() {
  # For PVE host only
  # Use before creating 
  subgid_root_entry_1="root:65604:100"
  subgid_root_entry_2="root:100:1"
  subuid_root_entry_1="root:1605:1"
  subuid_root_entry_2="root:1606:1"
  subuid_root_entry_3="root:1607:1"

  # Check if all the subgid entries exist
  if ! grep -qF "$subgid_root_entry_1" /etc/subgid || ! grep -qF "$subgid_root_entry_2" /etc/subgid || ! grep -qF "$subuid_root_entry_1" /etc/subuid || ! grep -qF "$subuid_root_entry_2" /etc/subuid || ! grep -qF "$subuid_root_entry_3" /etc/subuid
  then
    warn "There are issues with your PVE hosts UID & GID mapping.\nYou must run our PVE host toolbox ( option 'PVE Basic - required by all hosts' ), to prepare your PVE hosts before running this installer again.\nMore information is available here: https://github.com/ahuacate/pve-host \nBye..."
    echo
    exit 0
  fi
}


#---- SW Systemctl checks
# Check Install CT SW status (active or abort script)
function pct_check_systemctl() {
  # Usage: check_systemctl_sw "jellyfin.service"
  local service_name="$1"
  msg "Checking '${service_name}' service status..."
  FAIL_MSG='Systemctl '${service_name}' has failed. Reason unknown.\nExiting installation script in 2 second.'
  i=0
  while true
  do
    if [[ $(pct exec $CTID -- systemctl is-active ${service_name}) == 'active' ]]
    then
      info "Systemctl '${service_name}' status: ${YELLOW}active${NC}"
      echo
      break
    elif [[ ! $(pct exec $CTID -- systemctl is-active ${service_name}) == 'active' ]] && [ "$i" = '5' ]
    then
      warn "$FAIL_MSG"
      echo
      trap error_exit EXIT
    fi
    ((i=i+1))
    sleep 1
  done
}



#---- Bash Messaging Functions
if [[ ! $(dpkg -s boxes 2> /dev/null) ]]
then
  apt-get install -y boxes > /dev/null
fi
function msg() {
  local TEXT="$1"
  echo -e "$TEXT" | fmt -s -w 80 
}
function msg_nofmt() {
  local TEXT="$1"
  echo -e "$TEXT"
}
function warn() {
  local REASON="${WHITE}$1${NC}"
  local FLAG="${RED}[WARNING]${NC}"
  msg "$FLAG"
  msg "$REASON"
}
function info() {
  local REASON="$1"
  local FLAG="\e[36m[INFO]\e[39m"
  msg_nofmt "$FLAG $REASON"
}
function section() {
  local REASON="\e[97m$1\e[37m"
  printf -- '-%.0s' {1..84}; echo ""
  msg "  $SECTION_HEAD - $REASON"
  printf -- '-%.0s' {1..84}; echo ""
  echo
}
function msg_box () {
  echo -e "$1" | fmt -w 80 -s | boxes -d stone -p a1l3 -s 84
}
function indent() {
    eval "$@" |& sed "s/^/\t/"
    return "$PIPESTATUS"
}
function indent2() {
  sed "s/^/  /"
} # Use with pipe echo 'sample' | indent2

#----  Detect modules and automatically load at boot
#load_module aufs
#load_module overlay

#---- IP validate Tools
# IP validate
# function valid_ip() {
#   local  ip=$1
#   local  stat=1
#   if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
#       OIFS=$IFS
#       IFS='.'
#       ip=($ip)
#       IFS=$OIFS
#       [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 \
#           && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
#       stat=$?
#   fi
#   return $stat
# }
function valid_ip() {
  local  ip=$1
  local  stat=1
  if [[ "$ip" =~ ${ip4_regex} ]]
  then
    stat=$?
  elif [[ "$ip" =~ ${ip6_regex} ]]
  then
    stat=$?
  fi
  return $stat
}

#---- Terminal settings
RED=$'\033[0;31m'
YELLOW=$'\033[1;33m'
GREEN=$'\033[0;32m'
WHITE=$'\033[1;37m'
NC=$'\033[0m'
UNDERLINE=$'\033[4m'
printf '\033[8;40;120t'
# Position terminal top/left
printf '\e[3;0;3t'


#---- Set Bash Temp Folder
if [ -z "${TEMP_DIR+x}" ]
then
  TEMP_DIR=$(mktemp -d)
  pushd $TEMP_DIR > /dev/null
else
  if [ $(pwd -P) != $TEMP_DIR ]
  then
    cd $TEMP_DIR > /dev/null
  fi
fi
#-----------------------------------------------------------------------------------