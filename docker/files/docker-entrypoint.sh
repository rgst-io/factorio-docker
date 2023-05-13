#!/bin/bash
set -eoux pipefail

FACTORIO_VOL=/factorio
LOAD_LATEST_SAVE="${LOAD_LATEST_SAVE:-true}"
GENERATE_NEW_SAVE="${GENERATE_NEW_SAVE:-false}"
SAVE_NAME="${SAVE_NAME:-""}"
BIND="${BIND:-""}"
CONSOLE_LOG_LOCATION="${CONSOLE_LOG_LOCATION:-""}"
BINARY="/opt/factorio/bin/x64/factorio"

# FactoCord configuration
FACTOCORD_DISCORD_CHANNEL_ID="${FACTOCORD_DISCORD_CHANNEL_ID:-""}"
FACTOCORD_DISCORD_TOKEN="${FACTOCORD_DISCORD_TOKEN:-""}"
FACTOCORD_DISCORD_USER_COLORS="${FACTOCORD_DISCORD_USER_COLORS:-""}"

mkdir -p "$FACTORIO_VOL"
mkdir -p "$SAVES"
mkdir -p "$CONFIG"
mkdir -p "$MODS"
mkdir -p "$SCENARIOS"
mkdir -p "$SCRIPTOUTPUT"

if [[ ! -f $CONFIG/rconpw ]]; then
  # Generate a new RCON password if none exists
  pwgen 15 1 >"$CONFIG/rconpw"
fi

if [[ ! -f $CONFIG/server-settings.json ]]; then
  # Copy default settings if server-settings.json doesn't exist
  cp /opt/factorio/data/server-settings.example.json "$CONFIG/server-settings.json"
fi

if [[ ! -f $CONFIG/map-gen-settings.json ]]; then
  cp /opt/factorio/data/map-gen-settings.example.json "$CONFIG/map-gen-settings.json"
fi

if [[ ! -f $CONFIG/map-settings.json ]]; then
  cp /opt/factorio/data/map-settings.example.json "$CONFIG/map-settings.json"
fi

NRTMPSAVES=$(find -L "$SAVES" -iname \*.tmp.zip -mindepth 1 | wc -l)
if [[ $NRTMPSAVES -gt 0 ]]; then
  # Delete incomplete saves (such as after a forced exit)
  rm -f "$SAVES"/*.tmp.zip
fi

if [[ ${UPDATE_MODS_ON_START:-} == "true" ]]; then
  ./docker-update-mods.sh
fi

if [[ $(id -u) = 0 ]]; then
  # Update the User and Group ID based on the PUID/PGID variables
  usermod -o -u "$PUID" factorio
  groupmod -o -g "$PGID" factorio
  # Take ownership of factorio data if running as root
  chown -R factorio:factorio "$FACTORIO_VOL"
  # Drop to the factorio user
  SU_EXEC="su-exec factorio"
else
  SU_EXEC=""
fi

sed -i '/write-data=/c\write-data=\/factorio/' /opt/factorio/config/config.ini

NRSAVES=$(find -L "$SAVES" -iname \*.zip -mindepth 1 | wc -l)
if [[ $GENERATE_NEW_SAVE != true && $NRSAVES == 0 ]]; then
  GENERATE_NEW_SAVE=true
  SAVE_NAME=_autosave1
fi

if [[ $GENERATE_NEW_SAVE == true ]]; then
  if [[ -z "$SAVE_NAME" ]]; then
    echo "If \$GENERATE_NEW_SAVE is true, you must specify \$SAVE_NAME"
    exit 1
  fi
  if [[ -f "$SAVES/$SAVE_NAME.zip" ]]; then
    echo "Map $SAVES/$SAVE_NAME.zip already exists, skipping map generation"
  else
    $SU_EXEC "$BINARY" \
      --create "$SAVES/$SAVE_NAME.zip" \
      --map-gen-settings "$CONFIG/map-gen-settings.json" \
      --map-settings "$CONFIG/map-settings.json"
  fi
fi

FLAGS=(
  --port "$PORT"
  --server-settings "$CONFIG/server-settings.json"
  --server-banlist "$CONFIG/server-banlist.json"
  --rcon-port "$RCON_PORT"
  --server-whitelist "$CONFIG/server-whitelist.json"
  --use-server-whitelist
  --server-adminlist "$CONFIG/server-adminlist.json"
  --rcon-password "$(cat "$CONFIG/rconpw")"
  --server-id /factorio/config/server-id.json
)

if [ -n "$CONSOLE_LOG_LOCATION" ]; then
  FLAGS+=(--console-log "$CONSOLE_LOG_LOCATION")
fi

if [ -n "$BIND" ]; then
  FLAGS+=(--bind "$BIND")
fi

if [[ $LOAD_LATEST_SAVE == true ]]; then
  FLAGS+=(--start-server-load-latest)
else
  FLAGS+=(--start-server "$SAVE_NAME")
fi

# typeofvar returns the type of a variable
# Source: https://gist.github.com/CMCDragonkai/f1ed5e0676e53945429b
typeofvar() {
  local type_signature=$(declare -p "$1" 2>&1)

  if [[ "$type_signature" =~ "declare --" ]]; then
    printf "string"
  elif [[ "$type_signature" =~ "declare -a" ]]; then
    printf "array"
  elif [[ "$type_signature" =~ "declare -A" ]]; then
    printf "map"
  else
    echo "Unknown type of $1: $type_signature" >&2
    printf "none"
  fi
}

# replace_factocord_config_opt replaces the specified field in the Factocord
# configuration file with the specified value.
#
# This function converts all values to be JSON-compatible for handling arrays.
replace_factocord_config_opt() {
  local field="$1"
  shift

  # Attempt to determine if we're processing an array or not and set
  # the value accordingly.
  if [[ $# -ne 1 ]]; then
    local value=("$@")
  else
    local value="$1"
  fi

  local argumentType="arg"
  local tmpFile="$(mktemp)"

  echo "Setting $field (type $(typeofvar "value"))"

  # If we're processing an array, we need to convert it to JSON
  # to properly order the values.
  if [[ "$(typeofvar "value")" == "array" ]]; then
    argumentType="argjson"
    value=$(jq --compact-output --null-input '$ARGS.positional' --args -- "${value[@]}")
  elif [[ "$value" == "true" ]] || [[ "$value" == "false" ]]; then
    # If we're processing a boolean, we need to treat the value as JSON.
    argumentType="argjson"
  fi

  jq --arg field "$field" --"$argumentType" value "$value" '.[$field] = $value' "$FACTOCORD_CONFIG_PATH" >"$tmpFile"
  mv "$tmpFile" "$FACTOCORD_CONFIG_PATH"
}

if [[ "$FACTOCORD_ENABLED" == "true" ]]; then
  FACTOCORD_CONFIG_PATH="$FACTORIO_VOL/config.json"
  if [[ ! -e "$FACTOCORD_CONFIG_PATH" ]]; then
    # Create the config file
    echo "Creating Factocord config file..." >&2
    wget -qO "$FACTOCORD_CONFIG_PATH" https://github.com/maxsupermanhd/FactoCord-3.0/raw/master/config-example.json5
  fi

  # We need to convert it from json5 into JSON so we can
  # use jq to manipulate it later.
  hjson-cli -j "$FACTOCORD_CONFIG_PATH" >"$FACTOCORD_CONFIG_PATH.tmp"
  mv "$FACTOCORD_CONFIG_PATH.tmp" "$FACTOCORD_CONFIG_PATH"

  # Set variables to make it work with our environment
  replace_factocord_config_opt "executable" "$BINARY"
  replace_factocord_config_opt "launch_parameters" "${FLAGS[@]}"

  # Environment variables that we support passing through to the configuration.
  if [[ -n "$FACTOCORD_DISCORD_TOKEN" ]]; then
    replace_factocord_config_opt "discord_token" "$FACTOCORD_DISCORD_TOKEN"
  fi
  if [[ -n "$FACTOCORD_DISCORD_CHANNEL_ID" ]]; then
    replace_factocord_config_opt "factorio_channel_id" "$FACTOCORD_DISCORD_CHANNEL_ID"
  fi
  if [[ -n $FACTOCORD_DISCORD_USER_COLORS ]]; then
    replace_factocord_config_opt "discord_user_colors" "$FACTOCORD_DISCORD_USER_COLORS"
  fi

  # Ensure permissions are correct
  chown factorio:factorio "$FACTOCORD_CONFIG_PATH"
  chmod 600 "$FACTOCORD_CONFIG_PATH"

  echo "Modified Factocord config:" >&2
  cat "$FACTOCORD_CONFIG_PATH" >&2

  echo "Starting Factorio through Factocord3..." >&2
  cd "$FACTORIO_VOL"
  exec $SU_EXEC FactoCord-3.0 "$@"
fi

# shellcheck disable=SC2086
exec $SU_EXEC "$BINARY" "${FLAGS[@]}" "$@"
