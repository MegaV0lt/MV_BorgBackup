#!/usr/bin/env bash
# = = = = = = = = = = = =  MV_BorgBackup.sh - Borg BACKUP  = = = = = = = = = = = = = =  #
#                                                                                       #
# Author: MegaV0lt                                                                      #
# Forum: http://j.mp/1TblNNj                                                            #
# GIT: https://github.com/MegaV0lt/MV_BorgBackup                                        #
#                                                                                       #
# Alle Anpassungen zum Skript, kann man in der HISTORY und in der .conf nachlesen. Wer  #
# sich erkenntlich zeigen möchte, kann mir gerne einen kleinen Betrag zukommen lassen:  #
# => https://paypal.me/SteBlo <= Der Betrag kann frei gewählt werden.                   #
#                                                                                       #
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
VERSION=250601

# Dieses Skript sichert / synchronisiert Verzeichnisse mit borg.
# Dabei können beliebig viele Profile konfiguriert oder die Pfade direkt an das Skript übergeben werden.
# Eine kurze Anleitung kann mit der Option -h aufgerufen werden.

# Sämtliche Einstellungen werden in der *.conf vorgenommen.
# ---> Bitte ab hier nichts mehr ändern! <---
if ((BASH_VERSINFO[0] < 4)) ; then  # Test, ob min. Bash Version 4.0
  echo 'Sorry, dieses Skript benötigt Bash Version 4.0 oder neuer!' >&2 ; exit 1
fi

# Skriptausgaben zusätzlich in Datei speichern. (DEBUG)
# exec > >(tee -a /var/log/MV_BorgBackup.log) 2>&1

# --- INTERNE VARIABLEN ---
SELF="$(readlink /proc/$$/fd/255)" || SELF="$0"  # Eigener Pfad (besseres $0)
SELF_NAME="${SELF##*/}"                          # skript.sh
TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/${SELF_NAME%.*}.XXXX")"  # Ordner für temporäre Dateien
declare -a BORG_CREATE_OPT BORGPROF BORGRC BORG_VERSION ERRLOGS LOGFILES
declare -a SSH_ERRLOG SSH_LOG SSH_TARGET UNMOUNT  # Einige Array's
declare -A _arg _target
msgERR='\e[1;41m FEHLER! \e[0;1m' ; nc="\e[0m"  # Anzeige "FEHLER!" ; Reset der Farben
msgINF='\e[42m \e[0m' ; msgWRN='\e[103m \e[0m'  # " " mit grünem/gelben Hintergrund

# --- FUNKTIONEN ---
trap 'f_exit 3' SIGHUP SIGINT SIGQUIT SIGABRT  # Bei unerwarteten Ende (Strg-C) aufräumen
set -o errtrace  # ERR Trap auch in Funktionen

f_errtrap() {  # ERR-Trap mit "ON" aktivieren, ansonsten nur ins ERRLOG
  if [[ "${1^^}" == 'ON' ]] ; then
    trap 'f_exit 2 "$BASH_COMMAND" "$LINENO" ${FUNCNAME:-$BASH_SOURCE} $?' ERR  # Bei Fehlern und nicht gefundenen Programmen
  else  # ERR-Trap nur loggen
    trap 'echo "=> Info (Fehler $?) in Zeile $LINENO (${FUNCNAME:-$BASH_SOURCE}): $BASH_COMMAND" >> "${ERRLOG:-/tmp/${SELF_NAME%.*}.log}"' ERR
  fi
}

f_exit() {  # Beenden und aufräumen $1 = ExitCode
  local EXIT="${1:-0}"  # Wenn leer, dann 0
  if [[ "$EXIT" -eq 3 ]] ; then  # Strg-C
    echo -e "\n=> Aufräumen und beenden [$$]"
    [[ -n "$POST_ACTION" ]] && echo 'Achtung: POST_ACTION wird nicht ausgeführt!'
    [[ -n "$MAILADRESS" ]] && echo 'Achtung: Es erfolgt kein eMail-Versand!'
  fi
  [[ "$EXIT" -eq 2 ]] && echo -e "$msgERR (${5:-x}) in Zeile $3 ($4):${nc}\n$2\n" >&2
  if [[ "$EXIT" -ge 1 ]] ; then
    set -o posix ; set  > "/tmp/${SELF_NAME%.*}.env"  # Variablen speichern
    echo -e "$msgINF Skript- und Umgebungsvariablen wurden in \"/tmp/${SELF_NAME%.*}.env\" gespeichert!"
    [[ $EUID -ne 0 ]] && echo -e "$msgWRN Skript ohne root-Rechte gestartet!"
  fi
  [[ -n "${exfrom[*]}" ]] && rm "${exfrom[@]}" &>/dev/null
  [[ -d "$TMPDIR" ]] && rm --recursive --force "$TMPDIR" &>/dev/null  # Ordner für temporäre Dateien
  [[ -n "$MFS_PID" ]] && f_mfs_kill  # Hintergrundüberwachung beenden
  [[ "$EXIT" -ne 4 && -e "$PIDFILE" ]] && rm --force "$PIDFILE" &>/dev/null  # PID-Datei entfernen
  exit "$EXIT"
}

f_mfs_kill() {  # Beenden der Hintergrundüberwachung
  echo -e "$msgINF Beende Hintergrundüberwachung…"
  kill "$MFS_PID" &>/dev/null  # Hintergrundüberwachung beenden
  if ps --pid "$MFS_PID" &>/dev/null ; then  # Noch aktiv!
    echo '!> Hintergrundüberwachung konnte nicht beendet werden! Versuche erneut…'
    kill -9 "$MFS_PID" &>/dev/null  # Hintergrundüberwachung beenden
  else
    unset -v 'MFS_PID'
  fi
}

f_remove_slash() {  # "/" am Ende entfernen. $1=Variablenname ohne $
  local -n ptr="$1"  # This uses local namerefs to avoid using command substitution for function output capture
  [[ ${#ptr} -ge 2 && "${ptr: -1}" == '/' ]] && ptr="${ptr%/}"
}

# Wird in der Konsole angezeigt, wenn eine Option nicht angegeben oder definiert wurde
f_help() {
  echo -e "\e[44m \e[0;1m MV_BorgBackup${nc}\e[0;32m => Version: ${VERSION}${nc} by MegaV0lt"
  echo -e "Aufruf: \e[1m$0 \e[34m-p${nc} \e[1;36mARGUMENT${nc} [\e[1;34m-p${nc} \e[1;36mARGUMENT${nc}]"
  echo -e "        \e[1m$0 \e[34m-m${nc} \e[1;36mQUELLE(n)${nc} \e[1;36mZIEL${nc}"
  echo
  echo -e "\e[37;100m Erforderlich $nc"
  if [[ -n "$CONFLOADED" ]] ; then
    for i in "${!arg[@]}" ; do
      echo -e "  \e[1;34m-p${nc} \e[1;36m${arg[i]}${nc}\tProfil \"${title[i]}\""
    done
  else
    echo -e "  \e[1;34m-p${nc} \e[1;36mx${nc}\tProfil (arg[nr]=)"
  fi  # CONFLOADED
  echo -e " oder\n  \e[1;34m-a${nc}\tAlle Sicherungs-Profile"
  echo -e " oder\n  \e[1;34m-m${nc}\tVerzeichnisse manuell angeben"
  echo
  echo -e "\e[37;100m Optional $nc"
  echo -e "  \e[1;34m-c${nc} \e[1;36mBeispiel.conf${nc} Konfigurationsdatei angeben (Pfad und Name)"
  echo -e "  \e[1;34m-e${nc} \e[1;36mmy@email.de${nc}   Sendet eMail inkl. angehängten Log(s)"
  echo -e "  \e[1;34m-f${nc}    eMail nur senden, wenn Fehler auftreten (-e muss angegeben werden)"
  echo -e "  \e[1;34m-d${nc} \e[1;36mx${nc}  Logdateien die älter als x Tage sind löschen (Vorgabe 30)"
  echo -e "  \e[1;34m-s${nc}    Nach Beendigung automatisch herunterfahren (benötigt u. U. Root-Rechte)"
  echo -e "  \e[1;34m-h${nc}    Hilfe anzeigen"
  echo
  echo -e "\e[37;100m Beispiele ${nc}"
  echo -e "  \e[32mProfil \"${title[2]:-x}\"${nc} starten und den Computer anschließend \e[31mherunterfahren${nc}:"
  echo -e "\t$0 \e[32m-p${arg[2]:-x}${nc} \e[31m-s${nc}\n"
  echo -e "  \e[33m\"/tmp/Quelle1/\"${nc} und \e[35m\"/Leer zeichen2/\"${nc} in \e[36m\"/media/extern\"${nc} sichern;\n  anschließend \e[31mherunterfahren${nc}:"
  echo -e "\t$0 \e[31m-s\e[0;4mm${nc} \e[33m/tmp/Quelle1${nc} \e[4m\"\e[0;35m/Leer zeichen2\e[0;4m\"${nc} \e[36m/media/extern${nc}"
  f_exit 1
}

# === INPUT VALIDATION AND SANITIZATION FUNCTIONS ===
f_validate_path() {
    local path="$1" path_type="${2:-general}" max_length="${3:-4096}"
    
    # Eingabewert prüfen
    [[ -z "$path" ]] && { echo "Kein Pfad angegeben" >&2; return 1; }
    [[ ${#path} -gt $max_length ]] && { echo "Pfad zu lang (>${max_length} Zeichen)" >&2; return 1; }
    
    # Sicherheitsüberprüfungen - Verhindern von Pfad-Traversierung und gefährlichen Mustern
    if [[ "$path" =~ \.\./|/\.\./|^\.\./|/\.\.$ ]]; then
        echo "Pfad traversiert: $path" >&2
        return 1
    fi
    
    # Überprüfung auf Steuerzeichen und gefährliche Sequenzen
    if [[ "$path" =~ [[:cntrl:]] || "$path" =~ [\$\\\`\;\|\&\<\>] ]]; then
        echo "Gefährliche Zeichen in Pfad: $path" >&2
        return 1
    fi
    
    # Typspezifische Überprüfung
    case "$path_type" in
        source)
            [[ -d "$path" || -f "$path" ]] || { echo "Quellverzeichnis nicht gefunden: $path" >&2; return 1; }
            [[ -r "$path" ]] || { echo "Quellverzeichnis nicht lesbar: $path" >&2; return 1; }
            ;;
        target)
            local parent_dir="${path%/*}"
            [[ -d "$parent_dir" ]] || { echo "Zielverzeichnis nicht gefunden: $parent_dir" >&2; return 1; }
            [[ -w "$parent_dir" ]] || { echo "Zielverzeichnis nicht beschreibbar: $parent_dir" >&2; return 1; }
            ;;
        config)
            [[ -f "$path" ]] || { echo "Konfigurationsdatei nicht gefunden: $path" >&2; return 1; }
            [[ -r "$path" ]] || { echo "Konfigurationsdatei nicht lesbar: $path" >&2; return 1; }
            ;;
        ssh)
            # SSH Pfad Format: user@host:/path
            if [[ "$path" =~ ^[a-zA-Z0-9._-]+@[a-zA-Z0-9.-]+:[/a-zA-Z0-9._/-]+$ ]]; then
                return 0
            else
                echo "Ungültiger SSH-Pfad: $path" >&2
                return 1
            fi
            ;;
    esac
    
    return 0
}

f_validate_email() {
    local email="$1"
    
    [[ -z "$email" ]] && { echo "Keine eMail angegeben" >&2; return 1; }    
    # Basic email validation (RFC 5322 simplified)
    if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
      return 0
    else
      echo "Ungültige eMail: $email" >&2
      return 1
    fi
}

f_validate_numeric() {
    local value="$1" min="${2:-0}" max="${3:-2147483647}" name="${4:-value}"
    
    [[ -z "$value" ]] && { echo "Leere $name übergeben" >&2; return 1; }    
    # Check if it's a valid integer
    if [[ "$value" =~ ^[0-9]+$ ]]; then
      if [[ $value -ge $min && $value -le $max ]]; then
        return 0
      else
        echo "$name ausserhalb des erlaubten Bereichs ($min-$max): $value" >&2
        return 1
      fi
    else
      echo "Ungültiger Wert für $name: $value" >&2
      return 1
    fi
}

f_sanitize_filename() {
    local filename="$1" max_length="${2:-255}"
    
    filename="${filename//[^a-zA-Z0-9._-]/_}"  # Remove/replace dangerous characters
    # Ensure it doesn't start with dot or dash
    [[ "$filename" =~ ^[.-] ]] && filename="safe_${filename}"
    # Truncate if too long
    [[ ${#filename} -gt $max_length ]] && filename="${filename:0:$max_length}"
    
    echo "$filename"
}

f_validate_profile_name() {
    local profile="$1"
    
    [[ -z "$profile" ]] && { echo "Leere Profilbezeichnung" >&2; return 1; }
    [[ ${#profile} -gt 64 ]] && { echo "Profilname zu lang (64 Zeichen)" >&2; return 1; }
    # Only allow POSIX-compatible characters
    if [[ "$profile" =~ ^[a-zA-Z0-9._-]+$ ]]; then
      return 0
    else
      echo "Ungültige Profilbezeichnung: $profile" >&2
      return 1
    fi
}

f_validate_profile_config() {  # Prüfen, ob die Konfiguration gültig ist
  local notset="\e[1;41m -LEER- $nc"  # Anzeige, wenn nicht gesetzt
  if [[ -n "$TITLE" ]]; then  # Sanitize title name
      TITLE="$(f_sanitize_filename "$TITLE" 64)"  # Max. 64 Zeichen
  fi
  if [[ -n "${SOURCE[*]}" ]]; then
    for src in "${SOURCE[@]}"; do
      if ! f_validate_path "$src" "source"; then
        echo -e "$msgERR Ungültiger Quellpfad in Profil $PROFIL${nc}" >&2
        f_exit 1
      fi
    done
  fi
  if [[ -n "$TARGET" ]]; then
    # Determine target type (local or SSH)
    if [[ "$TARGET" =~ '@' ]]; then
      if ! f_validate_path "$TARGET" "ssh"; then
        echo -e "$msgERR Ungültiger SSH-Pfad in Profil $PROFIL${nc}" >&2
        f_exit 1
      fi
    else
      if ! f_validate_path "$TARGET" "target"; then
        echo -e "$msgERR Ungültiges Zielverzeichnis in Profil $PROFIL${nc}" >&2
        f_exit 1
      fi
    fi
  fi
  if [[ -n "$MINFREE" ]]; then
    if ! f_validate_numeric "$MINFREE" 0 999999999 "MINFREE"; then
      echo -e "$msgERR Ungültiger MINFREE-Wert in Profil $PROFIL${nc}" >&2
      f_exit 1
    fi
  fi
  if [[ -n "$MINFREE_BG" ]]; then
    if ! f_validate_numeric "$MINFREE_BG" 0 999999999 "MINFREE_BG"; then
      echo -e "$msgERR Ungültiger MINFREE_BG-Wert in Profil $PROFIL${nc}" >&2
      f_exit 1
    fi
  fi
  if [[ -z "${SOURCE[*]}" || -z "$TARGET" ]] ; then
    echo -e "$msgERR Quelle und/oder Ziel sind nicht konfiguriert!${nc}" >&2
    echo -e " Profil:    \"${TITLE:-$notset}\"\n Parameter: \"${ARG:-$notset}\" (Nummer: $i)"
    echo -e " Quelle:    \"${SOURCE[*]:-$notset}\"\n Ziel:      \"${TARGET:-$notset}\"" ; f_exit 1
  fi
  if [[ -n "$FTPSRC" && -z "$FTPMNT" ]] ; then
    echo -e "$msgERR FTP-Quelle und Einhängepunkt falsch konfiguriert!${nc}" >&2
    echo -e " Profil:        \"${TITLE:-$notset}\"\n Parameter:     \"${ARG:-$notset}\" (Nummer: $i)"
    echo -e " FTP-Quelle:    \"${FTPSRC:-$notset}\"\n Einhängepunkt: \"${FTPMNT:-$notset}\"" ; f_exit 1
  fi
  if [[ -n "$MINFREE" && -n "$MINFREE_BG" ]] ; then
    echo -e "$msgERR minfree und minfree_bg sind gesetzt! Bitte nur einen Wert verwenden!${nc}" >&2
    echo -e " Profil:     \"${TITLE:-$notset}\"\n Parameter:  \"${ARG:-$notset}\" (Nummer: $i)"
    echo -e " MINFREE:    \"${MINFREE:-$notset}\"\n MINFREE_BG: \"${MINFREE_BG:-$notset}\"" ; f_exit 1
  fi

}

f_setup_ssh_targets() {  # SSH-Quellen und -Ziele einrichten
  unset -v 'SSH_TARGET' 'SSH_LOG'
  if [[ "$TARGET" =~ '@' ]] ; then
    SSH_TARGET[0]="${TARGET##*//}"        # ohne 'ssh://'
    SSH_TARGET[1]="${SSH_TARGET[0]%%/*}"  # Pfade abschneiden (user@host[:port])
    SSH_TARGET[2]="/${SSH_TARGET[0]#*/}/${FILES_DIR}"  # Pfad zum Repository
    SSH_TARGET[3]="${SSH_TARGET[1]#*:}"   # Port
  fi
  if [[ "$LOG" =~ '@' ]] ; then
    SSH_LOG[0]="${LOG##*//}" ; SSH_ERRLOG[0]="${ERRLOG##*//}"              # ohne 'ssh://'
    SSH_LOG[1]="${SSH_LOG[0]%%/*}" ; SSH_ERRLOG[1]="${SSH_ERRLOG[0]%%/*}"  # Pfade abschneiden (user@host[:port])
    SSH_LOG[2]="/${SSH_LOG[0]#*/}" ; SSH_ERRLOG[2]="/${SSH_ERRLOG[0]#*/}"  # Pfad zum Log
    SSH_LOG[3]="${SSH_LOG[1]#*:}" ; SSH_ERRLOG[3]="${SSH_ERRLOG[1]#*:}"    # Port
	  LOG="${TMPDIR}/${LOG##*/}" ; ERRLOG="${TMPDIR}/${ERRLOG##*/}"
  fi
}

f_configure_profile_defaults() {  # Standardwerte setzen
  : "${TITLE:=Profil_${ARG}}"  # Wenn Leer, dann Profil_ gefolgt von Parameter
  : "${LOG:=${TMPDIR}/${SELF_NAME%.*}_${DT_NOW}.log}"  # Temporäre Logdatei
  ERRLOG="${LOG%.*}.err.log"                 # Fehlerlog im Logverzeichnis der Sicherung
  if [[ "${BORG_VERSION[1]}" -ge 2 ]] ; then
    : "${FILES_DIR:=borg2_repository}"       # Vorgabe für Sicherungsordner
    : "${ARCHIV:=${TITLE}}"                  # Vorgabe für Archivname (Borg 2.x)
  else
    : "${FILES_DIR:=borg_repository}"        # Vorgabe für Sicherungsordner (Borg 1.x)
    : "${ARCHIV:="${TITLE}_{now:%Y-%m-%d_%H:%M}"}"  # Vorgabe für Archivname (Borg)
  fi
}

f_settings() {
  if [[ "$PROFIL" != 'customBak' ]] ; then
    # Validate profile name first
    if ! f_validate_profile_name "$PROFIL"; then
      echo -e "$msgERR Ungültiger Profilname: $PROFIL${nc}" >&2
      f_exit 1
    fi
    # Benötigte Werte aus dem Array (.conf) holen
    for i in "${!arg[@]}" ; do  # Anzahl der vorhandenen Profile ermitteln
      if [[ "${arg[i]}" == "$PROFIL" ]] ; then  # Wenn das gewünschte Profil gefunden wurde
        # BORG_CREATE_OPT und MOUNT wieder herstelen
        if [[ -n "${_BORG_CREATE_OPT[*]}" ]] ; then
          read -r -a BORG_CREATE_OPT <<< "${_BORG_CREATE_OPT[@]}" ; unset -v '_BORG_CREATE_OPT'
        fi
        [[ -n "$_MOUNT" ]] && { MOUNT="$_MOUNT" ; unset -v '_MOUNT' ;}
        [[ "$MOUNT" == '0' ]] && unset -v 'MOUNT'  # MOUNT war nicht gesetzt
        TITLE="${title[i]}"   ; ARG="${arg[i]}"       ; MODE="${mode[i]}"
        IFS=';' read -r -a SOURCE <<< "${source[i]}"  ; TARGET="${target[i]}"
        FTPSRC="${ftpsrc[i]}" ; FTPMNT="${ftpmnt[i]}"
        ARCHIV="${archiv[i]}" ; BORG_PASSPHRASE="${passphrase[i]}"
        LOG="${log[i]}"       ; EXFROM="${exfrom[i]}" ; MINFREE="${minfree[i]}"
        SKIP_FULL="${skip_full[i]}" ; MINFREE_BG="${minfree_bg[i]}"
        f_configure_profile_defaults    # Standardwerte setzen (bei Bedarf)
        # Bei mehreren Profilen müssen die Werte erst gesichert und später wieder zurückgesetzt werden
        [[ -n "${mount[i]}" ]] && { _MOUNT="${MOUNT:-0}" ; MOUNT="${mount[i]}" ;}  # Eigener Einhängepunkt
        f_setup_ssh_targets  # SSH-Quellen und -Ziele einrichten
        f_validate_profile_config "$i"  # Prüfen, ob die Konfiguration gültig ist
        case "${MODE^^}" in  # ${VAR^^} ergibt Großbuchstaben!
          *) MODE='N' ; MODE_TXT='Normal'  # Vorgabe: Normaler Modus
            if [[ -n "${borg_create_opt[i]}" ]] ; then
              read -r -a _BORG_CREATE_OPT <<< "${BORG_CREATE_OPT[@]}"
              read -r -a BORG_CREATE_OPT <<< "${borg_create_opt[i]}"
            fi
          ;;
        esac  # MODE
        [[ -n "$MINFREE_BG" ]] && MODE_TXT+=" + HÜ [${MINFREE_BG} MB]"
      fi
    done
  fi
  return 0
}

f_del_old_backup() {  # Log-Dateien älter als $DEL_OLD_BACKUP Tage löschen. $1 = repository
  local -i del_old_backup="${DEL_OLD_BACKUP:-30}"
  local -a find_opts=(-maxdepth 1 -type f -mtime "+$del_old_backup" -name "*${TITLE}*")
  local stored_time current_time
  local lastcompact_flag="${1%/*}/.lastcompact_${1##*/}"  # Datei, die anzeigt, wann das letzte Mal kompaktiert wurde
  unset -v 'BORG_PRUNE_RC' 'BORG_COMPACT_RC'
  echo -e "$msgINF Lösche alte Sicherungen aus ${1}…"
  { printf "[%(%d.%m.%Y %H:%M:%S)T] Lösche alte Sicherungen aus %s…\n" "$EPOCHSECONDS" "$1"
    export BORG_PASSPHRASE

    # Alte Sicherungen löschen
    echo "$BORG_BIN prune ${BORG_PRUNE_OPT[*]} $1 ${BORG_PRUNE_OPT_KEEP[*]}"
    if ! "$BORG_BIN" prune "${BORG_PRUNE_OPT[@]}" "$1" "${BORG_PRUNE_OPT_KEEP[@]}" ; then
      BORG_PRUNE_RC=$?  # Fehlercode merken
      echo "Löschen der alten Sicherungen fehlgeschlagen! (BORG_PRUNE_OPT: ${BORG_PRUNE_OPT[*]})"
      echo "Löschen der alten Sicherungen fehlgeschlagen! (BORG_PRUNE_OPT: ${BORG_PRUNE_OPT[*]})" >> "$ERRLOG"
    fi

    # Gelöschten Speicher freigeben (Ab borg Version 1.2)
    if [[ "${BORG_VERSION[1]}" -ge 1 && "${BORG_VERSION[2]}" -ge 2 || "${BORG_VERSION[1]}" -ge 2 ]] ; then
      if [[ ! -f "$lastcompact_flag" ]]; then  # Datei existiert nicht
        echo "0" > "$lastcompact_flag"
      fi
      stored_time=$(<"$lastcompact_flag")  # Gespeicherte Zeit einlesen
      current_time=$EPOCHSECONDS  # Aktuelle Zeit in Sekunden
      if ((current_time - stored_time > $((60 * 60 * 24 * del_old_backup)) )) ; then
        echo "$BORG_BIN compact $1"
        if ! "$BORG_BIN" compact "$1" ; then
          BORG_COMPACT_RC=$?  # Fehlercode merken
          echo 'Freigeben des Speichers fehlgeschlagen!'
          echo "Freigeben des Speichers fehlgeschlagen!" >> "$ERRLOG"
        else
          echo "$current_time" > "$lastcompact_flag"  # Aktuelle Zeit speichern nur bei Erfolg
        fi
      fi
    fi

    [[ $del_old_backup -eq 0 ]] && { echo 'Löchen von Log-Dateien ist deaktiviert!' ; return ;}
    # Logdatei(en) löschen (Wenn $TITLE im Namen)
    if [[ -n "${SSH_LOG[*]}" ]] ; then
      echo "Lösche alte Logdateien (${del_old_backup} Tage) aus ${SSH_LOG[2]%/*}…"
      ssh -p "${SSH_LOG[3]:-22}" "${SSH_LOG[1]%:*}" \
        "find ${SSH_LOG[2]%/*} ${find_opts[*]} ! -name ${SSH_LOG[2]##*/} -delete -print"
    else
      echo "Lösche alte Logdateien (${del_old_backup} Tage) aus ${LOG%/*}…"
      find "${LOG%/*}" "${find_opts[@]}" ! -name "${LOG##*/}" -delete -print
    fi  # -n SSH_LOG
  } &>> "$LOG"
}

f_countdown_wait() {
  if [[ -t 1 ]] ; then
    # Länge des Strings [80] plus alle Steuerzeichen [21] (ohne \)
    printf '%-101b' "\n\e[30;46m  Profil \e[97m${TITLE}\e[30;46m wird in 5 Sekunden gestartet" ; printf '%b\n' '\e[0m'
    echo -e "\e[46m $nc Zum Abbrechen [Strg] + [C] drücken\n\e[46m $nc Zum Pausieren [Strg] + [Z] drücken (Fortsetzen mit \"fg\")\n"
    for i in {5..1} ; do  # Countdown ;)
      echo -e -n "\rStart in \e[97;44m  $i  ${nc} Sekunden"
      sleep 1
    done
    echo -e -n '\r'
  fi
  "$NOTIFY" "Sicherung startet (Profil: \"${TITLE}\")"
}

f_check_free_space() {  # Prüfen ob auf dem Ziel genug Platz ist
  local df_line df_free
  if [[ $MINFREE -gt 0 ]] ; then  # Aus *.conf
    mapfile -t < <(df -B M "$TARGET")  # Ausgabe von df (in Megabyte) in Array (Zwei Zeilen)
    read -r -a df_line <<< "${MAPFILE[1]}" ; df_free="${df_line[3]%M}"  # Drittes Element ist der freie Platz (M)
    if [[ $df_free -lt $MINFREE ]] ; then
      echo -e "$msgWRN Auf dem Ziel (${TARGET}) sind nur $df_free MegaByte frei! (MINFREE=${MINFREE})"
      echo "Auf dem Ziel (${TARGET}) sind nur $df_free MegaByte frei! (MINFREE=${MINFREE})" >> "$ERRLOG"
      if [[ -z "$SKIP_FULL" ]] ; then  # In der Konfig definiert
        echo -e "\nDie Sicherung (${TITLE}) ist vermutlich unvollständig!" >> "$ERRLOG"
        echo -e 'Bitte überprüfen Sie auch die Einträge in den Log-Dateien!\n' >> "$ERRLOG"
      else
        echo -e "\n\n => Die Sicherung (${TITLE}) wird nicht durchgeführt!" >> "$ERRLOG"
        FINISHEDTEXT='abgebrochen!'  # Text wird am Ende ausgegeben
      fi
      unset -v 'SKIP_FULL'  # Genug Platz! Variable löschen, falls gesetzt
    fi  # df_free
  elif [[ $MINFREE_BG -gt 0 ]] ; then  # Prüfung im Hintergrund
    unset -v 'SKIP_FULL'  # Löschen, falls gesetzt
    echo -e -n "$msgINF Starte Hintergrundüberwachung…"
    f_monitor_free_space &  # Prüfen, ob auf dem Ziel genug Platz ist (Hintergrundprozess)
    MFS_PID=$! ; echo " PID: $MFS_PID"  # PID merken
  fi  # MINFREE -gt 0
}

f_monitor_free_space() {  # Prüfen ob auf dem Ziel genug Platz ist (Hintergrundprozess [&])
  local df_line df_free
  while true ; do
    mapfile -t < <(df -B M "$TARGET")  # Ausgabe von df (in Megabyte) in Array (Zwei Zeilen)
    read -r -a df_line <<< "${MAPFILE[1]}" ; df_free="${df_line[3]%M}"  # Drittes Element ist der freie Platz (M)
    # echo "-> Auf dem Ziel (${TARGET}) sind $df_free MegaByte frei! (MINFREE_BG=${MINFREE_BG})"
    if [[ $df_free -lt $MINFREE_BG ]] ; then
      : > "${TMPDIR}/.stopflag"
      echo -e "$msgWRN Auf dem Ziel (${TARGET}) sind nur $df_free MegaByte frei! (MINFREE_BG=${MINFREE_BG})"
      { echo "Auf dem Ziel (${TARGET}) sind nur $df_free MegaByte frei! (MINFREE_BG=${MINFREE_BG})"
        echo -e "\n\n => Die Sicherung (${TITLE}) wird abgebrochen!" ;} >> "$ERRLOG"
      kill -TERM "$(pidof "$BORG_BIN")" 2>/dev/null
      if pgrep --exact "$BORG_BIN" ; then
        echo "$msgERR Es laüft immer noch ein borg-Prozess! Versuche zu beenden…"
        killall --exact --verbose "$BORG_BIN" 2>> "$ERRLOG"
      fi
      break  # Beenden der while-Schleife
    fi
    sleep "${MFS_TIMEOUT:-300}"  # Wenn nicht gesetzt, dann 300 Sekunden (5 Min.)
  done
  unset -v 'MFS_PID'  # Hintergrundüberwachung ist beendet
}

f_source_config() {  # Konfiguration laden
  local config_file="$1"
    # Prüfung der Konfigurationsdatei
    if ! f_validate_path "$config_file" "config" ; then
        echo -e "$msgERR Ungültige Konfigurationsdatei: $config_file${nc}" >&2
        f_exit 1
    fi
    
    # Prüfung, ob die Konfigurationsdatei world-writable ist
    if [[ $(stat -c %a "$config_file") =~ [0-9][0-9][2367] ]] ; then
        echo -e "$msgWRN Konfigurationsdatei ist 'world-writable': $config_file${nc}" >&2
        echo "Dies ist ein Sicherheitsrisiko. Bitte verwenden Sie: chmod 644 $config_file" >&2
        sleep 3
    fi
    
    # Konfigurationsdatei laden
    # shellcheck source=MV_BorgBackup.conf.dist
    if ! source "$config_file" ; then
        echo -e "$msgERR Konfiguration konnte nicht geladen werden: $config_file${nc}" >&2
        f_exit 1
    fi  
}

f_borg_check_repo() {
  local borg_repo="$1" do_init='false' repo_create_opt=("${BORG_CREATE_OPT[@]}")
  local repo_create_cmd='repo-create' repo_info_cmd='repo-info'  # Borg Version 2.x
  if [[ "$borg_repo" =~ '@' ]] ; then  # ssh
    if ! ssh "${SSH_TARGET[1]%:*}" -p "${SSH_TARGET[3]:-22}" "[ -d ${SSH_TARGET[2]} ]" ; then
      echo -e "$msgWRN Borg Repository nicht gefunden! (${borg_repo})" >&2
      do_init='true'
    fi
  elif [[ ! -d "$R_TARGET" ]] ; then   # Das Repository muss vorhanden sein
      echo -e "$msgWRN Borg Repository nicht gefunden! (${borg_repo})" >&2
      do_init='true'
  fi
  if [[ "$PROFIL" != 'customBak' && "$do_init" == 'true' ]] ; then
    if [[ "${BORG_VERSION[1]}" -eq 1 ]] ; then  # Borg Version 1.x
      repo_create_cmd='init'
      repo_create_opt=("${BORG_INIT_OPT[@]}")
      repo_info_cmd='info'
    else  # Borg Version 2.x
      if [[ !  -d "$R_TARGET" ]] ; then
        mkdir --partents "$R_TARGET" || \
          { echo -e "$msgERR Erstellen von ${R_TARGET} fehlgeschlagen!${nc}" >&2 ; f_exit 1; }
      fi
    fi
    echo -e "$msgINF Versuche das Repository anzulegen…"
    export BORG_PASSPHRASE
    if ! "$BORG_BIN" "$repo_create_cmd" "${repo_create_opt[@]}" "$borg_repo" &>/dev/null ; then
      echo -e "$msgERR Anlegen des Repostories fehlgeschlagen!${nc}" ; f_exit 1
    fi
    "$BORG_BIN" "$repo_info_cmd" --verbose "$borg_repo" &>> "$LOG"  # Daten in das Log
  fi
}

# --- START ---
[[ -e "/tmp/${SELF_NAME%.*}.log" ]] && rm --force "/tmp/${SELF_NAME%.*}.log" &>/dev/null
[[ -e "/tmp/${SELF_NAME%.*}.env" ]] && rm --force "/tmp/${SELF_NAME%.*}.env" &>/dev/null
f_errtrap OFF  # Err-Trap deaktivieren und nur loggen
SCRIPT_TIMING[0]=$SECONDS  # Startzeit merken (Sekunden)

# --- AUSFÜHRBAR? ---
if [[ ! -x "$SELF" ]] ; then
  echo -e "$msgWRN Das Skript ist nicht ausführbar!"
  echo '  Bitte folgendes ausführen: chmod +x' "$SELF" ; f_exit 1
fi

# --- LOCKING ---
if [[ $EUID -eq 0 ]] ; then  # Nur wenn 'root'
  PIDFILE="/var/run/${SELF_NAME%.*}.pid"
  if [[ -f "$PIDFILE" ]] ; then  # PID-Datei existiert
    PID="$(< "$PIDFILE")"        # PID einlesen
    if ps --pid "$PID" &>/dev/null ; then  # Skript läuft schon!
      echo -e "$msgERR Das Skript läuft bereits!\e[0m (PID: $PID)" >&2
      f_exit 4                   # Beenden aber PID-Datei nicht löschen
    else  # Prozess nicht gefunden. PID-Datei überschreiben
      echo "$$" > "$PIDFILE" \
        || { echo -e "$msgWRN Die PID-Datei konnte nicht überschrieben werden!" >&2 ;}
    fi
  else                           # PID-Datei existiert nicht. Neu anlegen
    echo "$$" > "$PIDFILE" \
      || { echo -e "$msgWRN Die PID-Datei konnte nicht erzeugt werden!" >&2 ;}
  fi  # -f PIDFILE
fi  # EUID

# --- KONFIGURATION LADEN ---
# Testen, ob Konfiguration angegeben wurde (-c …)
while getopts ":c:" opt ; do
  case "$opt" in
    c) if f_validate_path "$OPTARG" "config" ; then
         # Konfiguration wurde angegeben und ist gültig
         CONFIG="$OPTARG"
         f_source_config "$CONFIG" ; CONFLOADED='Angegebene' ; break
       else
         f_exit 1
       fi
    ;;
    ?) ;;
  esac
done

# Konfigurationsdatei laden [Wenn Skript=MV_Backup.sh Konfig=MV_Backup.conf]
if [[ -z "$CONFLOADED" ]] ; then  # Konfiguration wurde noch nicht geladen
  # Suche Konfig im aktuellen Verzeichnis, im Verzeichnis des Skripts und im eigenen etc
  CONFIG_DIRS=('.' "${SELF%/*}" "${HOME}/etc" "${0%/*}") ; CONFIG_NAME="${SELF_NAME%.*}.conf"
  for dir in "${CONFIG_DIRS[@]}" ; do
    CONFIG="${dir}/${CONFIG_NAME}"
    if [[ -f "$CONFIG" ]] ; then
      f_source_config "$CONFIG" ; CONFLOADED='Gefundene'
      break  # Die erste gefundene Konfiguration wird verwendet
    fi
  done
  if [[ -z "$CONFLOADED" ]] ; then  # Konfiguration wurde nicht gefunden
    echo -e "$msgERR Keine Konfigurationsdatei gefunden!${nc} (\"${CONFIG_DIRS[*]}\")" >&2
    f_help
  fi
fi

# Wenn eine grafische Oberfläche vorhanden ist, wird u.a. "notify-send" für Benachrichtigungen verwendet, ansonsten immer "echo"
if [[ -n "$DISPLAY" ]] ; then
  type notify-send-all &>/dev/null && NOTIFY='notify-send-all' || NOTIFY='notify-send'
  WALL='wall'
else
  NOTIFY='echo'
fi

# Borg Version auslesen und speichern
IFS=' .' read -r -a BORG_VERSION < <(${BORG_BIN} --version)  # borg 1 1 17
# Beta-Versionen werden nicht unterstützt
#if [[ "${BORG_VERSION[3]}" =~ ^[0-9] ]] ; then  # !DEBUG
#  echo -e "$msgERR Borg Testversionen werden nicht unterstützt! (Aktuell: ${BORG_VERSION[*]})" >&2
#  f_exit 1
#fi
# Ab Borg 1.4.x detailiertere Warnungen und Fehlermeldungen ausgegeben
if [[ ${BORG_VERSION[1]} -eq 1 || ${BORG_VERSION[2]} -ge '4' ]] ; then
  export BORG_EXIT_CODES='modern'  # Vorgabe ab Borg 2.0.0
fi

# --- START ANZEIGE ---
tty --silent && clear
echo -e "\e[44m \e[0;1m MV_BorgBackup${nc}\e[0;32m => Version: ${VERSION}${nc} by MegaV0lt"
# Anzeigen, welche Konfiguration geladen wurde!
echo -e "\e[46m $nc $CONFLOADED Konfiguration:\e[1m ${CONFIG}${nc}"
echo -e "\e[46m $nc Verwende: ${BORG_VERSION[0]} ${BORG_VERSION[1]}.${BORG_VERSION[2]}.${BORG_VERSION[3]}\n"
[[ $EUID -ne 0 ]] && echo -e "$msgWRN Skript ohne root-Rechte gestartet!"

# Symlink /dev/fd fehlt bei manchen Systemen (BSD, OpenWRT, ...). https://bugzilla.redhat.com/show_bug.cgi?id=814850
if [[ ! -L /dev/fd ]] ; then
  echo -e "$msgWRN Der Symbolische Link \"/dev/fd -> /proc/self/fd\" fehlt!"
  echo -e "$msgINF Erstelle Symbolischen Link \"/dev/fd\"…"
  ln --symbolic --force /proc/self/fd /dev/fd || \
    { echo -e "$msgERR Fehler beim erstellen des Symbolischen Links!${nc}" >&2 ; f_exit 1; }
fi

OPTIND=1  # Wird benötigt, weil getops ein weiteres mal verwendet wird!
optspec=':p:ac:m:sd:e:fh-:'
while getopts "$optspec" opt ; do
  case "$opt" in
    p) for i in $OPTARG ; do        # Bestimmte(s) Profil(e)
        if f_validate_profile_name "$i" ; then
          P+=("$i")
        else
          echo -e "$msgERR Ungültiger Profilparameter: $i${nc}" >&2
          f_exit 1
        fi
       done
    ;;
    a) P=("${arg[@]}") ;;           # Alle Profile
    c) ;;                           # Wurde beim Start ausgewertet
    m) # Eigene Verzeichnisse an das Skript übergeben (Letzter Pfad als Zielverzeichnis)
      if f_validate_path "${*: -1}" "target" ; then
        TARGET="${*: -1}"  # Letztes Argument als Zielverzeichnis
      else
        echo -e "$msgERR Ungültiger Zielpfad: ${*: -1}${nc}" >&2
        f_exit 1
      fi
      for i in "${@:1:${#}-1}" ; do  # Alle übergebenen Verzeichnisse außer $TARGET als Quelle
        if f_validate_path "$i" "source"; then
          f_remove_slash i          # "/" am Ende entfernen
          SOURCE+=("$i")            # Verzeichnis anhängen
        else
          echo -e "$msgERR Ungültiger Quellpfad: $i${nc}" >&2
          f_exit 1
        fi
      done
      [[ -z "${SOURCE[*]}" ]] && \
        { echo -e "$msgERR Keine Quellverzeichnisse gefunden!" >&2 ; f_exit 1 ;}
      f_remove_slash TARGET         # "/" am Ende entfernen
      P=('customBak') ; TITLE='Benutzerdefinierte Sicherung'
      LOG="${TARGET}/../${TITLE}_log.txt"
      ARCHIV="Benutzerdefiniert_{now:%Y-%m-%d_%H:%M}"
      MOUNT='' ; MODE='N' ; MODE_TXT='Benutzerdefiniert'
    ;;
    s) SHUTDOWN='true' ;;           # Herunterfahren gewählt
    d) if f_validate_numeric "$OPTARG" 0 365 "DEL_OLD_BACKUP" ; then
         DEL_OLD_BACKUP="$OPTARG"  # Tage, die erhalten bleiben
       else
         echo -e "$msgERR Ungültige Zahl für -d (0-365): $OPTARG${nc}" >&2
         f_exit 1
       fi
    ;;
    e) if f_validate_email "$OPTARG"; then
         MAILADRESS="$OPTARG"  # eMail-Adresse verwenden um Logs zu senden
       else
         echo -e "$msgERR Ungültige eMail-Adresse: $OPTARG${nc}" >&2
         f_exit 1
       fi
    ;;     
    f) MAILONLYERRORS='true' ;;     # eMail nur bei Fehlern senden
    h) f_help ;;                    # Hilfe anzeigen
    *) if [[ "$OPTERR" != 1 || "${optspec:0:1}" == ':' ]] ; then
         echo -e "$msgERR Unbekannte Option: -${OPTARG}${nc}\n" && f_help
       fi
    ;;
  esac
done

# Wenn $P leer ist, wurde die Option -p oder -a nicht angegeben
if [[ -z "${P[*]}" ]] ; then
  if [[ "${#arg[@]}" -eq 1 ]] ; then  # Wenn nur ein Profil definiert ist, dieses automatisch auswählen
    P=("${arg[@]}")   # Profil zuweisen
    msgAUTO='(auto)'  # Text zur Anzeige
  else
    echo -e "$msgERR Es wurde kein Profil angegeben!${nc}\n" >&2 ; f_help
  fi
  [[ -z "${arg[*]}" ]] && { echo -e "$msgERR arg[nr] darf nicht leer sein!${nc}" >&2 ; f_exit 1 ;}
fi

# Prüfen ob alle Profile eindeutige Buchstaben haben (arg[])
for parameter in "${arg[@]}" ; do
  [[ -z "${_arg[$parameter]+_}" ]] && { _arg[$parameter]=1 ;} \
    || { echo -e "$msgERR Profilkonfiguration ist fehlerhaft! (Keine eindeutigen Buchstaben)\n\t\t => arg[nr]=\"$parameter\" <= wird mehrfach verwendet${nc}\n" >&2 ; f_exit 1 ;}
done

# Prüfen ob alle Profile eindeutige Sicherungsziele verwenden (target[])
for parameter in "${target[@]}" ; do
  [[ -z "${_target[$parameter]+_}" ]] && { _target[$parameter]=1 ;} \
    || { echo -e "$msgERR Profilkonfiguration ist fehlerhaft! (Keine eindeutigen Sicherungsziele)\n  => \"$parameter\" <= wird mehrfach verwendet (target[nr] oder extra_target[nr])${nc}\n" >&2 ; f_exit 1 ;}
done

# Folgende Zeile auskommentieren, falls zum Herunterfahren des Computers Root-Rechte erforderlich sind
# [[ -n "$SHUTDOWN" && "$(whoami)" != "root" ]] && echo -e "$msgERR Zum automatischen Herunterfahren sind Root-Rechte erforderlich!\e[0m\n" && f_help

[[ -n "$SHUTDOWN" ]] && echo -e "  \e[1;31mDer Computer wird nach Durchführung der Sicherung(en) automatisch heruntergefahren!${nc}"

# Prüfen, ob BORG_BIN gültig ist
 if ! f_validate_path "${BORG_BIN:=borg}" "general" ; then
  # Wenn BORG_BIN nicht gesetzt ist, dann wird nach "borg" gesucht
  f_exit 1
fi

# Sind die benötigen Programme installiert?
NEEDPROGS=(find mktemp "$BORG_BIN")
[[ -n "$FTPSRC" ]] && NEEDPROGS+=(curlftpfs)
if [[ -n "$MAILADRESS" ]] ; then
  [[ "${MAILPROG^^}" == 'CUSTOMMAIL' ]] && { NEEDPROGS+=("${CUSTOM_MAIL[0]}") ;} || NEEDPROGS+=("$MAILPROG")
  [[ "$MAILPROG" == 'sendmail' ]] && NEEDPROGS+=(uuencode)
  NEEDPROGS+=(tar)
fi
for prog in "${NEEDPROGS[@]}" ; do
  type "$prog" &>/dev/null || MISSING+=("$prog")
done
if [[ -n "${MISSING[*]}" ]] ; then  # Fehlende Programme anzeigen
  echo -e "$msgERR Sie benötigen \"${MISSING[*]}\" zur Ausführung dieses Skriptes!" >&2
  f_exit 1
fi

for PROFIL in "${P[@]}" ; do  # Anzeige der Einstellungen
  f_settings

  # Wurden der Option -p gültige Argument zugewiesen?
  if [[ "$PROFIL" != "$ARG" && "$PROFIL" != 'customBak' ]] ; then
    notset="\e[1;41m -LEER- $nc"  # Anzeige, wenn nicht gesetzt
    echo -e "$msgERR Option -p wurde nicht korrekt definiert!${nc}\n" >&2
    echo -e " Profil:        \"${TITLE:-$notset}\"\n Parameter:     \"${ARG:-$notset}\""
    echo -e " Variable PROFIL: \"${PROFIL:-$notset}\"" ; f_exit 1
  fi

  # Konfiguration zu allen gewählten Profilen anzeigen
  # Länge des Strings [80] plus alle Steuerzeichen [14] (ohne \)
  printf '%-94b' "\n\e[30;46m  Konfiguration von:    \e[97m${TITLE} $msgAUTO" ; printf '%b\n' "$nc"
  echo -e "\e[46m $nc Sicherungsmodus:\e[1m\t${MODE_TXT}${nc}"
  echo -e "\e[46m $nc Quellverzeichnis(se):\e[1m\t${SOURCE[*]}${nc}"
  echo -e "\e[46m $nc Zielverzeichnis:\e[1m\t${TARGET}${nc}"
  echo -e "\e[46m $nc Log-Datei:\e[1m\t\t${SSH_LOG[0]:-${LOG}}${nc}"
  if [[ "$PROFIL" != 'customBak' ]] ; then
    echo -e "\e[46m $nc Ausschluss:"
    while read -r ; do
      echo -e "\e[46m ${nc}\t\t\t${REPLY}"
    done < "$EXFROM"
  fi
  if [[ -n "$MAILADRESS" ]] ; then  # eMail-Adresse ist angegeben
    echo -e -n "\e[46m $nc eMail-Versand an:\e[1m\t${MAILADRESS}${nc}"
    [[ "$MAILONLYERRORS" == 'true' ]] && { echo ' [NUR bei Fehler(n)]' ;} || echo ''
  elif [[ "$MAILONLYERRORS" == 'true' ]] ; then
    echo -e "\e[1;43m $nc Es wurde \e[1mkeine eMail-Adresse${nc} für den Versand bei Fehler(n) angegeben!\n"
  fi
  if [[ -n "$DEL_OLD_BACKUP" ]] ; then
    case $MODE in
      [N]) if [[ $DEL_OLD_BACKUP =~ ^[0-9]+$ ]] ; then  # Prüfen, ob eine Zahl angegeben wurde
             if [[ $DEL_OLD_BACKUP -eq 0 ]] ; then
               echo -e "$msgWRN Log-Dateien:\t\t Werden \e[1mnicht gelöscht${nc} (-d $DEL_OLD_BACKUP)"
             else
               echo -e "$msgWRN Log-Dateien:\e[1m\tLÖSCHEN wenn älter als $DEL_OLD_BACKUP Tage${nc}"
             fi
           else
             echo -e "$msgERR Keine gültige Zahl!${nc} (-d $DEL_OLD_BACKUP)" >&2 ; f_exit 1
           fi
      ;;
    esac
  fi
done

# --- PRE_ACTION ---
if [[ -n "$PRE_ACTION" ]] ; then
  echo -e "$msgINF Führe PRE_ACTION-Befehl(e) aus…"
  eval "$PRE_ACTION" || { echo "$msgWRN Fehler beim Ausführen von \"${PRE_ACTION}\"!" ; sleep 10 ;}
fi

for PROFIL in "${P[@]}" ; do
  f_settings

  if [[ "$PROFIL" != 'customBak' ]] ; then  # Nicht bei benutzerdefinierter Sicherung
    # Festplatte (Ziel) eingebunden?
    if [[ -n "$MOUNT" && "$TARGET" == "$MOUNT"* ]] ; then
      if ! mountpoint --quiet "$MOUNT" ; then
        echo -e -n "$msgINF Versuche Sicherungsziel (${MOUNT}) einzuhängen…"
        mount "$MOUNT" &>/dev/null \
          || { echo -e "\n$msgERR Das Sicherungsziel konnte nicht eingebunden werden! (RC: $?)${nc} (\"${MOUNT}\")" >&2 ; f_exit 1 ;}
        echo -e "OK.\nDas Sicherungsziel (\"${MOUNT}\") wurde erfolgreich eingehängt."
        UNMOUNT+=("$MOUNT")  # Nach Sicherung wieder aushängen (Einhängepunkt merken)
      fi  # ! mountpoint
    fi
    # Ist die Quelle ein FTP und eingebunden?
    if [[ -n "$FTPSRC" ]] ; then
      if ! mountpoint --quiet "$FTPMNT" ; then
        echo -e -n "$msgINF Versuche FTP-Quelle (${FTPSRC}) unter \"${FTPMNT}\" einzuhängen…"
        curlftpfs "$FTPSRC" "$FTPMNT" &>/dev/null    # FTP einhängen
        grep --quiet "$FTPMNT" /proc/mounts \
          || { echo -e "\n$msgERR Die FTP-Quelle konnte nicht eingebunden werden! (RC: $?)${nc} (\"${FTPMNT}\")" >&2 ; f_exit 1 ;}
        echo -e "OK.\nDie FTP-Quelle (${FTPSRC}) wurde erfolgreich unter (\"${FTPMNT}\") eingehängt."
        UMOUNT_FTP=1  # Nach Sicherung wieder aushängen
      fi  # ! mountpoint
    fi
  fi  # ! customBak

  [[ -e "${TMPDIR}/.stopflag" ]] && rm --force "${TMPDIR}/.stopflag" &>/dev/null
  unset -v 'FINISHEDTEXT' 'MFS_PID'
  printf -v dt '%(%F %R)T' -1  # Datum für die erste Zeile im Log

  case $MODE in
    N) # Normale Sicherung (inkl. customBak)
      R_TARGET="${TARGET}/${FILES_DIR}"  # Ordner für das Repository
      f_borg_check_repo "$R_TARGET"  # Prüfen, ob das Repository existiert und ggf. anlegen
      f_countdown_wait               # Countdown vor dem Start anzeigen
      if [[ $MINFREE -gt 0 || $MINFREE_BG -gt 0 ]] ; then
        f_check_free_space  # Platz auf dem Ziel überprüfen (MINFREE oder MINFREE_BG)
      fi

      # Keine Sicherung, wenn zu wenig Platz und "SKIP_FULL" gesetzt ist
      if [[ -z "$SKIP_FULL" ]] ; then
        if [[ "${BORG_VERSION[1]}" -eq 1 ]] ; then  # Borg Version 1.x
          BORG_REPO_ARCHIVE=("${R_TARGET}::${ARCHIV}")  # Repositorie und Archivname
        else  # Borg Version 2.x
          BORG_REPO_ARCHIVE=(--repo "${R_TARGET}" "${ARCHIV}")  # Repositorie und Archivname
        fi
        # Sicherung mit borg starten
        echo "==> [${dt}] - $SELF_NAME [#${VERSION}] - Start:" >> "$LOG"  # Sicher stellen, dass ein Log existiert
        echo "$BORG_BIN create ${BORG_CREATE_OPT[*]} --exclude-from=${EXFROM:-'Nicht_gesetzt'} ${BORG_REPO_ARCHIVE[*]} ${SOURCE[*]}" >> "$LOG"
        echo -e "$msgINF Starte Sicherung (borg)…"
        if [[ "$PROFIL" == 'customBak' ]] ; then  # Verzeichnisse wurden manuell übergeben
          export -n BORG_PASSPHRASE  # unexport
          "$BORG_BIN" create "${BORG_CREATE_OPT[@]}" "${BORG_REPO_ARCHIVE[@]}" "${SOURCE[@]}" &>> "$LOG"
        else
          export BORG_PASSPHRASE
          "$BORG_BIN" create "${BORG_CREATE_OPT[@]}" --exclude-from="$EXFROM" "${BORG_REPO_ARCHIVE[@]}" "${SOURCE[@]}" &>> "$LOG"
        fi
        RC=$? ; [[ $RC -ne 0 ]] && { BORGRC+=("$RC") ; BORGPROF+=("$TITLE") ;}  # Profilname und Fehlercode merken
        [[ -n "$MFS_PID" ]] && f_mfs_kill  # Hintergrundüberwachung beenden!
        if [[ -e "${TMPDIR}/.stopflag" ]] ; then
          FINISHEDTEXT='abgebrochen!'  # Platte voll!
        else  # Alte Daten nur löschen wenn nicht abgebrochen wurde!
          [[ "$RC" -lt 2 ]] && f_del_old_backup "$R_TARGET"  # Funktion zum Löschen alter Sicherungen aufrufen
          if [[ "$BORG_PRUNE_RC" -ne 0 || "$BORG_COMPACT_RC" -ne 0 ]] ; then
            echo -e "$msgERR Löschen alter Sicherungen oder Kompaktieren des Repositories fehlgeschlagen! (RC: $BORG_PRUNE_RC / $BORG_COMPACT_RC)${nc}" >&2
            BORG_PRUNE_COMPACT+=("$TITLE")  # Profilname merken
          fi
        fi  # -e .stopflag
        if [[ "$SHOWBORGINFO" == 'true' ]] ; then  # Temporär speichern für Mail-Bericht
          tempinfo="${LOG##*/}" ; tempinfo="${tempinfo%*.log}_info.txt"
          "$BORG_BIN" info --last 1 "$R_TARGET" > "${TMPDIR}/${tempinfo}"
        fi
      fi  # SKIP_FULL
    ;;
    *) # Üngültiger Modus
      echo -e "$msgERR Unbekannter Sicherungsmodus!${nc} (\"${MODE}\")" >&2
      f_exit 1
    ;;
  esac

  # Partitionstabelle sichern
  if [[ "$EUID" -eq 0 ]] && type -p sfdisk &>/dev/null ; then  # 'sfdisk' vorhanden?
    if [[ -e "${TARGET}/ReadMe.partition.table.txt" ]] ; then  # ReadMe erstellen, wenn nicht vorhanden
      { echo -e "Die Partitionstabelle wurde mit dem Skript \"${SELF_NAME}\" gesichert.\n"
        echo -e "Bitte beachten, dass die Bezeichnungen der Partitionen zwischen"
        echo -e "Systemneustarts wechseln können!"
        echo -e "Beispiel: /dev/sda kann sich in /dev/sdb ändern,"
        echo -e "          /dev/nvme0n1p1 kann sich in /dev/nvme0n2p1 ändern.\n"
        echo -e "Die Partitionstabelle wurde mit dem Befehl \"sfdisk -d\" gesichert.\n"
      } > "${TARGET}/ReadMe.partition.table.txt"
    fi
    if [[ -z "${SOURCE[*]}" ]] ; then  # Keine Quelle angegeben
      echo -e "$msgWRN Es wurde keine Quelle angegeben! (Partitionstabelle wird nicht gesichert)"
    else  # Quellen vorhanden
      echo -e "$msgINF Sichere Partitionstabellen der Quellverzeichnisse:"
      echo -e "  ${SOURCE[*]}"
      for source in "${SOURCE[@]}" ; do
        mapfile -t < <(df -P "$source")
        read -r device rest <<< "${MAPFILE[1]}"
        : "${device#/dev/}" ; dev="${_%[1-9]}"  # /dev/ und Nummer entfernen (/dev/sda1 -> sda)
        src="${source//'/'/'_'}"  # Alle '/' durch '_' ersetzen
        if ! sfdisk -d "/dev/${dev}" &> "${TARGET}/partition.table.${src}.${dev}.txt" ; then
          rm -f "${TARGET}/partition.table.${src}.${dev}.txt" &>/dev/null  # Leere Datei löschen
          dev="${dev%p}"                        # 'p' entfernen (nvme0n1p1 -> nvme0n1)
          if ! sfdisk -d "/dev/${dev}" &> "${TARGET}/partition.table.${src}.${dev}.txt" ; then
            rm -f "${TARGET}/partition.table.${src}.${dev}.txt" &>/dev/null  # Leere Datei löschen
            echo -e "\n$msgERR Die Partitionstabelle von $dev (${device}) wurde nicht erkannt!${nc}" >&2
          fi
        fi
      done
    fi
  fi

  # Log-Datei, Ziel und Name des Profils merken für Mail-Versand
  [[ -n "$MAILADRESS" ]] && { LOGFILES+=("$LOG") ; TARGETS+=("$TARGET") ; USEDPROFILES+=("$TITLE") ;}

  # Zuvor eingehängte FTP-Quelle wieder aushängen
  [[ -n "$UMOUNT_FTP" ]] && { umount "$FTPMNT" ; unset -v 'UMOUNT_FTP' ;}

  [[ ${RC:-0} -ne 0 ]] && ERRTEXT="\e[91mmit Fehler ($RC) \e[0;1m"
  echo -e -n "\a\n\n${msgINF} \e[1mProfil \"${TITLE}\" wurde ${ERRTEXT}${FINISHEDTEXT:=abgeschlossen}"
  printf ' (%(%x %X)T)\n' -1  # Datum und Zeit
  echo -e "  Weitere Informationen sind in der Datei:\n  \"${SSH_LOG[0]:-${LOG}}\" gespeichert.\n"
  if [[ -s "$ERRLOG" ]] ; then  # Existiert und ist nicht Leer
    if [[ $(stat -c %Y "$ERRLOG") -gt $(stat -c %Y "$TMPDIR") ]] ; then  # Fehler-Log merken, wenn neuer als "$TMPDIR"
      ERRLOGS+=("$ERRLOG")
      echo -e "$msgINF Fehlermeldungen wurden in der Datei:\n  \"${SSH_ERRLOG[0]:-${ERRLOG}}\" gespeichert.\n"
    fi
  else
    [[ -e "$ERRLOG" ]] && rm "$ERRLOG" &>/dev/null  # Leeres Log löschen
  fi
  unset -v 'RC' 'ERRTEXT'  # $RC und $ERRTEXT zurücksetzen
  # Falls nötig Log-Dateien zum SSH-Host kopieren
  if [[ -n "${SSH_LOG[*]}" ]] ; then
    #scp -P 2222 file.txt user@remote.host:/some/remote/directory
    [[ -e "$LOG" ]] && scp -q -P "${SSH_LOG[3]:-22}" "$LOG" "${SSH_LOG[1]%:*}:${SSH_LOG[2]}"
    [[ -e "$ERRLOG" ]] && scp -q -P "${SSH_ERRLOG[3]:-22}" "$ERRLOG" "${SSH_ERRLOG[1]%:*}:${SSH_ERRLOG[2]}"
    echo -e "$msgINF Log's wurden nach ${SSH_LOG[1]%:*}:${SSH_LOG[2]%/*} kopiert"
  fi
done # for PROFIL
SCRIPT_TIMING[1]=$SECONDS  # Zeit nach der Sicherung mit borg/tar/getfacl (Sekunden)

# --- eMail senden ---
if [[ -n "$MAILADRESS" ]] ; then
  # Variablen
  printf -v ARCH 'Logs_%(%F-%H%M)T'."${LOGARCH_FMT:=tar.xz}"  # Archiv mit Datum und Zeit (kein :)
  MAILARCHIV="${TMPDIR}/${ARCH}"              # Archiv mit Pfad
  MAILFILE="${TMPDIR}/~Mail.txt"              # Text für die eMail
  SUBJECT="[${HOSTNAME^^}] Sicherungs-Bericht von $SELF_NAME" # Betreff der Mail

  if [[ ${MAXLOGSIZE:=$((1024*1024))} -gt 0 ]] ; then  # Wenn leer dann Vorgabe 1 MB. 0 = deaktiviert
    if [[ ${#LOGFILES[@]} -ge 1 || ${#ERRLOGS[@]} -ge 1 ]]; then
      # Log(s) packen
      echo -e "$msgINF Erstelle Archiv mit $((${#LOGFILES[@]}+${#ERRLOGS[@]})) Logdatei(en):\n  \"${MAILARCHIV}\" "
      tar --create --absolute-names --auto-compress --file="$MAILARCHIV" "${LOGFILES[@]}" "${ERRLOGS[@]}"
      FILESIZE="$(stat -c %s "$MAILARCHIV" 2>/dev/null)"  # Größe des Archivs
      if [[ ${FILESIZE:-0} -gt $MAXLOGSIZE ]] ; then
        rm "$MAILARCHIV" &>/dev/null            # Archiv ist zu groß für den eMail-Versand
        MAILARCHIV="${MAILARCHIV%%.*}.txt"      # Info-Datei als Ersatz
        { echo 'Das Archiv mit den Logdateien ist zu groß für den Versand per eMail.'
          echo "Der eingestellte Wert für die Maximalgröße ist $MAXLOGSIZE Bytes."
          echo -e '\n==> Liste der lokal angelegten Log-Datei(en):'
          for file in "${LOGFILES[@]}" "${ERRLOGS[@]}" ; do
            echo "$file"
          done
        } > "$MAILARCHIV"
      fi
    fi
  else  # MAXLOGSIZE=0
    MAILARCHIV="${MAILARCHIV%%.*}.txt"  # Info-Datei
    { echo 'Das Senden von Logdateien ist deaktiviert (MAXLOGSZE=0).'
      if [[ ${#LOGFILES[@]} -ge 1 || ${#ERRLOGS[@]} -ge 1 ]]; then
        echo -e '\n==> Liste der lokal angelegten Log-Datei(en):'
        for file in "${LOGFILES[@]}" "${ERRLOGS[@]}" ; do
          echo "$file"
        done
      else
        echo -e '\n==> Es wurden keine Logdateien erstellt!'
      fi
    } > "$MAILARCHIV"
  fi

    echo -e "$msgINF Erzeuge eMail-Bericht…"  # Text der eMail erzeugen
  { echo -e "Sicherungs-Bericht von $SELF_NAME [#${VERSION}] auf ${HOSTNAME^^}.\n"
    echo -n 'Die letzte Sicherung wurde beendet. '
    [[ ${#LOGFILES[@]} -ge 1 ]] && echo "Es wurde(n) ${#LOGFILES[@]} Log-Datei(en) erstellt."
  } > "$MAILFILE"

  if [[ ${#ERRLOGS[@]} -ge 1 ]] ; then
    echo -e "\n==> Zusätzlich wurde(n) ${#ERRLOGS[@]} Fehler-Log(s) erstellt!" >> "$MAILFILE"
    SUBJECT="[${HOSTNAME^^}] FEHLER bei Sicherung von $SELF_NAME"  # Neuer Betreff der Mail bei Fehlern
  fi

  if [[ "$SHOWERRORS" == 'true' ]] ; then
    if [[ ${#BORGRC[@]} -ge 1 ]] ; then  # Profile mit Fehlern anzeigen
      echo -e '\n==> Profil(e) mit Fehler(n) bei Sicherung:' >> "$MAILFILE"
      for i in "${!BORGRC[@]}" ; do
        echo "${BORGPROF[i]} (Rückgabecode ${BORGRC[i]})" >> "$MAILFILE"
      done
      echo -e '--> Rückgabecodes ab 2 sind schwere Fehler (siehe Log)' >> "$MAILFILE"
    fi  # BORGRC
    if [[ ${#BORG_PRUNE_COMPACT[@]} -ge 1 ]] ; then  # Profil(e) mit Fehlern beim Löschen
      echo -e '\n==> Profil(e) mit Fehler(n) beim Löschen alter Sicherungen:' >> "$MAILFILE"
      for i in "${!BORG_PRUNE_COMPACT[@]}" ; do
        echo "${BORG_PRUNE_COMPACT[i]}" >> "$MAILFILE"
      done
    fi
  fi  # SHOWERRORS

  if [[ "$SHOWOS" == 'true' && -f '/etc/os-release' ]] ; then
    while read -r ; do
      [[ ${REPLY^^} =~ PRETTY_NAME ]] && { OSNAME="${REPLY/*=}"
        OSNAME="${OSNAME//\"/}" ; break ;}
    done < /etc/os-release
    { echo -e "\n==> Auf ${HOSTNAME^^} verwendetes Betriebssystem:\n${OSNAME:-'Unbekannt'}"
      echo -e "\n==> Ermittelte Version von 'borg': ${BORG_VERSION[1]:-?}.${BORG_VERSION[2]:-?}.${BORG_VERSION[3]:-?}"
    } >> "$MAILFILE"
  fi  # SHOWOS

  [[ "$SHOWOPTIONS" == 'true' ]] && echo -e "\n==> Folgende Optionen wurden verwendet:\n$*" >> "$MAILFILE"

  if [[ "$SHOWUSEDPROFILES" == 'true' ]] ; then
    if [[ ${#USEDPROFILES[@]} -eq 0 ]] ; then
      echo -e "\n==> Keine Profile zur Sicherung ausgewählt!" >> "$MAILFILE"
    else
      echo -e "\n==> Folgende Profile wurden zur Sicherung ausgewählt:" >> "$MAILFILE"
      for i in "${!USEDPROFILES[@]}" ; do
        echo "${USEDPROFILES[i]}" >> "$MAILFILE"
      done
    fi
  fi  # SHOWUSEDPROFILES

  for i in "${!TARGETS[@]}" ; do
    # Nur wenn das Verzeichnis existiert. Anzeige ist abschaltbar in der *.conf
    if [[ "$SHOWUSAGE" == 'true' && -d "${TARGETS[i]}" ]] ; then
      mapfile -t < <(df -Ph "${TARGETS[i]}")  # Ausgabe von df in Array (Zwei Zeilen)
      read -r -a TARGETLINE <<< "${MAPFILE[1]}" ; TARGETDEV="${TARGETLINE[0]}"  # Erstes Element ist das Device
      if [[ ! "${TARGETDEVS[*]}" =~ $TARGETDEV ]] ; then
        TARGETDEVS+=("$TARGETDEV")
        echo -e "\n==> Status des Sicherungsziels (${TARGETDEV}):" >> "$MAILFILE"
        echo -e "${MAPFILE[0]}\n${MAPFILE[1]}" >> "$MAILFILE"
      fi
    fi  # SHOWUSAGE  && -d TARGETS[i]
    if [[ "$SHOWCONTENT" == 'true' ]] ; then  # Auflistung ist abschaltbar in der *.conf
      LOGDIR="${LOGFILES[i]%/*}" ; [[ "${LOGDIRS[*]}" =~ $LOGDIR ]] && continue
      LOGDIRS+=("$LOGDIR")
      { echo -e "\n==> Inhalt von ${LOGDIR}:"
        ls -l --human-readable "$LOGDIR"
        # Anzeige der Belegung des Sicherungsverzeichnisses und Unterordner
        echo -e "\n==> Belegung von ${LOGDIR}:"
        du --human-readable --summarize "$LOGDIR"
        for dir in "${LOGDIR}"/*/ ; do
          du --human-readable --summarize "$dir"
          if [[ "$SHOWBORGINFO" == 'true' ]] ; then
            tempinfo="${LOGFILES[i]##*/}" ; tempinfo="${tempinfo%*.log}_info.txt"
            echo -e "\n==> Borg info:"
            cat "${TMPDIR}/${tempinfo}"  # Borg info zum Mailbericht
          fi  # SHOWBORGINFO
        done
      } >> "$MAILFILE"
    fi  # SHOWCONTENT
  done

  if [[ "$SHOWDURATION" == 'true' ]] ; then  # Auflistung ist abschaltbar in der *.conf
    SCRIPT_TIMING[2]=$SECONDS  # Zeit nach der Statistik
    SCRIPT_TIMING[10]=$((SCRIPT_TIMING[2] - SCRIPT_TIMING[0]))  # Gesamt
    SCRIPT_TIMING[11]=$((SCRIPT_TIMING[1] - SCRIPT_TIMING[0]))  # borg/tar
    SCRIPT_TIMING[12]=$((SCRIPT_TIMING[2] - SCRIPT_TIMING[1]))  # Statistik
    { echo -e '\n==> Ausführungszeiten:'
      echo "Skriptlaufzeit: $((SCRIPT_TIMING[10] / 60)) Minute(n) und $((SCRIPT_TIMING[10] % 60)) Sekunde(n)"
      echo "  Sicherung: $((SCRIPT_TIMING[11] / 60)) Minute(n) und $((SCRIPT_TIMING[11] % 60)) Sekunde(n)"
      echo "  Erstellen des Mailberichts: $((SCRIPT_TIMING[12] / 60)) Minute(n) und $((SCRIPT_TIMING[12] % 60)) Sekunde(n)"
    } >> "$MAILFILE"
  fi  # SHOWDURATION

  # eMail nur, wenn (a) MAILONLYERRORS=true und Fehler vorhanden sind oder (b) MAILONLYERRORS nicht true
  if [[ ${#ERRLOGS[@]} -ge 1 && "$MAILONLYERRORS" == 'true' || "$MAILONLYERRORS" != 'true' ]] ; then
    # eMail versenden
    echo -e "$msgINF Sende eMail an ${MAILADRESS}…"
    case "$MAILPROG" in
      mpack)  # Sende Mail mit mpack via ssmtp
        iconv --from-code=UTF-8 --to-code=iso-8859-1 --output="${MAILFILE}.x" "$MAILFILE"  #  Damit Umlaute richtig angezeigt werden
        mpack -s "$SUBJECT" -d "${MAILFILE}.x" "$MAILARCHIV" "$MAILADRESS"  # Kann "root" sein, wenn in sSMTP konfiguriert
      ;;
      sendmail)  # Variante mit sendmail und uuencode
        mail_to_send="${TMPDIR}/~mail_to_send"
        { echo "Subject: $SUBJECT" ; cat "$MAILFILE" ; uuencode "$MAILARCHIV" "$ARCH" ;} > "$mail_to_send"
        sendmail "$MAILADRESS" < "$mail_to_send"
      ;;
      send[Ee]mail)  # Variante mit "sendEmail". Keine " für die Variable $USETLS verwenden!
        sendEmail -f "$MAILSENDER" -t "$MAILADRESS" -u "$SUBJECT" -o message-file="$MAILFILE" -a "$MAILARCHIV" \
          -o message-charset=utf-8 -s "${MAILSERVER}:${MAILPORT}" -xu "$MAILUSER" -xp "$MAILPASS" "${USETLS[@]}"
      ;;
      e[Mm]ail)  # Sende Mail mit eMail (https://github.com/deanproxy/eMail)
        email -s "$SUBJECT" -attach "$MAILARCHIV" "$MAILADRESS" < "$MAILFILE"  # Die ausführbare Datei ist 'email'
      ;;
      mail)  # Sende Mail mit mail (http://j.mp/2kZlJdk)
        mail -s "$SUBJECT" -a "$MAILARCHIV" "$MAILADRESS" < "$MAILFILE"
      ;;
      custom[Mm]ail)  # Eigenes Mailprogramm verwenden. Siehe auch *.conf -> CUSTOM_MAIL
        for var in MAILADRESS SUBJECT MAILFILE MAILARCHIV ; do
          CUSTOM_MAIL=("${CUSTOM_MAIL[@]/$var/${!var}}")  # Platzhalter ersetzen
        done
        "${CUSTOM_MAIL[@]}"  # Gesamte Zeile ohne 'eval' ausführen
      ;;
      *) echo -e "\nUnbekanntes Mailprogramm: \"${MAILPROG}\"" ;;
    esac
    RC=$? ; [[ ${RC:-0} -eq 0 ]] && echo -e "\n${msgINF} Sicherungs-Bericht wurde mit \"${MAILPROG}\" an $MAILADRESS versendet.\n    Es wurde(n) ${#LOGFILES[@]} Logdatei(en) angelegt."
  fi  # MAILONLYERRORS
fi  # -n MAILADDRESS

# Zuvor eingehängte(s) Sicherungsziel(e) wieder aushängen
if [[ ${#UNMOUNT[@]} -ge 1 ]] ; then
  echo -e "$msgINF Manuell eingehängte Sicherungsziele werden wieder ausgehängt…"
  for volume in "${UNMOUNT[@]}" ; do
    mountpoint --quiet "$volume" && umount --force "$volume"
  done
fi

# --- POST_ACTION ---
if [[ -n "$POST_ACTION" ]] ; then
  echo -e "$msgINF Führe POST_ACTION-Befehl(e) aus…"
  eval "$POST_ACTION" || { echo "$msgWRN Fehler beim Ausführen von \"${POST_ACTION}\"!" ; sleep 10 ;}
  unset -v 'POST_ACTION'
fi

# Ggf. Herunterfahren
if [[ -n "$SHUTDOWN" ]] ; then
  # Möglichkeit, das automatische Herunterfahren noch abzubrechen
  "$NOTIFY" "Sicherung(en) abgeschlossen. ACHTUNG: Der Computer wird in 5 Minuten heruntergefahren. Führen Sie \"kill -9 $(pgrep "${0##*/}")\" aus, um das Herunterfahren abzubrechen."
  sleep 1
  echo "This System is going DOWN for System halt in 5 minutes! Run \"kill -9 $(pgrep "${0##*/}")\" to cancel shutdown." | $WALL
  echo -e '\a\e[1;41m ACHTUNG \e[0m Der Computer wird in 5 Minuten heruntergefahren.\n'
  echo -e 'Bitte speichern Sie jetzt alle geöffneten Dokumente oder drücken Sie \e[1m[Strg] + [C]\e[0m,\nfalls der Computer nicht heruntergefahren werden soll.\n'
  sleep 5m
  # Verschiedene Befehle zum Herunterfahren mit Benutzerrechten [muss evtl. an das eigene System angepasst werden!]
  # Alle Systeme mit HAL || GNOME DBUS || KDE DBUS || GNOME || KDE
  # Root-Rechte i. d. R. erforderlich für "halt" und "shutdown"!
  # Optimierte Reihenfolge: shutdown, halt, systemd, dann DBus/DE-spezifisch
  shutdown --halt now \
    || halt \
    || systemctl poweroff \
    || dbus-send --print-reply --system --dest=org.freedesktop.Hal /org/freedesktop/Hal/devices/computer org.freedesktop.Hal.Device.SystemPowerManagement.Shutdown \
    || dbus-send --print-reply --dest=org.gnome.SessionManager /org/gnome/SessionManager org.gnome.SessionManager.RequestShutdown \
    || dbus-send --print-reply --dest=org.kde.ksmserver /KSMServer org.kde.KSMServerInterface.logout 0 2 2 \
    || gnome-power-cmd shutdown \
    || dcop ksmserver ksmserver logout 0 2 2
else
  [[ -t 1 ]] && echo -e '\n'
  "$NOTIFY" "Sicherung(en) abgeschlossen."
fi

f_exit  # Aufräumen und beenden
