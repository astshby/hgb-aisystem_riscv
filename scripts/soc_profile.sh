# Source from the repository root. One public hardware profile, never independent device switches.
soc_profile="${SOC_PROFILE:-full}"
case "$soc_profile" in
    full) soc_profile_id=0 ;;
    lite) soc_profile_id=1 ;;
    *) echo 'SOC_PROFILE must be full or lite' >&2; exit 2 ;;
esac
