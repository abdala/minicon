function generate_dockerimagename() {
  local NEWNAME
  NEWNAME="$(cat /proc/sys/kernel/random/uuid)"
  NEWNAME="${NEWNAME%%-*}"
  echo "$NEWNAME"
}

function correct_dockerimagename() {
  local IMNAME="$1"
  local BASE TAG

  # Correct NEWNAME
  IFS=':' read BASE TAG <<< "${IMNAME}"
  if [ "$TAG" == "" ]; then
    IMNAME="${IMNAME}:latest"
  fi
  echo "$IMNAME"
}

_INSPECT_STRING=
_INSPECT_IMAGE=
function get_config_field() {
  local IMAGE="$1"
  local FIELD="$2"
  local RAW_JQ="$3"
  local C_RESULT

  if [ "$_INSPECT_IMAGE" != "$IMAGE" ]; then
    _INSPECT_STRING="$(docker inspect $IMAGE)"
    _INSPECT_IMAGE="$IMAGE"
  fi

  C_RESULT="$(echo "$_INSPECT_STRING" | jq -r "if .[].Config.${FIELD} != null then if .[].Config.${FIELD}${RAW_JQ} | type == \"array\" then .[].Config.${FIELD}${RAW_JQ} | .[] else .[].Config.${FIELD}${RAW_JQ} end else null end")"
  echo "$(trim "$C_RESULT")"
}

function get_config_field_raw() {
  local IMAGE="$1"
  local FIELD="$2"
  local RAW_JQ="$3"
  local C_RESULT

  if [ "$_INSPECT_IMAGE" != "$IMAGE" ]; then
    _INSPECT_STRING="$(docker inspect $IMAGE)"
    _INSPECT_IMAGE="$IMAGE"
  fi

  C_RESULT="$(echo "$_INSPECT_STRING" | jq -r "if .[].Config.${FIELD} != null then .[].Config.${FIELD}${RAW_JQ} else null end")"
  echo "$(trim "$C_RESULT")"
}
