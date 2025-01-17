#!/usr/bin/env bash
#
# Copyright 2016 The Kubernetes Authors All rights reserved.
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
# Provide a default $PROG (for use in most functions that use a $PROG: prefix
: ${PROG:="common"}
export PROG

##############################################################################
# Common library of useful functions and GLOBALS.
##############################################################################

set -o errtrace

declare -A some_var || (echo "Bash version >= 4.0 required" && exit 1)

if [[ $(uname) == "Darwin" ]]; then
  # Support for OSX.
  READLINK_CMD=greadlink
  LC_ALL=C  # To make BSD sed work with double-quoted strings.
else
  READLINK_CMD=readlink
fi

##############################################################################
# COMMON CONSTANTS
#

TOOL_LIB_PATH=${TOOL_LIB_PATH:-$(dirname $($READLINK_CMD -ne $BASH_SOURCE))}
TOOL_ROOT=${TOOL_ROOT:-$($READLINK_CMD -ne $TOOL_LIB_PATH/..)}
PATH=$TOOL_ROOT:$PATH
# Provide a default EDITOR for those that don't have this set
: ${EDITOR:="vi"}
export PATH TOOL_ROOT TOOL_LIB_PATH EDITOR

# Pretty curses stuff for terminals
if [[ -t 1 ]]; then
  # Set some video text attributes for use in error/warning msgs.
  declare -A TPUT=([BOLD]=$(tput bold 2>/dev/null))
  TPUT+=(
  [REVERSE]=$(tput rev 2>/dev/null)
  [UNDERLINE]=$(tput smul 2>/dev/null)
  [BLINK]=$(tput blink 2>/dev/null)
  [GREEN]=${TPUT[BOLD]}$(tput setaf 2 2>/dev/null)
  [RED]=${TPUT[BOLD]}$(tput setaf 1 2>/dev/null)
  [YELLOW]=${TPUT[BOLD]}$(tput setaf 3 2>/dev/null)
  [OFF]=$(tput sgr0 2>/dev/null)
  [COLS]=$(tput cols 2>/dev/null)
  )

  # HR
  HR="$(for ((i=1;i<=${TPUT[COLS]};i++)); do echo -en '\u2500'; done)"

  # Save original TTY State
  TTY_SAVED_STATE="$(stty -g)"
else
  HR="$(for ((i=1;i<=80;i++)); do echo -en '='; done)"
fi

# Set some usable highlighted keywords for functions like logrun -s
YES="${TPUT[GREEN]}YES${TPUT[OFF]}"
OK="${TPUT[GREEN]}OK${TPUT[OFF]}"
DONE="${TPUT[GREEN]}DONE${TPUT[OFF]}"
PASSED="${TPUT[GREEN]}PASSED${TPUT[OFF]}"
FAILED="${TPUT[RED]}FAILED${TPUT[OFF]}"
FATAL="${TPUT[RED]}FATAL${TPUT[OFF]}"
NO="${TPUT[RED]}NO${TPUT[OFF]}"
WARNING="${TPUT[YELLOW]}WARNING${TPUT[OFF]}"
ATTENTION="${TPUT[YELLOW]}ATTENTION${TPUT[OFF]}"
MOCK="${TPUT[YELLOW]}MOCK${TPUT[OFF]}"
FOUND="${TPUT[GREEN]}FOUND${TPUT[OFF]}"
NOTFOUND="${TPUT[YELLOW]}NOT FOUND${TPUT[OFF]}"

# Ensure USER is set
USER=${USER:-$LOGNAME}

# Set a PID for use throughout.
export PID=$$

# Save original cmd-line.
ORIG_CMDLINE="$*"

# Global arrays and dictionaries for use with common::stepheader()
#  and common::stepindex()
declare -A PROGSTEP
declare -a PROGSTEPS
declare -A PROGSTEPS_INDEX

###############################################################################
# Define logecho() function to display to both log and stdout.
# As this is widely used and to reduce clutter, we forgo the common:: prefix
# Options can be -n or -p or -np/-pn.
# @optparam -p Add $PROG: prefix to stdout
# @optparam -r Exclude log prefix (used to output status' like $OK $FAILED)
# @optparam -n no newline (just like echo -n)
# @param a string to echo to stdout
logecho () {
  local log_prefix="$PROG::${FUNCNAME[1]:-"main"}(): "
  local prefix
  # Dynamically set fmtlen
  local fmtlen=$((${TPUT[COLS]:-"90"}))
  local n
  local raw=0
  #local -a sed_pat=()

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -r) raw=1; shift ;;
      -n) n="-n"; shift ;;
      -p) prefix="$PROG: "; ((fmtlen+=${#prefix})); shift ;;
       *) break ;;
    esac
  done

  if ((raw)) || [[ -z "$*" ]]; then
    # Clean log_prefix for blank lines
    log_prefix=""
  #else
    # Increase fmtlen to account for control characters
    #((fmtlen+=$(echo "$*" grep -o '[[:cntrl:]]' |wc -l)))
    #sed_pat=(-e '2,${s}/^/ ... /g')
  fi

  # Allow widespread use of logecho without having to
  # determine if $LOGFILE exists first.
  [[ -f $LOGFILE ]] || LOGFILE="/dev/null"
  (
  # If -n is set, do not provide autoformatting or you lose the -n effect
  # Use of -n should only be used on short status lines anyway.
  if ((raw)) || [[ $n == "-n" ]]; then
    echo -e $n "$log_prefix$*"
  else
    # Add FUNCNAME to line prefix, but strip it from visible output
    # Useful for viewing log detail
    echo -e "$*" | fmt -$fmtlen | sed -e "1s,^,$log_prefix,g" "${sed_pat[@]}"
  fi
  ) | tee -a "$LOGFILE" |sed "s,^$log_prefix,$prefix,g"
}

###############################################################################
# logrun() function to run commands to both log and stdout.
# As this is widely used and to reduce clutter, we forgo the common:: prefix
#
# The calling function is added to the line prefix.
# NOTE: All optparam's for logrun() (obviously) must precede the command string
# @optparam -v Run verbosely
# @optparam -s Provide a $OK or $FAILED status from running command
# @optparam -m MOCK command by printing out command line rather than running it.
# @optparam -r Retry attempts. Integer arg follows -r (Ex. -r 2)
#              Typically used together with -v to show retry attempts.
# @param a command string
# GLOBALS used in this function:
# * LOGFILE (Set by common::logfileinit()), if set, gets full command output
# * FLAGS_verbose (Set by caller - defaults to false), if true, full output to stdout
logrun () {
  local mock=0
  local status=0
  local arg
  local retries=0
  local try
  local retry_string
  local scope="::${FUNCNAME[1]:-main}()"
  local ret
  local verbose=0

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -v) verbose=1; shift ;;
      -s) status=1; shift ;;
      -m) mock=1; shift ;;
      -r) retries=$2; shift 2;;
       *) break ;;
    esac
  done

  for ((try=0; try<=$retries; try++)); do
    if [[ $try -gt 0 ]]; then
      if ((verbose)) || ((FLAGS_verbose)); then
        # if global FLAGS_verbose, be very verbose
        logecho "Retry #$try..."
      elif ((status)); then
        # if we're reporting a status (-v), then just ...
        logecho -n "."
      fi
      # Add some minimal wait between retries assuming we're retrying due to
      # something resolvable by waiting 'just a bit'
      sleep 2
    fi

    # if no args, take stdin
    if (($#==0)); then
      if ((verbose)) || ((FLAGS_verbose)); then
        tee -a $LOGFILE
      else
        tee -a $LOGFILE &>/dev/null
      fi
      ret=$?
    elif [[ -f "$LOGFILE" ]]; then
      printf "\n$PROG$scope: %s\n" "$*" >> $LOGFILE

      if ((mock)); then
        logecho "($MOCK)"
        logecho "(CMD): $@"
        return 0
      fi

      # Special case "cd" which cannot be run through a pipe (subshell)
      if (! ((FLAGS_verbose)) && ! ((verbose)) ) || [[ "$1" == "cd" ]]; then
        "${@:-:}" >> $LOGFILE 2>&1
      else
        printf "\n$PROG$scope: %s\n" "$*"
        "${@:-:}" 2>&1 | tee -a $LOGFILE
      fi
    ret=${PIPESTATUS[0]}
    else
      if ((mock)); then
        logecho "($MOCK)"
        logecho "(CMD): $@"
        return 0
      fi

      if ((verbose)) || ((FLAGS_verbose)); then
        printf "\n$PROG$scope: %s\n" "$*"
        "${@:-:}"
      else
        "${@:-:}" &>/dev/null
      fi
      ret=${PIPESTATUS[0]}
    fi

    [[ "$ret" = 0 ]] && break
  done

  [[ -n "$retries" && $try > 0 ]] && retry_string=" (retry #$try)"

  if ((status)); then
    [[ "$ret" = 0 ]] && logecho -r "$OK$retry_string"
    [[ "$ret" != 0 ]] && logecho -r "$FAILED"
  fi

  return $ret
}

###############################################################################
# common::timestamp() Capture block timings and display them
# The calling function is added to the line prefix.
# NOTE: All optparam's for logrun() (obviously) must precede the command string
# @param begin|end|done
# @optparam section defaults to main, but can be specified to time sub sections
common::timestamp () {
  local action=$1
  local section=${2:-main}
  # convert illegal characters to (legal) underscore
  section_var=${section//[-\.:\/]/_}
  local start_var="${section_var}start_seconds"
  local end_var="${section_var}end_seconds"
  local prefix
  local elapsed
  local d
  local h
  local m
  local s
  local prettyd
  local prettyh
  local prettym
  local prettys
  local pretty

  # Only prefix for "main"
  if [[ $section == "main" ]]; then
    prefix="$PROG: "
  fi

  case $action in
  begin)
    # Get time(date) for display and calc.
    eval $start_var=$(date '+%s')

    if [[ $section == "main" ]]; then
      # Print BEGIN message for $PROG.
      echo "${prefix}BEGIN $section on ${HOSTNAME%%.*} $(date)"
    else
      echo "$(date +[%Y-%b-%d\ %R:%S\ %Z]) $section"
    fi

    if [[ $section == "main" ]]; then
      echo
    fi
    ;;
  end|done)
    # Check for "START" values before calcing.
    if [[ -z ${!start_var} ]]; then
      #display_time="EE:EE:EE - 'end' run without 'begin' in this scope or sourced script using common::timestamp"
      return 0
    fi

    # Get time(date) for display and calc.
    eval $end_var=$(date '+%s')

    elapsed=$(( ${!end_var} - ${!start_var} ))
    d=$(( elapsed / 86400 ))
    h=$(( (elapsed % 86400) / 3600 ))
    m=$(( (elapsed % 3600) / 60 ))
    s=$(( elapsed % 60 ))
    (($d>0)) && local prettyd="${d}d"
    (($h>0)) && local prettyh="${h}h"
    (($m>0)) && local prettym="${m}m"
    prettys="${s}s"
    pretty="$prettyd$prettyh$prettym$prettys"

    if [[ $section == "main" ]]; then
      echo
      echo "${prefix}DONE $section on ${HOSTNAME%%.*} $(date) in $pretty"
    else
      echo "$(date +[%Y-%b-%d\ %R:%S\ %Z]) $section in $pretty"
    fi
    ;;
  esac
}

# Write our own trap to capture signal
common::trap () {
  local func="$1"
  shift
  local sig

  for sig; do
    trap "$func $sig" "$sig"
  done
}

common::trapclean () {
  local sig=$1
  local frame=0

  # If user ^C's at read then tty is hosed, so make it sane again.
  [[ -n "$TTY_SAVED_STATE" ]] && stty "$TTY_SAVED_STATE"

  logecho;logecho
  logecho "Signal $sig caught!"
  logecho
  logecho "Traceback (line function script):"
  while caller $frame; do
    ((frame++))
  done
  common::exit 2 "Exiting..."
}

#############################################################################
# Clean exit with an ending timestamp
# @param Exit code
common::cleanexit () {
  # Display end common::timestamp when an existing common::timestamp begin
  # was run.
  [[ -n ${mainstart_seconds} ]] && common::timestamp end
  exit ${1:-0}
}

#############################################################################
# common::cleanexit() entry point with some formatting and message printing
# @param Exit code
# @param message
common::exit () {
  local etype=${1:-0}
  shift

  [[ -n "$1" ]] && (logecho;logecho "$@";logecho)
  common::cleanexit $etype
}

#############################################################################
# Simple yes/no prompt
#
# @optparam default -n(default)/-y/-e (default to n, y or make (e)xplicit)
# @param message
common::askyorn () {
  local yorn
  local def=n
  local msg="y/N"

  case $1 in
  -y) # yes default
      def="y" msg="Y/n"
      shift
      ;;
  -e) # Explicit
      def="" msg="y/n"
      shift
      ;;
  -n) shift
      ;;
  esac

  while [[ $yorn != [yYnN] ]]; do
    logecho -n "$*? ($msg): "
    read yorn
    : ${yorn:=$def}
  done

  # Final test to set return code
  [[ $yorn == [yY] ]]
}

###############################################################################
# Print PROGSTEPs as bolded headers within scripts.
# PROGSTEP is a globally defined dictionary (associative array) that can
# take a function name or integer as its key
# The function indexes the dictionary in the order the items are added (by
# calling the function) so that progress can be shown during script execution
# (1/4, 2/4...4/4)
# If a PROGSTEP dictionary is empty, common::stepheader() will just show the
# text passed in.
common::stepheader () {
  # If called with no args, assume the key is the caller's function name
  local key="${1:-${FUNCNAME[1]}}"
  local append="$2"
  local msg="${PROGSTEP[$key]:-$key}"
  local index=

  # Only display an index if the $key is part of one
  [[ -n "${PROGSTEPS_INDEX[$key]:-}" ]] \
    && index="(${PROGSTEPS_INDEX[$key]}/${#PROGSTEPS_INDEX[@]})"

  logecho
  logecho -r "$HR"
  logecho "$msg" "$append" $index
  logecho -r "$HR"
  logecho
}

# Save a specified number of backups to a file
common::rotatelog () {
  local file=$1
  local num=$2
  local tmpfile=$TMPDIR/rotatelog.$PID
  local counter=$num

  # Quiet exit
  [[ ! -f "$file" ]] && return

  cp -p $file $tmpfile

  while ((counter>=0)); do
    if ((counter==num)); then
      rm -f $file.$counter
    elif ((counter==0)); then
      if [[ -f "$file" ]]; then
        next=$((counter+1))
        mv $file $file.$next
      fi
    else
      next=$((counter+1))
      [[ -f $file.$counter ]] && mv $file.$counter $file.$next
    fi
    ((counter==0)) && break
    ((counter--))
  done

  mv $tmpfile $file
}

# --norotate assumes you're passing in a unique LOGFILE.
# $2 then indicates the number of unique filenames prefixed up to the last
# dot extension that will be saved.  The rest of those files will be deleted
# For example, common::logfileinit --norotate foo.log.234 100
# common::logfileinit maintains up to 100 foo.log.* files.  Anything else named
# foo.log.* > 100 are removed.
common::logfileinit () {
  local nr=false

  if [[ "$1" == "--norotate" ]]; then
    local nr=true
    shift
  fi
  LOGFILE=${1:-$PWD/$PROG.log}
  local num=$2

  # Ensure LOG directory exists
  mkdir -p $(dirname $LOGFILE 2>&-)

  # Initialize Logfile.
  if ! $nr; then
    common::rotatelog "$LOGFILE" ${num:-3}
  fi
  # Truncate the logfile.
  > "$LOGFILE"

  echo "CMD: $PROG $ORIG_CMDLINE" >> "$LOGFILE"

  # with --norotate, remove the list of files that start with $PROG.log
  if $nr; then
    ls -1tr ${LOGFILE%.*}.* |head --lines=-$num |xargs rm -f
  fi
}

# An alternative that has a dependency on external program - pandoc
# store markdown man pages in companion files.  Allow prog -man to still read
# those and display a man page using:
# pandoc -s -f markdown -t man prog.md |man -l -
common::manpage () {
  [[ "$usage" == "yes" ]] && set -- -usage
  [[ "$man" == "yes" ]] && set -- -man
  [[ "$comments" == "yes" ]] && set -- -comments

  case $1 in
  -*usage|"-?")
    sed -n '/#+ SYNOPSIS/,/^#+ DESCRIPTION/p' $0 |sed '/^#+ DESCRIPTION/d' |\
     envsubst | sed -e 's,^#+ ,,g' -e 's,^#+$,,g'
    exit 1
    ;;
  -*man|-h|-*help)
    grep "^#+" "$0" |\
     sed -e 's,^#+ ,,g' -e 's,^#+$,,g' |envsubst |${PAGER:-"less"}
    exit 1
    ;;
  esac
}

###############################################################################
# General command-line parser converting -*arg="value" to $FLAGS_arg="value"
# Set -name/--name booleans to FLAGS_name=1
# As a convenience, flags can contain dashes or underscores, but dashes are
# converted to underscores in the final FLAGS_name to conform to variable
# naming standards.
# Sets global array POSITIONAL_ARGV holding all non-dash command-line arguments
common::namevalue () {
  local arg
  local name
  local value
  local -A arg_aliases=([v]="verbose" [n]="dryrun")

  for arg in "$@"; do
    case $arg in
      -*[[:alnum:]]*) # Strip off any leading - or --
          arg=$(printf "%s\n" $arg |sed 's/^-\{1,2\}//')
          # Handle global aliases
          arg=${arg_aliases[$arg]:-"$arg"}
          if [[ $arg =~ =(.*) ]]; then
            name=${arg%%=*}
            value=${arg#*=}
            # change -'s to _ in name for legal vars in bash
            eval export FLAGS_${name//-/_}=\""$value"\"
          else
            # bool=1
            # change -'s to _ in name for legal vars in bash
            eval export FLAGS_${arg//-/_}=1
          fi
          ;;
    *) POSITIONAL_ARGV+=($arg)
       ;;
    esac
  done
}

###############################################################################
# Print vars in simple or pretty format with text highlighting, columnized,
# logged.
# Prints the shell-quoted values of all of the given variables.
# Arrays and associative arrays are supported; all their elements will be
# printed.
# @optparam -p Pretty print the values
# @param space separated list of variables
common::printvars () {
  local var
  local var_str
  local key
  local tmp
  local pprint=0
  local pprintvar
  local pprintval
  local -a quoted

  # Pretty/format print?
  if [[ "$1" == "-p" ]]; then
    pprint=1
    pprintvar=$2
    shift 2
  fi

  for var in "$@"; do
    (($pprint)) && var_str=$var

    # if var is an array, do special tricks
    # bash wizardry courtesy of
    # https://stackoverflow.com/questions/4582137/bash-indirect-array-addressing
    if [[ "$(declare -p $var 2>/dev/null)" =~ ^declare\ -[aA] ]]; then
      tmp="$var[@]"
      quoted=("${!tmp}") # copy the variable
      for key in "${!quoted[@]}"; do
        # shell-quote each element
        quoted[$key]="$(printf %q "${quoted[$key]}")"
      done
      if (($pprint)); then
        logecho -r "$(printf '%-32s%s\n' "${var_str}:" "${quoted[*]}")"
      else
        printf '%s=%s\n' "$var" "${quoted[*]}"
      fi
    else
      if (($pprint)); then
        pprintval=$(eval echo \$$pprintvar)
        logecho -r \
         "$(printf '%-32s%s\n' "${var_str}:" "${!var/$pprintval\//\$$pprintvar/}")"
      else
        echo "$var=${!var}"
      fi
    fi
  done
}


###############################################################################
# Simple argc validation with a usage return
# @param num - number of POSITIONAL_ARGV that should be on the command-line
# return 1 if any number other than num
common::argc_validate () {
  local args=$1

  # Validate number of args
  if ((${#POSITIONAL_ARGV[@]}>args)); then
    logecho
    logecho "Exceeded maximum argument limit of $args!"
    logecho
    $PROG -?
    logecho
    common::exit 1
  fi
}


###############################################################################
# Get the md5 hash of a file
# @param file - The file
# @print the md5 hash
common::md5 () {
  local file=$1

  if which md5 >/dev/null 2>&1; then
    md5 -q "$1"
  else
    md5sum "$file" | awk '{print $1}'
  fi
}

###############################################################################
# Get the sha1 hash of a file
# @param file - The file
# @param algo - Algorithm 1 (default), 224, 256, 384, 512, 512224, 512256
# @print the sha hash
common::sha () {
  local file=$1
  local algo=${2:-1}

  which shasum >/dev/null 2>&1 && LANG=C shasum -a$algo $file | awk '{print $1}'
}

###############################################################################
# Stub for messaging and catching the --nomock unauthorized case
security_layer::acl_check () {
  logecho
  logecho "--nomock runs from the command-line are restricted to those that" \
          "have direct access to the K8S Release GCP project.  Contact" \
          "https://github.com/kubernetes/kubernetes-community/tree/master/sig-release" \
          "for more information."
  return 1
}

###############################################################################
# Check for and source security layer
# This function looks for an additional security layer and activates
# special code paths to allow for enhanced features.
# The pointer to this file is set with FLAGS_security_layer:
# * --security_layer=/path/to/script_to_source
# * $HOME/${PROG}rc (FLAGS_security_layer=/path/to/source)
# SECURITY_LAYER global defaulted here.  Set to 1 in external source
common::security_layer () {
  local rcfile=$HOME/.kubernetes-releaserc
  SECURITY_LAYER=0

  # Quietly attempt to source the include
  source $rcfile >/dev/null 2>&1 || true

  # If not there attempt to set it from env
  FLAGS_security_layer=${FLAGS_security_layer:-""}

  if [[ -n $FLAGS_security_layer ]]; then
    if [[ -r $FLAGS_security_layer ]]; then
      source $FLAGS_security_layer >/dev/null 2>&1
    else
      logecho "$FATAL! $FLAGS_security_layer is not readable."
      return 1
    fi
  elif [[ "$HOSTNAME" =~ google.com ]]; then
    logecho "$FATAL! Googler, this session is incomplete." \
            "$PROG is running with missing functionality.  See go/$PROG"
    return 1
  fi
}

###############################################################################
# Check PIP packages
# @param package - A space separated list of PIP packages to verify exist
#
common::check_pip_packages () {
  local prereq
  local -a missing=()

  # Make sure a bunch of packages are available
  logecho -n "Checking required PIP packages: "

  for prereq in $*; do
    (pip list --format legacy 2>&- || pip list) |\
     fgrep -w $prereq > /dev/null || missing+=($prereq)
  done

  if ((${#missing[@]}>0)); then
    logecho -r "$FAILED"
    logecho "PREREQ: Missing prerequisites: ${missing[@]}" \
            "Run the following and try again:"
    logecho
    for prereq in ${missing[@]}; do
      logecho "$ sudo pip install $prereq"
    done
    return 1
  fi
  logecho -r "$OK"
}


###############################################################################
# Check packages for a K8s release
# @param package - A space separated list of packages to verify exist
#
common::check_packages () {
  local prereq
  local packagemgr
  local distro
  local -a missing=()

  # Make sure a bunch of packages are available
  logecho -n "Checking required system packages: "

  if ((FLAGS_gcb)); then
    # Just force Ubuntu
    distro="Ubuntu"
  else
    distro=$(lsb_release -si)
  fi
  case $distro in
    Fedora)
      packagemgr="dnf"
      for prereq in $*; do
        rpm --quiet -q $prereq 2>/dev/null || missing+=($prereq)
      done
      ;;
    Ubuntu|LinuxMint|Debian)
      packagemgr="apt-get"
      for prereq in $*; do
        dpkg --get-selections 2>/dev/null | fgrep -qw $prereq || missing+=($prereq)
      done
      ;;
    *)
      logecho "Unsupported distribution. Only Fedora and Ubuntu are supported"
      return 1
      ;;
  esac

  if ((${#missing[@]}>0)); then
    logecho -r "$FAILED"
    logecho "PREREQ: Missing prerequisites: ${missing[@]}" \
            "Run the following and try again:"
    logecho
    for prereq in ${missing[@]}; do
      if [[ -n ${PREREQUISITE_INSTRUCTIONS[$prereq]} ]]; then
        logecho "# See ${PREREQUISITE_INSTRUCTIONS[$prereq]}"
      else
        logecho "$ sudo $packagemgr install $prereq"
      fi
    done
    return 1
  fi
  logecho -r "$OK"
}


###############################################################################
# Check disk space
# @param disk - a path
# @param threshold - int in GB
#
# This is a fast moving target and difficult to estimate with any accuracy
# so set it high.
# A recent run of release-1.8 --official took:
# ~95G in the build tree
# ~90G in the docker dir
#
PROGSTEP[common::disk_space_check]="DISK SPACE CHECK"
common::disk_space_check () {
  local disk=$1
  local threshold=$2
  local avail=$(df -BG $disk |\
                sed -nr -e "s|^\S+\s+\S+\s+\S+\s+([0-9]+).*$|\1|p")

  logecho -n "Checking for at least $threshold GB on $disk: "

  if ((threshold>avail)); then
    logecho -r "$FAILED"
    logecho "AVAILABLE SPACE: $avail"
    logecho "THRESHOLD: $threshold"
    return 1
  else
    logecho -r "$OK"
  fi
}

###############################################################################
# Run a function and display time metrics
# @param function - a function name to run and time
common::runstep () {
  local function=$1
  local finishtime
  local retcode

  common::timestamp begin $function &>/dev/null

  $*
  retcode=$?

  logecho "${TPUT[BOLD]}$(common::timestamp end $function)${TPUT[OFF]}"
  return $retcode
}

###############################################################################
# Absolutify incoming path
#
# @param relative or absolute path
# @print absolute path
common::absolute_path () {
  local arg=$1

  [[ -z "$arg" ]] && return 0

  [[ "$arg" =~ ^/ ]] || dir="$PWD/$arg"
  logecho $arg
}

###############################################################################
# Strip all control characters out of a text file
# Useful for stripping color codes and things from text files after runs
# @param file text file
common::strip_control_characters () {
  local file=$1

  sed -ri -e "s/\x1B[\[(]([0-9]{1,2}(;[0-9]{1,2})?)?[m|K|B]//g" \
          -e 's/\o015$//g' $file
}

###############################################################################
# General log sanitizer
# @param file text file
common::sanitize_log () {
  local file=$1

  sed -i 's/[a-f0-9]\{40\}:x-oauth-basic/__SANITIZED__:x-oauth-basic/g' $file
}

###############################################################################
# Print a number of characters (with no newline)
# @param char single character
# @param num number to print
common::print_n_char () {
  local char=$1
  local num=$2
  local sep

  printf -v sep '%*s' $num
  echo "${sep// /$char}"
}

###############################################################################
# Generate a (github) markdown TOC between BEGIN/END tags
# @param file The file to update in place
#
common::mdtoc () {
  local file=$1
  local indent
  local anchor
  local heading
  local begin_block="<!-- BEGIN MUNGE: GENERATED_TOC -->"
  local end_block="<!-- END MUNGE: GENERATED_TOC -->"
  local tmpfile=$TMPDIR/$PROG-cm.$$

  declare -A count

  while read level heading; do
    indent="$(echo $level |sed -e "s,^#,,g" -e 's,#,  ,g')"
    # make a valid anchor
    anchor=${heading,,}
    anchor=${anchor// /-}
    anchor=${anchor//[\.\?\*\,\/\[\]:=\<\>’()]/}
    # Keep track of dups and identify
    if [[ -n ${count[$anchor]} ]]; then
      ((count[$anchor]++)) ||true
      anchor+="-${count[$anchor]}"
    else
      # initialize value
      count[$anchor]=0
    fi
    echo "${indent}- [$heading](#$anchor)"
  done < <(sed -n '/^```$/,/^```$/!p' $file | egrep '^#+ ') > $tmpfile
  # Above, sed a reasonable attempt to exclude comment lines within code blocks

  # Insert new TOC
  sed -ri "/^$begin_block/,/^$end_block/{
       /^$begin_block/{
         n
         r $tmpfile
       }
       /^$end_block/!d
       }" $file

  logrun rm -f $tmpfile
}

###############################################################################
# Set the global GSUTIL and GCLOUD binaries
# Returns:
#   0 if both GSUTIL and GCLOUD are set to executables
#   1 if both GSUTIL and GCLOUD are not set to executables
common::set_cloud_binaries () {

  logecho -n "Checking/setting cloud tools: "

  for GSUTIL in "$(which gsutil)" /opt/google/google-cloud-sdk/bin/gsutil; do
    if [[ -x $GSUTIL ]]; then
      break
    fi
  done

  for GCLOUD in "${GSUTIL/gsutil/gcloud}" "$(which gcloud)"; do
    if [[ -x $GCLOUD ]]; then
      break
    fi
  done

  if [[ -x "$GSUTIL" && -x "$GCLOUD" ]]; then
    logecho -r $OK
  else
    logecho -r $FAILED
    return 1
  fi

  # 'gcloud docker' access is now set in .docker/config.json
  # TODO: Reactivate when the deprecated functionality's replacement is working
  # See deprecated bit in lib/releaselib.sh ($GCLOUD docker -- push)
  #logrun $GCLOUD --quiet auth configure-docker || return 1

  return 0
}

###############################################################################
# sendmail/mailer front end.
# @optparam (flag) -h - Send html formatted
# @param to - To
# @param from - From
# @param reply_to - Reply To
# @param subject - Subject
# @param cc - cc
# @param file - file to send
#
common::sendmail () {
  local cc_arg
  local html=0

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -h) html=1; shift ;;
       *) break ;;
    esac
  done

  local to="$1"
  local from="$2"
  local reply_to="$3"
  local subject="$4"
  local cc="$5"
  local file="$6"

  if [[ "$HOSTNAME" =~ google.com ]]; then
    logecho "$FAILED! sendmail unavailable at Google."
    return 1
  fi

  {
  cat <<EOF+
To: $to
From: $from
Subject: $subject
Cc: $cc
Reply-To: $reply_to
EOF+
  ((html)) && echo "Content-Type: text/html"
  cat $file
  } |/usr/sbin/sendmail -t
}

# Stubs for security_layer functions
security_layer::auth_check () {
  logecho "Skipping $FUNCNAME..."
  return 0
}

#############################################################################
# common::join() returns a string in which the string elements of sequence
# have been joined by str separator.
# @param str separator
# @param $string or "${array[@]}" (quoting is intentional for both)
common::join() {
  local IFS="$1"

  echo "${*:2}"
}

###############################################################################
# Run a stateful command with arguments
# @optparam --strip-args - Do not use function args for state or pass to
#+                         common::stepheader().
# @optparam --non-fatal - Do not treat failure as a fatal.  Do not exit.
# @param    fcall A quoted function and arguments to be run
#                 The resulting unique entry in PROGSTATE will look like this:
#                 function+arg1%%arg2%%...
# @optparam var   A space-separated list of variables set by $fcall to be
#                 included in the $PROGSTATE file associated with the entry
common::run_stateful () {
  local nonfatal=0
  local stripargs=0
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
       --non-fatal) nonfatal=1; shift ;;
      --strip-args) stripargs=1; shift ;;
                 *) break ;;
    esac
  done
  local -a fcall=($1)
  local function=${fcall[0]}
  local args="${fcall[@]:1}"
  local entry=$function
  shift
  local nameval=($@)
  local -a setvar
  local c

  # Strip args?  Clear args for the purposes of storing their state and
  # passing to common::stepheader()
  ((stripargs)) && unset args

  # Create the PROGSTATE entry based on function+args
  [[ -n $args ]] && entry+="+$(common::join "%%" $args)"

  common::check_state $entry && return 0

  common::stepheader "$function" "$args"
  if ! common::runstep ${fcall[@]}; then
    logecho "$FAILED in $function."
    ((nonfatal)) || common::exit 1 "RELEASE INCOMPLETE! Exiting..."
  fi

  if [[ -n "${nameval[@]}" ]]; then
    for ((c=0;c<${#nameval[@]};c++)); do
      # Only add name=value pairs when value !null
      [[ -n "${!nameval[$c]}" ]] && setvar+=("${nameval[$c]}=${!nameval[$c]}")
    done
  fi

  common::check_state -a $entry ${setvar[@]}
}

###############################################################################
# Manage the state of PROG and allow re-entrancy
#
# @optparam -a    Add a label to the run state file ($PROGSTATE)
# @param    label The label to check or add
# @optparam nv    A single name=value pair to associate with the label in the
#                 run state file (does not support spaces in value)
# @return 1 when no label is found in state file.
common::check_state () {
  local add=false
  case "$1" in
    -a) add=true;shift ;;
  esac
  local label=$1
  shift
  local nv=($@)

  # initialize if step 1
  if $add; then
    echo "$label ${nv[@]}" >> $PROGSTATE
    return 0
  fi

  # if no file exists yet, return 1
  [[ ! -f $PROGSTATE ]] && return 1

  # check to see if it's done or not
  if grep -wq "^$label" $PROGSTATE; then
    eval $(awk '$1 == "'$label'" {$1="";print}' $PROGSTATE)
    return 0
  else
    return 1
  fi
}

###############################################################################
# BUILD a PROGSTEPS_INDEX from PROGSTEPS and optionally print out the TOC
# @param List of PROGSTEPs to add to PROGSTEPS global array
# @optparam --toc Print out the TOC of PROGSTEPs
common::stepindex () {
  local c=1
  local step
  local stepmark

  # Print Table Of Contents and return
  if [[ $1 == --toc ]]; then
    for ((c=0; c<${#PROGSTEPS_INDEX[@]}; c++)); do
      if common::check_state ${PROGSTEPS[$c]}; then
        stepmark="✔"
      else
        stepmark="☐"
      fi
      logecho "$stepmark  $(printf "%-2s" "$((c+1))")" \
      "${PROGSTEP[${PROGSTEPS[$c]}]:-"${TPUT[RED]}MISSING DESCRIPTION
       FOR ${PROGSTEPS[$c]}${TPUT[OFF]}"}"
    done
    return
  fi

  # Build an index for PROGSTEPS so we can reference these by index later
  PROGSTEPS+=("$@")
  for step in "${PROGSTEPS[@]}"; do
    PROGSTEPS_INDEX[$step]=$c
    ((c++))
  done
}

##############################################################################
# Validate command-line for re-entrancy
# Capture the original command-line and warn if subsequent runs differ
# This is specific to anago but due to when it's called, it needs to be
# pre-defined quite early.
# @param args - The quoted full original command-line args
# returns 1 on failure
common::validate_command_line () {
  local -a args=($@)
  local -a last_args
  local continue=0

  # Ignore state clearing args
  args=(${args[@]/--clean})
  args=(${args[@]/--prebuild})
  args=(${args[@]/--buildonly})

  logecho
  if [[ -f $PROGSTATE ]]; then
    last_args=($(awk '/^CMDLINE: / {for(i=2;i<=NF;++i)print $i}' $PROGSTATE))
    if [[ ${args[*]} != ${last_args[*]} ]]; then
      logecho "A previous incomplete run using different command-line values" \
              "exists."
      logecho
      logecho "${TPUT[RED]}Did you mean to --clean" \
              "and start a new session?${TPUT[OFF]}"
      logecho
      if common::askyorn "Do you want to continue" \
                         "this new session over top of the existing"; then
        continue=1
      else
        return 1
      fi
    else
      continue=1
    fi
  fi

  if ((continue)); then
    logecho "${TPUT[RED]}Continuing previous session ($PROGSTATE).${TPUT[OFF]}"
    logecho "${TPUT[RED]}Use --clean to restart${TPUT[OFF]}"
    logecho
  else
    echo "CMDLINE: ${args[*]}" > $PROGSTATE
  fi
}

##############################################################################
# Run a command line, where the first command is expected to be a go binary
# from this repo. If the binary cannot be found in the $PATH, a hopefully
# helpful message on how to install that binary is printed.
common::run_gobin () {
  local orgCmd expandedCmd
  orgCmd="$1"
  shift
  expandedCmd="$( command -v "$orgCmd" )"

  if [ -z "$expandedCmd" ]
  then
    logecho -r "${FAILED}: ${orgCmd} is not in the \$PATH, you can try to install it via 'go install k8s.io/release/cmd/${orgCmd}'" >&2
    return 1
  fi
  "$expandedCmd" "$@"
}

# right thing in common::trapclean().
common::trap common::trapclean ERR SIGINT SIGQUIT SIGTERM SIGHUP

# parse cmdline
common::namevalue "$@"

# Run common::manpage to show usage and man pages
common::manpage "$@"

# Set a TMPDIR
TMPDIR="${FLAGS_tmpdir:-/tmp}"
mkdir -p $TMPDIR

# Set some values that depend on $TMPDIR
PROGSTATE=$TMPDIR/$PROG-runstate
LOCAL_CACHE="$TMPDIR/buildresults-cache.$$"
