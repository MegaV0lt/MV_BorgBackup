#!/bin/bash

# Disable or enable suspend

# Schema                                    # Key
#org.gnome.settings-daemon.plugins.power    sleep-inactive-ac-timeout
#org.gnome.settings-daemon.plugins.power    sleep-inactive-battery-timeout
#org.cinnamon.settings-daemon.plugins.power sleep-inactive-ac-timeout
#org.cinnamon.settings-daemon.plugins.power sleep-inactive-battery-timeout

SCHEMA='org.cinnamon.settings-daemon.plugins.power'  # Cinnamon
KEY_AC='sleep-inactive-ac-timeout'
KEY_BAT='sleep-inactive-battery-timeout'

# Interne Variablen
SELF="$(readlink /proc/$$/fd/255)" || SELF="$0"  # Eigener Pfad (besseres $0)
key_ac="${SELF%.*}.key_ac"                       # Datei zum speichern des Wertes
key_bat="${SELF%.*}.key_bat"

# Exit bei Fehler!
set -e

case "${1^^}" in
  ENABLE|ON) # Alte Werte wieder herstellen
    if [[ -e "$key_ac" && -e "$key_bat" ]] ; then
      read -r ac < "$key_ac" ; read -r bat < "$key_bat"
      gsettings set "$SCHEMA" "$KEY_AC" "$ac" && rm "$key_ac"
      gsettings set "$SCHEMA" "$KEY_BAT" "$bat"  && rm "$key_bat"
      echo "Werte für Bereitschaft wieder hergestellt (${ac} ${bat})."
    fi
  ;;
  DISABLE|OFF) # Aktuelle Einstellungen speichern
    if [[ ! -e "$key_ac" && ! -e "$key_bat" ]] ; then
      gsettings get "$SCHEMA" "$KEY_AC" > "$key_ac"
      gsettings get "$SCHEMA" "$KEY_BAT" > "$key_bat"
      # Bereitschft deaktivieren
      gsettings set "$SCHEMA" "$KEY_AC" 0
      gsettings set "$SCHEMA" "$KEY_BAT" 0
      echo "Bereitschaft deaktiviert. Alte Werte gespeichert."
    fi
  ;;
  *) echo "Unbekannte Option! Erlaubt sind: enable, on, diasble, off"
  ;;
esac
