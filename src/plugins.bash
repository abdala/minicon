function plugin_parameter() {
  # Gets the value of a parameter passed to a plugin
  #   the format is: <plugin>:<param1>=<value1>:<param2>=<value2>...
  local PLUGIN="$1"
  local PARAMETER="$2"
  local PARAMS PP PP2 K V

  while read -d ',' PP; do
    if [[ "$PP" =~ ^$PLUGIN\: ]]; then
      PARAMS="${PP:$((${#PLUGIN}+1))}"
      while read -d ':' PP2; do
        IFS='=' read K V <<< "$PP2"
        if [ "$K" == "$PARAMETER" ]; then
          p_debug "found param $K with value $V"
          echo "$V"
          return 0
        fi
      done <<< "${PARAMS}:"
    fi
  done <<< "${PLUGINS_ACTIVATED},"
  return 1
}

function buildpaths() {
  local S_PATH="$1"
  local L_PATH="$S_PATH"
  local C_PATH="$S_PATH"

  while [ "$C_PATH" != "/" -a "$C_PATH" != "." -a "$C_PATH" != ".." ]; do
    C_PATH="$(dirname "$C_PATH")"
    L_PATH="$C_PATH
$L_PATH"
  done
  echo "$L_PATH"
}

function checklinks() {
  local L_PATH="$1"
  local C_PATH
  local D_PATH
  local FOUND
  while read C_PATH; do
    if [ "$C_PATH" != "" -a "$C_PATH" != "." -a "$C_PATH" != ".." -a -h "$C_PATH" ]; then
      D_PATH="$(readlink "$C_PATH")"
      if [ "${D_PATH:0:1}" != "/" ]; then
        D_PATH="$(dirname "${C_PATH}")/${D_PATH}"
      fi
      D_PATH="$(realpath -Ls "$D_PATH")"
      FOUND=true
      break
    fi
  done <<< "$L_PATH"
  if [ "$FOUND" == "true" ]; then
    local F_PATH="$(echo "$L_PATH" | tail -n 1)"
    local N_PATH="${#C_PATH}"
    N_PATH="${D_PATH}${F_PATH:$N_PATH}"
    echo "$F_PATH:$C_PATH:$D_PATH:$N_PATH"
  fi
}

function _linked_file() {
  local L_PATH="$1"
  local L_PATHS
  local RES
  local C_FILE="$L_PATH"
  local FINAL_FILE="$L_PATH"

  # Special cases that we do not want to handle
  if [ "$L_PATH" == "." -o "$L_PATH" == ".." ]; then
    echo "$L_PATH"
    return
  fi

  while [ "$C_FILE" != "" ]; do
    L_PATHS="$(buildpaths "$C_FILE")"
    RES="$(checklinks "$L_PATHS")"
    if [ "$RES" != "" ]; then
      local SRC DST L_ORIG L_DST
      IFS=':' read SRC L_ORIG L_DST DST <<< "${RES}:"
      p_debug "$L_ORIG -> $L_DST"
      L_DST="$(relPath "$(dirname $L_ORIG)" "$L_DST")"
      
      local EFF_FILE="$ROOTFS/$L_ORIG"
      mkdir -p "$(dirname "$EFF_FILE")"
      ln -s "$L_DST" "$EFF_FILE" 2> /dev/null
      C_FILE="$DST"
    else
      FINAL_FILE="$C_FILE"
      C_FILE=
    fi
  done
  echo "$FINAL_FILE"
}

function PLUGIN_00_link() {
  # If the path is a link to other path, we will create the link and analyze the real path
  local L_PATH="$1"

  local L_PATH="$(_linked_file "$1")"
  if [ "$L_PATH" != "$1" ]; then
    add_command "$L_PATH"
    return 1
  fi
  return 0
}

function PLUGIN_01_which() {
  # This plugin tries to guess whether the command to analize is in the path or not.
  # If the command can be obtained calling which, we'll analyze the actual command and not the short name.
  local S_PATH="$1"
  local W_PATH="$(which $S_PATH)"

  if [ "$W_PATH" != "" -a "$W_PATH" != "$S_PATH" ]; then
    p_debug "$1 is $W_PATH"
    add_command "$W_PATH"
    return 1
  fi
}

function PLUGIN_02_folder() {
  # If it is a folder, just copy it to its location in the new FS
  local S_PATH="$1"

  if [ -d "$S_PATH" ]; then
    p_debug "copying the whole folder $S_PATH"
    copy "$S_PATH" -r
    return 1
  fi

  return 0
}

function PLUGIN_09_ldd() {
  # Checks the list of dynamic libraries using ldd and copy them to the proper folder
  local S_PATH="$1"
  local LIBS= LIB=
  local COMMAND="$(which -- $S_PATH)"
  local LIB_DIR=
  if [ "$COMMAND" == "" ]; then
    COMMAND="$S_PATH"
  fi

  COMMAND="$(readlink -e $COMMAND)"
  if [ "$COMMAND" == "" ]; then
    p_debug "cannot analize $S_PATH using ldd"
    return 0
  fi

  p_info "inspect command $COMMAND"
  ldd "$COMMAND" > /dev/null 2> /dev/null
  if [ $? -eq 0 ]; then
    LIBS="$(ldd "$COMMAND" | grep -v 'linux-vdso' | grep -v 'statically' | sed 's/^[ \t]*//g' | sed 's/^.* => //g' | sed 's/(.*)//' | sed '/^[ ]*$/d')"
    for LIB in $LIBS; do
      # Here we build the ld config file to add the new paths where the libraries are located
      if [ "$LDCONFIGFILE" != "" ]; then
        LIB_DIR="$(dirname "$LIB")"
        mkdir -p "$ROOTFS/$(dirname $LDCONFIGFILE)"
        echo "$LIB_DIR" >> "$ROOTFS/$LDCONFIGFILE"
      fi
      add_command "$LIB"
    done
  fi

  copy "$COMMAND"
}

function analyze_strace_strings() {
  local STRINGS="$1"
  local S _S
  while read S; do
    S="${S:1:-1}"
    if [ "$S" != "!" ]; then
      if [ "$S" != "" -a "${S::1}" != "-" -a -e "$S" ]; then
        _S="$(readlink -e -- ${S})"
        if [ "$_S" != "" -a -e "$_S" ]; then
          if [ -f "$_S" -o -d "$_S" ]; then
            p_debug "file $S was used"
            echo "$S"
          fi
        fi
      fi
    fi
  done <<< "$STRINGS"
}

_ALREADY_STRACED=()

function MARK_straced() {
  local CMD="$@"
  _ALREADY_STRACED+=("$CMD")
}

function already_straced() {
  local i
  local CMD="$@"
  for ((i=0;i<${#_ALREADY_STRACED[@]};i=i+1)); do
    if [ "${_ALREADY_STRACED[$i]}" == "$CMD" ]; then
      return 0
    fi
  done
  return 1
}

function _strace_mode() {
  local MODE="$(plugin_parameter "strace" "mode")"
  local ERR=0
  case "$MODE" in
    loose|regular|slim|skinny|default) 
        ;;
    "") MODE=default;;
    *)  p_error "invalid mode '$MODE' for strace"
        MODE=
        ERR=1;;
  esac
  if [ "$MODE" == "default" ]; then
    MODE=skinny
  fi
  echo "$MODE"
  return $ERR
}

function _strace_copy_folder() {
  local _FILE="$1"
  local _STRACE_EXCLUDED_PATHS='
^//$
^\./$
^\.\./$
^/tmp/$
^/boot/$
^/home/$
^/sys/
^/usr/lib(32|64|)/
^/lib(32|64|)/
^/etc/$
^/var/$
^/proc/$
^/dev/$
^/usr/$
^/bin/$
^/usr/bin/$
^/sbin/$
^/usr/sbin/$
'

  local DN
  if [ -f "$_FILE" ]; then
    DN="$(dirname "$_FILE")/"
  else
    DN="$(realpath -Lsm "$_FILE")/"
  fi

  if [ ! -d "$DN" ]; then
    return 1
  fi

  while read EP; do
    if [ "$EP" != "" ]; then
      if [[ "$DN" =~ $EP ]]; then
        p_debug "excluding ${DN} because it matches pattern ${EP}"
        return 0
      fi
    fi
  done <<< "$_STRACE_EXCLUDED_PATHS"

  p_debug "copying $DN because $_FILE is in it"
  copy "$DN" -r
  return 0
}

function _strace_exec() {  

  if already_straced "${COMMAND[@]}"; then
    p_debug "command ${COMMAND[@]} already straced"
    return
  fi

  MARK_straced "${COMMAND[@]}"

  # Execute the app without any parameter, using strace and see which files does it open 
  local SECONDSSIM=$(plugin_parameter "strace" "seconds")
  if [[ ! $SECONDSSIM =~ ^[0-9]*$ ]]; then
    SECONDSSIM=3
  fi
  if [ "$SECONDSSIM" == "" ]; then
    SECONDSSIM=3
  fi

  local SHOWSTRACE
  SHOWSTRACE=$(plugin_parameter "strace" "showoutput")
  if [ $? -eq 0 ]; then
    if [ "$SHOWSTRACE" == "" ]; then
      SHOWSTRACE=true
    fi
  fi

  local MODE
  MODE="$(_strace_mode)"

  if [ $? -ne 0 ]; then
    finalize 1 "error in strace parameter"
  fi

  p_info "analysing ${COMMAND[@]} using strace and $SECONDSSIM seconds ($MODE)"

  local TMPFILE=$(tempfile)
  if [ "$SHOWSTRACE" == "true" ]; then
    timeout -s 9 $SECONDSSIM strace -qq -e file -fF -o "$TMPFILE" "${COMMAND[@]}"
  else
    {
      timeout -s 9 $SECONDSSIM strace -qq -e file -fF -o "$TMPFILE" "${COMMAND[@]}" > /dev/null 2> /dev/null
    } > /dev/null 2> /dev/null
  fi

  # Now we'll inspect the files that the execution has used
  local EXEC_FUNCTIONS="exec.*"
  local STRINGS
  local L BN DN

  # Add all the folders and files that are used, but analyze libraries or executable files
  #FUNCTIONS="open|mkdir"
  #STRINGS="$(cat "$TMPFILE" | grep -E "($FUNCTIONS)\(" | grep -o '"[^"]*"' | sort -u)"  
  #while read L; do
  #  if [ "$L" != "" ]; then
  #    BN="$(basename $L)"
  #    if [ "${BN::3}" == "lib" -o "${BN: -3}" == ".so" ]; then
  #      add_command "$L"
  #    else
  #      copy "$L" -r
  #    fi
  #  fi
  #done <<< "$(analyze_strace_strings "$STRINGS")"

  # Add all the folders and files that checked to exist (folders are not copied, just may
  # appear in the resulting filesystem, but libraries are analyzed)
  # FUNCTIONS="stat|lstat"

  push_logger "PLAIN"
  STRINGS="$(cat "$TMPFILE" | grep -vE "($EXEC_FUNCTIONS)\(" | grep -o '"[^"]*"' | sort -u)"  
  while read L; do
    if [ "$L" != "" -a "$L" != "/" -a "$L" != "." -a "$L" != ".." ]; then
      if [ -f "$L" ]; then
        BN="$(basename $L)"
        if [ "${BN::3}" == "lib" -o "${BN: -3}" == ".so" ]; then
          add_command "$L"
        else
          copy "$L"
        fi
      else
        copy "$L"
      fi
    fi
  done <<< "$(analyze_strace_strings "$STRINGS")"
  pop_logger

  # If the mode is slim, we'll also copy the whole opened (or created) folders
  if [ "$MODE" == "slim" -o "$MODE" == "regular" -o "$MODE" == "loose" ]; then
    push_logger "OPENDIRS"
    local FUNCTIONS="open|mkdir"
    STRINGS="$(cat "$TMPFILE" | grep -E "($FUNCTIONS)\(" | grep -o '"[^"]*"' | sort -u)"  
    while read L; do
      if [ "$L" != "" ]; then
        if [ -d "$L" ]; then
          copy "$L" -r
        fi
      fi
    done <<< "$(analyze_strace_strings "$STRINGS")"
    pop_logger
  fi

  # If the mode is regular, we'll copy the whole folders used
  if [ "$MODE" == "loose" ]; then
    push_logger "COPYDIRS"
    STRINGS="$(cat "$TMPFILE" | grep -vE "($EXEC_FUNCTIONS)\(" | grep -o '"[^"]*"' | sort -u)"  
    while read L; do
      if [ "$L" != "" ]; then
        if [ -d "$L" ]; then
          _strace_copy_folder "$L"
          # copy "$L" -r
        fi
      fi
    done <<< "$(analyze_strace_strings "$STRINGS")"
    pop_logger
  fi

  # If the mode is slim, we'll also copy the whole opened (or created) folders
  if [ "$MODE" == "regular" -o "$MODE" == "loose" ]; then
    push_logger "DIRSFROMFILES"
    local FUNCTIONS="open"
    STRINGS="$(cat "$TMPFILE" | grep -E "($FUNCTIONS)\(" | grep -o '"[^"]*"' | sort -u)"  
    while read L; do
      if [ "$L" != "" ]; then
        _strace_copy_folder "$L"
      fi
    done <<< "$(analyze_strace_strings "$STRINGS")"
    pop_logger
  fi

  # Add all the executables that have been executed (they are analyzed).
  # FUNCTIONS="exec.*"

  push_logger "EXEC"  
  STRINGS="$(cat "$TMPFILE" | grep -E "($EXEC_FUNCTIONS)\(" | grep -o '"[^"]*"' | sort -u)"  
  while read L; do
    [ "$L" != "" ] && add_command "$L"
  done <<< "$(analyze_strace_strings "$STRINGS")"
  pop_logger

  rm "$TMPFILE"

  copy "${COMMAND[0]}"
}

function PLUGIN_10_strace() {
  # Execute the app without any parameter, using strace and see which files does it open 

  # A file that contains examples of calls for the commands to be considered (e.g. this is because
  # some commands will not perform any operation if they do not have parameters; e.g. echo)
  local EXECFILE=$(plugin_parameter "strace" "execfile")

  local S_PATH="$1"
  local COMMAND="$(which -- $S_PATH)"
  if [ "$COMMAND" == "" ]; then
    p_debug "cannot analize $S_PATH using strace"
    return 0
  fi

  # Let's see if there is a specific commandline (with parameters) for this command in the file
  local CMDTOEXEC CMDLINE=()
  if [ -e "$EXECFILE" ]; then
    local L 
    while read L; do
      CMDTOEXEC=
      arrayze_cmd CMDLINE "$L"
      n=0
      while [ $n -lt ${#CMDLINE[@]} ]; do
        if [ "${CMDLINE[$n]}" == "$COMMAND" ]; then
          CMDTOEXEC="$L"
          break
        fi
        n=$((n+1))
      done
      if [ "$CMDTOEXEC" != "" ]; then
        break
      fi
    done < "$EXECFILE"
  fi

  COMMAND=($COMMAND)

  # If there is a specific commandline, we'll use it; otherwise we'll run the command as-is
  if [ "$CMDTOEXEC" != "" ]; then
    p_debug "will run $CMDTOEXEC"
    COMMAND=( ${CMDLINE[@]} )
  fi

  _strace_exec
}

function STRACE_command() {
  local CMDLINE=()
  local COMMAND

  push_logger "STRACE"

  arrayze_cmd CMDLINE "$1"
  local _PLUGINS_ACTIVATED="${PLUGINS_ACTIVATED}"

  if [ "${CMDLINE[0]}" != "" ]; then
    local S_PATH="${CMDLINE[0]}"
    local OPTIONS="${S_PATH%,*}"
    local N_PATH="${S_PATH##*,}"

    if [ "$N_PATH" != "" -a "$OPTIONS" != "" ]; then
      # Remove the possible leading spaces before the options
      OPTIONS="$(trim "$OPTIONS")"
      p_info "specific options to strace: $OPTIONS"
      PLUGINS_ACTIVATED="${PLUGINS_ACTIVATED},strace:${OPTIONS}"
      S_PATH="$N_PATH"
    fi

    COMMAND="$(which -- $S_PATH)"
    if [ "$COMMAND" == "" ]; then
      p_debug "cannot analize $S_PATH using strace"
      pop_logger
      return 0
    fi
    CMDLINE[0]="$COMMAND"
  fi
  COMMAND=( "${CMDLINE[@]}" )
  _strace_exec

  PLUGINS_ACTIVATED="${_PLUGINS_ACTIVATED}"

  pop_logger
}

function PLUGIN_11_scripts() {
  # Checks the output of the invocation to the "file" command and guess whether it is a interpreted script or not
  #  If it is, adds the interpreter to the list of commands to add to the container
  p_debug "trying to guess if $1 is a interpreted script"

  local INCLUDEFOLDERS
  INCLUDEFOLDERS=$(plugin_parameter "scripts" "includefolders")
  if [ $? -eq 0 ]; then
    if [ "$INCLUDEFOLDERS" == "" ]; then
      INCLUDEFOLDERS=true
    fi
  else
    # The default value is to include the folders that the interpreter may use
    INCLUDEFOLDERS=false
  fi

  local S_PATH="$(which $1)"
  local ADD_PATHS=

  if [ "$S_PATH" == "" -o ! -x "$S_PATH" ]; then
    p_debug "$1 cannot be executed (if it should, please check the path)"
    return 0
  fi

  local FILE_RES="$(file $S_PATH | grep -o ':.* script')"
  if [ "$FILE_RES" == "" ]; then
    p_debug "$S_PATH is not recognised as a executable script"
    return 0
  fi

  FILE_RES="${FILE_RES:2:-7}"
  FILE_RES="${FILE_RES,,}"
  local SHELL_EXEC=
  local SHBANG_LINE=$(cat $S_PATH | sed '/^#!.*/q' | tail -n 1 | sed 's/^#![ ]*//')
  local INTERPRETER="${SHBANG_LINE%% *}"
  ADD_PATHS="$INTERPRETER"
  local ENV_APP=
  if [ "$(basename $INTERPRETER)" == "env" ]; then
    ADD_PATHS="$INTERPRETER"
    ENV_APP="${SHBANG_LINE#* }" # This is in case there are parameters for the interpreter e.g. #!/usr/bin/env bash -c
    ENV_APP="${ENV_APP%% *}"
    local W_ENV_APP="$(which "$ENV_APP")"
    if [ "$W_ENV_APP" != "" ]; then
      ENV_APP="$W_ENV_APP"
    fi
  fi

  case "$(basename "$INTERPRETER")" in
    perl) ;;
    python) ;;
    bash) ;;
    sh) ;;
    env)  ADD_PATHS="${ADD_PATHS}
${ENV_APP}";;
    *)    p_warning "interpreter $INTERPRETER not recognised"
          return 0;;
  esac

  # If we want to include the 'include' folders of the scripts (to also include libraries), let's get them
  if [ "$INCLUDEFOLDERS" == "true" ]; then
    case "$(basename "$INTERPRETER")" in
      perl) ADD_PATHS="${ADD_PATHS}
$(perl -e "print qq(@INC)" | tr ' ' '\n' | grep -v -e '^/home' -e '^\.')";;
      python) ADD_PATHS="${ADD_PATHS}
$(python -c 'import sys;print "\n".join(sys.path)' | grep -v -e '^/home' -e '^\.')";;
    esac
  fi

  if [ "$ADD_PATHS" != "" ]; then
    p_debug "found that $S_PATH needs $ADD_PATHS"
    local P
    while read P; do
      [ "$P" != "" ] && add_command "$P"
    done <<< "$ADD_PATHS"
  fi
  return 0
}

function PLUGIN_funcs() {
  # Gets the list of plugins available for the app (those functions named PLUGIN_xxx_<plugin name>)
  echo "$(typeset -F | grep PLUGIN_ | awk '{print $3}' | grep -v 'PLUGIN_funcs')"
}

function plugin_list() {
  local P
  while read P; do
    echo -n "${P##*_},"
  done <<< "$(PLUGIN_funcs)"
  echo
}