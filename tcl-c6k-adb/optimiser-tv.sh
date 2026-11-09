#!/system/bin/sh
# Optimisation ADB d'un téléviseur TCL C6K (Google TV).
# Ce script s'exécute SUR le téléviseur (shell Android), lancé par lancer.sh ou lancer.ps1 :
#   sh /data/local/tmp/tcl-opt/optimiser-tv.sh <commande> [option]
#
# Commandes :
#   audit                    état du système (mémoire, stockage, processus, paquets)
#   allegement               simulation : liste ce qui serait désactivé
#   allegement --appliquer   désactive les paquets de liste-allegement.txt
#   reglages [échelle]       animations (0.5 par défaut) + vidage des caches
#   compiler                 optimisation du code des applications (plusieurs minutes)
#   etat                     ce que ce script a modifié
#   restaurer [paquet]       annule tout, ou réactive un seul paquet

DIR=${TCL_OPT_DIR:-/data/local/tmp/tcl-opt}
LISTE="$DIR/liste-allegement.txt"
ETAT_INITIAL="$DIR/etat-initial.txt"
DESACTIVES="$DIR/desactives.txt"
JOURNAL="$DIR/journal.txt"

CLES_ANIMATION="window_animation_scale transition_animation_scale animator_duration_scale"

# Paquets jamais désactivés, même s'ils figurent dans la liste : entrées HDMI, télécommande,
# réglages d'image et de son, services Google, écran d'accueil, ou paquets pour lesquels une
# source signale une panne ou se contredit (voir README).
PROTEGES="android
com.android.settings
com.android.shell
com.android.systemui
com.android.tv.settings
com.android.vending
com.google.android.apps.tv.launcherx
com.google.android.gms
com.google.android.gsf
com.google.android.katniss
com.google.android.tungsten.setupwraith
com.google.android.tv.remote.service
com.google.android.webview
com.netflix.tokenmanager
com.tcl.autopair
com.tcl.dashboard
com.tcl.eva
com.tcl.factory.view
com.tcl.globalkeyoverlay
com.tcl.hearaid
com.tcl.initsetup
com.tcl.inputmethod.international
com.tcl.providers.config
com.tcl.suspension
com.tcl.systemserver
com.tcl.systemui.plugin
com.tcl.t_solo
com.tcl.ttvs
com.tcl.tv
com.tcl.tvinput
com.tcl.useragreement
com.tcl.waterfall.overseas
tv.mopa.ginga"

mkdir -p "$DIR" || exit 1

log() {
	echo "$*"
	echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$JOURNAL"
}

section() {
	echo
	echo "=== $* ==="
}

est_protege() {
	case "$1" in
		com.mediatek.*|com.android.providers.*) return 0 ;;
	esac
	echo "$PROTEGES" | grep -qxF "$1"
}

# Une entrée par ligne ; tout ce qui suit '#' est un commentaire.
lire_liste() {
	tr -d '\r' < "$LISTE" | sed 's/#.*//; s/[[:space:]]//g' | grep -v '^$'
}

# Enregistre les valeurs d'origine une seule fois, avant la première modification.
sauvegarder_etat() {
	[ -f "$ETAT_INITIAL" ] && return
	for cle in $CLES_ANIMATION; do
		echo "global $cle $(settings get global "$cle")"
	done > "$ETAT_INITIAL"
	pm list packages -d > "$DIR/paquets-desactives-avant.txt"
	log "Valeurs d'origine enregistrées dans $ETAT_INITIAL"
}

cmd_audit() {
	fichier="$DIR/audit-$(date +%Y%m%d-%H%M%S).txt"
	{
		section "Appareil"
		echo "Modèle   : $(getprop ro.product.model)"
		echo "Android  : $(getprop ro.build.version.release)"
		echo "Version  : $(getprop ro.build.display.id)"
		echo "Empreinte: $(getprop ro.build.fingerprint)"
		echo "Allumé   : $(uptime)"

		section "Mémoire vive"
		grep -E '^(MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo

		section "Stockage interne"
		df -h /data

		section "Mémoire par processus"
		dumpsys meminfo | head -60

		section "Processeur (charge récente)"
		dumpsys cpuinfo | head -25

		section "Animations"
		for cle in $CLES_ANIMATION; do
			echo "$cle = $(settings get global "$cle")"
		done

		section "Nombre de paquets"
		echo "Actifs     : $(pm list packages -e | wc -l)"
		echo "Désactivés : $(pm list packages -d | wc -l)"

		section "Applications installées par l'utilisateur"
		pm list packages -3 | sed 's/^package://' | sort

		section "Paquets TCL actifs"
		pm list packages -e | sed 's/^package://' | grep -i tcl | sort

		section "Paquets désactivés"
		pm list packages -d | sed 's/^package://' | sort

		if [ -f "$LISTE" ]; then
			section "Liste d'allègement : état actuel"
			cmd_allegement --simulation
		fi
	} > "$fichier" 2>&1
	echo "Audit enregistré : $fichier"
}

cmd_allegement() {
	appliquer=0
	[ "$1" = "--appliquer" ] && appliquer=1
	if [ ! -f "$LISTE" ]; then
		echo "Liste introuvable : $LISTE"
		return 1
	fi
	installes=$(pm list packages)
	actifs=$(pm list packages -e)
	[ $appliquer -eq 1 ] && sauvegarder_etat
	for p in $(lire_liste); do
		if est_protege "$p"; then
			echo "PROTÉGÉ      $p (ignoré)"
		elif ! echo "$installes" | grep -qxF "package:$p"; then
			echo "ABSENT       $p"
		elif ! echo "$actifs" | grep -qxF "package:$p"; then
			echo "DÉJÀ INACTIF $p"
		elif [ $appliquer -eq 0 ]; then
			echo "À DÉSACTIVER $p"
		else
			sortie=$(pm disable-user --user 0 "$p" 2>&1)
			case "$sortie" in
				*"new state: disabled"*)
					grep -qxF "$p" "$DESACTIVES" 2>/dev/null || echo "$p" >> "$DESACTIVES"
					log "DÉSACTIVÉ    $p"
					;;
				*)
					log "ÉCHEC        $p : $sortie"
					;;
			esac
		fi
	done
	if [ $appliquer -eq 0 ] && [ "$1" != "--simulation" ]; then
		echo
		echo "Simulation : rien n'a été modifié. Relancez avec --appliquer pour exécuter."
	fi
}

cmd_reglages() {
	echelle=${1:-0.5}
	case "$echelle" in
		0|0.5|1) ;;
		*) echo "Échelle refusée : $echelle (valeurs admises : 0, 0.5, 1)"; return 1 ;;
	esac
	sauvegarder_etat
	for cle in $CLES_ANIMATION; do
		settings put global "$cle" "$echelle" && log "RÉGLAGE      $cle = $echelle"
	done
	if pm trim-caches 999G > /dev/null 2>&1; then
		log "CACHES       vidés"
	else
		log "ÉCHEC        vidage des caches"
	fi
}

cmd_compiler() {
	log "COMPILATION  démarrée (plusieurs minutes, ne pas éteindre le téléviseur)"
	sortie=$(cmd package bg-dexopt-job 2>&1)
	code=$?
	case "$sortie" in
		*Failure*|*Exception*|*"Unknown command"*) code=1 ;;
	esac
	if [ $code -eq 0 ]; then
		log "COMPILATION  terminée $sortie"
	else
		log "ÉCHEC        compilation : $sortie"
	fi
}

cmd_etat() {
	section "Animations (valeurs actuelles)"
	for cle in $CLES_ANIMATION; do
		echo "$cle = $(settings get global "$cle")"
	done
	section "Valeurs d'origine enregistrées"
	if [ -f "$ETAT_INITIAL" ]; then cat "$ETAT_INITIAL"; else echo "(aucune modification enregistrée)"; fi
	section "Paquets désactivés par ce script"
	if [ -s "$DESACTIVES" ]; then cat "$DESACTIVES"; else echo "(aucun)"; fi
}

reactiver() {
	sortie=$(pm enable --user 0 "$1" 2>&1)
	case "$sortie" in
		*"new state: enabled"*)
			log "RÉACTIVÉ     $1"
			if [ -f "$DESACTIVES" ]; then
				grep -vxF "$1" "$DESACTIVES" > "$DESACTIVES.tmp"
				mv "$DESACTIVES.tmp" "$DESACTIVES"
			fi
			;;
		*)
			log "ÉCHEC        réactivation de $1 : $sortie"
			;;
	esac
}

cmd_restaurer() {
	if [ -n "$1" ]; then
		reactiver "$1"
		return
	fi
	if [ -s "$DESACTIVES" ]; then
		for p in $(cat "$DESACTIVES"); do
			reactiver "$p"
		done
	fi
	if [ -f "$ETAT_INITIAL" ]; then
		while read -r ns cle valeur; do
			if [ "$valeur" = "null" ] || [ -z "$valeur" ]; then
				settings delete "$ns" "$cle" > /dev/null
			else
				settings put "$ns" "$cle" "$valeur"
			fi
			log "RESTAURÉ     $cle = $valeur"
		done < "$ETAT_INITIAL"
		rm -f "$ETAT_INITIAL"
	fi
	log "Restauration terminée."
}

commande=$1
[ $# -gt 0 ] && shift
case "$commande" in
	audit) cmd_audit ;;
	allegement) cmd_allegement "$@" ;;
	reglages) cmd_reglages "$@" ;;
	compiler) cmd_compiler ;;
	etat) cmd_etat ;;
	restaurer) cmd_restaurer "$@" ;;
	*)
		sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
		exit 1
		;;
esac
